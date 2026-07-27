using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;
using Amazon.S3;
using Amazon.S3.Model;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace FileIngest;

public sealed class ApiFunction
{
    private const string CsvContentType = "text/csv";
    private readonly IAmazonDynamoDB _dynamoDb;
    private readonly IAmazonS3 _publicS3;
    private readonly string _tableName;
    private readonly string _bucketName;
    private readonly string _corsOrigin;

    public ApiFunction() : this(AwsClients.DynamoDb(), AwsClients.S3(publicUrl: true))
    {
    }

    internal ApiFunction(IAmazonDynamoDB dynamoDb, IAmazonS3 publicS3)
    {
        _dynamoDb = dynamoDb;
        _publicS3 = publicS3;
        _tableName = RequiredEnvironment("FILE_JOBS_TABLE");
        _bucketName = RequiredEnvironment("FILE_INGEST_BUCKET");
        _corsOrigin = Environment.GetEnvironmentVariable("CORS_ALLOW_ORIGIN") ?? "*";
    }

    public Task<APIGatewayProxyResponse> Handler(
        APIGatewayProxyRequest request,
        ILambdaContext context) =>
        request.HttpMethod?.ToUpperInvariant() switch
        {
            "POST" => Start(request, context),
            "GET" => Get(request, context),
            _ => Task.FromResult(Response(405, new { message = "Method not allowed" }))
        };

    private async Task<APIGatewayProxyResponse> Start(
        APIGatewayProxyRequest request,
        ILambdaContext context)
    {
        StartFileJobRequest? input;
        try
        {
            input = JsonSerializer.Deserialize<StartFileJobRequest>(
                request.Body ?? "{}",
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch (JsonException)
        {
            return Response(400, new { message = "Request body must be valid JSON." });
        }

        var fileName = Path.GetFileName(input?.FileName?.Trim() ?? "");
        if (fileName.Length is < 5 or > 120 ||
            !fileName.EndsWith(".csv", StringComparison.OrdinalIgnoreCase))
        {
            return Response(400, new { message = "fileName must be a .csv name between 5 and 120 characters." });
        }

        var ownerUserId = ReadUserId(request);
        if (ownerUserId is null)
        {
            return Response(401, new { message = "Authenticated user context is missing." });
        }

        var now = DateTimeOffset.UtcNow;
        var jobId = Guid.NewGuid().ToString("N");
        var inputKey = $"uploads/{ownerUserId}/{jobId}/{fileName}";
        await _dynamoDb.PutItemAsync(new PutItemRequest
        {
            TableName = _tableName,
            Item = new Dictionary<string, AttributeValue>
            {
                ["jobId"] = new(jobId),
                ["ownerUserId"] = new(ownerUserId),
                ["fileName"] = new(fileName),
                ["inputKey"] = new(inputKey),
                ["status"] = new("WAITING_UPLOAD"),
                ["createdAt"] = new(now.ToString("O")),
                ["updatedAt"] = new(now.ToString("O")),
                ["expiresAt"] = new() { N = now.AddDays(1).ToUnixTimeSeconds().ToString() }
            },
            ConditionExpression = "attribute_not_exists(jobId)"
        });

        var uploadExpires = DateTime.UtcNow.AddMinutes(5);
        var uploadUrl = await _publicS3.GetPreSignedURLAsync(new GetPreSignedUrlRequest
        {
            BucketName = _bucketName,
            Key = inputKey,
            Expires = uploadExpires,
            Verb = HttpVerb.PUT,
            ContentType = CsvContentType,
            Protocol = AwsClients.PublicS3Protocol
        });

        context.Logger.LogInformation("Created file ingest job {JobId} for {UserId}", jobId, ownerUserId);
        return Response(202, new
        {
            jobId,
            status = "WAITING_UPLOAD",
            uploadUrl,
            uploadExpiresAt = new DateTimeOffset(uploadExpires).ToString("O"),
            requiredHeaders = new Dictionary<string, string> { ["Content-Type"] = CsvContentType },
            statusUrl = $"/api/file-jobs/{jobId}"
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
            FileJobItem.String(result.Item, "ownerUserId") != ownerUserId)
        {
            return Response(404, new { message = "File job was not found." });
        }

        var jobExpiresAt = FileJobItem.Long(result.Item, "expiresAt");
        if (jobExpiresAt <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
        {
            return Response(410, new { message = "File job has expired." });
        }

        var status = FileJobItem.String(result.Item, "status") ?? "UNKNOWN";
        string? reportUrl = null;
        string? reportExpiresAt = null;
        if (status == "COMPLETED" && FileJobItem.String(result.Item, "reportKey") is { } reportKey)
        {
            var expires = new[]
            {
                DateTime.UtcNow.AddMinutes(5),
                DateTimeOffset.FromUnixTimeSeconds(jobExpiresAt).UtcDateTime
            }.Min();
            reportUrl = await _publicS3.GetPreSignedURLAsync(new GetPreSignedUrlRequest
            {
                BucketName = _bucketName,
                Key = reportKey,
                Expires = expires,
                Verb = HttpVerb.GET,
                Protocol = AwsClients.PublicS3Protocol,
                ResponseHeaderOverrides = new ResponseHeaderOverrides
                {
                    ContentDisposition = $"attachment; filename=\"file-report-{jobId}.json\""
                }
            });
            reportExpiresAt = new DateTimeOffset(expires).ToString("O");
        }

        context.Logger.LogInformation("Read file ingest job {JobId} status {Status}", jobId, status);
        return Response(200, new
        {
            jobId,
            status,
            fileName = FileJobItem.String(result.Item, "fileName"),
            createdAt = FileJobItem.String(result.Item, "createdAt"),
            updatedAt = FileJobItem.String(result.Item, "updatedAt"),
            sizeBytes = FileJobItem.Long(result.Item, "sizeBytes"),
            rowCount = FileJobItem.Long(result.Item, "rowCount"),
            columnCount = FileJobItem.Long(result.Item, "columnCount"),
            columns = ParseColumns(FileJobItem.String(result.Item, "columns")),
            reportUrl,
            reportExpiresAt,
            error = status == "FAILED" ? FileJobItem.String(result.Item, "error") : null
        });
    }

    private static IReadOnlyList<string> ParseColumns(string? columns) =>
        string.IsNullOrWhiteSpace(columns) ? [] : columns.Split('\t');

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
