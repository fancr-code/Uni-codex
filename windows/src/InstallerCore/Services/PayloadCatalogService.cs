using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CodexOneClickInstaller;

public sealed class PayloadCatalogService
{
    private const string ExpectedPackageFamily = "OpenAI.Codex_2p2nqsd0c76g0";
    private const string ExpectedCompatibilityRevision = "cross-provider-content-v1";
    private const string ExpectedScriptCommit = "b3c1d16d7d75145b9cf5b0e34000316436d905dd";
    private const string ExpectedScriptIndexSha =
        "0776ecee1165babd3794fa3a740433b5326549bc8c5d8546aa4f8bb52374d540";
    private static readonly Regex Sha256Pattern =
        new("^[0-9a-f]{64}$", RegexOptions.CultureInvariant);
    private static readonly Regex DrivePathPattern =
        new("^[A-Za-z]:", RegexOptions.CultureInvariant);
    private static readonly Regex ReservedDevicePattern =
        new("^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\..*)?$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex DependencyIdPattern =
        new("^codex-dependency-[0-9]+$", RegexOptions.CultureInvariant);
    private static readonly HashSet<string> RequiredComponentIds =
    [
        "codex-windows-x64",
        "codex-plus-plus-windows-x64",
        "codex-plus-plus-source",
        "model-catalog",
        "plugin-marketplaces",
        "script-market"
    ];
    private static readonly IReadOnlyDictionary<string, string> ExpectedPluginDelivery =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["openai-bundled/browser"] = "offline",
            ["openai-bundled/chrome"] = "offline",
            ["openai-bundled/computer-use"] = "offline",
            ["openai-bundled/latex"] = "offline",
            ["openai-primary-runtime/pdf"] = "runtime",
            ["openai-primary-runtime/documents"] = "runtime",
            ["openai-primary-runtime/spreadsheets"] = "runtime",
            ["openai-primary-runtime/presentations"] = "runtime",
            ["openai-curated/github"] = "offline"
        };
    private static readonly HashSet<string> ExpectedPlugins =
        ExpectedPluginDelivery.Keys.ToHashSet(StringComparer.Ordinal);
    private static readonly IReadOnlyDictionary<string, ScriptLock> ProductionScriptLocks =
        new Dictionary<string, ScriptLock>(StringComparer.Ordinal)
        {
            ["codex-context-used-meter"] = new("101",
                "7d1f79dd2f379bf25787ed1fc65778266fd286cd33966692708f985fe3adba7d"),
            ["codex-token-usage"] = new("0.1.7",
                "bf233607f8e60f56b3c68d29c15bbd5ed5d7582fc488380f56b8d2f553bb4ddd"),
            ["codex-daily-token-usage"] = new("1.4.13",
                "80f5efb88d1e2e0da5c22f229b65d08710460a7c258bdaea7b82a84071fb7576"),
            ["codex-live-token-cost"] = new("0.7.2",
                "aee6bf61236aa9edf183a71bba5a45cbb1f273f94e2197d4421d557999de5da8")
        };
    private static readonly IReadOnlyDictionary<string, ScriptLock> FixtureScriptLocks =
        new Dictionary<string, ScriptLock>(StringComparer.Ordinal)
        {
            ["codex-context-used-meter"] = new("101",
                "2355c76bc467f5ba25f56ead9abf3ee1dc1c8653a6d6d9d0f0846d7b89b65798"),
            ["codex-token-usage"] = new("0.1.7",
                "15f97d3ecd87886cf9c6c47dd0e6040ac422a0c659d3e32ea169932f79377467"),
            ["codex-daily-token-usage"] = new("1.4.13",
                "e5060f06cd96022c315892e54e96958d7dc7753bcf857f23d734b8b474cb7c59"),
            ["codex-live-token-cost"] = new("0.7.2",
                "bd433af9ba95637e0a6babb7728e50d50d3ef44763a3e7d1ec47e4d9c25ece82")
        };
    private static readonly IReadOnlyDictionary<string, ComponentLock> ProductionComponents =
        new Dictionary<string, ComponentLock>(StringComparer.Ordinal)
        {
            ["codex-windows-x64"] = new("apps/Codex.msix", "msix"),
            ["codex-plus-plus-windows-x64"] = new(
                "apps/CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe", "exe"),
            ["codex-plus-plus-source"] = new(
                "sources/CodexPlusPlus-v1.2.43-codexkit.1-source.tar.gz", "archive"),
            ["model-catalog"] = new("model-catalog.json", "json"),
            ["plugin-marketplaces"] = new("plugins", "directory"),
            ["script-market"] = new("script-market", "directory")
        };
    private static readonly IReadOnlyDictionary<string, ComponentLock> FixtureComponents =
        new Dictionary<string, ComponentLock>(StringComparer.Ordinal)
        {
            ["codex-windows-x64"] = new("apps/Codex.msix", "msix"),
            ["codex-plus-plus-windows-x64"] = new(
                "apps/CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe", "exe"),
            ["codex-plus-plus-source"] = new(
                "sources/CodexPlusPlus-v1.2.43-codexkit.1-source.tar.gz", "archive"),
            ["model-catalog"] = new("model-catalog.json", "json"),
            ["plugin-marketplaces"] = new("plugins", "directory"),
            ["script-market"] = new("script-market", "directory")
        };
    private const string FixtureScriptCommit = "fixture-commit";
    private const string FixtureScriptIndexSha =
        "bdb39dcb17eb31776318f7acdab4dc31a5bc2b782feba9dc21b0022f0556a5f4";
    private readonly Func<string, FileAttributes> _getAttributes;

    public PayloadCatalogService() : this(File.GetAttributes) { }

    public PayloadCatalogService(Func<string, FileAttributes> getAttributes) =>
        _getAttributes = getAttributes ?? throw new ArgumentNullException(nameof(getAttributes));

    public async Task<PayloadCatalog> ValidateAsync(
        string payloadRoot,
        bool fixtureMode = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadRoot);
        var root = Path.GetFullPath(payloadRoot);
        if (!Directory.Exists(root))
            throw Invalid($"payload root does not exist: {root}");
        RejectReparsePointsInAbsolutePath(root, "payload root", _getAttributes);

        var manifestPath = Path.Combine(root, "payload-manifest.json");
        var manifest = await ParseJsonFileAsync(manifestPath, "payload manifest",
            cancellationToken);
        using (manifest)
        {
            var document = manifest.RootElement;
            if (document.ValueKind != JsonValueKind.Object)
                throw Invalid("payload manifest root must be an object");
            if (RequiredInt32(document, "schemaVersion") != 2)
                throw Invalid("payload manifest schemaVersion must be 2");
            var manifestFixture = OptionalBoolean(document, "fixture") ?? false;
            if (fixtureMode != manifestFixture)
            {
                throw Invalid(
                    "fixture payload requires explicit fixtureMode and production mode rejects fixture manifests");
            }

            var supplyLock = await LoadPayloadLockAsync(root, fixtureMode, cancellationToken);
            var files = RequiredProperty(document, "files", JsonValueKind.Array);
            var entries = new List<PayloadEntry>();
            var byId = new Dictionary<string, PayloadEntry>(StringComparer.Ordinal);
            var byWindowsPath = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var element in files.EnumerateArray())
            {
                var entry = ParseEntry(element);
                if (!RequiredComponentIds.Contains(entry.Id)
                    && !DependencyIdPattern.IsMatch(entry.Id))
                    throw Invalid($"unexpected payload id: {entry.Id}");
                if (!byId.TryAdd(entry.Id, entry))
                    throw Invalid($"duplicate payload id: {entry.Id}");
                if (!byWindowsPath.TryAdd(entry.RelativePath, entry.Id))
                {
                    throw Invalid(
                        $"relativePath collision under Windows case rules: {entry.RelativePath}");
                }
                entries.Add(entry);
            }

            foreach (var id in RequiredComponentIds)
            {
                if (!byId.ContainsKey(id))
                    throw Invalid($"missing required component: {id}");
            }

            ValidateCanonicalComponents(byId, supplyLock);
            ValidateComponentIdentity(byId, supplyLock);
            await ValidatePluginCatalogAsync(root, supplyLock, cancellationToken);
            await ValidateMonitoringScriptsAsync(root, supplyLock, cancellationToken);

            foreach (var entry in entries)
                await ValidatePayloadAsync(root, entry, cancellationToken);

            return new PayloadCatalog(2, entries);
        }
    }

    public static async Task<DirectoryHashResult> CalculateDirectoryHashAsync(
        string directory,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        var root = Path.GetFullPath(directory);
        if (!Directory.Exists(root))
            throw Invalid($"payload directory does not exist: {root}");
        RejectReparsePointsInAbsolutePath(root, "payload directory", File.GetAttributes);

        var files = new List<(string RelativePath, string FullPath)>();
        var windowsPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            foreach (var path in Directory.EnumerateFileSystemEntries(current))
            {
                RejectReparsePoint(path, "payload tree entry");
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    pending.Push(path);
                    continue;
                }

                var relativePath = Path.GetRelativePath(root, path)
                    .Replace(Path.DirectorySeparatorChar, '/')
                    .Replace(Path.AltDirectorySeparatorChar, '/');
                relativePath = NormalizeRelativePath(relativePath);
                if (!windowsPaths.Add(relativePath))
                {
                    throw Invalid(
                        $"directory path collision under Windows case rules: {relativePath}");
                }
                files.Add((relativePath, path));
            }
        }

        files.Sort((left, right) => CompareUtf8(left.RelativePath, right.RelativePath));
        using var treeHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long totalSize = 0;
        foreach (var (relativePath, fullPath) in files)
        {
            var result = await CalculateFileHashAsync(fullPath, cancellationToken);
            totalSize = checked(totalSize + result.Size);
            AppendUtf8(treeHash, relativePath);
            treeHash.AppendData([0]);
            AppendUtf8(treeHash, result.Sha256);
            treeHash.AppendData([0]);
            AppendUtf8(treeHash, result.Size.ToString(CultureInfo.InvariantCulture));
            treeHash.AppendData([(byte)'\n']);
        }

        return new DirectoryHashResult(
            Convert.ToHexString(treeHash.GetHashAndReset()).ToLowerInvariant(),
            totalSize);
    }

    private static async Task<PayloadSupplyLock> LoadPayloadLockAsync(
        string root,
        bool fixtureMode,
        CancellationToken cancellationToken)
    {
        var path = Path.Combine(root, "payload-lock.json");
        JsonDocument document;
        try
        {
            document = await ParseJsonFileAsync(path, "payload lock", cancellationToken);
        }
        catch (InvalidDataException exception)
        {
            throw Invalid($"payload lock is invalid: {exception.Message}", exception);
        }
        using (document)
        {
            try
            {
                var value = document.RootElement;
                var rootFields = new List<string>
                {
                    "schemaVersion", "requiredComponents", "components", "codex",
                    "codexPlusPlus", "plugins", "monitoringScripts", "scriptMarket"
                };
                if (fixtureMode) rootFields.Add("fixture");
                RequireExactProperties(value, "payload lock", rootFields);
                if (RequiredInt32(value, "schemaVersion") != 2)
                    throw Invalid("schemaVersion must be 2");
                if ((OptionalBoolean(value, "fixture") ?? false) != fixtureMode)
                    throw Invalid("fixture marker does not match explicit fixture mode");

                var required = RequiredProperty(value, "requiredComponents", JsonValueKind.Array)
                    .EnumerateArray().Select(item => RequiredArrayString(item,
                        "requiredComponents")).ToHashSet(StringComparer.Ordinal);
                if (!required.SetEquals(RequiredComponentIds))
                    throw Invalid("required component IDs do not match the approved set");

                var componentsElement = RequiredProperty(value, "components",
                    JsonValueKind.Object);
                var components = new Dictionary<string, ComponentLock>(StringComparer.Ordinal);
                foreach (var component in componentsElement.EnumerateObject())
                {
                    RequireExactProperties(component.Value,
                        $"payload lock component {component.Name}",
                        ["relativePath", "format"]);
                    components[component.Name] = new ComponentLock(
                        NormalizeRelativePath(RequiredString(component.Value, "relativePath")),
                        RequiredString(component.Value, "format"));
                }
                if (!components.Keys.ToHashSet(StringComparer.Ordinal)
                        .SetEquals(RequiredComponentIds))
                    throw Invalid("canonical component rules are incomplete");
                var compiledComponents = fixtureMode
                    ? FixtureComponents
                    : ProductionComponents;
                if (components.Count != compiledComponents.Count
                    || components.Any(pair =>
                        !compiledComponents.TryGetValue(pair.Key, out var compiled)
                        || pair.Value != compiled))
                    throw Invalid("payload lock components differ from compiled policy");

                var codex = RequiredProperty(value, "codex", JsonValueKind.Object);
                RequireExactProperties(codex, "payload lock Codex",
                    ["architecture", "packageFamilyName"]);
                if (RequiredString(codex, "architecture") != "x64"
                    || RequiredString(codex, "packageFamilyName") != ExpectedPackageFamily)
                    throw Invalid("Codex identity rule is not approved");

                var cpp = RequiredProperty(value, "codexPlusPlus", JsonValueKind.Object);
                RequireExactProperties(cpp, "payload lock Codex++",
                    ["payloadVersion", "architecture", "compatibilityRevision", "licenseID"]);
                var cppVersion = RequiredString(cpp, "payloadVersion");
                if (RequiredString(cpp, "architecture") != "x64"
                    || RequiredString(cpp, "compatibilityRevision")
                        != ExpectedCompatibilityRevision
                    || RequiredString(cpp, "licenseID") != "AGPL-3.0-only"
                    || cppVersion != "1.2.43+codexkit.1")
                    throw Invalid("Codex++ lock rule differs from compiled policy");

                var plugins = ReadPluginSet(value);
                if (!plugins.SetEquals(ExpectedPlugins))
                    throw Invalid(
                        "plugin rules differ from compiled policy of three markets and nine plugins");

                var scripts = ReadScriptLocks(value);
                var compiledScripts = fixtureMode ? FixtureScriptLocks : ProductionScriptLocks;
                if (!ScriptLocksEqual(scripts, compiledScripts))
                    throw Invalid(
                        "monitoring script versions or hashes differ from compiled policy");

                var market = RequiredProperty(value, "scriptMarket", JsonValueKind.Object);
                RequireExactProperties(market, "payload lock script market",
                    ["commit", "indexSha256"]);
                var commit = RequiredString(market, "commit");
                var indexSha = RequiredString(market, "indexSha256");
                var compiledCommit = fixtureMode ? FixtureScriptCommit : ExpectedScriptCommit;
                var compiledIndexSha = fixtureMode
                    ? FixtureScriptIndexSha
                    : ExpectedScriptIndexSha;
                if (!Sha256Pattern.IsMatch(indexSha)
                    || commit != compiledCommit || indexSha != compiledIndexSha)
                    throw Invalid(
                        "script market commit or index hash differs from compiled policy");

                return new PayloadSupplyLock(components, cppVersion, plugins, scripts,
                    commit, indexSha);
            }
            catch (InvalidDataException exception)
            {
                throw Invalid($"payload lock is invalid: {exception.Message}", exception);
            }
        }
    }

    private static HashSet<string> ReadPluginSet(JsonElement value)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (var plugin in RequiredProperty(value, "plugins", JsonValueKind.Array)
                     .EnumerateArray())
        {
            RequireExactProperties(plugin, "payload lock plugin", ["marketplace", "id"]);
            var identity = $"{RequiredString(plugin, "marketplace")}/" +
                           RequiredString(plugin, "id");
            if (!result.Add(identity))
                throw Invalid($"duplicate plugin lock: {identity}");
        }
        return result;
    }

    private static Dictionary<string, ScriptLock> ReadScriptLocks(JsonElement value)
    {
        var result = new Dictionary<string, ScriptLock>(StringComparer.Ordinal);
        foreach (var script in RequiredProperty(value, "monitoringScripts",
                     JsonValueKind.Array).EnumerateArray())
        {
            RequireExactProperties(script, "payload lock monitoring script",
                ["id", "version", "sha256"]);
            var id = RequiredString(script, "id");
            var sha = RequiredString(script, "sha256");
            if (!Sha256Pattern.IsMatch(sha)
                || !result.TryAdd(id, new ScriptLock(RequiredString(script, "version"), sha)))
                throw Invalid($"invalid or duplicate monitoring script lock: {id}");
        }
        if (!result.Keys.ToHashSet(StringComparer.Ordinal)
                .SetEquals(ProductionScriptLocks.Keys))
            throw Invalid("monitoring script lock IDs do not match the approved set");
        return result;
    }

    private static bool ScriptLocksEqual(
        IReadOnlyDictionary<string, ScriptLock> left,
        IReadOnlyDictionary<string, ScriptLock> right) =>
        left.Count == right.Count && left.All(pair =>
            right.TryGetValue(pair.Key, out var expected) && pair.Value == expected);

    private static PayloadEntry ParseEntry(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
            throw Invalid("each payload entry must be an object");
        var id = RequiredString(element, "id");
        var sha256 = RequiredString(element, "sha256");
        if (!Sha256Pattern.IsMatch(sha256))
            throw Invalid($"payload {id} sha256 must be 64 lowercase hexadecimal characters");
        var size = RequiredInt64(element, "size");
        if (size < 0)
            throw Invalid($"payload {id} size must not be negative");
        var source = RequiredString(element, "sourceURL");
        if (!Uri.TryCreate(source, UriKind.Absolute, out var sourceUrl)
            || sourceUrl.Scheme != Uri.UriSchemeHttps)
            throw Invalid($"payload {id} sourceURL must be an absolute HTTPS URL");

        return new PayloadEntry(
            id,
            RequiredString(element, "version"),
            RequiredString(element, "architecture"),
            NormalizeRelativePath(RequiredString(element, "relativePath")),
            sha256,
            size,
            sourceUrl,
            RequiredString(element, "format"),
            OptionalString(element, "packageFamilyName"),
            OptionalString(element, "publisher"),
            OptionalString(element, "packageName"),
            OptionalString(element, "minimumVersion"),
            OptionalString(element, "compatibilityRevision"),
            OptionalString(element, "licenseID"));
    }

    private static string NormalizeRelativePath(string path)
    {
        var normalized = path.Replace('\\', '/');
        if (normalized.Length == 0
            || normalized.StartsWith("/", StringComparison.Ordinal)
            || DrivePathPattern.IsMatch(normalized))
            throw Invalid($"unsafe relativePath: {path}");
        var segments = normalized.Split('/');
        foreach (var segment in segments)
        {
            if (segment.Length == 0 || segment is "." or ".."
                || segment.EndsWith(' ') || segment.EndsWith('.')
                || segment.Any(character => character < 32 || "<>:\"|?*".Contains(character))
                || ReservedDevicePattern.IsMatch(segment))
                throw Invalid($"unsafe relativePath: {path}");
        }
        return string.Join('/', segments);
    }

    private static void ValidateCanonicalComponents(
        IReadOnlyDictionary<string, PayloadEntry> entries,
        PayloadSupplyLock supplyLock)
    {
        foreach (var id in RequiredComponentIds)
        {
            var entry = entries[id];
            var canonical = supplyLock.Components[id];
            if (entry.RelativePath != canonical.RelativePath || entry.Format != canonical.Format)
                throw Invalid($"required component {id} does not use its canonical path and format");
        }

        var codex = entries["codex-windows-x64"];
        var expectedCodexPath = codex.Format switch
        {
            "msix" => "apps/Codex.msix",
            "msixbundle" => "apps/Codex.msixbundle",
            "appinstaller" => "apps/Codex.appinstaller",
            _ => string.Empty
        };
        if (codex.RelativePath != expectedCodexPath)
            throw Invalid("required component codex-windows-x64 does not use a canonical package path");
    }

    private static void ValidateComponentIdentity(
        IReadOnlyDictionary<string, PayloadEntry> entries,
        PayloadSupplyLock supplyLock)
    {
        var codex = entries["codex-windows-x64"];
        if (codex.Architecture != "x64"
            || codex.PackageFamilyName != ExpectedPackageFamily
            || string.IsNullOrWhiteSpace(codex.Publisher)
            || codex.Format is not ("msix" or "msixbundle" or "appinstaller"))
            throw Invalid("Codex identity requires x64, approved package family, publisher and format");

        var setup = entries["codex-plus-plus-windows-x64"];
        var source = entries["codex-plus-plus-source"];
        if (setup.Architecture != "x64"
            || source.Architecture != "source"
            || setup.Version != supplyLock.CodexPlusPlusVersion
            || source.Version != supplyLock.CodexPlusPlusVersion
            || setup.CompatibilityRevision != ExpectedCompatibilityRevision
            || source.CompatibilityRevision != ExpectedCompatibilityRevision
            || setup.LicenseId != "AGPL-3.0-only"
            || source.LicenseId != "AGPL-3.0-only")
            throw Invalid(
                "Codex++ setup/source identity, compatibilityRevision or license does not match the payload lock");
        if (entries["script-market"].Version != supplyLock.ScriptCommit)
            throw Invalid("script market version does not match the payload lock commit");

        foreach (var dependency in entries.Values.Where(entry =>
                     DependencyIdPattern.IsMatch(entry.Id)))
        {
            var extension = dependency.Format switch
            {
                "msix" => "msix",
                "msixbundle" => "msixbundle",
                _ => string.Empty
            };
            if (extension.Length == 0
                || !Regex.IsMatch(dependency.RelativePath,
                    $"^apps/dependencies/Codex-dependency-[0-9]+\\.{extension}$",
                    RegexOptions.CultureInvariant)
                || dependency.Architecture is not ("x64" or "neutral")
                || string.IsNullOrWhiteSpace(dependency.PackageName)
                || string.IsNullOrWhiteSpace(dependency.PackageFamilyName)
                || string.IsNullOrWhiteSpace(dependency.Publisher)
                || !Version.TryParse(dependency.Version, out var version)
                || !Version.TryParse(dependency.MinimumVersion, out var minimumVersion)
                || version < minimumVersion)
                throw Invalid(
                    $"dependency entry identity, format, architecture or MinVersion is invalid: {dependency.Id}");
        }
    }

    private static async Task ValidatePluginCatalogAsync(
        string root,
        PayloadSupplyLock supplyLock,
        CancellationToken cancellationToken)
    {
        var pluginRoot = Path.Combine(root, "plugins");
        var path = Path.Combine(pluginRoot, "plugin-catalog.json");
        var document = await ParseJsonFileAsync(path, "plugin catalog", cancellationToken);
        using (document)
        {
            if (RequiredInt32(document.RootElement, "schemaVersion") != 2)
                throw Invalid("plugin catalog schemaVersion must be 2");
            var actual = new HashSet<string>(StringComparer.Ordinal);
            var offline = new HashSet<string>(StringComparer.Ordinal);
            foreach (var plugin in RequiredProperty(document.RootElement, "plugins",
                         JsonValueKind.Array).EnumerateArray())
            {
                var identity = $"{RequiredString(plugin, "marketplace")}/" +
                               RequiredString(plugin, "id");
                if (!actual.Add(identity))
                    throw Invalid($"duplicate plugin: {identity}");
                var delivery = RequiredString(plugin, "delivery");
                if (!ExpectedPluginDelivery.TryGetValue(identity, out var expectedDelivery)
                    || delivery != expectedDelivery)
                    throw Invalid($"plugin delivery differs from compiled policy: {identity}");
                if (delivery == "offline")
                {
                    if (plugin.TryGetProperty("runtimeId", out _))
                        throw Invalid($"offline plugin has runtimeId: {identity}");
                    offline.Add(identity);
                }
                else if (delivery == "runtime")
                {
                    if (RequiredString(plugin, "runtimeId") != "codex-primary-runtime")
                        throw Invalid($"plugin runtimeId differs from compiled policy: {identity}");
                }
                else
                {
                    throw Invalid($"invalid plugin delivery: {identity}");
                }
            }
            if (!actual.SetEquals(supplyLock.Plugins))
                throw Invalid("plugin catalog does not match the locked three markets/nine plugins");

            await ValidatePluginDirectoriesAsync(pluginRoot, offline, cancellationToken);
        }
    }

    private static async Task ValidatePluginDirectoriesAsync(
        string pluginRoot,
        IReadOnlySet<string> expected,
        CancellationToken cancellationToken)
    {
        var marketRoot = Path.Combine(pluginRoot, "marketplaces");
        var expectedByMarket = expected.Select(identity => identity.Split('/', 2))
            .GroupBy(parts => parts[0], parts => parts[1], StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.ToHashSet(StringComparer.Ordinal),
                StringComparer.Ordinal);
        var actualMarkets = Directory.EnumerateDirectories(marketRoot)
            .Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal);
        var actualCacheMarkets = Directory.EnumerateDirectories(
                Path.Combine(pluginRoot, "cache"))
            .Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal);
        if (!actualMarkets.SetEquals(expectedByMarket.Keys))
            throw Invalid("plugin marketplace directories contain missing or extra markets");
        if (!actualCacheMarkets.SetEquals(expectedByMarket.Keys))
            throw Invalid("plugin cache contains missing or extra markets");

        foreach (var (market, plugins) in expectedByMarket)
        {
            var pluginsRoot = Path.Combine(marketRoot, market, "plugins");
            var cacheMarketRoot = Path.Combine(pluginRoot, "cache", market);
            var actualPlugins = Directory.EnumerateDirectories(pluginsRoot)
                .Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal);
            var actualCachedPlugins = Directory.EnumerateDirectories(cacheMarketRoot)
                .Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal);
            if (!actualPlugins.SetEquals(plugins))
                throw Invalid($"plugin directories contain missing or extra plugins: {market}");
            if (!actualCachedPlugins.SetEquals(plugins))
                throw Invalid($"plugin cache contains missing or extra plugins: {market}");
            foreach (var plugin in plugins)
            {
                var identityPath = Path.Combine(pluginsRoot, plugin, ".codex-plugin",
                    "plugin.json");
                var identity = await ParseJsonFileAsync(identityPath,
                    $"plugin identity {market}/{plugin}", cancellationToken);
                using (identity)
                {
                    var version = RequiredString(identity.RootElement, "version");
                    if (RequiredString(identity.RootElement, "name") != plugin)
                        throw Invalid($"plugin identity mismatch: {market}/{plugin}");
                    var cachePluginRoot = Path.Combine(cacheMarketRoot, plugin);
                    var cachedVersions = Directory.EnumerateDirectories(cachePluginRoot)
                        .Select(Path.GetFileName).ToArray();
                    if (cachedVersions.Length != 1 || cachedVersions[0] != version)
                        throw Invalid($"plugin cache identity mismatch: {market}/{plugin}");
                    var cacheIdentity = await ParseJsonFileAsync(
                        Path.Combine(cachePluginRoot, version, ".codex-plugin", "plugin.json"),
                        $"plugin cache identity {market}/{plugin}", cancellationToken);
                    using (cacheIdentity)
                    {
                        if (RequiredString(cacheIdentity.RootElement, "name") != plugin
                            || RequiredString(cacheIdentity.RootElement, "version") != version)
                            throw Invalid($"plugin cache identity mismatch: {market}/{plugin}");
                    }
                }
            }
        }
    }

    private static async Task ValidateMonitoringScriptsAsync(
        string root,
        PayloadSupplyLock supplyLock,
        CancellationToken cancellationToken)
    {
        var marketRoot = Path.Combine(root, "script-market");
        var upstreamIndex = Path.Combine(marketRoot, "upstream-index.json");
        var upstreamDigest = await CalculateFileHashAsync(upstreamIndex, cancellationToken);
        if (upstreamDigest.Sha256 != supplyLock.ScriptIndexSha256)
            throw Invalid("script market upstream index sha256 does not match payload lock");

        var document = await ParseJsonFileAsync(Path.Combine(marketRoot, "index.json"),
            "script market index", cancellationToken);
        using (document)
        {
            var found = new HashSet<string>(StringComparer.Ordinal);
            foreach (var script in RequiredProperty(document.RootElement, "scripts",
                         JsonValueKind.Array).EnumerateArray())
            {
                var id = RequiredString(script, "id");
                if (!supplyLock.MonitoringScripts.TryGetValue(id, out var expected))
                    continue;
                if (!found.Add(id))
                    throw Invalid($"duplicate monitoring script: {id}");
                var version = RequiredString(script, "version");
                var expectedHash = RequiredString(script, "sha256");
                if (version != expected.Version || expectedHash != expected.Sha256)
                    throw Invalid($"monitoring script {id} has an invalid version or sha256");
                var localPath = OptionalString(script, "local_path") ?? $"scripts/{id}.js";
                if (localPath != $"scripts/{id}.js")
                    throw Invalid($"monitoring script {id} local path is not canonical");
                var actual = await CalculateFileHashAsync(
                    ResolveUnderRoot(marketRoot, localPath), cancellationToken);
                if (actual.Sha256 != expectedHash)
                    throw Invalid($"monitoring script {id} sha256 mismatch");
            }
            foreach (var expected in supplyLock.MonitoringScripts.Keys)
                if (!found.Contains(expected))
                    throw Invalid($"missing monitoring script: {expected}");
        }
    }

    private static async Task ValidatePayloadAsync(
        string root,
        PayloadEntry entry,
        CancellationToken cancellationToken)
    {
        var fullPath = ResolveUnderRoot(root, entry.RelativePath);
        RejectReparsePointsInPath(root, entry.RelativePath);
        FileHashResult actual;
        if (entry.Format == "directory")
        {
            if (!Directory.Exists(fullPath))
                throw Invalid($"payload {entry.Id} directory is missing");
            var directory = await CalculateDirectoryHashAsync(fullPath, cancellationToken);
            actual = new FileHashResult(directory.Sha256, directory.Size);
        }
        else
        {
            RejectUnsafeFile(fullPath, $"payload {entry.Id}");
            actual = await CalculateFileHashAsync(fullPath, cancellationToken);
        }
        if (actual.Sha256 != entry.Sha256)
            throw Invalid($"payload {entry.Id} sha256 mismatch");
        if (actual.Size != entry.Size)
            throw Invalid($"payload {entry.Id} size mismatch");
    }

    private static string ResolveUnderRoot(string root, string relativePath)
    {
        var fullPath = Path.GetFullPath(Path.Combine([root, .. relativePath.Split('/')]));
        var rootWithSeparator = root.TrimEnd(Path.DirectorySeparatorChar)
                                + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(rootWithSeparator,
                OperatingSystem.IsWindows()
                    ? StringComparison.OrdinalIgnoreCase
                    : StringComparison.Ordinal))
            throw Invalid($"relativePath escapes payload root: {relativePath}");
        return fullPath;
    }

    private static void RejectReparsePointsInAbsolutePath(
        string path,
        string description,
        Func<string, FileAttributes> getAttributes)
    {
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath)
                   ?? throw Invalid($"{description} has no volume root: {path}");
        var current = root;
        if ((getAttributes(current) & FileAttributes.ReparsePoint) != 0)
            throw Invalid(
                $"{description} volume or UNC root is a symbolic link or reparse point: {current}");
        foreach (var segment in fullPath[root.Length..]
                     .Split(Path.DirectorySeparatorChar,
                         StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if ((File.Exists(current) || Directory.Exists(current))
                && (getAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw Invalid($"{description} path contains a symbolic link or reparse point: {current}");
        }
    }

    private static void RejectReparsePointsInPath(string root, string relativePath)
    {
        var current = root;
        foreach (var segment in relativePath.Split('/'))
        {
            current = Path.Combine(current, segment);
            if ((File.Exists(current) || Directory.Exists(current))
                && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw Invalid($"payload path contains a symbolic link or reparse point: {current}");
        }
    }

    private static async Task<JsonDocument> ParseJsonFileAsync(
        string path,
        string description,
        CancellationToken cancellationToken)
    {
        RejectUnsafeFile(path, description);
        await using var stream = OpenReadOnly(path);
        try
        {
            return await JsonDocument.ParseAsync(stream, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            }, cancellationToken);
        }
        catch (JsonException exception)
        {
            throw Invalid($"{description} is not valid JSON", exception);
        }
    }

    private static async Task<FileHashResult> CalculateFileHashAsync(
        string path,
        CancellationToken cancellationToken)
    {
        RejectUnsafeFile(path, "payload file");
        await using var stream = OpenReadOnly(path);
        var digest = await SHA256.HashDataAsync(stream, cancellationToken);
        return new FileHashResult(Convert.ToHexString(digest).ToLowerInvariant(), stream.Length);
    }

    private static FileStream OpenReadOnly(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);

    private static void RejectUnsafeFile(string path, string description)
    {
        if (!File.Exists(path))
            throw Invalid($"{description} is missing: {path}");
        RejectReparsePoint(path, description);
        if ((File.GetAttributes(path) & FileAttributes.Directory) != 0)
            throw Invalid($"{description} must be a regular file: {path}");
    }

    private static void RejectReparsePoint(string path, string description)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw Invalid($"{description} is a symbolic link or reparse point: {path}");
    }

    private static JsonElement RequiredProperty(
        JsonElement element,
        string name,
        JsonValueKind kind)
    {
        if (element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty(name, out var property)
            || property.ValueKind != kind)
            throw Invalid($"{name} is required and must be {kind}");
        return property;
    }

    private static void RequireExactProperties(
        JsonElement element,
        string description,
        IEnumerable<string> expectedNames)
    {
        if (element.ValueKind != JsonValueKind.Object)
            throw Invalid($"{description} must be an object");
        var actual = element.EnumerateObject().Select(property => property.Name)
            .ToHashSet(StringComparer.Ordinal);
        if (!actual.SetEquals(expectedNames))
            throw Invalid($"{description} fields differ from compiled policy");
    }

    private static string RequiredString(JsonElement element, string name)
    {
        var value = RequiredProperty(element, name, JsonValueKind.String).GetString();
        if (string.IsNullOrWhiteSpace(value))
            throw Invalid($"{name} is required and must not be empty");
        return value;
    }

    private static string RequiredArrayString(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(element.GetString()))
            throw Invalid($"{name} must contain non-empty strings");
        return element.GetString()!;
    }

    private static string? OptionalString(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var property)
            || property.ValueKind == JsonValueKind.Null)
            return null;
        if (property.ValueKind != JsonValueKind.String)
            throw Invalid($"{name} must be a string when present");
        return property.GetString();
    }

    private static bool? OptionalBoolean(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var property))
            return null;
        if (property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw Invalid($"{name} must be a boolean when present");
        return property.GetBoolean();
    }

    private static int RequiredInt32(JsonElement element, string name)
    {
        var property = RequiredProperty(element, name, JsonValueKind.Number);
        if (!property.TryGetInt32(out var value))
            throw Invalid($"{name} must be a 32-bit integer");
        return value;
    }

    private static long RequiredInt64(JsonElement element, string name)
    {
        var property = RequiredProperty(element, name, JsonValueKind.Number);
        if (!property.TryGetInt64(out var value))
            throw Invalid($"{name} must be a 64-bit integer");
        return value;
    }

    private static void AppendUtf8(IncrementalHash hash, string value) =>
        hash.AppendData(Encoding.UTF8.GetBytes(value));

    private static int CompareUtf8(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        var common = Math.Min(leftBytes.Length, rightBytes.Length);
        for (var index = 0; index < common; index++)
        {
            var comparison = leftBytes[index].CompareTo(rightBytes[index]);
            if (comparison != 0) return comparison;
        }
        return leftBytes.Length.CompareTo(rightBytes.Length);
    }

    private static InvalidDataException Invalid(
        string message,
        Exception? innerException = null) =>
        new(message, innerException);

    private readonly record struct FileHashResult(string Sha256, long Size);
    private readonly record struct ComponentLock(string RelativePath, string Format);
    private readonly record struct ScriptLock(string Version, string Sha256);
    private sealed record PayloadSupplyLock(
        IReadOnlyDictionary<string, ComponentLock> Components,
        string CodexPlusPlusVersion,
        IReadOnlySet<string> Plugins,
        IReadOnlyDictionary<string, ScriptLock> MonitoringScripts,
        string ScriptCommit,
        string ScriptIndexSha256);
}

public readonly record struct DirectoryHashResult(string Sha256, long Size);
