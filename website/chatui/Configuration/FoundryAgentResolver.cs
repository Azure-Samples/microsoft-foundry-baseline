using Azure.AI.Projects;
using Microsoft.Agents.AI.Foundry;
using Microsoft.Extensions.Options;

namespace chatui.Configuration;

#pragma warning disable OPENAI001 // FoundryAgent is experimental

public class FoundryAgentResolver : IDisposable
{
    private readonly AIProjectClient _projectClient;
    private readonly IOptionsMonitor<ChatApiOptions> _options;
    private readonly IDisposable? _changeToken;
    private volatile FoundryAgent? _agent;
    private string? _agentId;

    public FoundryAgentResolver(AIProjectClient projectClient, IOptionsMonitor<ChatApiOptions> options)
    {
        _projectClient = projectClient;
        _options = options;
        _changeToken = options.OnChange(_ => Interlocked.Exchange(ref _agent, null));
    }

    public async Task<FoundryAgent> GetAgentAsync()
    {
        var current = _agent;
        if (current is not null)
            return current;

        var id = _options.CurrentValue.AIAgentId;
        var record = await _projectClient.AgentAdministrationClient.GetAgentAsync(id);
        var agent = _projectClient.AsAIAgent(record);

        _agent = agent;
        _agentId = id;
        return agent;
    }

    public void Dispose()
    {
        _changeToken?.Dispose();
    }
}
