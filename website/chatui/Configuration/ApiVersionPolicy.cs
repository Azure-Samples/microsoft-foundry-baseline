using System.ClientModel.Primitives;

namespace chatui.Configuration;

/// <summary>
/// Pipeline policy that appends an api-version query parameter to every request.
/// Required because the OpenAI SDK drops query parameters from the base endpoint
/// URL when constructing request URIs through the MAF/MEAI abstraction layer.
/// </summary>
public class ApiVersionPolicy(string apiVersion) : PipelinePolicy
{
    public override void Process(PipelineMessage message, IReadOnlyList<PipelinePolicy> pipeline, int currentIndex)
    {
        AddApiVersion(message);
        ProcessNext(message, pipeline, currentIndex);
    }

    public override async ValueTask ProcessAsync(PipelineMessage message, IReadOnlyList<PipelinePolicy> pipeline, int currentIndex)
    {
        AddApiVersion(message);
        await ProcessNextAsync(message, pipeline, currentIndex);
    }

    private void AddApiVersion(PipelineMessage message)
    {
        if (message.Request.Uri is null) return;
        var uri = message.Request.Uri;
        var uriBuilder = new UriBuilder(uri);
        uriBuilder.Query = string.IsNullOrEmpty(uriBuilder.Query)
            ? $"api-version={apiVersion}"
            : $"{uriBuilder.Query.TrimStart('?')}&api-version={apiVersion}";
        message.Request.Uri = uriBuilder.Uri;
    }
}
