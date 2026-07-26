namespace ApiAuthorizer;

public interface ITokenValidator
{
    Identity? Validate(string token);
}

/// <summary>
/// PoC-only token: local:user-001:Alice:reader:hello:read
/// Replace this implementation with OIDC/JWT validation before AWS use.
/// </summary>
public sealed class LocalTokenValidator : ITokenValidator
{
    public Identity? Validate(string token)
    {
        var parts = token.Split(':', 5, StringSplitOptions.TrimEntries);
        if (parts.Length != 5 ||
            parts[0] != "local" ||
            parts.Skip(1).Any(string.IsNullOrWhiteSpace))
            return null;

        return new Identity(
            parts[1],
            parts[2],
            parts[3].Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(),
            parts[4].Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet());
    }
}

public sealed class ResourceAuthorizer
{
    public bool IsAllowed(Identity identity, string methodArn) =>
        methodArn.Contains("/GET/api/hello", StringComparison.OrdinalIgnoreCase) &&
        identity.Permissions.Contains("hello:read");
}
