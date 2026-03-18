using System.ComponentModel.DataAnnotations;

namespace chatui.Configuration;

public class ChatApiOptions
{
    [Url]
    public string AgentBaseUrl { get; init; } = default!;

    public string AgentApiVersion { get; init; } = "2025-11-15-preview";

    public string AgentModelDeploymentName { get; init; } = "agent-model";
}