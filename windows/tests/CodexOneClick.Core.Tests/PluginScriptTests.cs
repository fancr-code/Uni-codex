using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class PluginScriptTests : IDisposable
{
    private readonly string temporaryRoot = Path.Combine(
        Path.GetTempPath(),
        "codex-plugin-script-tests",
        Guid.NewGuid().ToString("N"));

    public PluginScriptTests() => Directory.CreateDirectory(temporaryRoot);

    [Fact]
    public async Task Five_redistributable_plugins_are_copied_and_all_nine_are_configured()
    {
        var paths = Paths();
        Directory.CreateDirectory(Path.GetDirectoryName(paths.CodexConfig)!);
        var existingConfig = $"""
            approval_policy = "never"

            [plugins."private@user-market"]
            enabled = false

            # Codex One Click Installer managed table: marketplaces.openai-primary-runtime
            [marketplaces.openai-primary-runtime]
            source_type = "local"
            source = "{Path.Combine(paths.OfflineMarketplaces, "openai-primary-runtime").Replace("\\", "\\\\")}"
            """;
        await File.WriteAllTextAsync(
            paths.CodexConfig,
            existingConfig.ReplaceLineEndings("\r\n"));
        var legacyMarketplaceFile = Path.Combine(
            paths.OfflineMarketplaces,
            "openai-primary-runtime",
            "plugins",
            "documents",
            "legacy.txt");
        var legacyCacheFile = Path.Combine(
            paths.PluginCache,
            "openai-primary-runtime",
            "documents",
            "legacy.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(legacyMarketplaceFile)!);
        Directory.CreateDirectory(Path.GetDirectoryName(legacyCacheFile)!);
        await File.WriteAllTextAsync(legacyMarketplaceFile, "legacy");
        await File.WriteAllTextAsync(legacyCacheFile, "legacy");
        var source = CreatePluginPayload();
        var catalog = Catalog(source);
        var installer = new PluginInstaller(paths);

        var result = await installer.InstallAsync(source, catalog);

        Assert.Equal(3, result.MarketplaceCount);
        Assert.Equal(9, result.PluginCount);
        Assert.All(result.InstalledPluginJson, Assert.True);
        Assert.Equal(5, result.InstalledPluginJson.Count);
        var config = await File.ReadAllTextAsync(paths.CodexConfig);
        Assert.Contains("approval_policy = \"never\"", config, StringComparison.Ordinal);
        Assert.Contains(
            """[plugins."private@user-market"]""",
            config,
            StringComparison.Ordinal);
        Assert.Contains(
            """[marketplaces.openai-bundled]""",
            config,
            StringComparison.Ordinal);
        Assert.Contains(
            """[plugins."browser@openai-bundled"]""",
            config,
            StringComparison.Ordinal);
        Assert.Contains(
            """[plugins."documents@openai-primary-runtime"]""",
            config,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            """[marketplaces.openai-primary-runtime]""",
            config,
            StringComparison.Ordinal);
        Assert.DoesNotContain("\r", config.Replace("\r\n", string.Empty));
        Assert.True(File.Exists(legacyMarketplaceFile));
        Assert.True(File.Exists(legacyCacheFile));

        var verification = new VerificationService().VerifyPlugins(
            paths,
            source,
            catalog);
        Assert.Equal("pass", verification.Status);
        Assert.Equal(3, verification.MarketplaceCount);
        Assert.Equal(9, verification.PluginCount);
        Assert.Equal(2, verification.OfflineMarketplaceCount);
        Assert.Equal(5, verification.OfflinePluginCount);
        Assert.Equal(4, verification.RuntimePluginCount);
        Assert.Equal("configured", verification.RuntimeStatus);
    }

    [Fact]
    public async Task Runtime_owned_marketplace_source_is_preserved()
    {
        var paths = Paths();
        Directory.CreateDirectory(Path.GetDirectoryName(paths.CodexConfig)!);
        const string existing =
            """
            [marketplaces.openai-primary-runtime]
            source_type = "local"
            source = "C:\\runtime-cache\\openai-primary-runtime"
            """;
        await File.WriteAllTextAsync(paths.CodexConfig, existing);
        var source = CreatePluginPayload();

        await new PluginInstaller(paths).InstallAsync(source, Catalog(source));

        var config = await File.ReadAllTextAsync(paths.CodexConfig);
        Assert.Contains(
            "source = \"C:\\\\runtime-cache\\\\openai-primary-runtime\"",
            config,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task Invalid_plugin_identity_is_rejected_before_any_installation_mutation()
    {
        var source = CreatePluginPayload();
        var identity = Path.Combine(
            source,
            "plugins",
            "marketplaces",
            "openai-bundled",
            "plugins",
            "browser",
            ".codex-plugin",
            "plugin.json");
        await File.WriteAllTextAsync(identity, """{"name":"other","version":"1.0.0"}""");
        var catalog = Catalog(source);
        var paths = Paths();

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new PluginInstaller(paths).InstallAsync(source, catalog));

        Assert.False(Directory.Exists(paths.OfflineMarketplaces));
        Assert.False(File.Exists(paths.CodexConfig));
    }

    [Fact]
    public async Task Complete_script_index_is_copied_with_only_three_defaults_enabled()
    {
        var snapshot = CreateScriptMarket();
        var catalog = Catalog(snapshot);
        var paths = Paths();
        Directory.CreateDirectory(paths.UserScriptsDirectory);
        await File.WriteAllTextAsync(
            Path.Combine(paths.UserScriptsDirectory, "manual.js"),
            "user-created");
        Directory.CreateDirectory(Path.GetDirectoryName(paths.UserScriptsConfig)!);
        await File.WriteAllTextAsync(
            paths.UserScriptsConfig,
            """
            {
              "enabled": false,
              "privateSetting": true,
              "scripts": {"user:manual.js": true},
              "market": {"user:manual.js": {"private": true}}
            }
            """);

        var result = await new ScriptMarketInstaller(paths).InstallAsync(
            snapshot,
            catalog);

        Assert.Equal(6, result.InstalledCount);
        foreach (var id in ScriptIds)
        {
            Assert.True(File.Exists(Path.Combine(
                paths.UserScriptsDirectory,
                $"market-{id}.js")));
        }
        Assert.Equal(
            "user-created",
            await File.ReadAllTextAsync(
                Path.Combine(paths.UserScriptsDirectory, "manual.js")));
        var config = JsonNode.Parse(
            await File.ReadAllTextAsync(paths.UserScriptsConfig))!.AsObject();
        Assert.True((bool)config["enabled"]!);
        Assert.True((bool)config["privateSetting"]!);
        var states = config["scripts"]!.AsObject();
        Assert.True((bool)states["user:manual.js"]!);
        Assert.True((bool)states["user:market-codex-zhcn-translate.js"]!);
        Assert.True((bool)states["user:market-codex-context-used-meter.js"]!);
        Assert.True((bool)states["user:market-codex-token-usage.js"]!);
        Assert.False((bool)states["user:market-codex-daily-token-usage.js"]!);
        Assert.False((bool)states["user:market-codex-live-token-cost.js"]!);
        Assert.False((bool)states["user:market-other-script.js"]!);

        var verification = new VerificationService().VerifyScripts(
            paths,
            snapshot,
            catalog);
        Assert.Equal("pass", verification.Status);
        Assert.True(verification.TranslationEnabled);
        Assert.True(verification.ContextMeterEnabled);
        Assert.True(verification.TokenUsageEnabled);
        Assert.False(verification.DailyUsageEnabled);
        Assert.False(verification.LiveCostEnabled);
    }

    [Fact]
    public async Task Invalid_script_hash_is_rejected_without_overwriting_user_files()
    {
        var snapshot = CreateScriptMarket();
        await File.AppendAllTextAsync(
            Path.Combine(
                snapshot,
                "script-market",
                "scripts",
                "codex-token-usage.js"),
            "tampered");
        var catalog = Catalog(snapshot);
        var paths = Paths();
        Directory.CreateDirectory(paths.UserScriptsDirectory);
        var existing = Path.Combine(
            paths.UserScriptsDirectory,
            "market-codex-token-usage.js");
        await File.WriteAllTextAsync(existing, "keep-existing");

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new ScriptMarketInstaller(paths).InstallAsync(
                snapshot,
                catalog));

        Assert.Equal("keep-existing", await File.ReadAllTextAsync(existing));
        Assert.False(File.Exists(paths.UserScriptsConfig));
    }

    [Fact]
    public async Task Structured_final_verification_reports_configuration_plugins_and_scripts()
    {
        var paths = Paths();
        var payload = CreatePluginPayload();
        CreateScriptMarket(payload);
        var payloadCatalog = Catalog(payload);
        var modelService = new ModelCatalogService(
            RepositoryPath("Resources", "model-catalog.json"));
        var models = modelService.OfflineModels(ProviderKind.DeepSeek);
        var request = new InstallRequest(
            ProviderKind.DeepSeek,
            new SensitiveString("fixture-verification-key"),
            "deepseek-v4-flash",
            models.Select(model => model.Id).ToArray());
        var acl = new AcceptingAclPolicy();
        await new ConfigurationService(paths, aclPolicy: acl).ApplyAsync(request, models);
        await new PluginInstaller(paths).InstallAsync(payload, payloadCatalog);
        await new ScriptMarketInstaller(paths).InstallAsync(payload, payloadCatalog);

        var report = new VerificationService(acl).VerifyInstallation(
            paths,
            request,
            models,
            payload,
            payloadCatalog);

        Assert.Equal("pass", report.Overall);
        Assert.Empty(report.Applications);
        Assert.Equal("pass", report.Configuration.Status);
        Assert.Equal(3, report.Plugins.MarketplaceCount);
        Assert.Equal(9, report.Plugins.PluginCount);
        Assert.True(report.Scripts.TranslationEnabled);
        Assert.True(report.Scripts.ContextMeterEnabled);
        Assert.True(report.Scripts.TokenUsageEnabled);
    }

    [Fact]
    public async Task Extra_plugin_or_executable_is_rejected_by_compiled_policy()
    {
        var payload = CreatePluginPayload();
        var extra = Path.Combine(
            payload,
            "plugins",
            "marketplaces",
            "openai-bundled",
            "evil.exe");
        await File.WriteAllTextAsync(extra, "not allowed");
        var catalog = Catalog(payload);

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new PluginInstaller(Paths()).InstallAsync(payload, catalog));
    }

    [Theory]
    [InlineData("package-root-file")]
    [InlineData("cache-root-file")]
    [InlineData("cache-market-file")]
    [InlineData("market-root-directory")]
    [InlineData("runtime-market-directory")]
    public async Task Extra_plugin_root_or_market_entry_is_rejected(
        string extraKind)
    {
        var payload = CreatePluginPayload();
        var pluginRoot = Path.Combine(payload, "plugins");
        var extra = extraKind switch
        {
            "package-root-file" => Path.Combine(pluginRoot, "unexpected.txt"),
            "cache-root-file" => Path.Combine(
                pluginRoot,
                "cache",
                "unexpected.txt"),
            "cache-market-file" => Path.Combine(
                pluginRoot,
                "cache",
                "openai-bundled",
                "unexpected.txt"),
            "market-root-directory" => Path.Combine(
                pluginRoot,
                "marketplaces",
                "openai-bundled",
                "unexpected"),
            "runtime-market-directory" => Path.Combine(
                pluginRoot,
                "marketplaces",
                "openai-primary-runtime"),
            _ => throw new ArgumentOutOfRangeException(nameof(extraKind))
        };
        if (extraKind.EndsWith("directory", StringComparison.Ordinal))
            Directory.CreateDirectory(extra);
        else
            await File.WriteAllTextAsync(extra, "not allowed");
        var catalog = Catalog(payload);

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new PluginInstaller(Paths()).InstallAsync(payload, catalog));
    }

    [Fact]
    public async Task Plugin_source_reparse_point_is_rejected()
    {
        var payload = CreatePluginPayload();
        var catalog = Catalog(payload);
        var outside = Path.Combine(temporaryRoot, $"outside-{Guid.NewGuid():N}");
        Directory.CreateDirectory(outside);
        var link = Path.Combine(
            payload,
            "plugins",
            "cache",
            "openai-bundled",
            "linked");
        try
        {
            Directory.CreateSymbolicLink(link, outside);
        }
        catch (UnauthorizedAccessException) when (OperatingSystem.IsWindows())
        {
            return;
        }

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new PluginInstaller(Paths()).InstallAsync(payload, catalog));
    }

    [Fact]
    public async Task Service_transaction_roots_recover_only_their_own_crashes()
    {
        var paths = Paths();
        var payload = CreatePluginPayload();
        CreateScriptMarket(payload);
        var catalog = Catalog(payload);
        var configTransaction = await CreateInterruptedTransactionAsync(
            paths.ConfigurationTransactionsRoot,
            "configuration.codex-auth",
            paths.CodexAuth,
            "config-before",
            "config-partial");
        var pluginTransaction = await CreateInterruptedTransactionAsync(
            paths.PluginTransactionsRoot,
            "plugin.configuration",
            paths.CodexConfig,
            "plugin-before",
            "plugin-partial");
        var scriptTransaction = await CreateInterruptedTransactionAsync(
            paths.ScriptTransactionsRoot,
            "script.configuration",
            paths.UserScriptsConfig,
            "script-before",
            "script-partial");

        var configRecovered = await new ConfigurationService(
                paths,
                aclPolicy: new AcceptingAclPolicy())
            .RecoverIncompleteAsync();
        Assert.Equal([configTransaction], configRecovered);
        Assert.Equal("config-before", await File.ReadAllTextAsync(paths.CodexAuth));
        Assert.Equal("plugin-partial", await File.ReadAllTextAsync(paths.CodexConfig));
        Assert.Equal(
            "script-partial",
            await File.ReadAllTextAsync(paths.UserScriptsConfig));

        var pluginRecovered = await new PluginInstaller(paths)
            .RecoverIncompleteAsync(payload, catalog);
        Assert.Equal([pluginTransaction], pluginRecovered);
        Assert.Equal("plugin-before", await File.ReadAllTextAsync(paths.CodexConfig));
        Assert.Equal(
            "script-partial",
            await File.ReadAllTextAsync(paths.UserScriptsConfig));

        var scriptRecovered = await new ScriptMarketInstaller(paths)
            .RecoverIncompleteAsync(payload, catalog);
        Assert.Equal([scriptTransaction], scriptRecovered);
        Assert.Equal(
            "script-before",
            await File.ReadAllTextAsync(paths.UserScriptsConfig));
    }

    [Fact]
    public async Task Verification_rejects_joint_index_snapshot_tamper_and_extra_managed_target()
    {
        var payload = CreateScriptMarket();
        var catalog = Catalog(payload);
        var paths = Paths();
        await new ScriptMarketInstaller(paths).InstallAsync(payload, catalog);
        await File.WriteAllTextAsync(
            Path.Combine(paths.UserScriptsDirectory, "market-evil.js"),
            "evil");
        Assert.Throws<InvalidDataException>(
            () => new VerificationService().VerifyScripts(
                paths,
                payload,
                catalog));
        File.Delete(Path.Combine(paths.UserScriptsDirectory, "market-evil.js"));

        var script = Path.Combine(
            payload,
            "script-market",
            "scripts",
            "codex-token-usage.js");
        await File.AppendAllTextAsync(script, "joint tamper");
        var indexPath = Path.Combine(payload, "script-market", "index.json");
        var index = JsonNode.Parse(await File.ReadAllTextAsync(indexPath))!.AsObject();
        var bytes = await File.ReadAllBytesAsync(script);
        index["scripts"]!.AsArray()
            .Single(item => (string?)item!["id"] == "codex-token-usage")!["sha256"] =
            Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        await File.WriteAllTextAsync(indexPath, index.ToJsonString());

        Assert.Throws<InvalidDataException>(
            () => new VerificationService().VerifyScripts(
                paths,
                payload,
                catalog));
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryRoot))
            Directory.Delete(temporaryRoot, recursive: true);
    }

    private static readonly string[] ScriptIds =
    [
        "codex-zhcn-translate",
        "codex-context-used-meter",
        "codex-token-usage",
        "codex-daily-token-usage",
        "codex-live-token-cost",
        "other-script"
    ];

    private WindowsConfigurationPaths Paths() =>
        WindowsConfigurationPaths.Create(
            Path.Combine(temporaryRoot, "user"),
            Path.Combine(temporaryRoot, "roaming"),
            Path.Combine(temporaryRoot, "local"));

    private string CreateScriptMarket()
    {
        var payload = Path.Combine(
            temporaryRoot,
            $"payload-{Guid.NewGuid():N}");
        CreateScriptMarket(payload);
        return payload;
    }

    private void CreateScriptMarket(string payload)
    {
        var root = Path.Combine(payload, "script-market");
        var scripts = Path.Combine(root, "scripts");
        Directory.CreateDirectory(scripts);
        var entries = new JsonArray();
        foreach (var id in ScriptIds)
        {
            var data = Encoding.UTF8.GetBytes($"window.fixture = '{id}';\n");
            File.WriteAllBytes(Path.Combine(scripts, $"{id}.js"), data);
            entries.Add(new JsonObject
            {
                ["id"] = id,
                ["name"] = id,
                ["version"] = "1.0.0",
                ["homepage"] = "",
                ["script_url"] = $"https://example.invalid/{id}.js",
                ["sha256"] = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant()
            });
        }

        File.WriteAllText(
            Path.Combine(root, "index.json"),
            new JsonObject
            {
                ["version"] = 1,
                ["scripts"] = entries
            }.ToJsonString());
    }

    private string CreatePluginPayload()
    {
        var payload = Path.Combine(
            temporaryRoot,
            $"payload-{Guid.NewGuid():N}");
        var pluginRoot = CopyDirectory(
            RepositoryPath(
                "windows",
                "tests",
                "fixtures",
                "payload-root",
                "plugins"),
            Path.Combine(payload, "plugins"));
        foreach (var fixture in Directory.EnumerateFiles(
                     Path.Combine(pluginRoot, "marketplaces"),
                     "fixture.txt",
                     SearchOption.AllDirectories))
            File.Delete(fixture);
        return payload;
    }

    private static PayloadCatalog Catalog(string payload)
    {
        var entries = new List<PayloadEntry>();
        foreach (var component in new[]
                 {
                     ("plugin-marketplaces", "plugins"),
                     ("script-market", "script-market")
                 })
        {
            var path = Path.Combine(payload, component.Item2);
            if (!Directory.Exists(path))
                continue;
            var hash = TrustedPayloadComponent.HashDirectory(path);
            entries.Add(new PayloadEntry(
                component.Item1,
                "fixture",
                "any",
                component.Item2,
                hash.Sha256,
                hash.Size,
                new Uri("https://example.invalid/payload"),
                "directory",
                null,
                null,
                null,
                null,
                null,
                null));
        }
        return new PayloadCatalog(2, entries);
    }

    private static async Task<Guid> CreateInterruptedTransactionAsync(
        string transactionsRoot,
        string targetKey,
        string target,
        string before,
        string partial)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        await File.WriteAllTextAsync(target, partial);
        var transactionId = Guid.NewGuid();
        var transactionDirectory = Path.Combine(
            transactionsRoot,
            transactionId.ToString("N"));
        var backup = Path.Combine(transactionDirectory, "backups", "0001");
        Directory.CreateDirectory(Path.GetDirectoryName(backup)!);
        await File.WriteAllTextAsync(backup, before);
        await File.WriteAllTextAsync(
            Path.Combine(transactionDirectory, "state.json"),
            """{"state":"applying"}""");
        var journal = new
        {
            sequence = 1,
            action = "replaceFile",
            targetKey,
            backup = "backups/0001",
            beforeSha256 = Convert.ToHexString(
                    SHA256.HashData(Encoding.UTF8.GetBytes(before)))
                .ToLowerInvariant(),
            completed = false,
            backupMetadata = new FileBackupMetadata(
                true,
                (long)FileAttributes.Normal,
                null,
                null,
                null,
                null)
        };
        await File.WriteAllTextAsync(
            Path.Combine(transactionDirectory, "journal.jsonl"),
            JsonSerializer.Serialize(
                journal,
                new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
                }) + "\n");
        return transactionId;
    }

    private static string CopyDirectory(string source, string destination)
    {
        foreach (var directory in Directory.EnumerateDirectories(
                     source,
                     "*",
                     SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(
                destination,
                Path.GetRelativePath(source, directory)));
        }
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(
                     source,
                     "*",
                     SearchOption.AllDirectories))
        {
            var target = Path.Combine(
                destination,
                Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target);
        }
        return destination;
    }

    private static string RepositoryPath(params string[] components)
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            var candidate = components.Aggregate(
                current.FullName,
                Path.Combine);
            if (File.Exists(candidate) || Directory.Exists(candidate))
                return candidate;
            current = current.Parent;
        }
        throw new DirectoryNotFoundException(
            $"Could not locate repository path {string.Join('/', components)}.");
    }

    private sealed class AcceptingAclPolicy : ISecretFileAclPolicy
    {
        private readonly HashSet<string> compliant = new(StringComparer.Ordinal);

        public void PrepareForPublish(string temporaryPath, string finalPath)
        {
            compliant.Add(finalPath);
        }

        public bool IsCompliant(string path) => compliant.Contains(path);
    }
}
