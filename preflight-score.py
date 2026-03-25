#!/usr/bin/env python3
"""Preflight scoring: VM + storage + app service + model + vCPU → ranked region candidates."""

import argparse, json, os, re, sys
from collections import defaultdict
from dataclasses import dataclass, asdict
from typing import Optional, List, Tuple

# ── Scoring constants ────────────────────────────────────────────────────────
# Every constraint yields 0 (eliminated), 1 (degraded), or 2 (perfect).
MAX_SCORE = 2

def _effective(score):
    """Treat None (unevaluated) as MAX_SCORE for comparisons."""
    return score if score is not None else MAX_SCORE


# ── Candidate dataclass ──────────────────────────────────────────────────────

_FIELD_MAP = {
    "vm_s": "vm_score", "vm_n": "vm_name",
    "zone_s": "zone_score", "zone_n": "zone_name",
    "app_s": "app_score", "app_n": "app_name",
    "model_s": "model_score", "model_n": "model_name",
    "vcpu_s": "vcpu_score", "vcpu_n": "vcpu_name",
    "vmr_s": "vmr_score", "vmr_n": "vmr_name",
    "appq_s": "appq_score", "appq_n": "appq_name",
    "sto": "sto_scores",
    "p1": "p1_score",
    "app_zr": "app_zr_score",
}


@dataclass
class Candidate:
    loc: str
    vm_score: int
    vm_name: str
    sto_scores: List[Tuple[int, str]]
    zone_score: Optional[int] = None
    zone_name: Optional[str] = None
    app_score: Optional[int] = None
    app_zr_score: Optional[int] = None
    app_name: Optional[str] = None
    p1_score: int = 0
    model_score: int = 0
    model_name: str = ""
    vcpu_score: int = 0
    vcpu_name: str = ""
    vmr_score: Optional[int] = None
    vmr_name: Optional[str] = None
    appq_score: Optional[int] = None
    appq_name: Optional[str] = None
    total: int = 0

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> 'Candidate':
        mapped = {}
        for k, v in d.items():
            mapped[_FIELD_MAP.get(k, k)] = v
        # Convert sto_scores entries back to tuples
        if "sto_scores" in mapped:
            mapped["sto_scores"] = [tuple(s) for s in mapped["sto_scores"]]
        return cls(**{k: v for k, v in mapped.items()
                      if k in cls.__dataclass_fields__})


# ── Alternative mappings ─────────────────────────────────────────────────────

STORAGE_SKU_ALTS = {
    "Standard_GZRS":   ["Standard_GRS", "Standard_RAGRS", "Standard_LRS"],
    "Standard_ZRS":    ["Standard_LRS"],
    "Standard_RAGZRS": ["Standard_RAGRS", "Standard_GRS", "Standard_LRS"],
    "Standard_GRS":    ["Standard_LRS"],
    "Standard_LRS":    [],
}

MODEL_TIER_ALTS = {
    "Standard":         ["DataZoneStandard", "GlobalStandard"],
    "DataZoneStandard": ["Standard", "GlobalStandard"],
    "GlobalStandard":   ["Standard", "DataZoneStandard"],
}

# Fallback: same gen first, then next gen, then down-tier
APP_SKU_ALTS = {
    "P3V3": ["P2V3", "P1V3", "P0V3", "P3V4", "P2V4", "P1V4", "P0V4", "S1"],
    "P2V3": ["P1V3", "P0V3", "P2V4", "P1V4", "P0V4", "S1"],
    "P1V3": ["P0V3", "P1V4", "P0V4", "S1"],
    "P0V3": ["P0V4", "S1"],
    "P1V4": ["P0V4", "S1"],
    "P0V4": ["S1"],
    "S1":   [],
}

# Premium V3+ SKUs support zone redundancy
ZONE_REDUNDANT_APP_SKUS = {
    "P0V3", "P1V3", "P2V3", "P3V3",
    "P1MV3", "P2MV3", "P3MV3", "P4MV3", "P5MV3",
    "P0V4", "P1V4", "P2V4", "P3V4",
    "P1MV4", "P2MV4", "P3MV4", "P4MV4", "P5MV4",
}

# ── Region normalization ──────────────────────────────────────────────────────

def _normalize_loc(name):
    """Normalize any Azure region name to ARM format: 'East US' → 'eastus'."""
    return name.lower().replace(" ", "")

# ── VM SKU parsing ────────────────────────────────────────────────────────────

def parse_vm_sku(vm_sku):
    """Parse Standard_D2s_v3 → (family='D', cores=2, flags='s', gen=3) or None.
    Supports multi-letter families like DC, NC, NV, HB."""
    m = re.match(r"Standard_([A-Z]+)(\d+)([a-z]*)_v(\d+)", vm_sku)
    if not m:
        return None
    return m.group(1), int(m.group(2)), m.group(3), int(m.group(4))


def vm_family_pattern(fam, flags):
    """Regex matching same family: Standard_{fam}{cores}{flags}_v{gen}."""
    return re.compile(rf"^Standard_{re.escape(fam)}(\d+){re.escape(flags)}_v(\d+)$")


def vcpu_family_name(fam, flags, gen):
    """Azure vCPU family name: 'Standard DSv3 Family vCPUs'."""
    return f"Standard {fam}{flags.upper()}v{gen} Family vCPUs"


# ── VM scoring ───────────────────────────────────────────────────────────────

def _vm_candidates_by_region(vm_json, vm_sku):
    """All compatible VMs per region, sorted best-first.
    Returns {region: [(score, sku), ...]}.  Shared by Phase 1 and Phase 2."""
    fam, cores, flags, gen = parse_vm_sku(vm_sku)
    pat = vm_family_pattern(fam, flags)

    by_region = defaultdict(list)
    for entry in vm_json:
        loc = _normalize_loc(entry["loc"])
        match = pat.match(entry["name"])
        if not match:
            continue
        alt_cores, alt_gen = int(match.group(1)), int(match.group(2))
        if alt_cores < cores:
            continue
        score = 2 if entry["name"] == vm_sku else 1
        by_region[loc].append((score, alt_cores, alt_gen, entry["name"]))

    result = {}
    for loc, entries in by_region.items():
        entries.sort(key=lambda x: (-x[0], x[1], -x[2]))
        result[loc] = [(s, sku) for s, _, _, sku in entries]
    return result


def score_vm(vm_json, vm_sku):
    """Score every region by best available VM. Returns {region: (score, sku)}."""
    return {loc: alts[0] for loc, alts in _vm_candidates_by_region(vm_json, vm_sku).items()}

# ── Storage scoring ──────────────────────────────────────────────────────────

def score_storage(sto_json, required_skus):
    """Score every region per required storage SKU.
    Returns [{region: (score, sku_short)}, ...] one dict per SKU."""
    sku_regions = defaultdict(set)
    for entry in sto_json:
        for loc in entry.get("locs", entry.get("locations", [])):
            sku_regions[entry["name"]].add(_normalize_loc(loc))

    results = []
    for exact in required_skus:
        scored = {}
        alts = STORAGE_SKU_ALTS.get(exact, [])
        all_locs = set(sku_regions.get(exact, set()))
        for alt in alts:
            all_locs.update(sku_regions.get(alt, set()))
        for loc in all_locs:
            if loc in sku_regions.get(exact, set()):
                scored[loc] = (2, exact.replace("Standard_", ""))
            else:
                for alt in alts:
                    if loc in sku_regions.get(alt, set()):
                        scored[loc] = (1, alt.replace("Standard_", ""))
                        break
        results.append(scored)
    return results

# ── App Service scoring ──────────────────────────────────────────────────────

def score_app_service(pf_dir, app_sku):
    """Score App Service Plan availability per region.
    Returns {region: (sku_score, zr_score, display)}.
    sku_score: 2=exact, 1=fallback. zr_score: 2=ZR preserved, 1=ZR lost."""
    alts = APP_SKU_ALTS.get(app_sku, [])
    req_zr = app_sku in ZONE_REDUNDANT_APP_SKUS

    def load_locs(sku):
        path = os.path.join(pf_dir, f"app-{sku}.json")
        if not os.path.exists(path):
            return set()
        with open(path) as f:
            return {_normalize_loc(e["name"]) for e in json.load(f)}

    exact_locs = load_locs(app_sku)
    result = {loc: (2, 2, app_sku) for loc in exact_locs}
    for alt in alts:
        zr_lost = req_zr and alt not in ZONE_REDUNDANT_APP_SKUS
        zr_score = 1 if zr_lost else 2
        display = f"{alt}+noZR" if zr_lost else alt
        for loc in load_locs(alt):
            if loc not in result:
                result[loc] = (1, zr_score, display)
    return result

# ── Zone scoring ─────────────────────────────────────────────────────────────

def score_zones(pf_dir):
    """Score availability zones per region from zones.json.
    Returns {region: (score, display)} — 2=≥3 AZs, 1=1-2 AZs, 0=none.
    Display uses z[1,2,3] or z[1,_,3] format."""
    path = os.path.join(pf_dir, "zones.json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        data = json.load(f)
    result = {}
    for r in data:
        loc = _normalize_loc(r["name"])
        zones = r.get("zones") or []
        if len(zones) >= 3:
            result[loc] = (2, f"z[{','.join(str(z) for z in sorted(zones)[:3])}]")
        elif len(zones) >= 1:
            avail = {str(z) for z in zones}
            slots = [str(z) if str(z) in avail else "_" for z in ["1", "2", "3"]]
            result[loc] = (1, f"z[{','.join(slots)}]")
        # 0 AZs → not included (hard-eliminated)
    return result

# ── Model scoring ────────────────────────────────────────────────────────────

def _parse_model_quotas(data, exclude_tokens=()):
    """Parse raw az cognitiveservices usage list → {(model_api, tier): limit}.
    API naming: OpenAI.{Tier}.{model} where model uses dots (gpt4.1 not gpt-4.1).
    exclude_tokens: substrings that make a model name not applicable (e.g. finetune)."""
    quotas = {}
    for entry in data:
        name_val = entry.get("name", {})
        if isinstance(name_val, dict):
            name_val = name_val.get("value", "")
        limit = entry.get("limit", 0)
        if limit <= 0:
            continue
        parts = name_val.split(".")
        if len(parts) < 3:
            continue
        tier = parts[1]
        model_api = ".".join(parts[2:]).lower().replace("-", "")
        if any(tok in tier.lower() or tok in model_api for tok in exclude_tokens):
            continue
        quotas[(model_api, tier)] = limit
    return quotas


def score_model(model_json_path, model_name, model_tier, exclude_tokens=()):
    """Score model quota. Returns (score, display_name).
    2 = exact model + exact tier
    1 = alt tier, or smaller model (substring containment: gpt4.1 in gpt4.1mini)
    0 = nothing."""
    if not os.path.exists(model_json_path):
        return 0, "-"
    with open(model_json_path) as f:
        quotas = _parse_model_quotas(json.load(f), exclude_tokens)

    model_api = model_name.replace("-", "")
    tier_alts = MODEL_TIER_ALTS.get(model_tier, [])

    # Exact model + exact tier → 2
    if (model_api, model_tier) in quotas:
        return 2, f"{model_name}/{model_tier}"

    # Exact model + alt tier → 1
    for alt_tier in tier_alts:
        if (model_api, alt_tier) in quotas:
            return 1, f"{model_name}/{alt_tier}"

    # Smaller model via containment (gpt4.1 ⊂ gpt4.1mini) + exact tier → 1
    for (avail_api, avail_tier), _ in quotas.items():
        if avail_api != model_api and model_api in avail_api and avail_tier == model_tier:
            return 1, f"{avail_api}/{avail_tier}"

    # Smaller model via containment + alt tier → 1
    for (avail_api, avail_tier), _ in quotas.items():
        if avail_api != model_api and model_api in avail_api and avail_tier in tier_alts:
            return 1, f"{avail_api}/{avail_tier}"

    return 0, "-"


def has_model_quota(model_json_path, model_name, model_tier, exclude_tokens=()):
    """Quick check: any usable quota for this model family?"""
    score, _ = score_model(model_json_path, model_name, model_tier, exclude_tokens)
    return score > 0

# ── vCPU scoring ─────────────────────────────────────────────────────────────

def score_vcpu(vcpu_json_path, vm_sku_for_region):
    """Score vCPU from raw az vm list-usage. Derives family name dynamically
    from the VM SKU that Phase 1 chose for this region (may be alt gen).
    Returns (score, display) — 2=sufficient, 0=insufficient."""
    parsed = parse_vm_sku(vm_sku_for_region)
    if not parsed:
        return 0, "-"
    fam, cores, flags, gen = parsed
    family_name = vcpu_family_name(fam, flags, gen)

    if not os.path.exists(vcpu_json_path):
        return 0, "-"
    with open(vcpu_json_path) as f:
        data = json.load(f)

    for entry in data:
        local_name = entry.get("localName", "")
        if not local_name:
            name_val = entry.get("name", {})
            if isinstance(name_val, dict):
                local_name = name_val.get("localizedValue", "")
        if local_name.lower() != family_name.lower():
            continue
        current = int(entry.get("currentValue", 0))
        limit = int(entry.get("limit", 0))
        remaining = limit - current
        if remaining >= cores:
            return 2, f"{remaining} free"
        return 0, f"{remaining} free!"

    return 0, "-"


def score_vm_vcpu(vcpu_json_path, vm_alts):
    """Jointly resolve VM + vCPU. Walks vm_alts (best-first list of
    (vm_score, sku) from _vm_candidates_by_region) and returns the first
    VM whose family has sufficient vCPU quota.
    Returns (vm_score, vm_name, vcpu_score, vcpu_name)."""
    for vm_score, sku in vm_alts:
        vcpu_score, vcpu_name = score_vcpu(vcpu_json_path, sku)
        if vcpu_score > 0:
            return vm_score, sku, vcpu_score, vcpu_name
    # None had quota — return the best VM with its failing vCPU info
    if vm_alts:
        best_score, best_sku = vm_alts[0]
        vcpu_score, vcpu_name = score_vcpu(vcpu_json_path, best_sku)
        return best_score, best_sku, vcpu_score, vcpu_name
    return 0, "-", 0, "-"


def score_vm_restrictions(restr_json_path, vm_sku):
    """Score VM SKU subscription restrictions from Compute/skus REST API.
    Looks up vm_sku in the full regional SKU list. If restricted, tries same-family
    alternatives (same pattern as score_vm Phase 1 fallback).
    Returns (score, display) — 2=unrestricted, 1=fallback unrestricted, 0=all restricted.
    Display includes available zones when zone-restricted."""
    if not os.path.exists(restr_json_path):
        return 2, "ok"
    with open(restr_json_path) as f:
        data = json.load(f)

    # Build lookups: sku_name → {restrictions, zones}
    sku_info = {}
    for e in data:
        sku_info[e["name"]] = {
            "restrictions": e.get("restrictions", []),
            "zones": set(e.get("zones") or []),
        }

    def _zone_display(all_zones, avail):
        """Format zone availability: z[1,2,3] or z[1,_,3] for gaps."""
        slots = [str(z) if str(z) in avail else "_" for z in ["1", "2", "3"]]
        return f"z[{','.join(slots)}]"

    def _available_zones(sku):
        """Return (is_blocked, display) for a SKU."""
        info = sku_info.get(sku)
        if not info:
            return True, "missing"
        all_zones = info["zones"]
        for r in info["restrictions"]:
            if r.get("reasonCode") == "NotAvailableForSubscription":
                return True, "restricted"
            if r.get("type") == "Location":
                return True, "restricted"
            if r.get("type") == "Zone":
                blocked = set(r.get("restrictionInfo", {}).get("zones", []))
                avail = sorted(all_zones - blocked)
                if not avail:
                    return True, "no zones"
                return False, _zone_display(all_zones, set(avail))
        return False, _zone_display(all_zones, all_zones) if all_zones else "ok"

    # Exact SKU
    blocked, display = _available_zones(vm_sku)
    if not blocked:
        return 2, display

    # Walk family fallback
    parsed = parse_vm_sku(vm_sku)
    if not parsed:
        return 0, "restricted"
    fam, cores, flags, _ = parsed
    pat = vm_family_pattern(fam, flags)

    alts = []
    for name in sku_info:
        match = pat.match(name)
        if match and int(match.group(1)) >= cores and name != vm_sku:
            alts.append((int(match.group(1)), int(match.group(2)), name))
    alts.sort(key=lambda x: (x[0], -x[1]))

    for _, _, alt_name in alts:
        blocked, display = _available_zones(alt_name)
        if not blocked:
            return 1, f"{alt_name} {display}"
    return 0, "restricted"


def score_app_quota(appquota_json_path, app_sku, capacity=3):
    """Score App Service Plan quota from Microsoft.Web usages API.
    Returns (score, display) — 2=uncapped (deploy as requested), 0=restricted (eliminate).

    Only signal we trust: no per-SKU entry for our SKU and *=0 → truly uncapped.
    Any restriction signal → eliminate (API data unreliable for fallback).
    """
    if not os.path.exists(appquota_json_path):
        return 2, "ok"
    with open(appquota_json_path) as f:
        data = json.load(f)

    total_limit = 0
    sku_limit = None
    for entry in data:
        name = entry.get("name", {}).get("value", "")
        limit = entry.get("limit", 0)
        if name == "*":
            total_limit = limit
        elif name and name.lower() == app_sku.lower():
            sku_limit = limit

    # Regional cap active → eliminate
    if total_limit > 0:
        return 0, f"cap {total_limit}"

    # Per-SKU restricted → eliminate
    if sku_limit is not None and sku_limit < capacity:
        return 0, f"limit {sku_limit}"

    return 2, "ok"

# ── Output formatting ────────────────────────────────────────────────────────

def _mark(score, name):
    if score == 2: return f"✓ {name}"
    if score == 1: return f"~ {name}"
    return f"✗ {name}"


def _all_scores(c):
    """Collect all constraint scores for a candidate (Phase 2)."""
    scores = [c.vm_score] + [score for score, _ in c.sto_scores]
    if c.zone_score is not None:
        scores.append(c.zone_score)
    if c.app_score is not None:
        scores.append(c.app_score)
        scores.append(c.app_zr_score)
    scores += [c.model_score, c.vcpu_score]
    if c.vmr_score is not None:
        scores.append(c.vmr_score)
    if c.appq_score is not None:
        scores.append(c.appq_score)
    return scores


def print_phase1(candidates, max_p1, sto_skus, show_all):
    has_app = candidates and candidates[0].app_score is not None
    has_zones = candidates and candidates[0].zone_score is not None
    sto_hdrs = [f"sto-{i+1}" for i in range(len(sto_skus))]
    hdr = f"  {'region':<22} {'p1':>4}  {'vm':<18}" + "".join(f"  {h:<12}" for h in sto_hdrs)
    sep = f"  {'─'*22} {'─'*4}  {'─'*18}" + "".join(f"  {'─'*12}" for _ in sto_hdrs)
    if has_zones:
        hdr += f"  {'zones':<10}"
        sep += f"  {'─'*10}"
    if has_app:
        hdr += f"  {'app':<10}"
        sep += f"  {'─'*10}"

    print(f"\nPhase 1: {len(candidates)} candidates (max {max_p1} pts)")
    print(hdr)
    print(sep)

    for i, c in enumerate(candidates):
        line = f"  {c.loc:<22} {c.p1_score:>2}/{max_p1}  {_mark(c.vm_score, c.vm_name):<18}"
        line += "".join(f"  {_mark(score, name):<12}" for score, name in c.sto_scores)
        if has_zones:
            line += f"  {_mark(c.zone_score, c.zone_name):<10}"
        if has_app:
            line += f"  {_mark(c.app_score, c.app_name):<10}"
        print(line)
        if not show_all and i >= 14:
            rem = len(candidates) - i - 1
            if rem > 0:
                print(f"  ... {rem} more (ALL=true)")
            break

    print(f"\n→ {len(candidates)} candidates for Phase 2 (model quota)")


def print_final(scored, max_total, sto_skus, model_name, show_all):
    has_app = scored and scored[0].app_score is not None
    has_zones = scored and scored[0].zone_score is not None
    sto_hdrs = [f"sto-{i+1}" for i in range(len(sto_skus))]
    hdr  = f"  {'region':<22} {'pts':>5}  {'vm':<32}  {'vcpu':<10}"
    hdr += "".join(f"  {h:<12}" for h in sto_hdrs)
    if has_zones:
        hdr += f"  {'zones':<10}"
    if has_app:
        hdr += f"  {'app':<10}"
    hdr += f"  {'model'}"
    sep  = f"  {'─'*22} {'─'*5}  {'─'*32}  {'─'*10}"
    sep += "".join(f"  {'─'*12}" for _ in sto_hdrs)
    if has_zones:
        sep += f"  {'─'*10}"
    if has_app:
        sep += f"  {'─'*10}"
    sep += f"  {'─'*24}"

    print(f"Final: {len(scored)} regions with model quota (max {max_total} pts)")
    print(hdr)
    print(sep)

    for i, c in enumerate(scored):
        delta = sum(1 for s in _all_scores(c) if s == 1)
        vm_score = min(c.vm_score, _effective(c.vmr_score))
        vmr_display = c.vmr_name if c.vmr_name is not None else "ok"
        if _effective(c.vmr_score) == 1:
            vm_name = vmr_display
        elif vmr_display.startswith("z["):
            vm_name = f"{c.vm_name} {vmr_display}"
        else:
            vm_name = c.vm_name
        line  = f"  {c.loc:<22} {c.total:>2}/{max_total}  {_mark(vm_score, vm_name):<32}  {_mark(c.vcpu_score, c.vcpu_name):<10}"
        line += "".join(f"  {_mark(score, name):<12}" for score, name in c.sto_scores)
        if has_zones:
            line += f"  {_mark(c.zone_score, c.zone_name):<10}"
        if has_app:
            app_score = min(c.app_score, _effective(c.appq_score))
            app_name = (c.appq_name or c.app_name) if _effective(c.appq_score) < MAX_SCORE else c.app_name
            line += f"  {_mark(app_score, app_name):<10}"
        line += f"  {_mark(c.model_score, c.model_name)}"
        if delta > 0:
            line += f"  Δ{delta}"
        print(line)
        if not show_all and i >= 14:
            rem = len(scored) - i - 1
            if rem > 0:
                print(f"  ... {rem} more (ALL=true)")
            break

    perfect = [c for c in scored if c.total == max_total]
    if perfect:
        print(f"\n✓ Deploy to: {perfect[0].loc} (0 Bicep changes)")
    elif scored:
        best = scored[0]
        delta = sum(1 for s in _all_scores(best) if s == 1)
        print(f"\n~ Best fallback: {best.loc} ({delta} Bicep change{'s' if delta != 1 else ''})")
    else:
        print(f"\n✗ No regions found with {model_name} quota.")
    return len(scored) > 0

# ── Subcommands ──────────────────────────────────────────────────────────────

def _parse_model_args(args):
    """Extract model name, tier, and exclude tokens from parsed args."""
    if "/" not in args.model:
        sys.exit(f"error: --model must be model/tier (e.g. gpt-4.1/Standard), got '{args.model}'")
    model_name, model_tier = args.model.split("/", 1)
    exclude = [t.strip() for t in args.model_exclude.split(",") if t.strip()]
    return model_name, model_tier, exclude


def _load_phase1(pf_dir):
    """Load phase1.json → (meta, candidates)."""
    with open(os.path.join(pf_dir, "phase1.json")) as f:
        data = json.load(f)
    return data["meta"], [Candidate.from_dict(c) for c in data["candidates"]]


def _load_vm_alts(pf_dir, vm_sku):
    """Load vm.json and return per-region VM alternatives.
    Returns {region: [(score, sku), ...]} sorted best-first."""
    vm_path = os.path.join(pf_dir, "vm.json")
    if not os.path.exists(vm_path):
        return {}
    with open(vm_path) as f:
        return _vm_candidates_by_region(json.load(f), vm_sku)


def _load_hard_filters(pf_dir):
    """Load optional hard-filter sets: AI Search, CogSvc S0.
    Returns (search, cogsvc) — each a set of region names or None."""
    def _load(filename):
        path = os.path.join(pf_dir, filename)
        if not os.path.exists(path):
            return None
        with open(path) as f:
            return json.load(f)

    search = cogsvc = None

    data = _load("search.json")
    if data:
        search = {_normalize_loc(loc) for loc in data}

    data = _load("cogsvc.json")
    if data:
        cogsvc = {_normalize_loc(loc) for loc in data}

    return search, cogsvc


def _passes_hard_filters(loc, zones, search, cogsvc, sto_maps, app):
    """Check if a location passes all Phase 1 hard filters."""
    if zones is not None and loc not in zones:
        return False
    if search is not None and loc not in search:
        return False
    if cogsvc is not None and loc not in cogsvc:
        return False
    for sto_map in sto_maps:
        if loc not in sto_map:
            return False
    if app and loc not in app:
        return False
    return True


def _build_candidate(loc, vm_score, vm_name, sto_maps, zones, app):
    """Assemble a Phase 1 Candidate with all sub-scores."""
    sto_scores = [sto_map[loc] for sto_map in sto_maps]
    entry = Candidate(loc=loc, vm_score=vm_score, vm_name=vm_name, sto_scores=sto_scores)
    p1 = vm_score + sum(score for score, _ in sto_scores)
    if zones is not None:
        entry.zone_score, entry.zone_name = zones[loc]
        p1 += entry.zone_score
    if app:
        entry.app_score, entry.app_zr_score, entry.app_name = app[loc]
        p1 += entry.app_score + entry.app_zr_score
    entry.p1_score = p1
    return entry


def cmd_candidates(args):
    """Score and rank regions by VM + storage + app service availability."""
    sto_skus = args.storage.split(",")
    pf_dir = os.path.dirname(args.sto_json)

    with open(args.vm_json) as f:
        vm_data = json.load(f)

    with open(args.sto_json) as f:
        sto_data = json.load(f)

    vm = score_vm(vm_data, args.vm_sku)
    sto = score_storage(sto_data, sto_skus)
    app = score_app_service(pf_dir, args.app_sku) if args.app_sku else {}
    zones = score_zones(pf_dir)
    search, cogsvc = _load_hard_filters(pf_dir)

    print(f"  VM: {len(vm)} regions with compatible SKUs")
    for i, sto_map in enumerate(sto):
        print(f"  Storage-{i+1} ({sto_skus[i]}): {len(sto_map)} regions")
    if app:
        exact = sum(1 for score, _, _ in app.values() if score == 2)
        alt = sum(1 for score, _, _ in app.values() if score == 1)
        print(f"  App Service ({args.app_sku}): {exact} exact, {alt} fallback")
    if zones is not None:
        az3 = sum(1 for score, _ in zones.values() if score == 2)
        print(f"  Zones (≥3 AZ): {az3}, degraded: {len(zones) - az3}")
    if search is not None:
        print(f"  AI Search (standard): {len(search)} regions")
    if cogsvc is not None:
        print(f"  AI Foundry (S0): {len(cogsvc)} regions")

    candidates = []
    for loc, (vm_score, vm_name) in vm.items():
        if not _passes_hard_filters(loc, zones, search, cogsvc, sto, app):
            continue
        candidates.append(_build_candidate(loc, vm_score, vm_name, sto, zones, app))

    candidates.sort(key=lambda r: (-r.p1_score, r.loc))
    max_p1 = MAX_SCORE + MAX_SCORE * len(sto_skus) + (MAX_SCORE if zones else 0) + (2 * MAX_SCORE if app else 0)

    print_phase1(candidates, max_p1, sto_skus, args.all)
    with open(os.path.join(pf_dir, "phase1.json"), "w") as f:
        json.dump({"meta": {"sto_skus": sto_skus, "max_p1": max_p1,
                            "app_sku": args.app_sku,
                            "app_capacity": args.app_capacity,
                            "vm_sku": args.vm_sku},
                    "candidates": [c.to_dict() for c in candidates]}, f)


def cmd_filter(args):
    """Quick yes/no: does this region have usable model quota?"""
    model_name, model_tier, exclude = _parse_model_args(args)
    path = os.path.join(args.pf_dir, f"{args.region}.model")
    print("yes" if has_model_quota(path, model_name, model_tier, exclude) else "no")


def cmd_delta(args):
    """Score a single region after Phase 2 data is cached. Prints delta or NO-VIABLE."""
    model_name, model_tier, exclude = _parse_model_args(args)
    meta, candidates = _load_phase1(args.pf_dir)
    app_sku = meta.get("app_sku")
    app_capacity = meta.get("app_capacity", 3)
    vm_alts = _load_vm_alts(args.pf_dir, meta.get("vm_sku", ""))

    for c in candidates:
        if c.loc != args.region:
            continue
        c.model_score, c.model_name = score_model(
            os.path.join(args.pf_dir, f"{args.region}.model"),
            model_name, model_tier, exclude)
        region_alts = vm_alts.get(c.loc, [(c.vm_score, c.vm_name)])
        c.vm_score, c.vm_name, c.vcpu_score, c.vcpu_name = score_vm_vcpu(
            os.path.join(args.pf_dir, f"{args.region}.vcpu"), region_alts)
        c.vmr_score, c.vmr_name = score_vm_restrictions(
            os.path.join(args.pf_dir, f"{args.region}.skurestr"), c.vm_name)
        if app_sku:
            c.appq_score, c.appq_name = score_app_quota(
                os.path.join(args.pf_dir, f"{args.region}.appquota"), app_sku, app_capacity)
        scores = _all_scores(c)
        if all(s > 0 for s in scores):
            print(sum(1 for s in scores if s == 1))
        else:
            # Report first failing check
            checks = [("model", c.model_score),
                      ("vCPU", c.vcpu_score),
                      ("VM SKU", _effective(c.vmr_score)),
                      ("app quota", _effective(c.appq_score))]
            failed = next((n for n, s in checks if s == 0), "unknown")
            print(f"NO-VIABLE:{failed}")
        return
    print("MISSING")


def cmd_report(args):
    """Full Phase 2 table: score model + vCPU for all candidates."""
    model_name, model_tier, exclude = _parse_model_args(args)
    meta, candidates = _load_phase1(args.pf_dir)
    app_sku = meta.get("app_sku")
    app_capacity = meta.get("app_capacity", 3)
    vm_alts = _load_vm_alts(args.pf_dir, meta.get("vm_sku", ""))

    p2_extra = 3 * MAX_SCORE  # model + vcpu + vmr
    scored = []
    for c in candidates:
        loc = c.loc
        # Only include regions that were evaluated in Phase 2
        p2_files = [f"{loc}.model", f"{loc}.vcpu", f"{loc}.skurestr"]
        if app_sku:
            p2_files.append(f"{loc}.appquota")
        if not all(os.path.exists(os.path.join(args.pf_dir, f)) for f in p2_files):
            continue
        c.model_score, c.model_name = score_model(
            os.path.join(args.pf_dir, f"{loc}.model"),
            model_name, model_tier, exclude)
        region_alts = vm_alts.get(loc, [(c.vm_score, c.vm_name)])
        c.vm_score, c.vm_name, c.vcpu_score, c.vcpu_name = score_vm_vcpu(
            os.path.join(args.pf_dir, f"{loc}.vcpu"), region_alts)
        c.vmr_score, c.vmr_name = score_vm_restrictions(
            os.path.join(args.pf_dir, f"{loc}.skurestr"), c.vm_name)
        if app_sku:
            c.appq_score, c.appq_name = score_app_quota(
                os.path.join(args.pf_dir, f"{loc}.appquota"), app_sku, app_capacity)
            p2_extra = 4 * MAX_SCORE  # model + vcpu + vmr + appq
        c.total = sum(_all_scores(c))
        if c.model_score > 0 and c.vcpu_score > 0 and c.vmr_score > 0 and _effective(c.appq_score) > 0:
            scored.append(c)
    scored.sort(key=lambda c: (-c.total, c.loc))
    found = print_final(scored, meta["max_p1"] + p2_extra, meta["sto_skus"], model_name, args.all)
    if not found:
        sys.exit(1)

# ── CLI ──────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description="Preflight scoring engine")
    sub = p.add_subparsers(dest="cmd", required=True)

    # Shared argument groups
    model_parent = argparse.ArgumentParser(add_help=False)
    model_parent.add_argument("--model", required=True, help="model/tier (e.g. gpt-4.1/Standard)")
    model_parent.add_argument("--model-exclude", default="", help="Comma-separated exclusion tokens")

    p1 = sub.add_parser("candidates", help="Rank regions by VM, storage, app service availability")
    p1.add_argument("--vm-sku", required=True)
    p1.add_argument("--storage", required=True)
    p1.add_argument("--vm-json", required=True)
    p1.add_argument("--sto-json", required=True)
    p1.add_argument("--app-sku", required=True)
    p1.add_argument("--app-capacity", type=int, default=3, help="App Service Plan instance count")
    p1.add_argument("--all", action="store_true")

    hm = sub.add_parser("filter", parents=[model_parent], help="Pass/fail model quota gate for one region")
    hm.add_argument("--pf-dir", required=True)
    hm.add_argument("region")

    ck = sub.add_parser("delta", parents=[model_parent], help="Bicep change count for one region")
    ck.add_argument("--pf-dir", required=True)
    ck.add_argument("region")

    fn = sub.add_parser("report", parents=[model_parent], help="Full results table with all constraints")
    fn.add_argument("--pf-dir", required=True)
    fn.add_argument("--all", action="store_true")

    args = p.parse_args()
    {"candidates": cmd_candidates,
     "filter": cmd_filter, "delta": cmd_delta, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
