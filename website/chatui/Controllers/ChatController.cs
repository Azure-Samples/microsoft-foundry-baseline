using System.Collections.Concurrent;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Agents.AI;

namespace chatui.Controllers;

[ApiController]
[Route("[controller]/[action]")]

public class ChatController(
    AIAgent agent,
    ConcurrentDictionary<string, AgentSession> sessions,
    ILogger<ChatController> logger) : ControllerBase
{
    private readonly AIAgent _agent = agent;
    private readonly ConcurrentDictionary<string, AgentSession> _sessions = sessions;
    private readonly ILogger<ChatController> _logger = logger;

    [HttpPost]
    public async Task<IActionResult> Responses([FromBody] ResponsesRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Message))
            throw new ArgumentException("A message is required.");

        if (!_sessions.TryGetValue(request.SessionId, out var session))
            return BadRequest(new { error = "Invalid session. Create one via POST /chat/sessions." });

        _logger.LogDebug("Prompt received {Prompt}", request.Message);

        var result = await _agent.RunAsync(request.Message, session);

        return Ok(new { data = result.ToString() });
    }

    [HttpPost]
    public async Task<IActionResult> Sessions()
    {
        var sessionId = Guid.NewGuid().ToString();
        var session = await _agent.CreateSessionAsync();
        _sessions[sessionId] = session;
        _logger.LogDebug("Session created {SessionId}", sessionId);

        return Ok(new { sessionId });
    }
}

public record ResponsesRequest(string Message, string SessionId);
