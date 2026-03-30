using Microsoft.Extensions.AI;
using OpenAI.Responses;

namespace chatui.Configuration;

#pragma warning disable OPENAI001 // Responses API is in preview

/// <summary>
/// Rewrites assistant messages to use input_text content on the wire.
/// The published Foundry endpoint rejects output_text (which MEAI produces
/// for assistant messages). This middleware intercepts before serialization
/// and sets RawRepresentation to a user message item with input_text,
/// leveraging MEAI's passthrough mechanism.
/// Remove this middleware once the platform accepts output_text in input.
/// </summary>
public class InputTextAssistantChatClient(IChatClient inner) : DelegatingChatClient(inner)
{
    public override Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null,
        CancellationToken cancellationToken = default)
        => base.GetResponseAsync(RewriteAssistantMessages(messages), options, cancellationToken);

    public override IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null,
        CancellationToken cancellationToken = default)
        => base.GetStreamingResponseAsync(RewriteAssistantMessages(messages), options, cancellationToken);

    private static List<ChatMessage> RewriteAssistantMessages(IEnumerable<ChatMessage> messages)
        => messages.Select(m =>
        {
            if (m.Role != ChatRole.Assistant) return m;

            var text = string.Join("", m.Contents.OfType<TextContent>().Select(t => t.Text));
            var wireItem = ResponseItem.CreateUserMessageItem(
                [ResponseContentPart.CreateInputTextPart($"assistant_message: {text}")]);
            return new ChatMessage(ChatRole.Assistant,
                [new TextContent(text) { RawRepresentation = wireItem }]);
        }).ToList();
}
