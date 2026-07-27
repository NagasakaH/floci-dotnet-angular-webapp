using System.Text.Json.Serialization;
using Amazon.DynamoDBv2.Model;

namespace WorkflowJobs;

internal sealed record StartWorkflowRequest(string? RequestType, decimal? Amount);

internal sealed record WorkflowExecutionInput(
    [property: JsonPropertyName("jobId")] string JobId,
    [property: JsonPropertyName("ownerUserId")] string OwnerUserId,
    [property: JsonPropertyName("requestType")] string RequestType,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("requestedAt")] string RequestedAt);

public sealed record ValidationResult(
    [property: JsonPropertyName("requiresReview")] bool RequiresReview,
    [property: JsonPropertyName("riskLevel")] string RiskLevel,
    [property: JsonPropertyName("message")] string Message);

public sealed record ValidatedWorkflow(
    [property: JsonPropertyName("jobId")] string JobId,
    [property: JsonPropertyName("ownerUserId")] string OwnerUserId,
    [property: JsonPropertyName("requestType")] string RequestType,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("requestedAt")] string RequestedAt,
    [property: JsonPropertyName("validation")] ValidationResult? Validation = null,
    [property: JsonPropertyName("route")] WorkflowRoute? Route = null);

public sealed record WorkflowRoute(
    [property: JsonPropertyName("lane")] string Lane,
    [property: JsonPropertyName("delaySeconds")] int DelaySeconds);

internal static class WorkflowJobItem
{
    public static string? String(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) ? value.S : null;

    public static long Long(IReadOnlyDictionary<string, AttributeValue> item, string key) =>
        item.TryGetValue(key, out var value) && long.TryParse(value.N, out var result) ? result : 0;
}
