using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Tomlyn.Parsing;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class ConfigurationTests : IDisposable
{
    private readonly string temporaryRoot = Path.Combine(
        Path.GetTempPath(),
        "codex-configuration-tests",
        Guid.NewGuid().ToString("N"));

    public ConfigurationTests() => Directory.CreateDirectory(temporaryRoot);

    [Theory]
    [InlineData(
        ProviderKind.DeepSeek,
        "https://api.deepseek.com",
        "https://api.deepseek.com/models",
        "deepseek-v4-flash")]
    [InlineData(
        ProviderKind.KimiOpen,
        "https://api.moonshot.cn/v1",
        "https://api.moonshot.cn/v1/models",
        "kimi-k3")]
    [InlineData(
        ProviderKind.KimiCode,
        "https://api.kimi.com/coding/v1",
        "https://api.kimi.com/coding/v1/models",
        "k3")]
    [InlineData(
        ProviderKind.Zhipu,
        "https://open.bigmodel.cn/api/paas/v4",
        "https://open.bigmodel.cn/api/paas/v4/models",
        "glm-5.2")]
    [InlineData(
        ProviderKind.Qwen,
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "https://dashscope.aliyuncs.com/compatible-mode/v1/models",
        "qwen3.7-max")]
    [InlineData(
        ProviderKind.XiaomiMiMo,
        "https://api.xiaomimimo.com/v1",
        "https://api.xiaomimimo.com/v1/models",
        "mimo-v2.5-pro")]
    public void Provider_contract_has_exact_upstream_and_independent_models(
        ProviderKind provider,
        string baseUrl,
        string modelsUrl,
        string requiredModel)
    {
        var definition = InstallerConfig.Provider(provider);

        Assert.Equal(baseUrl, definition.BaseUrl.AbsoluteUri.TrimEnd('/'));
        Assert.Equal(modelsUrl, definition.ModelsUrl.AbsoluteUri);
        Assert.Contains(requiredModel, definition.RequiredOfflineModels);
        if (provider == ProviderKind.KimiOpen)
            Assert.DoesNotContain("k3", definition.RequiredOfflineModels);
        if (provider == ProviderKind.KimiCode)
            Assert.DoesNotContain("kimi-k3", definition.RequiredOfflineModels);
    }

    [Fact]
    public void New_provider_catalogs_are_sorted_complete_and_exclude_retired_xiaomi_models()
    {
        var service = new ModelCatalogService(
            RepositoryPath("Resources", "model-catalog.json"));

        Assert.Equal(
            InstallerConfig.Provider(ProviderKind.Zhipu).RequiredOfflineModels,
            service.OfflineModels(ProviderKind.Zhipu).Select(model => model.Id));
        Assert.Equal(
            ["qwen3.7-flash", "qwen3.7-max", "qwen3.7-plus"],
            service.OfflineModels(ProviderKind.Qwen).Select(model => model.Id));
        Assert.All(
            service.OfflineModels(ProviderKind.Qwen),
            model => Assert.Equal(1_000_000, model.ContextWindow));
        Assert.Equal(
            ["mimo-v2.5", "mimo-v2.5-pro"],
            service.OfflineModels(ProviderKind.XiaomiMiMo).Select(model => model.Id));
        Assert.All(
            service.OfflineModels(ProviderKind.XiaomiMiMo),
            model => Assert.Equal(1_000_000, model.ContextWindow));
        Assert.DoesNotContain(
            service.OfflineModels(ProviderKind.XiaomiMiMo),
            model => model.Id is "mimo-v2-pro" or "mimo-v2-omni" or "mimo-v2-flash");
    }

    [Fact]
    public async Task Models_refresh_uses_only_a_bearer_header_and_filters_invalid_ids()
    {
        var catalogPath = RepositoryPath("Resources", "model-catalog.json");
        const string key = "fixture-kimi-secret";
        var handler = new RecordingHandler(
            HttpStatusCode.OK,
            """{"data":[{"id":"kimi-k3"},{"id":"safe-custom"},{"id":"bad id"},{"id":"../escape"},{"id":""}]}""");
        var service = new ModelCatalogService(
            catalogPath,
            new HttpClient(handler));

        var result = await service.ResolveModelsAsync(
            ProviderKind.KimiOpen,
            new SensitiveString(key),
            ["user-model_1", "bad model", "safe-custom"]);

        Assert.Equal(ModelSource.UpstreamRefresh, result.Source);
        Assert.Equal(
            ["kimi-k3", "safe-custom", "user-model_1"],
            result.Models.Select(model => model.Id));
        Assert.Equal("Bearer", handler.Request!.Headers.Authorization!.Scheme);
        Assert.Equal(key, handler.Request.Headers.Authorization.Parameter);
        Assert.Equal(InstallerConfig.Provider(ProviderKind.KimiOpen).ModelsUrl, handler.Request.RequestUri);
        Assert.DoesNotContain(key, handler.Request.RequestUri!.AbsoluteUri, StringComparison.Ordinal);
        Assert.Null(handler.Request.Content);
    }

    [Fact]
    public async Task Models_failure_keeps_offline_snapshot_and_merges_only_legal_custom_ids()
    {
        var catalogPath = RepositoryPath("Resources", "model-catalog.json");
        var service = new ModelCatalogService(
            catalogPath,
            new HttpClient(new RecordingHandler(
                HttpStatusCode.OK,
                """{"unexpected":[]}""")));

        var result = await service.ResolveModelsAsync(
            ProviderKind.DeepSeek,
            new SensitiveString("fixture-deepseek-secret"),
            ["my-model.v1", "has whitespace", "deepseek-v4-flash"]);

        Assert.Equal(ModelSource.OfflineSnapshot, result.Source);
        Assert.Equal(
            ["deepseek-v4-flash", "deepseek-v4-pro", "my-model.v1"],
            result.Models.Select(model => model.Id));
    }

    [Fact]
    public void Complex_toml_is_losslessly_preserved_and_managed_edit_is_idempotent()
    {
        const string complex =
            """"
            # keep this header byte-for-byte
            "model.provider" = "literal dotted key"
            description = """
            multiline
            [not-a-table]
            """
            values = [
              1, # inline comment
              2,
            ]

            [model_providers."user.with.dot"]
            base_url = "https://example.invalid/v1" # keep inline comment
            wire_api = "responses"

            ["model_providers.codex-one-click-deepseek"]
            literal = "this is one quoted table key"

            [unmanaged]
            "quoted.dotted" = { keep = true }
            """";
        var request = new InstallRequest(
            ProviderKind.DeepSeek,
            new SensitiveString("fixture-complex-key"),
            "deepseek-v4-flash",
            ["deepseek-v4-flash"]);

        var once = InstallerConfig.GenerateConfigToml(request, complex);
        var twice = InstallerConfig.GenerateConfigToml(request, once);
        var fromCrlf = InstallerConfig.GenerateConfigToml(
            request,
            once.ReplaceLineEndings("\r\n"));

        Assert.Equal(once, twice);
        Assert.Contains(complex, once, StringComparison.Ordinal);
        Assert.Contains(
            "[model_providers.codex-one-click-deepseek]",
            once,
            StringComparison.Ordinal);
        Assert.False(SyntaxParser.ParseStrict(once).HasErrors);
        Assert.False(SyntaxParser.ParseStrict(fromCrlf).HasErrors);
        Assert.DoesNotContain(
            "\r",
            fromCrlf.Replace("\r\n", string.Empty),
            StringComparison.Ordinal);
    }

    [Fact]
    public void Managed_scalar_conflict_with_unmanaged_dotted_key_is_rejected()
    {
        const string existing =
            """
            model.value = "user-owned"
            approval_policy = "never"
            """;
        var request = new InstallRequest(
            ProviderKind.DeepSeek,
            new SensitiveString("fixture-conflict-key"),
            "deepseek-v4-flash",
            ["deepseek-v4-flash"]);

        Assert.Throws<InvalidDataException>(
            () => InstallerConfig.GenerateConfigToml(request, existing));
        Assert.Equal(
            """
            model.value = "user-owned"
            approval_policy = "never"
            """,
            existing);
    }

    [Theory]
    [InlineData(AuthenticationMode.PureApi, "pureApi", false)]
    [InlineData(AuthenticationMode.OpenAIAccountWithApi, "official", true)]
    public async Task Configuration_is_transactional_semantic_and_preserves_unmanaged_values(
        AuthenticationMode mode,
        string expectedRelayMode,
        bool expectedOfficialMix)
    {
        const string key = "fixture-config-super-secret";
        var paths = Paths();
        Directory.CreateDirectory(Path.GetDirectoryName(paths.CodexConfig)!);
        Directory.CreateDirectory(Path.GetDirectoryName(paths.CodexPlusSettings)!);
        await File.WriteAllTextAsync(
            paths.CodexConfig,
            """
            approval_policy = "on-request"

            [model_providers.user-owned]
            base_url = "https://example.invalid/v1"
            wire_api = "responses"
            """);
        await File.WriteAllTextAsync(
            paths.CodexPlusSettings,
            """{"privateSetting":true,"relayProfiles":[{"id":"user-owned","keep":true}]}""");
        var acl = new FakeSecretAclPolicy();
        var service = new ConfigurationService(paths, aclPolicy: acl);
        var models = new ModelCatalogService(
                RepositoryPath("Resources", "model-catalog.json"))
            .OfflineModels(ProviderKind.KimiOpen);
        var request = new InstallRequest(
            ProviderKind.KimiOpen,
            new SensitiveString(key),
            "kimi-k3",
            models.Select(model => model.Id).ToArray(),
            AuthenticationMode: mode);

        var result = await service.ApplyAsync(request, models);

        Assert.Equal(TransactionState.Committed, result.Transaction.State);
        var config = await File.ReadAllTextAsync(paths.CodexConfig);
        Assert.Contains("approval_policy = \"on-request\"", config, StringComparison.Ordinal);
        Assert.Contains("[model_providers.user-owned]", config, StringComparison.Ordinal);
        Assert.Contains("wire_api = \"responses\"", config, StringComparison.Ordinal);
        Assert.Contains("base_url = \"http://127.0.0.1:57321/v1\"", config, StringComparison.Ordinal);
        Assert.DoesNotContain("protocol = \"chatCompletions\"", config, StringComparison.Ordinal);

        var auth = JsonNode.Parse(await File.ReadAllTextAsync(paths.CodexAuth))!.AsObject();
        if (mode == AuthenticationMode.PureApi)
            Assert.Equal(key, (string?)auth["OPENAI_API_KEY"]);
        else
            Assert.Null(auth["OPENAI_API_KEY"]);

        var settings = JsonNode.Parse(
            await File.ReadAllTextAsync(paths.CodexPlusSettings))!.AsObject();
        Assert.True((bool)settings["privateSetting"]!);
        var profiles = settings["relayProfiles"]!.AsArray();
        Assert.Contains(profiles, profile => (string?)profile!["id"] == "user-owned");
        var managed = Assert.Single(
            profiles,
            profile =>
                (string?)profile!["id"] == "codex-one-click-kimi-open");
        Assert.Equal(expectedRelayMode, (string?)managed!["relayMode"]);
        Assert.Equal(expectedOfficialMix, (bool)managed["officialMixApiKey"]!);
        Assert.Equal(
            "https://api.moonshot.cn/v1",
            ((string?)managed["upstreamBaseUrl"])!.TrimEnd('/'));

        var expectationText = await File.ReadAllTextAsync(paths.InstallExpectation);
        Assert.DoesNotContain(key, expectationText, StringComparison.Ordinal);
        var expectation = JsonNode.Parse(expectationText)!.AsObject();
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant(),
            (string?)expectation["apiKeySHA256"]);
        Assert.Equal(
            mode == AuthenticationMode.PureApi ? "pureAPI" : "openAIAccountWithAPI",
            (string?)expectation["authenticationMode"]);

        Assert.Equal(
            new[]
            {
                paths.CodexConfig,
                paths.CodexAuth,
                paths.CodexPlusSettings,
                paths.InstallExpectation
            }.Order(),
            acl.AppliedPaths.Order());
        var verification = new VerificationService(acl).VerifyConfiguration(
            paths,
            request,
            models);
        Assert.Equal("pass", verification.Status);
    }

    [Fact]
    public async Task Acl_or_verification_failure_rolls_back_every_configuration_file_without_secret_errors()
    {
        const string key = "fixture-never-log-this-key";
        var paths = Paths();
        var before = new Dictionary<string, string>
        {
            [paths.CodexConfig] = "approval_policy = \"never\"\n",
            [paths.CodexAuth] = "{\"private\":true}\n",
            [paths.CodexPlusSettings] = "{\"private\":true}\n",
            [paths.InstallExpectation] = "{\"old\":true}\n"
        };
        foreach (var pair in before)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(pair.Key)!);
            await File.WriteAllTextAsync(pair.Key, pair.Value);
        }
        var service = new ConfigurationService(
            paths,
            aclPolicy: new FakeSecretAclPolicy(failOnApply: 3));
        var models = new ModelCatalogService(
                RepositoryPath("Resources", "model-catalog.json"))
            .OfflineModels(ProviderKind.DeepSeek);
        var request = new InstallRequest(
            ProviderKind.DeepSeek,
            new SensitiveString(key),
            "deepseek-v4-flash",
            models.Select(model => model.Id).ToArray());

        var error = await Assert.ThrowsAsync<UnauthorizedAccessException>(
            () => service.ApplyAsync(request, models));

        Assert.DoesNotContain(key, error.ToString(), StringComparison.Ordinal);
        foreach (var pair in before)
            Assert.Equal(pair.Value, await File.ReadAllTextAsync(pair.Key));
    }

    [Fact]
    public async Task Apply_recovers_an_interrupted_configuration_transaction_before_validation()
    {
        var paths = Paths();
        Directory.CreateDirectory(Path.GetDirectoryName(paths.CodexConfig)!);
        await File.WriteAllTextAsync(paths.CodexConfig, "partial");
        var transactionId = Guid.NewGuid();
        var transactionDirectory = Path.Combine(
            paths.ConfigurationTransactionsRoot,
            transactionId.ToString("N"));
        var backup = Path.Combine(transactionDirectory, "backups", "0001");
        Directory.CreateDirectory(Path.GetDirectoryName(backup)!);
        await File.WriteAllTextAsync(backup, "before-crash");
        await File.WriteAllTextAsync(
            Path.Combine(transactionDirectory, "state.json"),
            """{"state":"applying"}""");
        var metadata = new FileBackupMetadata(
            true,
            (long)FileAttributes.Normal,
            null,
            null,
            null,
            null);
        var journal = new
        {
            sequence = 1,
            action = "replaceFile",
            targetKey = "configuration.codex-config",
            backup = "backups/0001",
            beforeSha256 = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes("before-crash")))
                .ToLowerInvariant(),
            completed = false,
            backupMetadata = metadata
        };
        await File.WriteAllTextAsync(
            Path.Combine(transactionDirectory, "journal.jsonl"),
            JsonSerializer.Serialize(
                journal,
                new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
                }) + "\n");
        var models = new ModelCatalogService(
                RepositoryPath("Resources", "model-catalog.json"))
            .OfflineModels(ProviderKind.DeepSeek);
        var invalid = new InstallRequest(
            ProviderKind.DeepSeek,
            new SensitiveString("short"),
            "deepseek-v4-flash",
            ["deepseek-v4-flash"]);

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new ConfigurationService(
                    paths,
                    aclPolicy: new FakeSecretAclPolicy())
                .ApplyAsync(invalid, models));

        Assert.Equal("before-crash", await File.ReadAllTextAsync(paths.CodexConfig));
    }

    [Fact]
    public void Windows_acl_adapter_has_exact_non_inherited_trustee_contract()
    {
        Assert.Equal(
            ["CURRENT_USER", "S-1-5-18", "S-1-5-32-544"],
            WindowsSecretFileAclPolicy.ExpectedTrustees);
        Assert.True(WindowsSecretFileAclPolicy.ProtectsDacl);
        if (!OperatingSystem.IsWindows())
        {
            Assert.Throws<PlatformNotSupportedException>(
                () => new WindowsSecretFileAclPolicy().PrepareForPublish(
                    Path.Combine(temporaryRoot, "not-created"),
                    Path.Combine(temporaryRoot, "final")));
        }
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryRoot))
            Directory.Delete(temporaryRoot, recursive: true);
    }

    private WindowsConfigurationPaths Paths() =>
        WindowsConfigurationPaths.Create(
            Path.Combine(temporaryRoot, "user"),
            Path.Combine(temporaryRoot, "roaming"),
            Path.Combine(temporaryRoot, "local"));

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

    private sealed class RecordingHandler(
        HttpStatusCode status,
        string body) : HttpMessageHandler
    {
        public HttpRequestMessage? Request { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Request = request;
            return Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            });
        }
    }

    private sealed class FakeSecretAclPolicy(int? failOnApply = null)
        : ISecretFileAclPolicy
    {
        private int applyCount;
        public List<string> AppliedPaths { get; } = [];

        public List<string> PreparedTemporaryPaths { get; } = [];

        public void PrepareForPublish(string temporaryPath, string finalPath)
        {
            applyCount++;
            if (applyCount == failOnApply)
                throw new UnauthorizedAccessException("fixture ACL failure");
            Assert.True(File.Exists(temporaryPath));
            PreparedTemporaryPaths.Add(temporaryPath);
            AppliedPaths.Add(finalPath);
        }

        public bool IsCompliant(string path) => AppliedPaths.Contains(path);
    }
}
