using System.Text.Json.Serialization;
using Amazon.DynamoDBv2.Model;

namespace FileIngest;

internal sealed record StartFileJobRequest(string? FileName);

internal static class FileJobItem
{
    public static string? String(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) ? value.S : null;

    public static long Long(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) && long.TryParse(value.N, out var result) ? result : 0;
}

internal sealed class S3Notification
{
    [JsonPropertyName("Records")]
    public List<S3NotificationRecord> Records { get; init; } = [];
}

internal sealed class S3NotificationRecord
{
    [JsonPropertyName("s3")]
    public S3NotificationEntity S3 { get; init; } = new();
}

internal sealed class S3NotificationEntity
{
    [JsonPropertyName("bucket")]
    public S3BucketEntity Bucket { get; init; } = new();

    [JsonPropertyName("object")]
    public S3ObjectEntity Object { get; init; } = new();
}

internal sealed class S3BucketEntity
{
    [JsonPropertyName("name")]
    public string Name { get; init; } = "";
}

internal sealed class S3ObjectEntity
{
    [JsonPropertyName("key")]
    public string Key { get; init; } = "";

    [JsonPropertyName("size")]
    public long Size { get; init; }
}

internal sealed record FileReport(
    string JobId,
    string FileName,
    long SizeBytes,
    int RowCount,
    int ColumnCount,
    IReadOnlyList<string> Columns,
    string ProcessedAt);
