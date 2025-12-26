using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using Azure.AI.Projects;
using Azure.AI.Projects.OpenAI;
using OpenAI.Responses;
using chatui.Configuration;

namespace chatui.Controllers;

[ApiController]
[Route("[controller]/[action]")]

public class ChatController(
    AIProjectClient projectClient,
    IOptionsMonitor<ChatApiOptions> options,
    ILogger<ChatController> logger) : ControllerBase
{
    private readonly AIProjectClient _projectClient = projectClient;
    private readonly IOptionsMonitor<ChatApiOptions> _options = options;
    private readonly ILogger<ChatController> _logger = logger;

    // TODO: [security] Do not trust client to provide conversationId. Instead map current user to their active converstaionid in your application's own state store.
    // Without this security control in place, a user can inject messages into another user's conversation.
    [HttpPost("{conversationId}")]
    public async Task<IActionResult> Completions([FromRoute] string conversationId, [FromBody] string message)
    {
        if (string.IsNullOrWhiteSpace(message))
            throw new ArgumentException("Message cannot be null, empty, or whitespace.", nameof(message));
        _logger.LogDebug("Prompt received {Prompt}", message);

        #pragma warning disable OPENAI001
        MessageResponseItem userMessageResponseItem = ResponseItem.CreateUserMessageItem(
            [ResponseContentPart.CreateInputTextPart(message)]);

        var _config = _options.CurrentValue;
        AgentRecord agentRecord = await _projectClient.Agents.GetAgentAsync(_config.AIAgentId);
        var agent = agentRecord.Versions.Latest;

        ProjectResponsesClient responsesClient
            = _projectClient.OpenAI.GetProjectResponsesClientForAgent(agent, conversationId);

        var agentResponseItem = await responsesClient.CreateResponseAsync([userMessageResponseItem]);

        var fullText = agentResponseItem.Value.GetOutputText();

        return Ok(new { data = fullText });
    }

    [HttpPost]
    public async Task<IActionResult> Conversations()
    {
        // TODO [performance efficiency] Delay creating a conversation until the first user message arrives.
        ProjectConversationCreationOptions conversationOptions = new();

        ProjectConversation conversation
                = await _projectClient.OpenAI.Conversations.CreateProjectConversationAsync(
                    conversationOptions);

        return Ok(new { id = conversation.Id });
    }
}