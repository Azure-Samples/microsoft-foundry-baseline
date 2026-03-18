using Microsoft.Extensions.Options;
using Azure.AI.OpenAI;
using Azure.Identity;
using chatui.Configuration;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOptions<ChatApiOptions>()
    .Bind(builder.Configuration)
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddSingleton(provider =>
{
    var config = provider.GetRequiredService<IOptions<ChatApiOptions>>().Value;
    // The GA SDK falls through to the base ResponsesClient which appends /responses
    // to the endpoint but adds neither /openai nor ?api-version. We construct the
    // endpoint up to /protocols/openai with the required api-version, then the SDK
    // appends /responses to produce the correct Foundry URL:
    //   {AgentBaseUrl}/protocols/openai/responses?api-version={AgentApiVersion}
    var endpoint = new Uri($"{config.AgentBaseUrl.TrimEnd('/')}/protocols/openai?api-version={config.AgentApiVersion}");
    var options = new AzureOpenAIClientOptions { Audience = "https://ai.azure.com" };
    AzureOpenAIClient azureClient = new(endpoint, new DefaultAzureCredential(), options);

    #pragma warning disable OPENAI001 // Responses API is in preview
    return azureClient.GetResponsesClient();
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