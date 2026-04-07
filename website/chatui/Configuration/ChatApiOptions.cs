using System.ComponentModel.DataAnnotations;

namespace chatui.Configuration;

public class ChatApiOptions
{
    [Url]
    public string AIProjectEndpoint { get; init; } = default!;

    [Required]
    public string AIAgentId { get; init; } = default!;

    [Required]
    public string AIAgentVersion { get; init; } = default!;
}