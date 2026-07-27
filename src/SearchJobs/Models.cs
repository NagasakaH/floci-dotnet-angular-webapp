using Amazon.DynamoDBv2.Model;

namespace SearchJobs;

internal sealed record StartSearchRequest(string? Query, int? MaxResults);

internal sealed record SearchJobMessage(
    string JobId,
    string OwnerUserId,
    string Query,
    int MaxResults);

internal static class JobItem
{
    public static string? String(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) ? value.S : null;

    public static int Number(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) && int.TryParse(value.N, out var result) ? result : 0;

    public static long Long(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) && long.TryParse(value.N, out var result) ? result : 0;
}
