using System.Net;
using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;
using Amazon.S3;
using Amazon.S3.Model;
using Amazon.SQS;
using Amazon.SQS.Model;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace SearchJobs;

public sealed class ApiFunction
{
    private readonly IAmazonDynamoDB _dynamoDb;
    private readonly IAmazonSQS _sqs;
    private readonly IAmazonS3 _publicS3;
    private readonly string _tableName;
    private readonly string _queueUrl;
    private readonly string _bucketName;
    private readonly string _corsOrigin;

    public ApiFunction() : this(AwsClients.DynamoDb(), AwsClients.Sqs(), AwsClients.S3(publicUrl: true))
    {
    }

    internal ApiFunction(IAmazonDynamoDB dynamoDb, IAmazonSQS sqs, IAmazonS3 publicS3)
    {
        _dynamoDb = dynamoDb;
        _sqs = sqs;
        _publicS3 = publicS3;
        _tableName = RequiredEnvironment("SEARCH_JOBS_TABLE");
        _queueUrl = RequiredEnvironment("SEARCH_QUEUE_URL");
        _bucketName = RequiredEnvironment("SEARCH_RESULTS_BUCKET");
        _corsOrigin = Environment.GetEnvironmentVariable("CORS_ALLOW_ORIGIN") ?? "*";
    }

    public async Task<APIGatewayProxyResponse> Handler(
        APIGatewayProxyRequest request,
        ILambdaContext context)
    {
        return request.HttpMethod?.ToUpperInvariant() switch
        {
            "POST" => await Start(request, context),
            "GET" => await Get(request, context),
            _ => Response(405, new { message = "Method not allowed" })
        };
    }

    private async Task<APIGatewayProxyResponse> Start(
        APIGatewayProxyRequest request,
        ILambdaContext context)
    {
        StartSearchRequest? input;
        try
        {
            input = JsonSerializer.Deserialize<StartSearchRequest>(
                request.Body ?? "{}",
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch (JsonException)
        {
            return Response(400, new { message = "Request body must be valid JSON." });
        }

        var query = input?.Query?.Trim() ?? "";
        var maxResults = input?.MaxResults ?? 250;
        if (query.Length is < 2 or > 100)
        {
            return Response(400, new { message = "query must contain between 2 and 100 characters." });
        }
        if (maxResults is < 1 or > 1000)
        {
            return Response(400, new { message = "maxResults must be between 1 and 1000." });
        }

        var ownerUserId = ReadUserId(request);
        if (ownerUserId is null)
        {
            return Response(401, new { message = "Authenticated user context is missing." });
        }

        var now = DateTimeOffset.UtcNow;
        var jobId = Guid.NewGuid().ToString("N");
        var message = new SearchJobMessage(jobId, ownerUserId, query, maxResults);
        await _dynamoDb.PutItemAsync(new PutItemRequest
        {
            TableName = _tableName,
            Item = new Dictionary<string, AttributeValue>
            {
                ["jobId"] = new(jobId),
                ["ownerUserId"] = new(ownerUserId),
                ["query"] = new(query),
                ["status"] = new("QUEUED"),
                ["createdAt"] = new(now.ToString("O")),
                ["updatedAt"] = new(now.ToString("O")),
                ["expiresAt"] = new() { N = now.AddDays(1).ToUnixTimeSeconds().ToString() }
            },
            ConditionExpression = "attribute_not_exists(jobId)"
        });
        await _sqs.SendMessageAsync(new SendMessageRequest
        {
            QueueUrl = _queueUrl,
            MessageBody = JsonSerializer.Serialize(message)
        });

        context.Logger.LogInformation("Queued search job {JobId} for {UserId}", jobId, ownerUserId);
        return Response(202, new
        {
            jobId,
            status = "QUEUED",
            statusUrl = $"/api/search-jobs/{jobId}"
        });
    }

    private async Task<APIGatewayProxyResponse> Get(
        APIGatewayProxyRequest request,
        ILambdaContext context)
    {
        request.PathParameters ??= new Dictionary<string, string>();
        request.PathParameters.TryGetValue("jobId", out var jobId);
        var ownerUserId = ReadUserId(request);
        if (string.IsNullOrWhiteSpace(jobId) || ownerUserId is null)
        {
            return Response(400, new { message = "jobId is required." });
        }

        var result = await _dynamoDb.GetItemAsync(new GetItemRequest
        {
            TableName = _tableName,
            Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(jobId) },
            ConsistentRead = true
        });
        if (result.Item is null || result.Item.Count == 0 ||
            JobItem.String(result.Item, "ownerUserId") != ownerUserId)
        {
            return Response(404, new { message = "Search job was not found." });
        }

        var jobExpiresAt = JobItem.Long(result.Item, "expiresAt");
        if (jobExpiresAt <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
        {
            return Response(410, new { message = "Search job has expired." });
        }

        var status = JobItem.String(result.Item, "status") ?? "UNKNOWN";
        string? downloadUrl = null;
        string? downloadExpiresAt = null;
        if (status == "COMPLETED" && JobItem.String(result.Item, "resultKey") is { } resultKey)
        {
            var expires = new[]
            {
                DateTime.UtcNow.AddMinutes(5),
                DateTimeOffset.FromUnixTimeSeconds(jobExpiresAt).UtcDateTime
            }.Min();
            downloadUrl = await _publicS3.GetPreSignedURLAsync(new GetPreSignedUrlRequest
            {
                BucketName = _bucketName,
                Key = resultKey,
                Expires = expires,
                Verb = HttpVerb.GET,
                Protocol = AwsClients.PublicS3Protocol,
                ResponseHeaderOverrides = new ResponseHeaderOverrides
                {
                    ContentDisposition = $"attachment; filename=\"search-{jobId}.csv\""
                }
            });
            downloadExpiresAt = new DateTimeOffset(expires).ToString("O");
        }

        context.Logger.LogInformation("Read search job {JobId} status {Status}", jobId, status);
        return Response(200, new
        {
            jobId,
            status,
            query = JobItem.String(result.Item, "query"),
            createdAt = JobItem.String(result.Item, "createdAt"),
            updatedAt = JobItem.String(result.Item, "updatedAt"),
            scannedRecords = JobItem.Number(result.Item, "scannedRecords"),
            resultCount = JobItem.Number(result.Item, "resultCount"),
            downloadUrl,
            downloadExpiresAt,
            error = status == "FAILED" ? JobItem.String(result.Item, "error") : null
        });
    }

    private APIGatewayProxyResponse Response(int statusCode, object body) =>
        new()
        {
            StatusCode = statusCode,
            Headers = new Dictionary<string, string>
            {
                ["Content-Type"] = "application/json",
                ["Access-Control-Allow-Origin"] = _corsOrigin,
                ["Vary"] = "Origin",
                ["Cache-Control"] = "no-store"
            },
            Body = JsonSerializer.Serialize(body),
            IsBase64Encoded = false
        };

    private static string? ReadUserId(APIGatewayProxyRequest request)
    {
        var authorizer = request.RequestContext?.Authorizer;
        return authorizer is not null && authorizer.TryGetValue("userId", out var value)
            ? value?.ToString()
            : null;
    }

    private static string RequiredEnvironment(string name) =>
        Environment.GetEnvironmentVariable(name) ??
        throw new InvalidOperationException($"{name} is not set.");
}
