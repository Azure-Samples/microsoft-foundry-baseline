using System.Net;
using System.Text.Json.Serialization;
using Microsoft.Agents.AI;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.AI;

namespace chatui.Configuration;

/// <summary>
/// Cosmos DB-backed ChatHistoryProvider for MAF AgentSession persistence.
/// Stores MEAI ChatMessage objects as structured, queryable documents.
///
/// Round-trip budget per turn:
///   - ProvideChatHistoryAsync: 1 Cosmos point-read (loads messages + store ETag in StateBag)
///   - StoreChatHistoryAsync:  1 Cosmos replace (appends delta using stored ETag)
/// Total: 2 round-trips per turn.
/// </summary>
public class CosmosChatHistoryProvider(Container container) : ChatHistoryProvider
{
    private const string SessionIdKey = "CosmosChatHistory.SessionId";
    private const string MessagesKey = "CosmosChatHistory.Messages";
    private const string ETagKey = "CosmosChatHistory.ETag";

    private readonly Container _container = container;

    // ---- Controller-facing API ----

    /// <summary>
    /// Load session history from Cosmos into the AgentSession's StateBag.
    /// If the session has no prior history, the StateBag is initialized empty —
    /// the Cosmos document will be created on the first StoreChatHistoryAsync upsert.
    /// </summary>
    public async Task LoadSessionAsync(
        AgentSession session,
        string sessionId,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var response = await _container.ReadItemAsync<SessionDocument>(
                sessionId,
                new PartitionKey(sessionId),
                cancellationToken: cancellationToken);

            session.StateBag.SetValue(SessionIdKey, response.Resource.SessionId);
            session.StateBag.SetValue(MessagesKey, response.Resource.Messages);
            session.StateBag.SetValue(ETagKey, response.ETag);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            session.StateBag.SetValue(SessionIdKey, sessionId);
            session.StateBag.SetValue(MessagesKey, new List<ChatMessage>());
        }
    }

    // ---- MAF ChatHistoryProvider overrides ----

    /// <summary>
    /// Called by MAF before the agent runs. Returns previously stored messages.
    /// Data is already cached in StateBag from LoadSessionAsync.
    /// Cost: 0 Cosmos round-trips.
    /// </summary>
    protected override ValueTask<IEnumerable<ChatMessage>> ProvideChatHistoryAsync(
        InvokingContext context,
        CancellationToken cancellationToken = default)
    {
        if (context.Session?.StateBag.TryGetValue<List<ChatMessage>>(MessagesKey, out var messages) == true
            && messages is not null)
        {
            return new ValueTask<IEnumerable<ChatMessage>>(messages);
        }

        return new ValueTask<IEnumerable<ChatMessage>>(Enumerable.Empty<ChatMessage>());
    }

    /// <summary>
    /// Called by MAF after the agent runs. Appends new request + response messages to Cosmos.
    /// Uses the ETag cached from the initial read for optimistic concurrency.
    /// Cost: 1 Cosmos round-trip (replace).
    /// </summary>
    protected override async ValueTask StoreChatHistoryAsync(
        InvokedContext context,
        CancellationToken cancellationToken = default)
    {
        if (context.Session?.StateBag.TryGetValue<string>(SessionIdKey, out var sessionId) != true
            || sessionId is null)
            return;

        context.Session.StateBag.TryGetValue<List<ChatMessage>>(MessagesKey, out var existing);
        context.Session.StateBag.TryGetValue<string>(ETagKey, out var etag);

        var allMessages = existing ?? [];
        if (context.RequestMessages is not null)
            allMessages.AddRange(context.RequestMessages);
        if (context.ResponseMessages is not null)
            allMessages.AddRange(context.ResponseMessages);

        var document = new SessionDocument(sessionId, sessionId, allMessages, DateTime.UtcNow);

        var options = string.IsNullOrEmpty(etag)
            ? null
            : new ItemRequestOptions { IfMatchEtag = etag };

        var response = await _container.UpsertItemAsync(
            document,
            new PartitionKey(sessionId),
            requestOptions: options,
            cancellationToken: cancellationToken);

        // Update session state from the Cosmos response — source of truth for what was persisted
        context.Session.StateBag.SetValue(MessagesKey, response.Resource.Messages);
        context.Session.StateBag.SetValue(ETagKey, response.ETag);
    }

    private record SessionDocument(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("sessionId")] string SessionId,
        [property: JsonPropertyName("messages")] List<ChatMessage> Messages,
        [property: JsonPropertyName("createdAt")] DateTime CreatedAt);
}
