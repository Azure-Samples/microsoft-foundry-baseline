using Microsoft.AspNetCore.Mvc;
using Microsoft.Agents.AI;
using chatui.Configuration;

namespace chatui.Controllers;

[ApiController]
[Route("[controller]/[action]")]

public class ChatController(
    AIAgent agent,
    CosmosChatHistoryProvider sessionProvider,
    ILogger<ChatController> logger) : ControllerBase
{
    private readonly AIAgent _agent = agent;
    private readonly CosmosChatHistoryProvider _sessionProvider = sessionProvider;
    private readonly ILogger<ChatController> _logger = logger;

    [HttpPost]
    public async Task<IActionResult> Responses([FromBody] ResponsesRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Message))
            throw new ArgumentException("A message is required.");

        // Fresh AgentSession per request — conversation state lives in Cosmos.
        // LoadOrCreateSessionAsync populates the StateBag from Cosmos (existing session)
        // or initializes it empty (new session, document created on first upsert).
        var session = await _agent.CreateSessionAsync();
        await _sessionProvider.LoadSessionAsync(session, request.SessionId);

        _logger.LogDebug("Prompt received {Prompt}", request.Message);

        var result = await _agent.RunAsync(request.Message, session);

        return Ok(new { data = result.ToString() });
    }

    [HttpPost]
    public IActionResult Sessions()
    {
        var sessionId = Guid.NewGuid().ToString();
        _logger.LogDebug("Session created {SessionId}", sessionId);

        return Ok(new { sessionId });
    }
}

public record ResponsesRequest(string Message, string SessionId);
