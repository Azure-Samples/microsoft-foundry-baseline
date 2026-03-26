using Microsoft.Extensions.Options;
using Azure.Identity;
using OpenAI;
using System.ClientModel;
using chatui.Configuration;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOptions<ChatApiOptions>()
    .Bind(builder.Configuration)
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddSingleton(provider =>
{
    var config = provider.GetRequiredService<IOptions<ChatApiOptions>>().Value;
    var baseUrl = new Uri($"{config.AgentBaseUrl.TrimEnd('/')}/protocols/openai?api-version={config.AgentApiVersion}");

    // TODO: Token is fetched once at startup and will expire. Replace with a
    // delegating handler or token-refresh wrapper for production use.
    var token = new DefaultAzureCredential()
        .GetToken(new Azure.Core.TokenRequestContext(["https://ai.azure.com/.default"]));

    #pragma warning disable OPENAI001 // Responses API is in preview
    return new OpenAIClient(new ApiKeyCredential(token.Token), new OpenAIClientOptions { Endpoint = baseUrl })
        .GetResponsesClient();
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