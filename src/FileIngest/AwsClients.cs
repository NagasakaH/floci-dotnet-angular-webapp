using Amazon.DynamoDBv2;
using Amazon.Runtime;
using Amazon.S3;

namespace FileIngest;

internal static class AwsClients
{
    private static string? ServiceEndpoint =>
        EmptyToNull(Environment.GetEnvironmentVariable("AWS_SERVICE_ENDPOINT"));

    private static string Region =>
        Environment.GetEnvironmentVariable("AWS_REGION") ?? "ap-northeast-1";

    public static Protocol PublicS3Protocol =>
        EmptyToNull(Environment.GetEnvironmentVariable("PUBLIC_S3_ENDPOINT"))
            ?.StartsWith("http://", StringComparison.OrdinalIgnoreCase) == true
            ? Protocol.HTTP
            : Protocol.HTTPS;

    public static IAmazonDynamoDB DynamoDb()
    {
        var config = new AmazonDynamoDBConfig
        {
            RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(Region)
        };
        Configure(config, ServiceEndpoint);
        return new AmazonDynamoDBClient(config);
    }

    public static IAmazonS3 S3(bool publicUrl = false)
    {
        var endpoint = publicUrl
            ? EmptyToNull(Environment.GetEnvironmentVariable("PUBLIC_S3_ENDPOINT"))
            : ServiceEndpoint;
        var config = new AmazonS3Config
        {
            RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(Region),
            ForcePathStyle = endpoint is not null
        };
        Configure(config, endpoint);
        return new AmazonS3Client(config);
    }

    private static void Configure(ClientConfig config, string? endpoint)
    {
        if (endpoint is null)
        {
            return;
        }
        config.ServiceURL = endpoint;
        config.UseHttp = endpoint.StartsWith("http://", StringComparison.OrdinalIgnoreCase);
        config.AuthenticationRegion = Region;
    }

    private static string? EmptyToNull(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.TrimEnd('/');
}
