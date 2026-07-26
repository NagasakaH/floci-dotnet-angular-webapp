using System.Text.Json;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace HelloApi;

public sealed class Function
{
    public APIGatewayProxyResponse Handler(APIGatewayProxyRequest request, ILambdaContext context)
    {
        var authorizer = request.RequestContext?.Authorizer;
        var userId = ReadContext(authorizer, "userId") ?? "unknown";
        var user = ReadContext(authorizer, "user") ?? userId;

        context.Logger.LogInformation("Authorized hello request for {UserId}", userId);

        return new APIGatewayProxyResponse
        {
            StatusCode = 200,
            Headers = new Dictionary<string, string>
            {
                ["Content-Type"] = "application/json",
                ["Access-Control-Allow-Origin"] =
                    Environment.GetEnvironmentVariable("CORS_ALLOW_ORIGIN") ?? "*",
                ["Vary"] = "Origin"
            },
            Body = JsonSerializer.Serialize(new { message = "Hello", user, userId })
        };
    }

    private static string? ReadContext(IDictionary<string, object>? values, string key) =>
        values is not null && values.TryGetValue(key, out var value) ? value?.ToString() : null;
}
