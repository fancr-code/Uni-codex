using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Tomlyn;
using Tomlyn.Model;
using Tomlyn.Parsing;
using Tomlyn.Syntax;

namespace CodexOneClickInstaller;

public sealed record ProviderContract(
    ProviderKind Kind,
    string Name,
    string ManagedProviderId,
    Uri BaseUrl,
    Uri ModelsUrl,
    IReadOnlyList<string> RequiredOfflineModels);

public static partial class InstallerConfig
{
    public const string ResponsesRelayBaseUrl = "http://127.0.0.1:57321/v1";

    private static readonly IReadOnlyDictionary<ProviderKind, ProviderContract> Providers =
        new Dictionary<ProviderKind, ProviderContract>
        {
            [ProviderKind.DeepSeek] = new(
                ProviderKind.DeepSeek,
                "DeepSeek",
                "codex-one-click-deepseek",
                new Uri("https://api.deepseek.com"),
                new Uri("https://api.deepseek.com/models"),
                Array.AsReadOnly(["deepseek-v4-flash", "deepseek-v4-pro"])),
            [ProviderKind.KimiOpen] = new(
                ProviderKind.KimiOpen,
                "Kimi 开放平台",
                "codex-one-click-kimi-open",
                new Uri("https://api.moonshot.cn/v1"),
                new Uri("https://api.moonshot.cn/v1/models"),
                Array.AsReadOnly(
                [
                    "kimi-k2.6",
                    "kimi-k2.7-code",
                    "kimi-k2.7-code-highspeed",
                    "kimi-k3"
                ])),
            [ProviderKind.KimiCode] = new(
                ProviderKind.KimiCode,
                "Kimi Code 会员",
                "codex-one-click-kimi-code",
                new Uri("https://api.kimi.com/coding/v1"),
                new Uri("https://api.kimi.com/coding/v1/models"),
                Array.AsReadOnly(
                [
                    "k3",
                    "kimi-for-coding",
                    "kimi-for-coding-highspeed"
                ])),
            [ProviderKind.Zhipu] = new(
                ProviderKind.Zhipu,
                "智谱 GLM",
                "codex-one-click-zhipu",
                new Uri("https://open.bigmodel.cn/api/paas/v4"),
                new Uri("https://open.bigmodel.cn/api/paas/v4/models"),
                Array.AsReadOnly(
                [
                    "glm-4-flash-250414",
                    "glm-4-flashx-250414",
                    "glm-4.5-air",
                    "glm-4.5-airx",
                    "glm-4.5-flash",
                    "glm-4.6",
                    "glm-4.7",
                    "glm-4.7-flash",
                    "glm-4.7-flashx",
                    "glm-5",
                    "glm-5-turbo",
                    "glm-5.1",
                    "glm-5.2"
                ])),
            [ProviderKind.Qwen] = new(
                ProviderKind.Qwen,
                "阿里千问",
                "codex-one-click-qwen",
                new Uri("https://dashscope.aliyuncs.com/compatible-mode/v1"),
                new Uri("https://dashscope.aliyuncs.com/compatible-mode/v1/models"),
                Array.AsReadOnly(
                [
                    "qwen3.7-flash",
                    "qwen3.7-max",
                    "qwen3.7-plus"
                ])),
            [ProviderKind.XiaomiMiMo] = new(
                ProviderKind.XiaomiMiMo,
                "小米 MiMo",
                "codex-one-click-xiaomi-mimo",
                new Uri("https://api.xiaomimimo.com/v1"),
                new Uri("https://api.xiaomimimo.com/v1/models"),
                Array.AsReadOnly(["mimo-v2.5", "mimo-v2.5-pro"]))
        };

    public static ProviderContract Provider(ProviderKind provider) =>
        Providers.TryGetValue(provider, out var definition)
            ? definition
            : throw new ArgumentOutOfRangeException(nameof(provider));

    public static bool IsLegalModelId(string? value) =>
        value is not null
        && value.Length is > 0 and <= 128
        && LegalModelIdRegex().IsMatch(value);

    public static string GenerateConfigToml(
        InstallRequest request,
        string existing = "")
    {
        ArgumentNullException.ThrowIfNull(request);
        var provider = Provider(request.Provider);
        var key = NormalizedKey(request);
        var document = TomlEditor.WithTopLevelValues(
            existing,
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["model"] = QuoteToml(request.DefaultModel),
                ["model_provider"] = QuoteToml(provider.ManagedProviderId)
            });
        var values = new List<KeyValuePair<string, string>>
        {
            new("name", QuoteToml(provider.Name)),
            new("wire_api", QuoteToml("responses")),
            new("requires_openai_auth", "true"),
            new("base_url", QuoteToml(ResponsesRelayBaseUrl))
        };
        if (request.AuthenticationMode == AuthenticationMode.OpenAIAccountWithApi)
        {
            values.Add(new(
                "experimental_bearer_token",
                QuoteToml(key)));
        }

        return TomlEditor.WithSection(
            document,
            $"model_providers.{provider.ManagedProviderId}",
            values);
    }

    public static byte[] GenerateAuthJson(
        InstallRequest request,
        string? existing = null)
    {
        var root = ParseObjectOrEmpty(existing, "auth.json");
        if (request.AuthenticationMode == AuthenticationMode.PureApi)
            root["OPENAI_API_KEY"] = NormalizedKey(request);
        else
            root.Remove("OPENAI_API_KEY");
        return EncodeJson(root);
    }

    public static byte[] GenerateCodexPlusSettings(
        InstallRequest request,
        IReadOnlyList<ModelDefinition> models,
        string configText,
        string authText,
        string? existing = null)
    {
        ArgumentNullException.ThrowIfNull(models);
        var root = ParseObjectOrEmpty(existing, "Codex++ settings");
        var provider = Provider(request.Provider);
        var profiles = root["relayProfiles"] switch
        {
            null => new JsonArray(),
            JsonArray array => (JsonArray)array.DeepClone(),
            _ => throw new InvalidDataException("relayProfiles must be an array.")
        };
        for (var index = profiles.Count - 1; index >= 0; index--)
        {
            if (profiles[index] is JsonObject profile
                && string.Equals(
                    (string?)profile["id"],
                    provider.ManagedProviderId,
                    StringComparison.Ordinal))
            {
                profiles.RemoveAt(index);
            }
        }

        var modelWindows = new JsonObject();
        foreach (var model in models.Where(model =>
                     request.AvailableModels.Contains(model.Id, StringComparer.Ordinal)))
        {
            if (model.ContextWindow is > 0)
                modelWindows[model.Id] = model.ContextWindow.Value.ToString();
        }

        profiles.Add(new JsonObject
        {
            ["id"] = provider.ManagedProviderId,
            ["name"] = provider.Name,
            ["protocol"] = "chatCompletions",
            ["relayMode"] = request.AuthenticationMode == AuthenticationMode.OpenAIAccountWithApi
                ? "official"
                : "pureApi",
            ["officialMixApiKey"] =
                request.AuthenticationMode == AuthenticationMode.OpenAIAccountWithApi,
            ["upstreamBaseUrl"] = provider.BaseUrl.AbsoluteUri.TrimEnd('/'),
            ["testModel"] = request.DefaultModel,
            ["configContents"] = configText,
            ["authContents"] = request.AuthenticationMode == AuthenticationMode.PureApi
                ? authText
                : string.Empty,
            ["useCommonConfig"] = true,
            ["contextSelection"] = new JsonObject
            {
                ["mcpServers"] = new JsonArray(),
                ["skills"] = new JsonArray(),
                ["plugins"] = new JsonArray()
            },
            ["contextSelectionInitialized"] = false,
            ["modelInsertMode"] = "patch",
            ["modelList"] = string.Join('\n', request.AvailableModels),
            ["modelWindows"] = modelWindows.ToJsonString()
        });

        root["relayProfiles"] = profiles;
        root["relayProfilesEnabled"] = true;
        root["activeRelayId"] = provider.ManagedProviderId;
        root["relayTestModel"] = request.DefaultModel;
        root["launchMode"] = "patch";
        root["enhancementsEnabled"] = true;
        root["codexAppPluginMarketplaceUnlock"] = true;
        root["codexAppPluginAutoExpand"] = true;
        root["codexAppModelWhitelistUnlock"] = true;
        root["codexAppForceChineseLocale"] = true;
        root["codexAppNativeMenuLocalization"] = true;
        return EncodeJson(root);
    }

    public static byte[] GenerateExpectation(InstallRequest request)
    {
        var provider = Provider(request.Provider);
        var hash = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(NormalizedKey(request))))
            .ToLowerInvariant();
        var root = new JsonObject
        {
            ["schemaVersion"] = 2,
            ["provider"] = JsonSerializer.SerializeToNode(request.Provider),
            ["managedProviderID"] = provider.ManagedProviderId,
            ["defaultModel"] = request.DefaultModel,
            ["availableModels"] = new JsonArray(
                request.AvailableModels
                    .Select(model => (JsonNode?)JsonValue.Create(model))
                    .ToArray()),
            ["apiKeySHA256"] = hash,
            ["authenticationMode"] =
                JsonSerializer.SerializeToNode(request.AuthenticationMode)
        };
        return EncodeJson(root);
    }

    public static string Redact(string input)
    {
        if (string.IsNullOrEmpty(input))
            return input;
        var redacted = BearerRegex().Replace(input, "$1[REDACTED]");
        return ApiKeyRegex().Replace(redacted, "$1[REDACTED]");
    }

    internal static JsonObject ParseObjectOrEmpty(
        string? text,
        string description)
    {
        if (string.IsNullOrWhiteSpace(text))
            return [];
        try
        {
            return JsonNode.Parse(text) as JsonObject
                   ?? throw new InvalidDataException(
                       $"{description} root must be an object.");
        }
        catch (JsonException error)
        {
            throw new InvalidDataException(
                $"{description} is invalid JSON.",
                error);
        }
    }

    internal static byte[] EncodeJson(JsonObject root)
    {
        var text = root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        }) + "\n";
        return Encoding.UTF8.GetBytes(text);
    }

    internal static string QuoteToml(string value) =>
        "\"" + value
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal)
            .Replace("\r", "\\r", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal) + "\"";

    internal static string NormalizedKey(InstallRequest request)
    {
        var key = request.ApiKey.RevealForConfigurationWrite().Trim();
        if (key.Length < 8)
            throw new InvalidDataException("API Key must contain at least 8 characters.");
        return key;
    }

    [GeneratedRegex(
        "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$",
        RegexOptions.CultureInvariant)]
    private static partial Regex LegalModelIdRegex();

    [GeneratedRegex(
        "(Bearer\\s+)[^\\s\\\"']+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex BearerRegex();

    [GeneratedRegex(
        "((?:api[_-]?key|token|secret)\\s*[:=]\\s*)[^\\s,;\\\"']+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ApiKeyRegex();
}

internal static class TomlEditor
{
    private const string TopMarker =
        "# Codex One Click Installer managed top-level provider";
    private const string TableMarkerPrefix =
        "# Codex One Click Installer managed table: ";

    public static string WithTopLevelValues(
        string existing,
        IReadOnlyDictionary<string, string> values)
    {
        var syntax = Parse(existing);
        var ranges = syntax.KeyValues
            .Where(item =>
            {
                var path = ParseKeyPath(
                    item.Key?.ToString()
                    ?? throw Invalid("TOML key syntax is missing"));
                return path.Count == 1 && values.ContainsKey(path[0]);
            })
            .Select(item => ExpandedLine(existing, item.Span))
            .ToList();
        if (existing.StartsWith(TopMarker, StringComparison.Ordinal))
        {
            var markerSeparator = existing.StartsWith(
                TopMarker + "\r\n",
                StringComparison.Ordinal)
                    ? "\r\n\r\n"
                    : "\n\n";
            var markerEnd = existing.IndexOf(
                markerSeparator,
                StringComparison.Ordinal);
            if (markerEnd < 0)
                throw Invalid("managed TOML top-level marker is incomplete");
            ranges.Add(new TextRange(
                0,
                markerEnd + markerSeparator.Length));
        }
        var remainder = Remove(existing, ranges);
        var prefix = new StringBuilder()
            .Append(TopMarker)
            .Append('\n');
        foreach (var pair in values)
            prefix.Append(pair.Key).Append(" = ").Append(pair.Value).Append('\n');
        prefix.Append('\n').Append(remainder);
        return Validate(prefix.ToString());
    }

    public static string WithSection(
        string existing,
        string section,
        IEnumerable<KeyValuePair<string, string>> values)
    {
        var syntax = Parse(existing);
        var expectedPath = section.Split(
            '.',
            StringSplitOptions.RemoveEmptyEntries);
        var ranges = new List<TextRange>();
        foreach (var table in syntax.Tables.OfType<TableSyntax>())
        {
            if (!ParseKeyPath(
                    table.Name?.ToString()
                    ?? throw Invalid("TOML table name syntax is missing"))
                .SequenceEqual(expectedPath, StringComparer.Ordinal))
            {
                continue;
            }
            var range = ExpandedLine(existing, table.Span);
            var marker = TableMarkerPrefix + section;
            var markerStart = existing.LastIndexOf(
                marker,
                range.Offset,
                StringComparison.Ordinal);
            if (markerStart >= 0
                && IsOnlyWhitespace(
                    existing,
                    markerStart + marker.Length,
                    range.Offset))
            {
                var start = IncludePrecedingLineBreak(existing, markerStart);
                range = new TextRange(
                    start,
                    range.Offset + range.Length - start);
            }
            ranges.Add(range);
        }
        var remainder = Remove(existing, ranges);
        var builder = new StringBuilder(remainder);
        if (builder.Length > 0 && builder[^1] != '\n')
            builder.Append('\n');
        builder.Append('\n')
            .Append(TableMarkerPrefix)
            .Append(section)
            .Append('\n')
            .Append('[')
            .Append(FormatSection(section))
            .Append(']')
            .Append('\n');
        foreach (var pair in values)
            builder.Append(pair.Key).Append(" = ").Append(pair.Value).Append('\n');
        return Validate(builder.ToString());
    }

    public static string WithoutSection(string existing, string section)
    {
        var syntax = Parse(existing);
        var expectedPath = section.Split(
            '.',
            StringSplitOptions.RemoveEmptyEntries);
        var ranges = new List<TextRange>();
        foreach (var table in syntax.Tables.OfType<TableSyntax>())
        {
            if (!ParseKeyPath(
                    table.Name?.ToString()
                    ?? throw Invalid("TOML table name syntax is missing"))
                .SequenceEqual(expectedPath, StringComparer.Ordinal))
            {
                continue;
            }
            var range = ExpandedLine(existing, table.Span);
            var marker = TableMarkerPrefix + section;
            var markerStart = existing.LastIndexOf(
                marker,
                range.Offset,
                StringComparison.Ordinal);
            if (markerStart >= 0
                && IsOnlyWhitespace(
                    existing,
                    markerStart + marker.Length,
                    range.Offset))
            {
                var start = IncludePrecedingLineBreak(existing, markerStart);
                range = new TextRange(
                    start,
                    range.Offset + range.Length - start);
            }
            ranges.Add(range);
        }
        return Validate(Remove(existing, ranges));
    }

    public static string? Value(
        string document,
        string section,
        string key)
    {
        TomlTable model;
        try
        {
            _ = Parse(document);
            model = TomlSerializer.Deserialize<TomlTable>(document)
                    ?? throw Invalid("TOML root is empty");
        }
        catch (Exception error) when (error is not InvalidDataException)
        {
            throw Invalid("TOML semantic parse failed", error);
        }
        object? current = model;
        foreach (var component in section.Split(
                     '.',
                     StringSplitOptions.RemoveEmptyEntries))
        {
            if (current is not TomlTable table
                || !table.TryGetValue(component, out current))
                return null;
        }
        if (current is not TomlTable target
            || !target.TryGetValue(key, out var value))
            return null;
        return value switch
        {
            null => null,
            bool boolean => boolean ? "true" : "false",
            string text => text,
            _ => Convert.ToString(
                value,
                System.Globalization.CultureInfo.InvariantCulture)
        };
    }

    private static string FormatSection(string section) =>
        string.Join(
            '.',
            section.Split('.').Select(component =>
                component.Contains('@', StringComparison.Ordinal)
                    ? InstallerConfig.QuoteToml(component)
                    : component));

    private static DocumentSyntax Parse(string document)
    {
        try
        {
            return SyntaxParser.ParseStrict(document);
        }
        catch (Exception error)
        {
            throw Invalid("TOML syntax is invalid", error);
        }
    }

    private static string Validate(string document)
    {
        _ = Parse(document);
        try
        {
            _ = TomlSerializer.Deserialize<TomlTable>(document);
        }
        catch (Exception error)
        {
            throw Invalid("TOML semantic conflict", error);
        }
        return document;
    }

    private static TextRange ExpandedLine(string text, SourceSpan span)
    {
        var start = span.Offset;
        var end = checked(span.Offset + span.Length);
        while (end < text.Length && text[end] is ' ' or '\t')
            end++;
        if (end < text.Length && text[end] == '\r')
            end++;
        if (end < text.Length && text[end] == '\n')
            end++;
        return new TextRange(start, end - start);
    }

    private static int IncludePrecedingLineBreak(string text, int start)
    {
        if (start > 0 && text[start - 1] == '\n')
        {
            start--;
            if (start > 0 && text[start - 1] == '\r')
                start--;
        }
        return start;
    }

    private static string Remove(string text, IEnumerable<TextRange> ranges)
    {
        var result = new StringBuilder(text);
        foreach (var range in Merge(ranges)
                     .OrderByDescending(item => item.Offset))
            result.Remove(range.Offset, range.Length);
        return result.ToString();
    }

    private static IReadOnlyList<TextRange> Merge(IEnumerable<TextRange> ranges)
    {
        var ordered = ranges.OrderBy(item => item.Offset).ToArray();
        var merged = new List<TextRange>();
        foreach (var range in ordered)
        {
            if (range.Length == 0)
                continue;
            if (merged.Count == 0
                || range.Offset > merged[^1].Offset + merged[^1].Length)
            {
                merged.Add(range);
                continue;
            }
            var previous = merged[^1];
            var end = Math.Max(
                previous.Offset + previous.Length,
                range.Offset + range.Length);
            merged[^1] = new TextRange(
                previous.Offset,
                end - previous.Offset);
        }
        return merged;
    }

    private static bool IsOnlyWhitespace(
        string text,
        int start,
        int end)
    {
        if (start > end)
            return false;
        for (var index = start; index < end; index++)
        {
            if (!char.IsWhiteSpace(text[index]))
                return false;
        }
        return true;
    }

    private static IReadOnlyList<string> ParseKeyPath(string text)
    {
        var values = new List<string>();
        var index = 0;
        while (true)
        {
            SkipWhitespace(text, ref index);
            if (index >= text.Length)
                break;
            values.Add(text[index] switch
            {
                '"' => ParseBasicKey(text, ref index),
                '\'' => ParseLiteralKey(text, ref index),
                _ => ParseBareKey(text, ref index)
            });
            SkipWhitespace(text, ref index);
            if (index >= text.Length)
                break;
            if (text[index++] != '.')
                throw Invalid("TOML key path is invalid");
        }
        if (values.Count == 0)
            throw Invalid("TOML key path is empty");
        return values;
    }

    private static string ParseBareKey(string text, ref int index)
    {
        var start = index;
        while (index < text.Length
               && (char.IsAsciiLetterOrDigit(text[index])
                   || text[index] is '_' or '-'))
            index++;
        if (index == start)
            throw Invalid("TOML bare key is invalid");
        return text[start..index];
    }

    private static string ParseLiteralKey(string text, ref int index)
    {
        index++;
        var start = index;
        while (index < text.Length && text[index] != '\'')
            index++;
        if (index >= text.Length)
            throw Invalid("TOML literal key is unterminated");
        var value = text[start..index];
        index++;
        return value;
    }

    private static string ParseBasicKey(string text, ref int index)
    {
        index++;
        var builder = new StringBuilder();
        while (index < text.Length && text[index] != '"')
        {
            var character = text[index++];
            if (character != '\\')
            {
                builder.Append(character);
                continue;
            }
            if (index >= text.Length)
                throw Invalid("TOML basic key escape is incomplete");
            var escape = text[index++];
            builder.Append(escape switch
            {
                'b' => '\b',
                't' => '\t',
                'n' => '\n',
                'f' => '\f',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                'u' => ParseUnicode(text, ref index, 4),
                'U' => ParseUnicode(text, ref index, 8),
                _ => throw Invalid("TOML basic key escape is invalid")
            });
        }
        if (index >= text.Length)
            throw Invalid("TOML basic key is unterminated");
        index++;
        return builder.ToString();
    }

    private static string ParseUnicode(
        string text,
        ref int index,
        int digits)
    {
        if (index + digits > text.Length
            || !int.TryParse(
                text.AsSpan(index, digits),
                System.Globalization.NumberStyles.HexNumber,
                System.Globalization.CultureInfo.InvariantCulture,
                out var scalar)
            || !Rune.IsValid(scalar))
            throw Invalid("TOML unicode key escape is invalid");
        index += digits;
        return new Rune(scalar).ToString();
    }

    private static void SkipWhitespace(string text, ref int index)
    {
        while (index < text.Length && text[index] is ' ' or '\t')
            index++;
    }

    private static InvalidDataException Invalid(
        string message,
        Exception? inner = null) =>
        new(message, inner);

    private readonly record struct TextRange(int Offset, int Length);
}
