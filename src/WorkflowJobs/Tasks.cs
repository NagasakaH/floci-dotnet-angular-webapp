using Amazon.Lambda.Core;

namespace WorkflowJobs;

public sealed class ValidateTask
{
    public ValidatedWorkflow Handler(ValidatedWorkflow input, ILambdaContext context)
    {
        var requiresReview = input.Amount >= 100_000m;
        var validation = new ValidationResult(
            requiresReview,
            requiresReview ? "HIGH" : "NORMAL",
            requiresReview
                ? "High-value request requires the review route."
                : "Request is eligible for fast-track processing.");
        context.Logger.LogInformation(
            "Validated workflow {JobId}: risk={RiskLevel}",
            input.JobId,
            validation.RiskLevel);
        return input with { Validation = validation };
    }
}

public sealed class ProcessTask
{
    public object Handler(ValidatedWorkflow input, ILambdaContext context)
    {
        var lane = input.Route?.Lane ?? "UNKNOWN";
        context.Logger.LogInformation(
            "Completed workflow {JobId} through {Lane}",
            input.JobId,
            lane);
        return new
        {
            jobId = input.JobId,
            requestType = input.RequestType,
            amount = input.Amount,
            outcome = "APPROVED",
            processingLane = lane,
            riskLevel = input.Validation?.RiskLevel ?? "UNKNOWN",
            message = "Step Functions workflow completed successfully.",
            completedAt = DateTimeOffset.UtcNow.ToString("O")
        };
    }
}
