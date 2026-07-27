using System.Globalization;
using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;
using Amazon.StepFunctions;
using Amazon.StepFunctions.Model;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace WorkflowJobs;

public sealed class ApiFunction
{
    private const string RequiredAccessGroup = "workflow-users";
    private readonly IAmazonDynamoDB _dynamoDb;
    private readonly IAmazonStepFunctions _stepFunctions;
    private readonly string _tableName;
    private readonly string _stateMachineArn;
    private readonly string _corsOrigin;

    public ApiFunction() : this(AwsClients.DynamoDb(), AwsClients.StepFunctions())
    {
    }

    internal ApiFunction(IAmazonDynamoDB dynamoDb, IAmazonStepFunctions stepFunctions)
    {
        _dynamoDb = dynamoDb;
        _stepFunctions = stepFunctions;
        _tableName = RequiredEnvironment("WORKFLOW_JOBS_TABLE");
        _stateMachineArn = RequiredEnvironment("WORKFLOW_STATE_MACHINE_ARN");
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
        var authorization = ReadAuthorization(request);
        if (authorization.UserId is null)
        {
            return Response(401, new { message = "Authenticated user context is missing." });
        }
        if (!authorization.HasWorkflowPermission)
        {
            return Response(403, new { message = "Workflow permission is missing." });
        }

        StartWorkflowRequest? input;
        try
        {
            input = JsonSerializer.Deserialize<StartWorkflowRequest>(
                request.Body ?? "{}",
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch (JsonException)
        {
            return Response(400, new { message = "Request body must be valid JSON." });
        }

        var requestType = input?.RequestType?.Trim() ?? "";
        var amount = input?.Amount ?? 0m;
        if (requestType.Length is < 2 or > 60)
        {
            return Response(400, new { message = "requestType must contain between 2 and 60 characters." });
        }
        if (amount is <= 0m or > 100_000_000m)
        {
            return Response(400, new { message = "amount must be between 0 and 100000000." });
        }

        var now = DateTimeOffset.UtcNow;
        var jobId = Guid.NewGuid().ToString("N");
        await _dynamoDb.PutItemAsync(new PutItemRequest
        {
            TableName = _tableName,
            Item = new Dictionary<string, AttributeValue>
            {
                ["jobId"] = new(jobId),
                ["ownerUserId"] = new(authorization.UserId),
                ["requestType"] = new(requestType),
                ["amount"] = new() { N = amount.ToString(CultureInfo.InvariantCulture) },
                ["status"] = new("STARTING"),
                ["createdAt"] = new(now.ToString("O")),
                ["expiresAt"] = new() { N = now.AddDays(1).ToUnixTimeSeconds().ToString() }
            },
            ConditionExpression = "attribute_not_exists(jobId)"
        });

        try
        {
            var execution = await _stepFunctions.StartExecutionAsync(new StartExecutionRequest
            {
                StateMachineArn = _stateMachineArn,
                Name = jobId,
                Input = JsonSerializer.Serialize(new WorkflowExecutionInput(
                    jobId,
                    authorization.UserId,
                    requestType,
                    amount,
                    now.ToString("O")))
            });
            await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
            {
                TableName = _tableName,
                Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(jobId) },
                UpdateExpression = "SET executionArn = :executionArn, #status = :status",
                ExpressionAttributeNames = new Dictionary<string, string> { ["#status"] = "status" },
                ExpressionAttributeValues = new Dictionary<string, AttributeValue>
                {
                    [":executionArn"] = new(execution.ExecutionArn),
                    [":status"] = new("RUNNING")
                }
            });
            context.Logger.LogInformation(
                "Started workflow {JobId} for {UserId}: {ExecutionArn}",
                jobId,
                authorization.UserId,
                execution.ExecutionArn);
            return Response(202, new
            {
                jobId,
                status = "RUNNING",
                statusUrl = $"/api/workflow-jobs/{jobId}"
            });
        }
        catch (Exception exception)
        {
            await MarkStartFailed(jobId);
            context.Logger.LogError(
                "Could not start workflow {JobId}: {Error}",
                jobId,
                exception.Message);
            return Response(502, new { message = "Workflow could not be started." });
        }
    }

    private async Task<APIGatewayProxyResponse> Get(
        APIGatewayProxyRequest request,
        ILambdaContext context)
    {
        var authorization = ReadAuthorization(request);
        if (authorization.UserId is null)
        {
            return Response(401, new { message = "Authenticated user context is missing." });
        }
        if (!authorization.HasWorkflowPermission)
        {
            return Response(403, new { message = "Workflow permission is missing." });
        }

        request.PathParameters ??= new Dictionary<string, string>();
        request.PathParameters.TryGetValue("jobId", out var jobId);
        if (string.IsNullOrWhiteSpace(jobId))
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
            WorkflowJobItem.String(result.Item, "ownerUserId") != authorization.UserId)
        {
            return Response(404, new { message = "Workflow job was not found." });
        }
        if (WorkflowJobItem.Long(result.Item, "expiresAt") <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
        {
            return Response(410, new { message = "Workflow job has expired." });
        }

        var executionArn = WorkflowJobItem.String(result.Item, "executionArn");
        if (executionArn is null)
        {
            return Response(200, new
            {
                jobId,
                status = WorkflowJobItem.String(result.Item, "status") ?? "STARTING",
                requestType = WorkflowJobItem.String(result.Item, "requestType"),
                amount = Number(result.Item, "amount"),
                history = Array.Empty<object>()
            });
        }

        var execution = await _stepFunctions.DescribeExecutionAsync(new DescribeExecutionRequest
        {
            ExecutionArn = executionArn
        });
        var history = await _stepFunctions.GetExecutionHistoryAsync(new GetExecutionHistoryRequest
        {
            ExecutionArn = executionArn,
            MaxResults = 100
        });
        var steps = history.Events
            .Where(item => item.StateEnteredEventDetails is not null)
            .Select(item => new
            {
                name = item.StateEnteredEventDetails.Name,
                enteredAt = item.Timestamp?.ToString("O") ?? ""
            })
            .ToArray();
        var status = execution.Status?.Value ?? "UNKNOWN";
        object? output = null;
        if (!string.IsNullOrWhiteSpace(execution.Output))
        {
            output = JsonSerializer.Deserialize<JsonElement>(execution.Output);
        }

        context.Logger.LogInformation("Read workflow {JobId} status {Status}", jobId, status);
        return Response(200, new
        {
            jobId,
            status,
            requestType = WorkflowJobItem.String(result.Item, "requestType"),
            amount = Number(result.Item, "amount"),
            startedAt = execution.StartDate?.ToString("O"),
            stoppedAt = execution.StopDate?.ToString("O"),
            currentStep = steps.LastOrDefault()?.name,
            history = steps,
            output,
            error = execution.Error,
            cause = execution.Cause
        });
    }

    private async Task MarkStartFailed(string jobId)
    {
        await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
        {
            TableName = _tableName,
            Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(jobId) },
            UpdateExpression = "SET #status = :status",
            ExpressionAttributeNames = new Dictionary<string, string> { ["#status"] = "status" },
            ExpressionAttributeValues = new Dictionary<string, AttributeValue>
            {
                [":status"] = new("FAILED_TO_START")
            }
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

    private static AuthorizationContext ReadAuthorization(APIGatewayProxyRequest request)
    {
        var authorizer = request.RequestContext?.Authorizer;
        if (authorizer is null || !authorizer.TryGetValue("userId", out var userIdValue))
        {
            return new(null, false);
        }
        var accessGroups = authorizer.TryGetValue("accessRightGroups", out var groupsValue)
            ? groupsValue?.ToString()?.Split(
                ',',
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            : [];
        return new(
            userIdValue?.ToString(),
            accessGroups?.Contains(RequiredAccessGroup, StringComparer.Ordinal) == true);
    }

    private static decimal Number(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) &&
        decimal.TryParse(value.N, CultureInfo.InvariantCulture, out var result)
            ? result
            : 0m;

    private static string RequiredEnvironment(string name) =>
        Environment.GetEnvironmentVariable(name) ??
        throw new InvalidOperationException($"{name} is not set.");

    private sealed record AuthorizationContext(string? UserId, bool HasWorkflowPermission);
}
