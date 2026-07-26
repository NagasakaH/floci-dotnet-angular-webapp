using ApiAuthorizer;
using Xunit;

namespace ApiAuthorizer.Tests;

public sealed class AuthorizationTests
{
    [Fact]
    public void Valid_token_can_read_hello()
    {
        var identity =
            new LocalTokenValidator().Validate("local:user-001:Alice:reader:hello:read");

        Assert.NotNull(identity);
        Assert.True(new ResourceAuthorizer().IsAllowed(
            identity,
            "arn:aws:execute-api:ap-northeast-1:000000000000:id/local/GET/api/hello"));
    }

    [Theory]
    [InlineData("not-local")]
    [InlineData("local:too:few")]
    [InlineData("")]
    public void Invalid_token_is_rejected(string token) =>
        Assert.Null(new LocalTokenValidator().Validate(token));
}
