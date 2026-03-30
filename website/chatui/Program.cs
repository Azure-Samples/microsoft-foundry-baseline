using Microsoft.Extensions.Options;
using Azure.Identity;
using OpenAI;
using System.ClientModel;
using System.ClientModel.Primitives;
using Microsoft.Agents.AI;
using OpenAI.Responses;
using chatui.Configuration;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOptions<ChatApiOptions>()
    .Bind(builder.Configuration)
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddSingleton<AIAgent>(provider =>
{
    var config = provider.GetRequiredService<IOptions<ChatApiOptions>>().Value;
    var baseUrl = new Uri($"{config.AgentBaseUrl.TrimEnd('/')}/protocols/openai");

    // TODO: Token is fetched once at startup and will expire. Replace with a
    // delegating handler or token-refresh wrapper for production use.
    var token = new DefaultAzureCredential()
        .GetToken(new Azure.Core.TokenRequestContext(["https://ai.azure.com/.default"]));

    var options = new OpenAIClientOptions { Endpoint = baseUrl };
    options.AddPolicy(new ApiVersionPolicy(config.AgentApiVersion), PipelinePosition.BeforeTransport);

    var agentName = new Uri(config.AgentBaseUrl).Segments[^1].TrimEnd('/');

    #pragma warning disable OPENAI001, MAAI001
    return new OpenAIClient(new ApiKeyCredential(token.Token), options)
        .GetResponsesClient(config.AgentModelDeploymentName)
        .AsAIAgent(
            name: agentName,
            clientFactory: inner => new InputTextAssistantChatClient(inner));
});

builder.Services.AddControllersWithViews();

builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowAllOrigins",
        builder =>
        {
            builder.AllowAnyOrigin()
                   .AllowAnyMethod()
                   .AllowAnyHeader();
        });
});

var app = builder.Build();

app.UseStaticFiles();

app.UseRouting();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}");

app.UseCors("AllowAllOrigins");

app.Run();