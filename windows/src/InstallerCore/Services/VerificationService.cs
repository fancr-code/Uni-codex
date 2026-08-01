using System.Security.Cryptography;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CodexOneClickInstaller;

public sealed record ConfigurationVerification(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("provider")] ProviderKind Provider,
    [property: JsonPropertyName("defaultModel")] string DefaultModel,
    [property: JsonPropertyName("modelCount")] int ModelCount,
    [property: JsonPropertyName("authenticationMode")]
    AuthenticationMode AuthenticationMode);

public sealed record PluginVerification(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("marketplaceCount")] int MarketplaceCount,
    [property: JsonPropertyName("pluginCount")] int PluginCount,
    [property: JsonPropertyName("offlineMarketplaceCount")]
    int OfflineMarketplaceCount,
    [property: JsonPropertyName("offlinePluginCount")] int OfflinePluginCount,
    [property: JsonPropertyName("runtimePluginCount")] int RuntimePluginCount,
    [property: JsonPropertyName("runtimeStatus")] string RuntimeStatus);

public sealed record ScriptVerification(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("translationEnabled")] bool TranslationEnabled,
    [property: JsonPropertyName("contextMeterEnabled")] bool ContextMeterEnabled,
    [property: JsonPropertyName("tokenUsageEnabled")] bool TokenUsageEnabled,
    [property: JsonPropertyName("dailyUsageEnabled")] bool DailyUsageEnabled,
    [property: JsonPropertyName("liveCostEnabled")] bool LiveCostEnabled,
    [property: JsonPropertyName("installedCount")] int InstalledCount);

public sealed record InstallationVerification(
    [property: JsonPropertyName("overall")] string Overall,
    [property: JsonPropertyName("applications")]
    IReadOnlyDictionary<string, object> Applications,
    [property: JsonPropertyName("configuration")]
    ConfigurationVerification Configuration,
    [property: JsonPropertyName("plugins")] PluginVerification Plugins,
    [property: JsonPropertyName("scripts")] ScriptVerification Scripts);

public sealed class VerificationService
{
    private static readonly HashSet<string> ExpectationKeys =
    [
        "schemaVersion",
        "provider",
        "managedProviderID",
        "defaultModel",
        "availableModels",
        "apiKeySHA256",
        "authenticationMode"
    ];

    private readonly ISecretFileAclPolicy? aclPolicy;

    public VerificationService(ISecretFileAclPolicy? aclPolicy = null) =>
        this.aclPolicy = aclPolicy;

    public ConfigurationVerification VerifyConfiguration(
        WindowsConfigurationPaths paths,
        InstallRequest request,
        IReadOnlyList<ModelDefinition> catalog)
    {
        ArgumentNullException.ThrowIfNull(paths);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(catalog);
        foreach (var path in paths.ConfigurationFiles)
        {
            if (!File.Exists(path))
                throw Failure("configuration_file_missing");
            if (aclPolicy is null || !aclPolicy.IsCompliant(path))
                throw Failure("configuration_acl_mismatch");
        }

        var provider = InstallerConfig.Provider(request.Provider);
        var configText = File.ReadAllText(paths.CodexConfig);
        VerifyToml(configText, request, provider);
        var key = InstallerConfig.NormalizedKey(request);
        var auth = InstallerConfig.ParseObjectOrEmpty(
            File.ReadAllText(paths.CodexAuth),
            "auth.json");
        if (request.AuthenticationMode == AuthenticationMode.PureApi)
        {
            if (!SecretMatches((string?)auth["OPENAI_API_KEY"], key))
                throw Failure("api_key_mismatch");
        }
        else if (auth["OPENAI_API_KEY"] is not null)
        {
            throw Failure("official_auth_contains_api_key");
        }

        var settings = InstallerConfig.ParseObjectOrEmpty(
            File.ReadAllText(paths.CodexPlusSettings),
            "Codex++ settings");
        VerifySettings(settings, request, provider, auth, key);
        VerifyExpectation(
            File.ReadAllText(paths.InstallExpectation),
            request,
            provider,
            key);

        var catalogIds = catalog.Select(model => model.Id)
            .ToHashSet(StringComparer.Ordinal);
        if (!request.AvailableModels.All(catalogIds.Contains))
            throw Failure("catalog_provider_mismatch");
        return new ConfigurationVerification(
            "pass",
            request.Provider,
            request.DefaultModel,
            request.AvailableModels.Count,
            request.AuthenticationMode);
    }

    public PluginVerification VerifyPlugins(
        WindowsConfigurationPaths paths,
        string payloadRoot,
        PayloadCatalog validatedCatalog)
    {
        var component = TrustedPayloadComponent.ResolveDirectory(
            payloadRoot,
            validatedCatalog,
            "plugin-marketplaces");
        var package = PluginInstaller.ValidatePackage(component.Path);
        if (!File.Exists(paths.CodexConfig))
            throw Failure("plugin_configuration_missing");
        var config = File.ReadAllText(paths.CodexConfig);
        foreach (var marketplace in package.OfflinePlugins
                     .Select(plugin => plugin.Marketplace)
                     .Distinct(StringComparer.Ordinal))
        {
            var section = $"marketplaces.{marketplace}";
            if (TomlEditor.Value(config, section, "source_type") != "local"
                || TomlEditor.Value(config, section, "source")
                != Path.Combine(paths.OfflineMarketplaces, marketplace))
            {
                throw Failure("managed_marketplace_configuration_mismatch");
            }
        }
        foreach (var marketplace in package.Plugins
                     .Where(plugin => plugin.Delivery == PluginDelivery.Runtime)
                     .Select(plugin => plugin.Marketplace)
                     .Distinct(StringComparer.Ordinal))
        {
            var section = $"marketplaces.{marketplace}";
            if (TomlEditor.Value(config, section, "source_type") == "local"
                && TomlEditor.Value(config, section, "source")
                == Path.Combine(paths.OfflineMarketplaces, marketplace))
            {
                throw Failure("runtime_marketplace_has_stale_local_source");
            }
        }
        foreach (var plugin in package.Plugins)
        {
            if (TomlEditor.Value(
                    config,
                    $"plugins.{plugin.Id}@{plugin.Marketplace}",
                    "enabled") != "true")
            {
                throw Failure("managed_plugin_disabled");
            }
        }
        VerifyExactPluginTargets(paths, package);
        return new PluginVerification(
            "pass",
            package.Plugins.Select(plugin => plugin.Marketplace)
                .Distinct(StringComparer.Ordinal)
                .Count(),
            package.Plugins.Count,
            package.OfflinePlugins.Select(plugin => plugin.Marketplace)
                .Distinct(StringComparer.Ordinal)
                .Count(),
            package.OfflinePlugins.Count,
            package.Plugins.Count - package.OfflinePlugins.Count,
            "configured");
    }

    public ScriptVerification VerifyScripts(
        WindowsConfigurationPaths paths,
        string payloadRoot,
        PayloadCatalog validatedCatalog)
    {
        var component = TrustedPayloadComponent.ResolveDirectory(
            payloadRoot,
            validatedCatalog,
            "script-market");
        var scripts = ScriptMarketInstaller.ValidatePackage(component.Path);
        if (!File.Exists(paths.UserScriptsConfig))
            throw Failure("script_configuration_missing");
        var config = InstallerConfig.ParseObjectOrEmpty(
            File.ReadAllText(paths.UserScriptsConfig),
            "user_scripts.json");
        if (config["enabled"]?.GetValue<bool>() != true
            || config["scripts"] is not JsonObject states)
        {
            throw Failure("script_configuration_invalid");
        }
        foreach (var script in scripts)
        {
            var fileName = $"market-{script.Id}.js";
            var path = Path.Combine(paths.UserScriptsDirectory, fileName);
            if (!File.Exists(path)
                || !CryptographicOperations.FixedTimeEquals(
                    SHA256.HashData(File.ReadAllBytes(path)),
                    SHA256.HashData(script.Data)))
            {
                throw Failure("script_payload_mismatch");
            }
            var expected = ScriptMarketInstaller.EnabledByDefault
                .Contains(script.Id);
            if (states[$"user:{fileName}"]?.GetValue<bool>() != expected)
                throw Failure("script_enabled_state_mismatch");
        }
        RejectExtraManagedScripts(paths, scripts);

        return new ScriptVerification(
            "pass",
            State(states, "codex-zhcn-translate"),
            State(states, "codex-context-used-meter"),
            State(states, "codex-token-usage"),
            State(states, "codex-daily-token-usage"),
            State(states, "codex-live-token-cost"),
            scripts.Count);
    }

    public InstallationVerification VerifyInstallation(
        WindowsConfigurationPaths paths,
        InstallRequest request,
        IReadOnlyList<ModelDefinition> catalog,
        string payloadRoot,
        PayloadCatalog validatedCatalog)
    {
        var configuration = VerifyConfiguration(paths, request, catalog);
        var plugins = VerifyPlugins(paths, payloadRoot, validatedCatalog);
        var scripts = VerifyScripts(paths, payloadRoot, validatedCatalog);
        return new InstallationVerification(
            "pass",
            new Dictionary<string, object>(),
            configuration,
            plugins,
            scripts);
    }

    private static void VerifyToml(
        string config,
        InstallRequest request,
        ProviderContract provider)
    {
        var section = $"model_providers.{provider.ManagedProviderId}";
        if (TomlEditor.Value(config, string.Empty, "model")
                != request.DefaultModel
            || TomlEditor.Value(config, string.Empty, "model_provider")
                != provider.ManagedProviderId
            || TomlEditor.Value(config, section, "name") != provider.Name
            || TomlEditor.Value(config, section, "wire_api") != "responses"
            || TomlEditor.Value(config, section, "requires_openai_auth") != "true"
            || TomlEditor.Value(config, section, "base_url")
                != InstallerConfig.ResponsesRelayBaseUrl)
        {
            throw Failure("managed_toml_mismatch");
        }
        var bearer = TomlEditor.Value(
            config,
            section,
            "experimental_bearer_token");
        if (request.AuthenticationMode == AuthenticationMode.PureApi)
        {
            if (bearer is not null)
                throw Failure("pure_api_bearer_token_present");
        }
        else if (!SecretMatches(
                     bearer,
                     InstallerConfig.NormalizedKey(request)))
        {
            throw Failure("mixed_api_bearer_token_mismatch");
        }
    }

    private static void VerifySettings(
        JsonObject settings,
        InstallRequest request,
        ProviderContract provider,
        JsonObject auth,
        string key)
    {
        if (settings["relayProfilesEnabled"]?.GetValue<bool>() != true
            || (string?)settings["activeRelayId"] != provider.ManagedProviderId
            || (string?)settings["relayTestModel"] != request.DefaultModel)
        {
            throw Failure("active_relay_mismatch");
        }
        foreach (var setting in new[]
                 {
                     "enhancementsEnabled",
                     "codexAppPluginMarketplaceUnlock",
                     "codexAppPluginAutoExpand",
                     "codexAppModelWhitelistUnlock",
                     "codexAppForceChineseLocale",
                     "codexAppNativeMenuLocalization"
                 })
        {
            if (settings[setting]?.GetValue<bool>() != true)
                throw Failure("enhancement_disabled");
        }
        if (settings["relayProfiles"] is not JsonArray profiles)
            throw Failure("relay_profiles_invalid");
        var managed = profiles
            .OfType<JsonObject>()
            .Where(profile =>
                (string?)profile["id"] == provider.ManagedProviderId)
            .ToArray();
        if (managed.Length != 1)
            throw Failure("managed_relay_missing_or_duplicate");
        var profile = managed[0];
        var expectedMode =
            request.AuthenticationMode == AuthenticationMode.OpenAIAccountWithApi
                ? "official"
                : "pureApi";
        var expectedMix =
            request.AuthenticationMode == AuthenticationMode.OpenAIAccountWithApi;
        if ((string?)profile["name"] != provider.Name
            || (string?)profile["protocol"] != "chatCompletions"
            || (string?)profile["relayMode"] != expectedMode
            || profile["officialMixApiKey"]?.GetValue<bool>() != expectedMix
            || (string?)profile["upstreamBaseUrl"]
                != provider.BaseUrl.AbsoluteUri.TrimEnd('/')
            || (string?)profile["testModel"] != request.DefaultModel
            || profile["useCommonConfig"]?.GetValue<bool>() != true
            || (string?)profile["modelInsertMode"] != "patch"
            || (string?)profile["modelList"]
                != string.Join('\n', request.AvailableModels))
        {
            throw Failure("managed_relay_mismatch");
        }
        var profileConfig = (string?)profile["configContents"];
        if (profileConfig is null)
            throw Failure("relay_config_contents_missing");
        VerifyToml(profileConfig, request, provider);
        var profileAuth = (string?)profile["authContents"];
        if (request.AuthenticationMode == AuthenticationMode.OpenAIAccountWithApi)
        {
            if (!string.IsNullOrEmpty(profileAuth))
                throw Failure("official_relay_auth_must_follow_live_login");
        }
        else
        {
            if (profileAuth is null)
                throw Failure("relay_auth_contents_missing");
            var parsed = InstallerConfig.ParseObjectOrEmpty(
                profileAuth,
                "relay auth");
            if (!SecretMatches((string?)parsed["OPENAI_API_KEY"], key)
                || parsed.ToJsonString() != auth.ToJsonString())
            {
                throw Failure("relay_auth_contents_mismatch");
            }
        }
    }

    private static void VerifyExpectation(
        string text,
        InstallRequest request,
        ProviderContract provider,
        string key)
    {
        var expectation = InstallerConfig.ParseObjectOrEmpty(
            text,
            "install expectation");
        if (!expectation.Select(pair => pair.Key).ToHashSet(StringComparer.Ordinal)
                .SetEquals(ExpectationKeys)
            || expectation["schemaVersion"]?.GetValue<int>() != 2
            || (string?)expectation["provider"]
                != JsonSerializer.Serialize(request.Provider).Trim('"')
            || (string?)expectation["managedProviderID"]
                != provider.ManagedProviderId
            || (string?)expectation["defaultModel"] != request.DefaultModel
            || (string?)expectation["authenticationMode"]
                != JsonSerializer.Serialize(request.AuthenticationMode).Trim('"')
            || expectation["availableModels"] is not JsonArray models
            || !models.Select(node => (string?)node)
                .SequenceEqual(request.AvailableModels))
        {
            throw Failure("install_expectation_mismatch");
        }
        var expectedHash = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(key)))
            .ToLowerInvariant();
        if (!string.Equals(
                (string?)expectation["apiKeySHA256"],
                expectedHash,
                StringComparison.Ordinal)
            || text.Contains(key, StringComparison.Ordinal))
        {
            throw Failure("install_expectation_secret_mismatch");
        }
    }

    private static bool State(JsonObject states, string id) =>
        states[$"user:market-{id}.js"]?.GetValue<bool>() == true;

    private static bool SecretMatches(string? first, string second)
    {
        if (first is null)
            return false;
        var left = SHA256.HashData(Encoding.UTF8.GetBytes(first.Trim()));
        var right = SHA256.HashData(Encoding.UTF8.GetBytes(second.Trim()));
        return CryptographicOperations.FixedTimeEquals(left, right);
    }

    private static void VerifyExactPluginTargets(
        WindowsConfigurationPaths paths,
        PluginInstaller.PluginPackage package)
    {
        foreach (var tree in new[]
                 {
                     ("marketplaces", paths.OfflineMarketplaces),
                     ("cache", paths.PluginCache)
                 })
        {
            var expected = package.Files
                .Where(file => file.Tree == tree.Item1)
                .ToDictionary(
                    file => file.RelativePath.Replace('\\', '/'),
                    file => SHA256.HashData(file.Data),
                    StringComparer.OrdinalIgnoreCase);
            var runtimeMarketplaces = package.Plugins
                .Where(plugin => plugin.Delivery == PluginDelivery.Runtime)
                .Select(plugin => plugin.Marketplace)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            var actual = EnumerateVerifiedFiles(
                tree.Item2,
                runtimeMarketplaces);
            if (!actual.Keys.ToHashSet(StringComparer.OrdinalIgnoreCase)
                    .SetEquals(expected.Keys))
            {
                throw Failure("plugin_target_file_set_mismatch");
            }
            foreach (var pair in expected)
            {
                if (!CryptographicOperations.FixedTimeEquals(
                        pair.Value,
                        SHA256.HashData(File.ReadAllBytes(actual[pair.Key]))))
                {
                    throw Failure("plugin_target_hash_mismatch");
                }
            }
        }
    }

    private static void RejectExtraManagedScripts(
        WindowsConfigurationPaths paths,
        IReadOnlyList<ScriptMarketInstaller.ValidatedScript> scripts)
    {
        var expected = scripts.Select(script => $"market-{script.Id}.js")
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(paths.UserScriptsDirectory))
            throw Failure("script_directory_missing");
        RejectReparse(paths.UserScriptsDirectory);
        foreach (var entry in Directory.EnumerateFileSystemEntries(
                     paths.UserScriptsDirectory,
                     "*",
                     SearchOption.AllDirectories))
        {
            RejectReparse(entry);
            if (Directory.Exists(entry))
                throw Failure("script_target_extra_directory");
        }
        var managed = Directory.EnumerateFiles(paths.UserScriptsDirectory)
            .Select(Path.GetFileName)
            .Where(name => name!.StartsWith(
                "market-",
                StringComparison.OrdinalIgnoreCase))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!managed.SetEquals(expected))
            throw Failure("script_target_file_set_mismatch");
    }

    private static Dictionary<string, string> EnumerateVerifiedFiles(
        string root,
        IReadOnlySet<string> ignoredTopLevelDirectories)
    {
        if (!Directory.Exists(root))
            throw Failure("plugin_target_directory_missing");
        RejectReparse(root);
        var files = new Dictionary<string, string>(
            StringComparer.OrdinalIgnoreCase);
        foreach (var entry in Directory.EnumerateFileSystemEntries(
                     root,
                     "*",
                     SearchOption.AllDirectories))
        {
            RejectReparse(entry);
            if (Directory.Exists(entry))
                continue;
            var relative = Path.GetRelativePath(root, entry)
                .Replace('\\', '/');
            var separator = relative.IndexOf('/');
            var topLevel = separator < 0
                ? relative
                : relative[..separator];
            if (ignoredTopLevelDirectories.Contains(topLevel))
                continue;
            if (!files.TryAdd(relative, entry))
                throw Failure("plugin_target_case_collision");
        }
        return files;
    }

    private static void RejectReparse(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw Failure("managed_target_reparse_point");
    }

    private static InvalidDataException Failure(string reason) =>
        new(reason);
}

public sealed record TrustedPayloadDirectory(
    string Path,
    PayloadEntry Entry);

public static class TrustedPayloadComponent
{
    public static TrustedPayloadDirectory ResolveDirectory(
        string payloadRoot,
        PayloadCatalog validatedCatalog,
        string componentId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadRoot);
        ArgumentNullException.ThrowIfNull(validatedCatalog);
        var entry = validatedCatalog.Entries.SingleOrDefault(item =>
            string.Equals(item.Id, componentId, StringComparison.Ordinal))
                    ?? throw new InvalidDataException(
                        $"Validated payload catalog is missing {componentId}.");
        if (entry.Format != "directory")
            throw new InvalidDataException(
                $"Validated payload component {componentId} is not a directory.");
        var root = Path.GetFullPath(payloadRoot);
        var path = Path.GetFullPath(Path.Combine(
            root,
            entry.RelativePath.Replace('/', Path.DirectorySeparatorChar)));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (!path.StartsWith(
                Path.TrimEndingDirectorySeparator(root)
                + Path.DirectorySeparatorChar,
                comparison)
            || !Directory.Exists(path))
        {
            throw new InvalidDataException(
                $"Validated payload component {componentId} is outside its root.");
        }
        var calculated = HashDirectory(path);
        if (calculated.Size != entry.Size
            || !string.Equals(
                calculated.Sha256,
                entry.Sha256,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Validated payload component {componentId} changed after validation.");
        }
        return new TrustedPayloadDirectory(path, entry);
    }

    public static (string Sha256, long Size) HashDirectory(string root)
    {
        RejectReparse(root);
        var files = new List<(string Relative, string Full)>();
        var windowsPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in Directory.EnumerateFileSystemEntries(
                     root,
                     "*",
                     SearchOption.AllDirectories))
        {
            RejectReparse(entry);
            if (Directory.Exists(entry))
                continue;
            var relative = Path.GetRelativePath(root, entry)
                .Replace('\\', '/');
            if (!windowsPaths.Add(relative))
                throw new InvalidDataException(
                    "Payload directory has a Windows path collision.");
            files.Add((relative, entry));
        }
        files.Sort((left, right) => CompareUtf8(
            left.Relative,
            right.Relative));
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long size = 0;
        foreach (var file in files)
        {
            var bytes = File.ReadAllBytes(file.Full);
            var fileHash = Convert.ToHexString(SHA256.HashData(bytes))
                .ToLowerInvariant();
            size = checked(size + bytes.LongLength);
            Append(hash, file.Relative);
            hash.AppendData([0]);
            Append(hash, fileHash);
            hash.AppendData([0]);
            Append(hash, bytes.LongLength.ToString(CultureInfo.InvariantCulture));
            hash.AppendData([(byte)'\n']);
        }
        return (
            Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant(),
            size);
    }

    private static void Append(IncrementalHash hash, string value) =>
        hash.AppendData(Encoding.UTF8.GetBytes(value));

    private static int CompareUtf8(string left, string right)
    {
        var a = Encoding.UTF8.GetBytes(left);
        var b = Encoding.UTF8.GetBytes(right);
        for (var index = 0; index < Math.Min(a.Length, b.Length); index++)
        {
            var comparison = a[index].CompareTo(b[index]);
            if (comparison != 0)
                return comparison;
        }
        return a.Length.CompareTo(b.Length);
    }

    private static void RejectReparse(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException(
                "Payload directory contains a reparse point.");
    }
}
