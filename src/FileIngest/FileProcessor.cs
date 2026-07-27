using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Lambda.Core;
using Amazon.Lambda.SQSEvents;
using Amazon.S3;
using Amazon.S3.Model;

namespace FileIngest;

public sealed class FileProcessor
{
    private const long MaximumFileBytes = 2 * 1024 * 1024;
    private readonly IAmazonDynamoDB _dynamoDb;
    private readonly IAmazonS3 _s3;
    private readonly string _tableName;
    private readonly string _bucketName;

    public FileProcessor() : this(AwsClients.DynamoDb(), AwsClients.S3())
    {
    }

    internal FileProcessor(IAmazonDynamoDB dynamoDb, IAmazonS3 s3)
    {
        _dynamoDb = dynamoDb;
        _s3 = s3;
        _tableName = RequiredEnvironment("FILE_JOBS_TABLE");
        _bucketName = RequiredEnvironment("FILE_INGEST_BUCKET");
    }

    public async Task Handler(SQSEvent request, ILambdaContext context)
    {
        foreach (var message in request.Records)
        {
            var notification = JsonSerializer.Deserialize<S3Notification>(
                message.Body,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new InvalidOperationException("S3 notification is empty.");
            foreach (var record in notification.Records)
            {
                await Process(record, context);
            }
        }
    }

    private async Task Process(S3NotificationRecord record, ILambdaContext context)
    {
        var key = WebUtility.UrlDecode(record.S3.Object.Key);
        var keyParts = key.Split('/', 4);
        if (keyParts.Length != 4 || keyParts[0] != "uploads")
        {
            context.Logger.LogWarning("Ignored unexpected S3 key {Key}", key);
            return;
        }

        var jobId = keyParts[2];
        try
        {
            await UpdateStatus(jobId, "PROCESSING");
            if (record.S3.Object.Size > MaximumFileBytes)
            {
                throw new InvalidDataException("CSV file exceeds the 2 MiB sample limit.");
            }

            using var response = await _s3.GetObjectAsync(new GetObjectRequest
            {
                BucketName = _bucketName,
                Key = key
            });
            var summary = await InspectCsv(response.ResponseStream, record.S3.Object.Size);
            var reportKey = $"reports/{keyParts[1]}/{jobId}.json";
            var report = new FileReport(
                jobId,
                keyParts[3],
                record.S3.Object.Size,
                summary.RowCount,
                summary.Columns.Count,
                summary.Columns,
                DateTimeOffset.UtcNow.ToString("O"));
            await _s3.PutObjectAsync(new PutObjectRequest
            {
                BucketName = _bucketName,
                Key = reportKey,
                ContentBody = JsonSerializer.Serialize(report),
                ContentType = "application/json",
                ServerSideEncryptionMethod = ServerSideEncryptionMethod.AES256
            });
            await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
            {
                TableName = _tableName,
                Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(jobId) },
                ConditionExpression = "attribute_exists(jobId)",
                UpdateExpression =
                    "SET #status = :status, updatedAt = :updatedAt, reportKey = :reportKey, " +
                    "sizeBytes = :sizeBytes, rowCount = :rowCount, columnCount = :columnCount, #columns = :columns",
                ExpressionAttributeNames = new Dictionary<string, string>
                {
                    ["#status"] = "status",
                    ["#columns"] = "columns"
                },
                ExpressionAttributeValues = new Dictionary<string, AttributeValue>
                {
                    [":status"] = new("COMPLETED"),
                    [":updatedAt"] = new(DateTimeOffset.UtcNow.ToString("O")),
                    [":reportKey"] = new(reportKey),
                    [":sizeBytes"] = new() { N = record.S3.Object.Size.ToString(CultureInfo.InvariantCulture) },
                    [":rowCount"] = new() { N = summary.RowCount.ToString(CultureInfo.InvariantCulture) },
                    [":columnCount"] = new() { N = summary.Columns.Count.ToString(CultureInfo.InvariantCulture) },
                    [":columns"] = new(string.Join('\t', summary.Columns))
                }
            });
            context.Logger.LogInformation(
                "Processed file ingest job {JobId}: {Rows} rows, {Columns} columns",
                jobId,
                summary.RowCount,
                summary.Columns.Count);
        }
        catch (Exception exception)
        {
            await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
            {
                TableName = _tableName,
                Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(jobId) },
                ConditionExpression = "attribute_exists(jobId)",
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
                    [":error"] = new(exception is InvalidDataException
                        ? exception.Message
                        : "File processing failed.")
                }
            });
            context.Logger.LogError("File ingest job {JobId} failed: {Error}", jobId, exception.Message);
            throw;
        }
    }

    private async Task UpdateStatus(string jobId, string status)
    {
        await _dynamoDb.UpdateItemAsync(new UpdateItemRequest
        {
            TableName = _tableName,
            Key = new Dictionary<string, AttributeValue> { ["jobId"] = new(jobId) },
            ConditionExpression = "attribute_exists(jobId)",
            UpdateExpression = "SET #status = :status, updatedAt = :updatedAt",
            ExpressionAttributeNames = new Dictionary<string, string> { ["#status"] = "status" },
            ExpressionAttributeValues = new Dictionary<string, AttributeValue>
            {
                [":status"] = new(status),
                [":updatedAt"] = new(DateTimeOffset.UtcNow.ToString("O"))
            }
        });
    }

    private static async Task<CsvSummary> InspectCsv(Stream stream, long sizeBytes)
    {
        if (sizeBytes <= 0)
        {
            throw new InvalidDataException("CSV file is empty.");
        }

        using var reader = new StreamReader(
            stream,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true),
            detectEncodingFromByteOrderMarks: true);
        var headerLine = await reader.ReadLineAsync();
        if (string.IsNullOrWhiteSpace(headerLine))
        {
            throw new InvalidDataException("CSV header is missing.");
        }

        var columns = ParseCsvLine(headerLine);
        if (columns.Count is < 1 or > 50 || columns.Any(string.IsNullOrWhiteSpace))
        {
            throw new InvalidDataException("CSV must contain between 1 and 50 named columns.");
        }

        var rowCount = 0;
        while (await reader.ReadLineAsync() is { } line)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }
            if (ParseCsvLine(line).Count != columns.Count)
            {
                throw new InvalidDataException($"CSV row {rowCount + 2} has an unexpected column count.");
            }
            rowCount++;
            if (rowCount > 100_000)
            {
                throw new InvalidDataException("CSV exceeds the 100,000 row sample limit.");
            }
        }
        return new CsvSummary(columns, rowCount);
    }

    private static List<string> ParseCsvLine(string line)
    {
        var values = new List<string>();
        var current = new StringBuilder();
        var quoted = false;
        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            if (character == '"')
            {
                if (quoted && index + 1 < line.Length && line[index + 1] == '"')
                {
                    current.Append('"');
                    index++;
                }
                else
                {
                    quoted = !quoted;
                }
            }
            else if (character == ',' && !quoted)
            {
                values.Add(current.ToString().Trim());
                current.Clear();
            }
            else
            {
                current.Append(character);
            }
        }
        if (quoted)
        {
            throw new InvalidDataException("CSV contains an unterminated quoted field.");
        }
        values.Add(current.ToString().Trim());
        return values;
    }

    private static string RequiredEnvironment(string name) =>
        Environment.GetEnvironmentVariable(name) ??
        throw new InvalidOperationException($"{name} is not set.");

    private sealed record CsvSummary(IReadOnlyList<string> Columns, int RowCount);
}
