using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using OpenAI.Responses;
using chatui.Configuration;

namespace chatui.Controllers;

#pragma warning disable OPENAI001 // Responses API is in preview

[ApiController]
[Route("[controller]/[action]")]

public class ChatController(
    ResponsesClient responsesClient,
    IOptionsMonitor<ChatApiOptions> options,
    ILogger<ChatController> logger) : ControllerBase
{
    private readonly ResponsesClient _responsesClient = responsesClient;
    private readonly IOptionsMonitor<ChatApiOptions> _options = options;
    private readonly ILogger<ChatController> _logger = logger;

    [HttpPost]
    public async Task<IActionResult> Responses([FromBody] ResponsesRequest request)
    {
        if (request.Messages is not { Length: > 0 })
            throw new ArgumentException("At least one message is required.");
        _logger.LogDebug("Prompt received {Prompt}", request.Messages[^1].Content);

        var items = request.Messages.Select(m => m.Role switch
        {
            "user" => ResponseItem.CreateUserMessageItem(m.Content),
            "assistant" => ResponseItem.CreateAssistantMessageItem(m.Content),
            _ => throw new ArgumentException($"Unsupported message role: {m.Role}")
        }).ToList();

        var response = await _responsesClient.CreateResponseAsync(model: _options.CurrentValue.AgentModelDeploymentName, items);
        var fullText = response.Value.GetOutputText();

        return Ok(new { data = fullText });
    }
}

public record ChatMessage(string Role, string Content);
public record ResponsesRequest(ChatMessage[] Messages);