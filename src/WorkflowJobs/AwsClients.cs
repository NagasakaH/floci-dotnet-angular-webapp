using Amazon.DynamoDBv2;
using Amazon.Runtime;
using Amazon.StepFunctions;

namespace WorkflowJobs;

internal static class AwsClients
{
    private static string? ServiceEndpoint =>
        EmptyToNull(Environment.GetEnvironmentVariable("AWS_SERVICE_ENDPOINT"));

    private static string Region =>
        Environment.GetEnvironmentVariable("AWS_REGION") ?? "ap-northeast-1";

    public static IAmazonDynamoDB DynamoDb()
    {
        var config = new AmazonDynamoDBConfig
        {
            RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(Region)
        };
        Configure(config);
        return new AmazonDynamoDBClient(config);
    }

    public static IAmazonStepFunctions StepFunctions()
    {
        var config = new AmazonStepFunctionsConfig
        {
            RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(Region)
        };
        Configure(config);
        return new AmazonStepFunctionsClient(config);
    }

    private static void Configure(ClientConfig config)
    {
        if (ServiceEndpoint is null)
        {
            return;
        }
        config.ServiceURL = ServiceEndpoint;
        config.UseHttp = ServiceEndpoint.StartsWith("http://", StringComparison.OrdinalIgnoreCase);
        config.AuthenticationRegion = Region;
    }

    private static string? EmptyToNull(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.TrimEnd('/');
}
