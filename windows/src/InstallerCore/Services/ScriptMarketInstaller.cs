using System.Collections.Frozen;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexOneClickInstaller;

public sealed record ScriptMarketInstallResult(
    int InstalledCount,
    IReadOnlyList<string> InstalledFiles,
    TransactionResult Transaction);

public sealed class ScriptMarketInstaller
{
    internal static readonly FrozenSet<string> EnabledByDefault =
        new[]
        {
            "codex-zhcn-translate",
            "codex-context-used-meter",
            "codex-token-usage"
        }.ToFrozenSet(StringComparer.Ordinal);

    private readonly WindowsConfigurationPaths paths;

    public ScriptMarketInstaller(WindowsConfigurationPaths paths) =>
        this.paths = paths ?? throw new ArgumentNullException(nameof(paths));

    public async Task<ScriptMarketInstallResult> InstallAsync(
        string payloadRoot,
        PayloadCatalog validatedCatalog,
        CancellationToken cancellationToken = default)
    {
        var component = TrustedPayloadComponent.ResolveDirectory(
            payloadRoot,
            validatedCatalog,
            "script-market");
        var scripts = ValidatePackage(component.Path);
        Directory.CreateDirectory(paths.AppData);
        Directory.CreateDirectory(paths.UserScriptsDirectory);
        Directory.CreateDirectory(Path.GetDirectoryName(paths.UserScriptsConfig)!);

        var root = InstallerConfig.ParseObjectOrEmpty(
            File.Exists(paths.UserScriptsConfig)
                ? File.ReadAllText(paths.UserScriptsConfig)
                : null,
            "user_scripts.json");
        var states = ObjectField(root, "scripts");
        var market = ObjectField(root, "market");
        var installedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
        foreach (var script in scripts)
        {
            var fileName = $"market-{script.Id}.js";
            var key = $"user:{fileName}";
            states[key] = EnabledByDefault.Contains(script.Id);
            market[key] = new JsonObject
            {
                ["id"] = script.Id,
                ["name"] = script.Name,
                ["version"] = script.Version,
                ["script_url"] = script.ScriptUrl,
                ["homepage"] = script.Homepage,
                ["installed_at"] = installedAt
            };
        }
        root["enabled"] = true;
        root["scripts"] = states;
        root["market"] = market;

        var targets = new List<ManagedTargetDefinition>();
        var changes = new List<TransactionChange>();
        for (var index = 0; index < scripts.Count; index++)
        {
            var script = scripts[index];
            var target = Path.Combine(
                paths.UserScriptsDirectory,
                $"market-{script.Id}.js");
            var key = $"script.file.{index + 1:D5}";
            targets.Add(new ManagedTargetDefinition(key, paths.AppData, target));
            changes.Add(TransactionChange.ReplaceFile(key, script.Data));
        }
        const string configKey = "script.configuration";
        targets.Add(new ManagedTargetDefinition(
            configKey,
            paths.AppData,
            paths.UserScriptsConfig));
        changes.Add(TransactionChange.ReplaceFile(
            configKey,
            InstallerConfig.EncodeJson(root)));

        var transaction = new TransactionService(
            paths.ScriptTransactionsRoot,
            new ManagedTargetCatalog(targets),
            new AtomicConfigurationFileSystem());
        await transaction.RecoverIncompleteAsync(cancellationToken)
            .ConfigureAwait(false);
        var result = await transaction.ExecuteAsync(
                changes,
                ignoredCancellationToken =>
                {
                    new VerificationService()
                        .VerifyScripts(
                            paths,
                            payloadRoot,
                            validatedCatalog);
                    return Task.CompletedTask;
                },
                cancellationToken)
            .ConfigureAwait(false);
        return new ScriptMarketInstallResult(
            scripts.Count,
            scripts.Select(script => $"market-{script.Id}.js").ToArray(),
            result);
    }

    public async Task<IReadOnlyList<Guid>> RecoverIncompleteAsync(
        string payloadRoot,
        PayloadCatalog validatedCatalog,
        CancellationToken cancellationToken = default)
    {
        var component = TrustedPayloadComponent.ResolveDirectory(
            payloadRoot,
            validatedCatalog,
            "script-market");
        var scripts = ValidatePackage(component.Path);
        var targets = new List<ManagedTargetDefinition>();
        for (var index = 0; index < scripts.Count; index++)
        {
            targets.Add(new ManagedTargetDefinition(
                $"script.file.{index + 1:D5}",
                paths.AppData,
                Path.Combine(
                    paths.UserScriptsDirectory,
                    $"market-{scripts[index].Id}.js")));
        }
        targets.Add(new ManagedTargetDefinition(
            "script.configuration",
            paths.AppData,
            paths.UserScriptsConfig));
        var transaction = new TransactionService(
            paths.ScriptTransactionsRoot,
            new ManagedTargetCatalog(targets),
            new AtomicConfigurationFileSystem());
        return await transaction.RecoverIncompleteAsync(cancellationToken)
            .ConfigureAwait(false);
    }

    internal static IReadOnlyList<ValidatedScript> ValidatePackage(
        string snapshotRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(snapshotRoot);
        var root = Path.GetFullPath(snapshotRoot);
        if (!Directory.Exists(root))
            throw new DirectoryNotFoundException(root);
        RequireNoReparsePoints(root);
        using var document = JsonDocument.Parse(
            File.ReadAllBytes(Path.Combine(root, "index.json")));
        var manifest = document.RootElement;
        if (manifest.ValueKind != JsonValueKind.Object
            || !manifest.TryGetProperty("version", out var version)
            || version.GetInt32() < 1
            || !manifest.TryGetProperty("scripts", out var entries)
            || entries.ValueKind != JsonValueKind.Array
            || entries.GetArrayLength() == 0)
        {
            throw new InvalidDataException(
                "Script market manifest is empty or unsupported.");
        }

        var scripts = new List<ValidatedScript>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in entries.EnumerateArray())
        {
            var id = RequiredString(entry, "id");
            var name = entry.TryGetProperty("name", out var nameNode)
                ? nameNode.GetString() ?? string.Empty
                : id;
            var scriptVersion = RequiredString(entry, "version");
            var scriptUrl = RequiredString(entry, "script_url");
            var homepage = entry.TryGetProperty("homepage", out var homepageNode)
                ? homepageNode.GetString() ?? string.Empty
                : string.Empty;
            var sha256 = RequiredString(entry, "sha256");
            if (!IsScriptId(id)
                || !seen.Add(id)
                || string.IsNullOrWhiteSpace(name)
                || string.IsNullOrWhiteSpace(scriptVersion)
                || !Uri.TryCreate(scriptUrl, UriKind.Absolute, out var uri)
                || uri.Scheme != Uri.UriSchemeHttps
                || !IsSha256(sha256))
            {
                throw new InvalidDataException("Script market entry is invalid.");
            }
            var relative = entry.TryGetProperty("local_path", out var localPath)
                ? localPath.GetString()
                : $"scripts/{id}.js";
            if (!string.Equals(
                    relative?.Replace('\\', '/'),
                    $"scripts/{id}.js",
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Script market local path is not canonical.");
            }
            var path = Path.Combine(root, "scripts", $"{id}.js");
            if (!File.Exists(path))
                throw new InvalidDataException("Script payload is missing.");
            var data = File.ReadAllBytes(path);
            var actual = Convert.ToHexString(SHA256.HashData(data))
                .ToLowerInvariant();
            if (!string.Equals(actual, sha256, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Script market payload hash mismatch.");
            }
            scripts.Add(new ValidatedScript(
                id,
                name,
                scriptVersion,
                scriptUrl,
                homepage,
                data));
        }
        var requiredStates = EnabledByDefault.Concat(
            ["codex-daily-token-usage", "codex-live-token-cost"]);
        if (!requiredStates.All(seen.Contains))
        {
            throw new InvalidDataException(
                "Script market is missing a required default-state script.");
        }
        return scripts;
    }

    private static JsonObject ObjectField(JsonObject root, string key)
    {
        if (root[key] is null)
            return [];
        if (root[key] is not JsonObject value)
        {
            throw new InvalidDataException(
                $"user_scripts.json field {key} must be an object.");
        }
        return (JsonObject)value.DeepClone();
    }

    private static string RequiredString(JsonElement entry, string name)
    {
        if (!entry.TryGetProperty(name, out var value)
            || value.ValueKind != JsonValueKind.String
            || string.IsNullOrEmpty(value.GetString()))
        {
            throw new InvalidDataException(
                "Script market entry is missing a required string.");
        }
        return value.GetString()!;
    }

    private static bool IsScriptId(string id) =>
        id.Length is > 0 and <= 128
        && id.All(character =>
            character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '-'
            or '_');

    private static bool IsSha256(string value) =>
        value.Length == 64
        && value.All(character =>
            character is >= '0' and <= '9'
            or >= 'a' and <= 'f');

    private static void RequireNoReparsePoints(string root)
    {
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException(
                "Script payload root is a reparse point.");
        foreach (var path in Directory.EnumerateFileSystemEntries(
                     root,
                     "*",
                     SearchOption.AllDirectories))
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    "Script payload contains a reparse point.");
            }
        }
    }

    internal sealed record ValidatedScript(
        string Id,
        string Name,
        string Version,
        string ScriptUrl,
        string Homepage,
        byte[] Data);
}
