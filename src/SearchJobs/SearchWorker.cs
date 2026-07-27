using System.Globalization;
using System.Text;
using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Lambda.Core;
using Amazon.Lambda.SQSEvents;
using Amazon.S3;
using Amazon.S3.Model;

namespace SearchJobs;

public sealed class SearchWorker
{
    private const int ScannedRecords = 20_000;
    private readonly IAmazonDynamoDB _dynamoDb;
    private readonly IAmazonS3 _s3;
    private readonly string _tableName;
    private readonly string _bucketName;

    public SearchWorker() : this(AwsClients.DynamoDb(), AwsClients.S3())
    {
    }

    internal SearchWorker(IAmazonDynamoDB dynamoDb, IAmazonS3 s3)
    {
        _dynamoDb = dynamoDb;
        _s3 = s3;
        _tableName = RequiredEnvironment("SEARCH_JOBS_TABLE");
        _bucketName = RequiredEnvironment("SEARCH_RESULTS_BUCKET");
    }

    public async Task Handler(SQSEvent request, ILambdaContext context)
    {
        foreach (var record in request.Records)
        {
            var message = JsonSerializer.Deserialize<SearchJobMessage>(
                record.Body,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new InvalidOperationException("Search job message is empty.");
            await Process(message, context);
        }
    }

    private async Task Process(SearchJobMessage message, ILambdaContext context)
    {
        try
        {
            await UpdateStatus(message.JobId, "RUNNING");
            await Task.Delay(750);
            var matches = Search(message.Query, message.MaxResults);
            var resultKey = $"results/{message.OwnerUserId}/{message.JobId}.csv";
            var csv = BuildCsv(message, matches);

            await _s3.PutObjectAsync(new PutObjectRequest
            {
                BucketName = _bucketName,
                Key = resultKey,
                ContentBody = csv,
                ContentType = "text/csv; charset=utf-8",
                ServerSideEncryptionMethod = ServerSideEncryptionMethod.AES256
            });
            await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
            {
                TableName = _tableName,
                Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(message.JobId) },
                UpdateExpression =
                    "SET #status = :status, updatedAt = :updatedAt, resultKey = :resultKey, " +
                    "resultCount = :resultCount, scannedRecords = :scannedRecords",
                ExpressionAttributeNames = new Dictionary<string, string> { ["#status"] = "status" },
                ExpressionAttributeValues = new Dictionary<string, AttributeValue>
                {
                    [":status"] = new("COMPLETED"),
                    [":updatedAt"] = new(DateTimeOffset.UtcNow.ToString("O")),
                    [":resultKey"] = new(resultKey),
                    [":resultCount"] = new() { N = matches.Count.ToString(CultureInfo.InvariantCulture) },
                    [":scannedRecords"] = new() { N = ScannedRecords.ToString(CultureInfo.InvariantCulture) }
                }
            });
            context.Logger.LogInformation(
                "Completed search job {JobId}: {ResultCount}/{ScannedRecords}",
                message.JobId,
                matches.Count,
                ScannedRecords);
        }
        catch (Exception exception)
        {
            await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
            {
                TableName = _tableName,
                Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(message.JobId) },
                UpdateExpression = "SET #status = :status, updatedAt = :updatedAt, #error = :error",
                ExpressionAttributeNames = new Dictionary<string, string>
                {
                    ["#status"] = "status",
                    ["#error"] = "error"
                },
                ExpressionAttributeValues = new Dictionary<string, AttributeValue>
                {
                    [":status"] = new("FAILED"),
                    [":updatedAt"] = new(DateTimeOffset.UtcNow.ToString("O")),
                    [":error"] = new("Search processing failed.")
                }
            });
            context.Logger.LogError(
                "Search job {JobId} failed: {Error}",
                message.JobId,
                exception.Message);
            throw;
        }
    }

    private async Task UpdateStatus(string jobId, string status)
    {
        await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
        {
            TableName = _tableName,
            Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(jobId) },
            UpdateExpression = "SET #status = :status, updatedAt = :updatedAt",
            ExpressionAttributeNames = new Dictionary<string, string> { ["#status"] = "status" },
            ExpressionAttributeValues = new Dictionary<string, AttributeValue>
            {
                [":status"] = new(status),
                [":updatedAt"] = new(DateTimeOffset.UtcNow.ToString("O"))
            }
        });
    }

    private static List<EmployeeRecord> Search(string query, int maxResults)
    {
        var normalized = query.Trim().ToLowerInvariant();
        var result = new List<EmployeeRecord>(Math.Min(maxResults, 1000));
        for (var index = 1; index <= ScannedRecords && result.Count < maxResults; index++)
        {
            var record = EmployeeRecord.Create(index);
            if (record.SearchText.Contains(normalized, StringComparison.Ordinal))
            {
                result.Add(record);
            }
        }
        return result;
    }

    private static string BuildCsv(SearchJobMessage message, IEnumerable<EmployeeRecord> records)
    {
        var builder = new StringBuilder();
        builder.AppendLine("employeeId,name,department,location,email");
        foreach (var record in records)
        {
            builder.Append(record.EmployeeId).Append(',')
                .Append(Csv(record.Name)).Append(',')
                .Append(record.Department).Append(',')
                .Append(record.Location).Append(',')
                .Append(record.Email).AppendLine();
        }
        return builder.ToString();
    }

    private static string Csv(string value) => $"\"{value.Replace("\"", "\"\"")}\"";

    private static string RequiredEnvironment(string name) =>
        Environment.GetEnvironmentVariable(name) ??
        throw new InvalidOperationException($"{name} is not set.");

    private sealed record EmployeeRecord(
        string EmployeeId,
        string Name,
        string Department,
        string Location,
        string Email)
    {
        private static readonly string[] FirstNames =
            ["Alice", "Bob", "Carol", "David", "Emma", "Frank", "Grace", "Hiro", "Iris", "Jun"];
        private static readonly string[] LastNames =
            ["Sato", "Suzuki", "Takahashi", "Tanaka", "Watanabe", "Ito", "Yamamoto", "Nakamura"];
        private static readonly string[] Departments =
            ["engineering", "sales", "operations", "finance", "support"];
        private static readonly string[] Locations = ["tokyo", "osaka", "fukuoka", "sapporo"];

        public string SearchText =>
            $"{EmployeeId} {Name} {Department} {Location} {Email}".ToLowerInvariant();

        public static EmployeeRecord Create(int index)
        {
            var first = FirstNames[index % FirstNames.Length];
            var last = LastNames[(index / FirstNames.Length) % LastNames.Length];
            return new EmployeeRecord(
                $"EMP-{index:00000}",
                $"{first} {last}",
                Departments[index % Departments.Length],
                Locations[index % Locations.Length],
                $"{first.ToLowerInvariant()}.{last.ToLowerInvariant()}{index}@example.com");
        }
    }
}
