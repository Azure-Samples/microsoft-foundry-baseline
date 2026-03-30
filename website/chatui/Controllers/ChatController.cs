using Microsoft.AspNetCore.Mvc;
using Microsoft.Agents.AI;
using chatui.Configuration;
using AIChatMessage = Microsoft.Extensions.AI.ChatMessage;
using AIChatRole = Microsoft.Extensions.AI.ChatRole;

namespace chatui.Controllers;

[ApiController]
[Route("[controller]/[action]")]

public class ChatController(
    AIAgent agent,
    ILogger<ChatController> logger) : ControllerBase
{
    private readonly AIAgent _agent = agent;
    private readonly ILogger<ChatController> _logger = logger;

    [HttpPost]
    public async Task<IActionResult> Responses([FromBody] ResponsesRequest request)
    {
        if (request.Messages is not { Length: > 0 })
            throw new ArgumentException("At least one message is required.");
        _logger.LogDebug("Prompt received {Prompt}", request.Messages[^1].Content);

        // Build ChatMessage[] directly — the ResponseItem overload's AsChatMessages()
        // merges items with null MessageId into one message, breaking multi-turn.
        var chatMessages = request.Messages.Select<ChatMessage, AIChatMessage>(m => m.Role switch
        {
            "user" => new(AIChatRole.User, m.Content),
            "assistant" => new(AIChatRole.Assistant, m.Content),
            _ => throw new ArgumentException($"Unsupported message role: {m.Role}")
        }).ToList();

        var response = await _agent.RunAsync(chatMessages);
        var fullText = response.AsOpenAIResponse().GetOutputText();

        return Ok(new { data = fullText });
    }
}

public record ChatMessage(string Role, string Content);
public record ResponsesRequest(ChatMessage[] Messages);