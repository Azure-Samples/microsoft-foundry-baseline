#!/bin/bash
# preflight.sh — Best-first branch & bound region finder + name availability.
#
# Prerequisites: az (Azure CLI, logged in), jq, curl, python3
#
# Usage:
#   BASE_NAME=edoras
#   VM_SKU=Standard_D2s_v3 \
#   STORAGE=Standard_GZRS,Standard_ZRS \
#   MODEL=gpt-4.1/Standard \
#   APP_SKU=P1V3 \
#   STA_NAME=stagent$BASE_NAME \
#   STW_NAME=stwebapp$BASE_NAME \
#   KV_NAME=kv-$BASE_NAME \
#   CDB_NAME=cdb-ai-agent-threads-$BASE_NAME \
#   AIS_NAME=ais-ai-agent-vector-store-$BASE_NAME \
#   MODEL_EXCLUDE=batch,developer,finetune,embedding,rerank \
#   MAX_DELTA=2 \
#   ./preflight.sh
#
# Finds the best Azure region for deploying this reference implementation by:
#   Phase 1 — Scores all regions on VM SKU, storage, App Service, and zone
#             availability using global APIs.
#   Phase 2 — Probes top candidates (best-first) for model quota, vCPU
#             headroom, SKU restrictions, and App Service quota.
# Also checks global name availability for storage, Key Vault, Cosmos DB,
# and AI Search resources. Prints a ranked table and recommends a region.

set -euo pipefail

: "${VM_SKU:?}" "${STORAGE:?}" "${MODEL:?}" "${APP_SKU:?}" "${BASE_NAME:?}"
: "${STA_NAME:?}" "${STW_NAME:?}" "${KV_NAME:?}" "${CDB_NAME:?}" "${AIS_NAME:?}"
MAX_DELTA="${MAX_DELTA:-0}"
APP_CAPACITY="${APP_CAPACITY:-3}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$DIR/.preflight"
SUB_ID=$(az account show --query id -o tsv)
mkdir -p "$PF"

SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

spin() {
  local msg="$1" pid="$2" i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${SPIN[$((i % 10))]} %s" "$msg" >&2
    i=$((i + 1)); sleep 0.1
  done
  if [[ $i -gt 0 ]]; then
    local len=$(( ${#msg} + 4 ))  # 4 = "  X " prefix (2 spaces + spinner char + space)
    printf "\r%${len}s\r" "" >&2
  fi
}

await_job() {
  local label="$1" pid="$2" fallback="${3:-}"
  spin "$label" "$pid"
  if ! wait "$pid" 2>/dev/null; then
    [[ -n "$fallback" ]] && echo "$fallback" > "$PF/${label}.fallback"
  fi
}

normalize_availability() {
  local file="$1" value="$2"
  # CosmosDB returns inverted: true=taken, false=available
  if [[ "$file" == *"name-cdb.txt" ]]; then
    [[ "$value" == "false" ]] && echo "true" || echo "false"
  else
    echo "$value"
  fi
}

fetch_region_quotas() {
  local region="$1"
  local vcpu_pid sku_pid appq_pid
  az vm list-usage --location "$region" -o json > "$PF/${region}.vcpu" 2>/dev/null &
  vcpu_pid=$!
  az rest --method get --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq '${region}'" -o json 2>/dev/null | jq "[.value[] | select(.resourceType==\"virtualMachines\") | {name, restrictions, zones: .locationInfo[0].zones}]" > "$PF/${region}.skurestr" 2>/dev/null &
  sku_pid=$!
  az rest --method get --url "/subscriptions/${SUB_ID}/providers/Microsoft.Web/locations/${region}/usages?api-version=2025-05-01" --query value -o json > "$PF/${region}.appquota" 2>/dev/null &
  appq_pid=$!
  await_job "$region — quota + SKU" $vcpu_pid "[]"
  wait $sku_pid 2>/dev/null || echo "[]" > "$PF/${region}.skurestr"
  wait $appq_pid 2>/dev/null || echo "[]" > "$PF/${region}.appquota"
}

collect_name_availability() {
  for name in "${!NAME_JOBS[@]}"; do
    IFS=: read -r file pid <<< "${NAME_JOBS[$name]}"
    spin "name checks" "$pid"
    wait "$pid" 2>/dev/null || true
  done

  echo ""
  echo "Name availability (baseName=${BASE_NAME}):"

  NAMES_OK=true
  for name in "${!NAME_JOBS[@]}"; do
    IFS=: read -r file pid <<< "${NAME_JOBS[$name]}"
    avail=$(cat "$file" 2>/dev/null || echo "false")
    avail=$(normalize_availability "$file" "$avail")
    if [[ "$avail" == "true" ]]; then
      printf "  ✓ %s\n" "$name"
    else
      printf "  ✗ %s\n" "$name"
      NAMES_OK=false
    fi
  done

  if [[ "$NAMES_OK" == "false" ]]; then
    echo ""
    echo "  ✗ Some names are taken. Pick a different base name."
  else
    echo "  ✓ All names available"
  fi

  # Bing Grounding G1 (limit: 1 per subscription)
  if [[ -n "${BING_PID:-}" ]]; then
    wait "$BING_PID" 2>/dev/null || true
    BING_COUNT=$(cat "$PF/bing.txt" 2>/dev/null || echo "0")
    if [[ "$BING_COUNT" -gt 0 ]]; then
      echo ""
      echo "  ⚠ Bing Grounding G1 already exists (limit: 1 per subscription)"
    fi
  fi
}

fetch_vm_skus() {
  local pattern="${1%_v*}_v"  # Standard_D2s_v3 → Standard_D2s_v
  local out="$2"
  local filter="serviceName eq 'Virtual Machines' and contains(armSkuName,'${pattern}') and priceType eq 'Consumption'"
  local encoded; encoded=$(jq -rn --arg f "$filter" '$f | @uri')
  local url="https://prices.azure.com/api/retail/prices?\$filter=${encoded}"
  local tmp; tmp=$(mktemp)
  while [[ -n "$url" ]]; do
    local page; page=$(curl -sf "$url")
    echo "$page" | jq -c '.Items[] | {name: .armSkuName, loc: .armRegionName}' >> "$tmp"
    url=$(echo "$page" | jq -r '.NextPageLink // empty')
  done
  jq -s 'unique_by([.name, .loc])' "$tmp" > "$out"
  rm -f "$tmp"
}

fetch_name_availability() {
  az storage account check-name --name "${STA_NAME}" --query nameAvailable -o tsv > "$PF/name-sta.txt" 2>/dev/null &
  NAME_JOBS["${STA_NAME}"]="$PF/name-sta.txt:$!"

  az storage account check-name --name "${STW_NAME}" --query nameAvailable -o tsv > "$PF/name-stw.txt" 2>/dev/null &
  NAME_JOBS["${STW_NAME}"]="$PF/name-stw.txt:$!"

  az keyvault check-name --name "${KV_NAME}" --query nameAvailable -o tsv > "$PF/name-kv.txt" 2>/dev/null &
  NAME_JOBS["${KV_NAME}"]="$PF/name-kv.txt:$!"

  az cosmosdb check-name-exists --name "${CDB_NAME}" > "$PF/name-cdb.txt" 2>/dev/null &
  NAME_JOBS["${CDB_NAME}"]="$PF/name-cdb.txt:$!"

  az search service check-name-availability --name "${AIS_NAME}" --type searchServices --query nameAvailable -o tsv > "$PF/name-ais.txt" 2>/dev/null &
  NAME_JOBS["${AIS_NAME}"]="$PF/name-ais.txt:$!"

  az resource list --resource-type "Microsoft.Bing/accounts" --query "length(@)" -o tsv > "$PF/bing.txt" 2>/dev/null &
  BING_PID=$!
}

fetch_phase1_data() {
  fetch_vm_skus "$VM_SKU" "$PF/vm.json" &
  VM_PID=$!

  az storage sku list --query "[?resourceType=='storageAccounts'].{name:name,locs:locations}" -o json > "$PF/sto.json" 2>/dev/null &
  STO_PID=$!

  az appservice list-locations --linux-workers-enabled --sku "$APP_SKU" -o json > "$PF/app-${APP_SKU}.json" 2>/dev/null &
  APP_PID=$!

  APP_ALT_PID=""
  if [[ "$APP_SKU" != "S1" ]]; then
    az appservice list-locations --linux-workers-enabled --sku S1 -o json > "$PF/app-S1.json" 2>/dev/null &
    APP_ALT_PID=$!
  fi

  az account list-locations --query "[?metadata.regionType=='Physical'].{name:name,zones:availabilityZoneMappings[*].logicalZone}" -o json > "$PF/zones.json" 2>/dev/null &
  ZONES_PID=$!

  az provider show --namespace Microsoft.Search --query "resourceTypes[?resourceType=='searchServices'].locations[]" -o json > "$PF/search.json" 2>/dev/null &
  SEARCH_PID=$!

  az cognitiveservices account list-skus --kind AIServices --query "[?name=='S0'].locations[0]" -o json > "$PF/cogsvc.json" 2>/dev/null &
  COGSVC_PID=$!

  await_job "VM SKUs (retail API)" $VM_PID
  await_job "storage + app service" $STO_PID
  await_job "storage + app service" $APP_PID
  if [[ -n "$APP_ALT_PID" ]]; then
    await_job "storage + app service" $APP_ALT_PID
  fi
  await_job "zones + search + AI services" $ZONES_PID
  wait $SEARCH_PID 2>/dev/null || true
  wait $COGSVC_PID 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo "Requirements: vm=${VM_SKU} storage=${STORAGE} model=${MODEL} app=${APP_SKU} max-delta=${MAX_DELTA}"

declare -A NAME_JOBS  # name → file:pid
fetch_name_availability

echo ""
echo "Phase 1: scanning..."
fetch_phase1_data

# ── Score and rank ────────────────────────────────────────────────────────────

python3 "$DIR/preflight-score.py" candidates --vm-sku "$VM_SKU" --storage "$STORAGE" --app-sku "$APP_SKU" --app-capacity "$APP_CAPACITY" --vm-json "$PF/vm.json" --sto-json "$PF/sto.json" ${ALL:+--all}

# ── Phase 2: model quota + vCPU (per-region, best-first) ─────────────────────

echo ""
echo "Phase 2: model quota + vCPU (best-first)..."

CANDIDATES=$(python3 -c "import json; [print(c['loc']) for c in json.load(open('$PF/phase1.json'))['candidates']]")
COUNT=0

for REGION in $CANDIDATES; do
  COUNT=$((COUNT + 1))

  # Model quota check
  az cognitiveservices usage list --location "$REGION" -o json > "$PF/${REGION}.model" 2>/dev/null &
  MODEL_PID=$!
  await_job "$REGION — model" $MODEL_PID "[]"

  HAS_MODEL=$(python3 "$DIR/preflight-score.py" filter --model "$MODEL" --pf-dir "$PF" ${MODEL_EXCLUDE:+--model-exclude "$MODEL_EXCLUDE"} "$REGION")

  if [[ "$HAS_MODEL" != "yes" ]]; then
    echo "  ✗ $REGION — no model quota"
    continue
  fi

  # vCPU + SKU restriction + App Service quota (parallel)
  fetch_region_quotas "$REGION"

  RESULT=$(python3 "$DIR/preflight-score.py" delta --model "$MODEL" --pf-dir "$PF" ${MODEL_EXCLUDE:+--model-exclude "$MODEL_EXCLUDE"} "$REGION")

  if [[ "$RESULT" == NO-VIABLE* ]]; then
    REASON="${RESULT#NO-VIABLE:}"
    [[ "$REASON" == "$RESULT" ]] && REASON="unknown"
    echo "  ✗ $REGION — no ${REASON}"
  else
    echo "  ✓ $REGION — model + vCPU (Δ${RESULT})"
  fi

  if [[ "$RESULT" != NO-VIABLE* && "$RESULT" -le "$MAX_DELTA" && "${ALL:-}" != "true" ]]; then
    echo "  → Good enough (Δ${RESULT} ≤ ${MAX_DELTA}) after $COUNT regions"
    break
  fi
done

# ── Final output ──────────────────────────────────────────────────────────────

echo ""
PREFLIGHT_RC=0
python3 "$DIR/preflight-score.py" report --model "$MODEL" --pf-dir "$PF" ${MODEL_EXCLUDE:+--model-exclude "$MODEL_EXCLUDE"} ${ALL:+--all} || PREFLIGHT_RC=$?

collect_name_availability

exit "$PREFLIGHT_RC"
