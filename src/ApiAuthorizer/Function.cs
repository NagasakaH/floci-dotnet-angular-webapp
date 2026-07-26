using Amazon.Lambda.Core;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace ApiAuthorizer;

public sealed class Function
{
    private readonly ITokenValidator _tokens;
    private readonly ResourceAuthorizer _authorization;

    public Function() : this(new LocalTokenValidator(), new ResourceAuthorizer()) { }

    public Function(ITokenValidator tokens, ResourceAuthorizer authorization)
    {
        _tokens = tokens;
        _authorization = authorization;
    }

    public AuthorizerResponse Handler(AuthorizerRequest request, ILambdaContext context)
    {
        var token = ExtractBearerToken(request.AuthorizationToken);
        var identity = token is null ? null : _tokens.Validate(token);
        var allowed = identity is not null &&
                      _authorization.IsAllowed(identity, request.MethodArn);

        context.Logger.LogInformation(
            "Authorization decision: user={UserId}, allowed={Allowed}, resource={Resource}",
            identity?.UserId ?? "anonymous", allowed, request.MethodArn);

        return new AuthorizerResponse(
            identity?.UserId ?? "anonymous",
            new PolicyDocument("2012-10-17",
            [
                new PolicyStatement(
                    "execute-api:Invoke",
                    allowed ? "Allow" : "Deny",
                    request.MethodArn)
            ]),
            new Dictionary<string, object>
            {
                ["userId"] = identity?.UserId ?? string.Empty,
                ["user"] = identity?.User ?? string.Empty,
                ["roles"] = identity is null ? string.Empty : string.Join(',', identity.Roles),
                ["permissions"] =
                    identity is null ? string.Empty : string.Join(',', identity.Permissions)
            });
    }

    internal static string? ExtractBearerToken(string? value)
    {
        const string prefix = "Bearer ";
        return value?.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) == true
            ? value[prefix.Length..].Trim()
            : null;
    }
}
