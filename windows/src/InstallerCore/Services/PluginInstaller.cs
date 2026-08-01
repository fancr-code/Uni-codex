using System.Text;
using System.Text.Json;

namespace CodexOneClickInstaller;

public enum PluginDelivery
{
    Offline,
    Runtime
}

public sealed record ManagedPlugin(
    string Marketplace,
    string Id,
    PluginDelivery Delivery,
    string? RuntimeId = null);

public sealed record PluginInstallResult(
    int MarketplaceCount,
    int PluginCount,
    IReadOnlyList<bool> InstalledPluginJson,
    TransactionResult Transaction);

public sealed class PluginInstaller
{
    internal static readonly IReadOnlyList<ManagedPlugin> RequiredPlugins =
        Array.AsReadOnly<ManagedPlugin>(
        [
            new("openai-bundled", "browser", PluginDelivery.Offline),
            new("openai-bundled", "chrome", PluginDelivery.Offline),
            new("openai-bundled", "computer-use", PluginDelivery.Offline),
            new("openai-bundled", "latex", PluginDelivery.Offline),
            new("openai-primary-runtime", "pdf", PluginDelivery.Runtime,
                "codex-primary-runtime"),
            new("openai-primary-runtime", "documents", PluginDelivery.Runtime,
                "codex-primary-runtime"),
            new("openai-primary-runtime", "spreadsheets", PluginDelivery.Runtime,
                "codex-primary-runtime"),
            new("openai-primary-runtime", "presentations", PluginDelivery.Runtime,
                "codex-primary-runtime"),
            new("openai-curated", "github", PluginDelivery.Offline)
        ]);

    private readonly WindowsConfigurationPaths paths;
    private readonly ISecretFileAclPolicy? aclPolicy;

    public PluginInstaller(
        WindowsConfigurationPaths paths,
        ISecretFileAclPolicy? aclPolicy = null)
    {
        this.paths = paths ?? throw new ArgumentNullException(nameof(paths));
        this.aclPolicy = aclPolicy
                         ?? (OperatingSystem.IsWindows()
                             ? new WindowsSecretFileAclPolicy()
                             : null);
    }

    public async Task<PluginInstallResult> InstallAsync(
        string payloadRoot,
        PayloadCatalog validatedCatalog,
        CancellationToken cancellationToken = default)
    {
        var component = TrustedPayloadComponent.ResolveDirectory(
            payloadRoot,
            validatedCatalog,
            "plugin-marketplaces");
        var package = ValidatePackage(component.Path);
        Directory.CreateDirectory(paths.UserProfile);
        Directory.CreateDirectory(Path.GetDirectoryName(paths.CodexConfig)!);
        Directory.CreateDirectory(paths.OfflineMarketplaces);
        Directory.CreateDirectory(paths.PluginCache);

        var targets = new List<ManagedTargetDefinition>();
        var changes = new List<TransactionChange>();
        for (var index = 0; index < package.Files.Count; index++)
        {
            var file = package.Files[index];
            var destinationRoot = file.Tree == "marketplaces"
                ? paths.OfflineMarketplaces
                : paths.PluginCache;
            var target = Path.Combine(destinationRoot, file.RelativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            var key = $"plugin.file.{index + 1:D5}";
            targets.Add(new ManagedTargetDefinition(
                key,
                paths.UserProfile,
                target));
            changes.Add(TransactionChange.ReplaceFile(key, file.Data));
        }
        var config = ConfigurePlugins(
            File.Exists(paths.CodexConfig)
                ? File.ReadAllText(paths.CodexConfig)
                : string.Empty,
            package.Plugins,
            paths.OfflineMarketplaces);
        const string configKey = "plugin.configuration";
        targets.Add(new ManagedTargetDefinition(
            configKey,
            paths.UserProfile,
            paths.CodexConfig));
        changes.Add(TransactionChange.ReplaceFile(
            configKey,
            Encoding.UTF8.GetBytes(config)));

        var transaction = new TransactionService(
            paths.PluginTransactionsRoot,
            new ManagedTargetCatalog(targets),
            new AtomicConfigurationFileSystem(
                aclPolicy: aclPolicy,
                protectTarget: target => string.Equals(
                    target,
                    paths.CodexConfig,
                    OperatingSystem.IsWindows()
                        ? StringComparison.OrdinalIgnoreCase
                        : StringComparison.Ordinal)));
        await transaction.RecoverIncompleteAsync(cancellationToken)
            .ConfigureAwait(false);
        var result = await transaction.ExecuteAsync(
                changes,
                ignoredCancellationToken =>
                {
                    new VerificationService()
                        .VerifyPlugins(
                            paths,
                            payloadRoot,
                            validatedCatalog);
                    return Task.CompletedTask;
                },
                cancellationToken)
            .ConfigureAwait(false);
        var installed = package.Plugins
            .Where(plugin => plugin.Delivery == PluginDelivery.Offline)
            .Select(plugin => File.Exists(Path.Combine(
                paths.OfflineMarketplaces,
                plugin.Marketplace,
                "plugins",
                plugin.Id,
                ".codex-plugin",
                "plugin.json")))
            .ToArray();
        return new PluginInstallResult(
            package.Plugins.Select(plugin => plugin.Marketplace)
                .Distinct(StringComparer.Ordinal)
                .Count(),
            package.Plugins.Count,
            installed,
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
            "plugin-marketplaces");
        var package = ValidatePackage(component.Path);
        var targets = BuildRecoveryTargets(package);
        targets.Add(new ManagedTargetDefinition(
            "plugin.configuration",
            paths.UserProfile,
            paths.CodexConfig));
        var transaction = new TransactionService(
            paths.PluginTransactionsRoot,
            new ManagedTargetCatalog(targets),
            new AtomicConfigurationFileSystem(
                aclPolicy: aclPolicy,
                protectTarget: target => string.Equals(
                    target,
                    paths.CodexConfig,
                    OperatingSystem.IsWindows()
                        ? StringComparison.OrdinalIgnoreCase
                        : StringComparison.Ordinal)));
        return await transaction.RecoverIncompleteAsync(cancellationToken)
            .ConfigureAwait(false);
    }

    internal static PluginPackage ValidatePackage(string payloadPluginsRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadPluginsRoot);
        var root = Path.GetFullPath(payloadPluginsRoot);
        if (!Directory.Exists(root))
            throw new DirectoryNotFoundException(root);
        RequireNoReparsePoints(root);
        ValidateRootShape(root);
        var catalogPath = Path.Combine(root, "plugin-catalog.json");
        using var catalog = JsonDocument.Parse(File.ReadAllBytes(catalogPath));
        var catalogRoot = catalog.RootElement;
        if (catalogRoot.ValueKind != JsonValueKind.Object
            || catalogRoot.GetProperty("schemaVersion").GetInt32() != 2
            || catalogRoot.GetProperty("plugins").ValueKind
                != JsonValueKind.Array)
        {
            throw new InvalidDataException("Invalid plugin catalog.");
        }
        var plugins = catalogRoot.GetProperty("plugins")
            .EnumerateArray()
            .Select(ParseManagedPlugin)
            .ToArray();
        if (!plugins.SequenceEqual(RequiredPlugins)
            || plugins.Any(plugin =>
                !IsIdentifier(plugin.Marketplace)
                || !IsIdentifier(plugin.Id)))
        {
            throw new InvalidDataException(
                "Plugin catalog must pin the expected three marketplaces and nine plugins.");
        }

        var offlinePlugins = plugins
            .Where(plugin => plugin.Delivery == PluginDelivery.Offline)
            .ToArray();
        foreach (var plugin in offlinePlugins)
        {
            var marketplaceIdentity = ValidatePluginIdentity(
                Path.Combine(
                    root,
                    "marketplaces",
                    plugin.Marketplace,
                    "plugins",
                    plugin.Id,
                    ".codex-plugin",
                    "plugin.json"),
                plugin);
            var cacheRoot = Path.Combine(
                root,
                "cache",
                plugin.Marketplace,
                plugin.Id);
            if (!Directory.Exists(cacheRoot))
                throw new InvalidDataException("Plugin cache entry is missing.");
            var versions = Directory.EnumerateDirectories(cacheRoot).ToArray();
            if (versions.Length != 1)
                throw new InvalidDataException(
                    "Plugin cache must contain exactly one frozen version.");
            var cacheIdentity = ValidatePluginIdentity(
                Path.Combine(
                    versions[0],
                    ".codex-plugin",
                    "plugin.json"),
                plugin);
            if (!string.Equals(
                    marketplaceIdentity,
                    cacheIdentity,
                    StringComparison.Ordinal)
                || !string.Equals(
                    Path.GetFileName(versions[0]),
                    marketplaceIdentity,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Plugin marketplace and cache versions do not match.");
            }
        }
        ValidateExactPluginDirectories(root, offlinePlugins);
        return new PluginPackage(
            root,
            plugins,
            offlinePlugins,
            CollectExplicitFiles(root, offlinePlugins));
    }

    internal static string ConfigurePlugins(
        string existing,
        IReadOnlyList<ManagedPlugin> plugins,
        string offlineMarketplaces)
    {
        var config = existing;
        foreach (var marketplace in plugins
                     .Where(plugin => plugin.Delivery == PluginDelivery.Runtime)
                     .Select(plugin => plugin.Marketplace)
                     .Distinct(StringComparer.Ordinal))
        {
            var section = $"marketplaces.{marketplace}";
            if (TomlEditor.Value(config, section, "source_type") == "local"
                && TomlEditor.Value(config, section, "source")
                == Path.Combine(offlineMarketplaces, marketplace))
            {
                config = TomlEditor.WithoutSection(config, section);
            }
        }
        foreach (var marketplace in plugins
                     .Where(plugin => plugin.Delivery == PluginDelivery.Offline)
                     .Select(plugin => plugin.Marketplace)
                     .Distinct(StringComparer.Ordinal)
                     .OrderBy(value => value, StringComparer.Ordinal))
        {
            config = TomlEditor.WithSection(
                config,
                $"marketplaces.{marketplace}",
                new[]
                {
                    new KeyValuePair<string, string>(
                        "source_type",
                        InstallerConfig.QuoteToml("local")),
                    new KeyValuePair<string, string>(
                        "source",
                        InstallerConfig.QuoteToml(Path.Combine(
                            offlineMarketplaces,
                            marketplace)))
                });
        }
        foreach (var plugin in plugins)
        {
            config = TomlEditor.WithSection(
                config,
                $"plugins.{plugin.Id}@{plugin.Marketplace}",
                new[]
                {
                    new KeyValuePair<string, string>("enabled", "true")
                });
        }
        return config;
    }

    private static ManagedPlugin ParseManagedPlugin(JsonElement item)
    {
        var deliveryText = item.GetProperty("delivery").GetString();
        var delivery = deliveryText switch
        {
            "offline" => PluginDelivery.Offline,
            "runtime" => PluginDelivery.Runtime,
            _ => throw new InvalidDataException("Plugin delivery is invalid.")
        };
        var runtimeId = item.TryGetProperty("runtimeId", out var runtime)
            ? runtime.GetString()
            : null;
        if ((delivery == PluginDelivery.Runtime
                && !string.Equals(
                    runtimeId,
                    "codex-primary-runtime",
                    StringComparison.Ordinal))
            || (delivery == PluginDelivery.Offline && runtimeId is not null))
        {
            throw new InvalidDataException("Plugin runtime delivery is invalid.");
        }
        return new ManagedPlugin(
            item.GetProperty("marketplace").GetString() ?? string.Empty,
            item.GetProperty("id").GetString() ?? string.Empty,
            delivery,
            runtimeId);
    }

    private List<ManagedTargetDefinition> BuildRecoveryTargets(
        PluginPackage package)
    {
        var targets = new List<ManagedTargetDefinition>();
        for (var index = 0; index < package.Files.Count; index++)
        {
            var file = package.Files[index];
            var root = file.Tree == "marketplaces"
                ? paths.OfflineMarketplaces
                : paths.PluginCache;
            targets.Add(new ManagedTargetDefinition(
                $"plugin.file.{index + 1:D5}",
                paths.UserProfile,
                Path.Combine(root, file.RelativePath)));
        }
        return targets;
    }

    private static string ValidatePluginIdentity(
        string path,
        ManagedPlugin expected)
    {
        if (!File.Exists(path))
            throw new InvalidDataException("Plugin identity file is missing.");
        using var identity = JsonDocument.Parse(File.ReadAllBytes(path));
        var root = identity.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("name", out var name)
            || !string.Equals(
                name.GetString(),
                expected.Id,
                StringComparison.Ordinal)
            || !root.TryGetProperty("version", out var version)
            || string.IsNullOrWhiteSpace(version.GetString()))
        {
            throw new InvalidDataException("Plugin identity does not match catalog.");
        }
        if (root.TryGetProperty("marketplace", out var marketplace)
            && !string.Equals(
                marketplace.GetString(),
                expected.Marketplace,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Plugin marketplace identity does not match catalog.");
        }
        return version.GetString()!;
    }

    private static void ValidateRootShape(string root)
    {
        var directories = Directory.EnumerateDirectories(root)
            .Select(Path.GetFileName)
            .ToHashSet(StringComparer.Ordinal);
        if (!directories.SetEquals(["marketplaces", "cache"]))
            throw new InvalidDataException(
                "Plugin payload contains an extra root directory.");
        var files = Directory.EnumerateFiles(root)
            .Select(Path.GetFileName)
            .ToHashSet(StringComparer.Ordinal);
        if (!files.SetEquals(["plugin-catalog.json"])
            && !files.SetEquals(["plugin-catalog.json", "file-manifest.json"]))
        {
            throw new InvalidDataException(
                "Plugin payload contains an extra root file.");
        }
    }

    private static void ValidateExactPluginDirectories(
        string root,
        IReadOnlyList<ManagedPlugin> plugins)
    {
        var expectedByMarket = plugins
            .GroupBy(plugin => plugin.Marketplace, StringComparer.Ordinal)
            .ToDictionary(
                group => group.Key,
                group => group.Select(plugin => plugin.Id)
                    .ToHashSet(StringComparer.Ordinal),
                StringComparer.Ordinal);
        foreach (var tree in new[] { "marketplaces", "cache" })
        {
            var treeRoot = Path.Combine(root, tree);
            if (Directory.EnumerateFiles(treeRoot).Any())
            {
                throw new InvalidDataException(
                    "Plugin marketplace/cache root contains an extra file.");
            }
            var actualMarkets = Directory.EnumerateDirectories(treeRoot)
                .Select(Path.GetFileName)
                .ToHashSet(StringComparer.Ordinal);
            if (!actualMarkets.SetEquals(expectedByMarket.Keys))
                throw new InvalidDataException(
                    "Plugin payload contains an extra marketplace.");
        }
        foreach (var pair in expectedByMarket)
        {
            var marketRoot = Path.Combine(
                root,
                "marketplaces",
                pair.Key);
            var marketDirectories = Directory.EnumerateDirectories(marketRoot)
                .Select(Path.GetFileName)
                .ToHashSet(StringComparer.Ordinal);
            if (!marketDirectories.IsSubsetOf(["plugins", ".agents"])
                || !marketDirectories.Contains("plugins"))
            {
                throw new InvalidDataException(
                    "Marketplace contains an extra directory.");
            }
            var marketFiles = Directory.EnumerateFiles(marketRoot)
                .Select(Path.GetFileName)
                .ToArray();
            if (marketFiles.Any(file => file != "marketplace.json"))
                throw new InvalidDataException(
                    "Marketplace contains an extra file.");
            if (marketDirectories.Contains(".agents"))
            {
                var agentsRoot = Path.Combine(marketRoot, ".agents");
                if (Directory.EnumerateFiles(agentsRoot).Any()
                    || !Directory.EnumerateDirectories(agentsRoot)
                        .Select(Path.GetFileName)
                        .ToHashSet(StringComparer.Ordinal)
                        .SetEquals(["plugins"]))
                {
                    throw new InvalidDataException(
                        "Marketplace metadata contains an extra entry.");
                }
                var agentsPluginsRoot = Path.Combine(agentsRoot, "plugins");
                if (Directory.EnumerateDirectories(agentsPluginsRoot).Any()
                    || !Directory.EnumerateFiles(agentsPluginsRoot)
                        .Select(Path.GetFileName)
                        .ToHashSet(StringComparer.Ordinal)
                        .SetEquals(["marketplace.json"]))
                {
                    throw new InvalidDataException(
                        "Marketplace metadata contains an extra entry.");
                }
            }
            var marketplacePluginsRoot = Path.Combine(marketRoot, "plugins");
            if (Directory.EnumerateFiles(marketplacePluginsRoot).Any())
            {
                throw new InvalidDataException(
                    "Marketplace plugin root contains an extra file.");
            }
            var actualPlugins = Directory.EnumerateDirectories(
                    marketplacePluginsRoot)
                .Select(Path.GetFileName)
                .ToHashSet(StringComparer.Ordinal);
            var cacheMarketRoot = Path.Combine(root, "cache", pair.Key);
            if (Directory.EnumerateFiles(cacheMarketRoot).Any())
            {
                throw new InvalidDataException(
                    "Plugin cache market root contains an extra file.");
            }
            var cachedPlugins = Directory.EnumerateDirectories(
                    cacheMarketRoot)
                .Select(Path.GetFileName)
                .ToHashSet(StringComparer.Ordinal);
            if (!actualPlugins.SetEquals(pair.Value)
                || !cachedPlugins.SetEquals(pair.Value))
            {
                throw new InvalidDataException(
                    "Marketplace contains an extra plugin.");
            }
            foreach (var plugin in pair.Value)
            {
                var cachePluginRoot = Path.Combine(
                    cacheMarketRoot,
                    plugin);
                if (Directory.EnumerateFiles(cachePluginRoot).Any())
                {
                    throw new InvalidDataException(
                        "Plugin cache entry contains an extra root file.");
                }
            }
        }
    }

    private static IReadOnlyList<FrozenPluginFile> CollectExplicitFiles(
        string root,
        IReadOnlyList<ManagedPlugin> plugins)
    {
        var files = new List<FrozenPluginFile>();
        foreach (var market in plugins.Select(plugin => plugin.Marketplace)
                     .Distinct(StringComparer.Ordinal))
        {
            foreach (var metadata in new[]
                     {
                         Path.Combine(
                             root,
                             "marketplaces",
                             market,
                             "marketplace.json"),
                         Path.Combine(
                             root,
                             "marketplaces",
                             market,
                             ".agents",
                             "plugins",
                             "marketplace.json")
                     })
            {
                if (File.Exists(metadata))
                    files.Add(Frozen(root, metadata, "marketplaces"));
            }
        }
        foreach (var plugin in plugins)
        {
            var marketplaceRoot = Path.Combine(
                root,
                "marketplaces",
                plugin.Marketplace,
                "plugins",
                plugin.Id);
            foreach (var path in Directory.EnumerateFiles(
                         marketplaceRoot,
                         "*",
                         SearchOption.AllDirectories))
                files.Add(Frozen(root, path, "marketplaces"));
            var cacheRoot = Path.Combine(
                root,
                "cache",
                plugin.Marketplace,
                plugin.Id);
            foreach (var path in Directory.EnumerateFiles(
                         cacheRoot,
                         "*",
                         SearchOption.AllDirectories))
                files.Add(Frozen(root, path, "cache"));
        }
        if (files.Any(file => ExecutableExtension(file.RelativePath)))
            throw new InvalidDataException(
                "Plugin payload contains executable content.");
        return files.OrderBy(
                file => $"{file.Tree}/{file.RelativePath}",
                StringComparer.Ordinal)
            .ToArray();
    }

    private static FrozenPluginFile Frozen(
        string root,
        string path,
        string tree)
    {
        var treeRoot = Path.Combine(root, tree);
        return new FrozenPluginFile(
            tree,
            Path.GetRelativePath(treeRoot, path),
            File.ReadAllBytes(path));
    }

    private static bool ExecutableExtension(string path) =>
        Path.GetExtension(path).ToLowerInvariant() is
            ".exe" or ".dll" or ".com" or ".bat" or ".cmd" or ".ps1"
            or ".msi" or ".msix" or ".appx";

    private static bool IsIdentifier(string value) =>
        value.Length is > 0 and <= 128
        && value.All(character =>
            character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '-'
            or '_');

    private static void RequireNoReparsePoints(string root)
    {
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Plugin payload root is a reparse point.");
        foreach (var path in Directory.EnumerateFileSystemEntries(
                     root,
                     "*",
                     SearchOption.AllDirectories))
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException(
                    "Plugin payload contains a reparse point.");
        }
    }

    internal sealed record PluginPackage(
        string Root,
        IReadOnlyList<ManagedPlugin> Plugins,
        IReadOnlyList<ManagedPlugin> OfflinePlugins,
        IReadOnlyList<FrozenPluginFile> Files);

    internal sealed record FrozenPluginFile(
        string Tree,
        string RelativePath,
        byte[] Data);
}
