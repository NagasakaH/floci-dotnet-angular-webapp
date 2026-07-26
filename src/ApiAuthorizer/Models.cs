using System.Text.Json.Serialization;

namespace ApiAuthorizer;

public sealed record AuthorizerRequest(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("authorizationToken")] string AuthorizationToken,
    [property: JsonPropertyName("methodArn")] string MethodArn);

public sealed record PolicyStatement(
    [property: JsonPropertyName("Action")] string Action,
    [property: JsonPropertyName("Effect")] string Effect,
    [property: JsonPropertyName("Resource")] string Resource);

public sealed record PolicyDocument(
    [property: JsonPropertyName("Version")] string Version,
    [property: JsonPropertyName("Statement")] IReadOnlyList<PolicyStatement> Statement);

public sealed record AuthorizerResponse(
    [property: JsonPropertyName("principalId")] string PrincipalId,
    [property: JsonPropertyName("policyDocument")] PolicyDocument PolicyDocument,
    [property: JsonPropertyName("context")] IReadOnlyDictionary<string, object> Context);

public sealed record Identity(
    string UserId,
    string User,
    IReadOnlySet<string> Roles,
    IReadOnlySet<string> Permissions);
