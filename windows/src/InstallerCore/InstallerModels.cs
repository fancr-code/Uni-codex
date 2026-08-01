using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexOneClickInstaller;

[JsonConverter(typeof(ProviderKindJsonConverter))]
public enum ProviderKind
{
    DeepSeek,
    KimiOpen,
    KimiCode,
    Zhipu,
    Qwen,
    XiaomiMiMo
}

[JsonConverter(typeof(ModelSourceJsonConverter))]
public enum ModelSource
{
    OfflineSnapshot,
    UpstreamRefresh
}

[JsonConverter(typeof(AuthenticationModeJsonConverter))]
public enum AuthenticationMode
{
    PureApi,
    OpenAIAccountWithApi
}

public sealed class SensitiveString : IEquatable<SensitiveString>
{
    private readonly string value;

    public SensitiveString(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        this.value = value;
    }

    internal string RevealForConfigurationWrite() => value;

    public override string ToString() => "[REDACTED]";

    public bool Equals(SensitiveString? other) => other is not null && value == other.value;

    public override bool Equals(object? obj) => obj is SensitiveString other && Equals(other);

    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(value);
}

public sealed record InstallRequest(
    ProviderKind Provider,
    [property: JsonIgnore] SensitiveString ApiKey,
    string DefaultModel,
    IReadOnlyList<string> AvailableModels,
    ModelSource ModelSource = ModelSource.OfflineSnapshot,
    AuthenticationMode AuthenticationMode = AuthenticationMode.PureApi)
{
    public static InstallRequest CreateDefault(
        SensitiveString apiKey,
        string defaultModel,
        IEnumerable<string> availableModels)
    {
        ArgumentNullException.ThrowIfNull(apiKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(defaultModel);
        ArgumentNullException.ThrowIfNull(availableModels);

        return new InstallRequest(
            ProviderKind.DeepSeek,
            apiKey,
            defaultModel,
            Array.AsReadOnly(availableModels.ToArray()));
    }
}

public sealed record InstallerEvent(
    string Kind,
    double? Progress,
    string Message,
    string? Code);

public sealed record PreflightResult(
    bool IsSupported,
    string? FailureCode,
    IReadOnlyList<InstalledPackage> InstalledPackages,
    IReadOnlyList<RunningComponent> RunningComponents);

public sealed record InstallResult(bool Succeeded, string? FailureCode = null);

public sealed record RestoreResult(bool Restored, string? BackupPath = null, string? FailureCode = null);

public sealed class ProviderKindJsonConverter : StrictEnumJsonConverter<ProviderKind>
{
    public ProviderKindJsonConverter()
        : base(new Dictionary<ProviderKind, string>
        {
            [ProviderKind.DeepSeek] = "deepseek",
            [ProviderKind.KimiOpen] = "kimi-open",
            [ProviderKind.KimiCode] = "kimi-code",
            [ProviderKind.Zhipu] = "zhipu",
            [ProviderKind.Qwen] = "qwen",
            [ProviderKind.XiaomiMiMo] = "xiaomi-mimo"
        })
    {
    }
}

public sealed class ModelSourceJsonConverter : StrictEnumJsonConverter<ModelSource>
{
    public ModelSourceJsonConverter()
        : base(new Dictionary<ModelSource, string>
        {
            [ModelSource.OfflineSnapshot] = "offlineSnapshot",
            [ModelSource.UpstreamRefresh] = "upstreamRefresh"
        })
    {
    }
}

public sealed class AuthenticationModeJsonConverter : StrictEnumJsonConverter<AuthenticationMode>
{
    public AuthenticationModeJsonConverter()
        : base(new Dictionary<AuthenticationMode, string>
        {
            [AuthenticationMode.PureApi] = "pureAPI",
            [AuthenticationMode.OpenAIAccountWithApi] = "openAIAccountWithAPI"
        })
    {
    }
}

public abstract class StrictEnumJsonConverter<TEnum> : JsonConverter<TEnum>
    where TEnum : struct, Enum
{
    private readonly IReadOnlyDictionary<TEnum, string> names;
    private readonly IReadOnlyDictionary<string, TEnum> values;

    protected StrictEnumJsonConverter(IReadOnlyDictionary<TEnum, string> names)
    {
        this.names = names;
        values = names.ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.Ordinal);
    }

    public override TEnum Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String || !values.TryGetValue(reader.GetString() ?? string.Empty, out var value))
        {
            throw new JsonException($"Invalid {typeof(TEnum).Name} value.");
        }

        return value;
    }

    public override void Write(Utf8JsonWriter writer, TEnum value, JsonSerializerOptions options)
    {
        if (!names.TryGetValue(value, out var name))
        {
            throw new JsonException($"Invalid {typeof(TEnum).Name} value.");
        }

        writer.WriteStringValue(name);
    }
}
