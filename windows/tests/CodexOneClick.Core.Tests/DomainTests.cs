using System.Text.Json;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class DomainTests
{
    [Fact]
    public void InstallRequest_defaults_to_pure_api_and_deepseek()
    {
        var request = InstallRequest.CreateDefault(
            new SensitiveString("fixture-deepseek-key"),
            "deepseek-v4-flash",
            new[] { "deepseek-v4-flash" });

        Assert.Equal(ProviderKind.DeepSeek, request.Provider);
        Assert.Equal(AuthenticationMode.PureApi, request.AuthenticationMode);
    }

    [Fact]
    public void Event_json_never_serializes_secret_fields()
    {
        var json = JsonSerializer.Serialize(new InstallerEvent("ready", 0, "ok", null));

        Assert.DoesNotContain("ApiKey", json, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData(ProviderKind.DeepSeek, "deepseek")]
    [InlineData(ProviderKind.KimiOpen, "kimi-open")]
    [InlineData(ProviderKind.KimiCode, "kimi-code")]
    [InlineData(ProviderKind.Zhipu, "zhipu")]
    [InlineData(ProviderKind.Qwen, "qwen")]
    [InlineData(ProviderKind.XiaomiMiMo, "xiaomi-mimo")]
    public void Provider_json_uses_exact_contract_values(ProviderKind provider, string expectedJson)
    {
        Assert.Equal($"\"{expectedJson}\"", JsonSerializer.Serialize(provider));
    }

    [Theory]
    [InlineData(AuthenticationMode.PureApi, "pureAPI")]
    [InlineData(AuthenticationMode.OpenAIAccountWithApi, "openAIAccountWithAPI")]
    public void Authentication_json_uses_exact_contract_values(AuthenticationMode mode, string expectedJson)
    {
        Assert.Equal($"\"{expectedJson}\"", JsonSerializer.Serialize(mode));
    }

    [Fact]
    public void Provider_json_rejects_non_contract_casing()
    {
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<ProviderKind>("\"DeepSeek\""));
    }

    [Fact]
    public void Sensitive_string_never_exposes_its_value_through_to_string()
    {
        var secret = new SensitiveString("fixture-deepseek-key");

        Assert.Equal("[REDACTED]", secret.ToString());
        Assert.DoesNotContain("fixture-deepseek-key", secret.ToString(), StringComparison.Ordinal);
    }
}
