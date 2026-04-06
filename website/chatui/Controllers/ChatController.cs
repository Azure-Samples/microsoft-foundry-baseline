using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using Azure.AI.Projects;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry;
using chatui.Configuration;

namespace chatui.Controllers;

[ApiController]
[Route("[controller]/[action]")]
public class ChatController(
    AIProjectClient projectClient,
    IOptionsMonitor<ChatApiOptions> options,
    ILogger<ChatController> logger) : ControllerBase
{
    // TODO: [security] Do not trust client to provide conversationId. Instead map current user to their active conversationId in your application's own state store.
    // Without this security control in place, a user can inject messages into another user's conversation.
    [HttpPost("{conversationId}")]
    public async Task<IActionResult> Responses([FromRoute] string conversationId, [FromBody] string message)
    {
        if (string.IsNullOrWhiteSpace(message))
            throw new ArgumentException("Message cannot be null, empty, or whitespace.", nameof(message));
        logger.LogDebug("Prompt received {Prompt}", message);

        FoundryAgent agent = await ResolveAgentAsync();

        var innerAgent = agent.GetService<ChatClientAgent>()!;
        var session = await innerAgent.CreateSessionAsync(conversationId);
        var response = await agent.RunAsync(message, session);

        return Ok(new { data = response.ToString() });
    }

    [HttpPost]
    public async Task<IActionResult> Conversations()
    {
        // TODO [performance efficiency] Delay creating a conversation until the first user message arrives.
        FoundryAgent agent = await ResolveAgentAsync();

        var session = await agent.CreateConversationSessionAsync();

        return Ok(new { id = session.ConversationId });
    }

    private async Task<FoundryAgent> ResolveAgentAsync()
    {
        var config = options.CurrentValue;
        var agentRecord = await projectClient.AgentAdministrationClient.GetAgentAsync(config.AIAgentId);
        return projectClient.AsAIAgent(agentRecord);
    }
}