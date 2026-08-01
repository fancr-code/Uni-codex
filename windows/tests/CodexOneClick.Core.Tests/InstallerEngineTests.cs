using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class InstallerEngineTests : IDisposable
{
    private readonly string temporaryRoot = Path.Combine(
        Path.GetTempPath(),
        "codex-installer-engine-tests",
        Guid.NewGuid().ToString("N"));

    public InstallerEngineTests() => Directory.CreateDirectory(temporaryRoot);

    public void Dispose()
    {
        if (Directory.Exists(temporaryRoot))
            Directory.Delete(temporaryRoot, recursive: true);
    }

    [Theory]
    [InlineData(ProviderKind.DeepSeek, "deepseek-v4-flash")]
    [InlineData(ProviderKind.KimiOpen, "kimi-k3")]
    public async Task End_to_end_fixture_preserves_healthy_codex_and_installs_full_offline_bundle(
        ProviderKind provider,
        string model)
    {
        AssertScenario(provider, model);
        var root = NewRoot(provider.ToString());
        var paths = Paths(root);
        var acl = new AcceptingAclPolicy();
        var models = new[] { new ModelDefinition(model, model, null) };
        var state = new MutableState("clean");
        var order = new List<string>();
        var stateProvider = new StateSnapshotProvider(state, order);
        var transaction = Coordinator(root, stateProvider);
        var marker = Path.Combine(root, "apps", "Codex++.exe");
        var operationalPayload = CopyDirectory(
            PayloadRoot(),
            Path.Combine(root, "operational-payload"));
        foreach (var fixtureMarker in Directory.EnumerateFiles(
                     Path.Combine(operationalPayload, "plugins"),
                     "fixture.txt",
                     SearchOption.AllDirectories))
        {
            File.Delete(fixtureMarker);
        }
        var operationalScriptMarket = Path.Combine(
            operationalPayload,
            "script-market");
        Directory.Delete(operationalScriptMarket, recursive: true);
        CopyDirectory(EndToEndScriptMarket(), operationalScriptMarket);
        var operationalCatalog = OperationalCatalog(operationalPayload);
        var configuration = new ConfigurationService(paths, aclPolicy: acl);
        var plugins = new PluginInstaller(paths, acl);
        var scripts = new ScriptMarketInstaller(paths);
        var verification = new VerificationService(acl);
        var logger = new RedactingLogger();
        var secret = $"engine-{provider}-secret";
        var hash = Sha256(secret);
        logger.AddSecret(new SensitiveString(secret));
        logger.Log($"diagnostic key={secret} sha256={hash}");

        var operations = new InstallerEngineOperations(
            async (plan, _, _, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                Assert.Equal(
                    PlanAction.Preserve,
                    plan.Single(item =>
                        item.Component == "codex-windows-x64").Action);
                Assert.Equal(
                    PlanAction.Install,
                    plan.Single(item =>
                        item.Component == "codex-plus-plus-windows-x64").Action);
                order.Add("applications");
                state.Value = "applications";
                Directory.CreateDirectory(Path.GetDirectoryName(marker)!);
                await File.WriteAllTextAsync(
                    marker,
                    "fixture Codex++",
                    cancellationToken);
                return new ApplicationInstallSummary(
                    new ApplicationInstallResult(
                        PlanAction.Preserve,
                        Changed: false),
                    new ApplicationInstallResult(
                        PlanAction.Install,
                        Changed: true));
            },
            async (request, catalog, cancellationToken) =>
            {
                order.Add("configuration");
                state.Value = "configuration";
                return await configuration.ApplyAsync(
                    request,
                    catalog,
                    cancellationToken);
            },
            async (catalog, cancellationToken) =>
            {
                order.Add("plugins");
                state.Value = "plugins";
                return await plugins.InstallAsync(
                    operationalPayload,
                    operationalCatalog,
                    cancellationToken);
            },
            async (catalog, cancellationToken) =>
            {
                order.Add("scripts");
                state.Value = "scripts";
                return await scripts.InstallAsync(
                    operationalPayload,
                    operationalCatalog,
                    cancellationToken);
            },
            (request, catalog, validatedPayload, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                order.Add("verification");
                state.Value = "verified";
                return Task.FromResult(verification.VerifyInstallation(
                    paths,
                    request,
                    catalog,
                    operationalPayload,
                    operationalCatalog));
            });
        var engine = Engine(
            root,
            operations,
            transaction,
            models,
            logger: logger);
        var request = new InstallRequest(
            provider,
            new SensitiveString(secret),
            model,
            [model]);

        var result = await engine.InstallAsync(
            request,
            new Progress<InstallerEvent>(_ => { }),
            CancellationToken.None);

        Assert.True(
            result.Succeeded,
            $"{result.FailureCode}: {string.Join(" | ", logger.Messages)}");
        Assert.True(File.Exists(marker));
        Assert.Equal(
            [
                "stage",
                "applications",
                "configuration",
                "plugins",
                "scripts",
                "verification",
                "commit"
            ],
            order);
        Assert.NotNull(engine.LastReport);
        Assert.Equal(3, engine.LastReport!.MarketplaceCount);
        Assert.Equal(9, engine.LastReport.PluginCount);
        Assert.Equal(5, engine.LastReport.ScriptCount);
        Assert.True(engine.LastReport.Verification.Scripts.TranslationEnabled);
        Assert.True(engine.LastReport.Verification.Scripts.ContextMeterEnabled);
        Assert.True(engine.LastReport.Verification.Scripts.TokenUsageEnabled);
        Assert.False(engine.LastReport.Verification.Scripts.DailyUsageEnabled);
        Assert.False(engine.LastReport.Verification.Scripts.LiveCostEnabled);
        Assert.Equal(PlanAction.Preserve, engine.LastReport.Plan[0].Action);
        Assert.Contains(
            InstallerConfig.Provider(provider).ManagedProviderId,
            await File.ReadAllTextAsync(paths.CodexConfig),
            StringComparison.Ordinal);
        Assert.Contains(
            model,
            await File.ReadAllTextAsync(paths.CodexConfig),
            StringComparison.Ordinal);
        var report = await File.ReadAllTextAsync(engine.LastReportPath!);
        Assert.DoesNotContain(secret, report, StringComparison.Ordinal);
        Assert.DoesNotContain(hash, report, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("[REDACTED]", report, StringComparison.Ordinal);
        Assert.Equal(0, stateProvider.RestoreCount);
    }

    [Theory]
    [InlineData("applications")]
    [InlineData("plugins")]
    [InlineData("verification")]
    public async Task Apply_or_verify_fault_rolls_back_the_outer_transaction(
        string faultPhase)
    {
        var root = NewRoot(faultPhase);
        var state = new MutableState("before");
        var provider = new StateSnapshotProvider(state);
        var operations = SyntheticOperations(
            state,
            faultPhase: faultPhase);
        var engine = Engine(
            root,
            operations,
            Coordinator(root, provider),
            DeepSeekModels());

        var result = await engine.InstallAsync(
            DeepSeekRequest(),
            new Progress<InstallerEvent>(_ => { }),
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal($"{faultPhase}_failed", result.FailureCode);
        Assert.Equal("before", state.Value);
        Assert.Equal(1, provider.RestoreCount);
        Assert.Equal(0, provider.CommitCleanupCount);
    }

    [Fact]
    public async Task Cancellation_rolls_back_the_outer_transaction()
    {
        var root = NewRoot("cancel");
        var state = new MutableState("before");
        var provider = new StateSnapshotProvider(state);
        var entered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = SyntheticOperations(
            state,
            applications: async cancellationToken =>
            {
                state.Value = "partial";
                entered.SetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            });
        var engine = Engine(
            root,
            operations,
            Coordinator(root, provider),
            DeepSeekModels());
        using var cancellation = new CancellationTokenSource();

        var install = engine.InstallAsync(
            DeepSeekRequest(),
            new Progress<InstallerEvent>(_ => { }),
            cancellation.Token);
        await entered.Task;
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => install);
        Assert.Equal("before", state.Value);
        Assert.Equal(1, provider.RestoreCount);
        Assert.Equal(0, provider.CommitCleanupCount);
    }

    [Fact]
    public async Task Startup_recovers_an_applying_crash_journal_before_new_install()
    {
        var root = NewRoot("recovery");
        var state = new MutableState("before");
        var provider = new StateSnapshotProvider(state);
        var coordinator = Coordinator(root, provider);
        var abandoned = await coordinator.BeginExternalMutationAsync(
            [StateSnapshotProvider.TargetKey]);
        await abandoned.MarkApplyingAsync();
        state.Value = "crash-partial";
        var sawRecoveredState = false;
        var operations = SyntheticOperations(
            state,
            applications: _ =>
            {
                sawRecoveredState = state.Value == "before";
                state.Value = "installed";
                return Task.CompletedTask;
            });
        var engine = Engine(
            root,
            operations,
            coordinator,
            DeepSeekModels());

        var result = await engine.InstallAsync(
            DeepSeekRequest(),
            new Progress<InstallerEvent>(_ => { }),
            CancellationToken.None);

        Assert.True(result.Succeeded, result.FailureCode);
        Assert.True(sawRecoveredState);
        Assert.Contains(abandoned.TransactionId, engine.LastRecoveredTransactions);
        Assert.Equal("verification", state.Value);
        Assert.Equal(1, provider.RestoreCount);
        Assert.Equal(0, provider.CommitCleanupCount);
    }

    [Fact]
    public async Task Authorization_exception_paths_are_redacted_after_commit_without_rollback()
    {
        var root = NewRoot("authorization");
        var state = new MutableState("before");
        var provider = new StateSnapshotProvider(state);
        var coordinator = Coordinator(root, provider);
        var logger = new RedactingLogger();
        var sensitivePaths = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            PayloadRoot(),
            root,
            Path.Combine(root, "reports"),
            coordinator.TransactionsRoot
        };
        var authentication = new ThrowingAuthenticationCoordinator(
            $"authorization failed in {string.Join(" and ", sensitivePaths)}");
        var engine = Engine(
            root,
            SyntheticOperations(state),
            coordinator,
            DeepSeekModels(),
            authentication,
            logger);
        var request = DeepSeekRequest() with
        {
            AuthenticationMode = AuthenticationMode.OpenAIAccountWithApi
        };

        var result = await engine.InstallAsync(
            request,
            new Progress<InstallerEvent>(_ => { }),
            CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Equal("recoverable_failure", engine.LastReport!.AuthorizationStatus);
        var report = await File.ReadAllTextAsync(engine.LastReportPath!);
        foreach (var path in sensitivePaths.Where(path =>
                     !string.IsNullOrWhiteSpace(path)))
        {
            Assert.DoesNotContain(
                Path.GetFullPath(path),
                report,
                StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(
                Path.GetFullPath(path),
                string.Join(" | ", engine.LastReport.Messages),
                StringComparison.OrdinalIgnoreCase);
        }
        Assert.Contains("[REDACTED]", report, StringComparison.Ordinal);
        Assert.Equal(0, provider.RestoreCount);
        Assert.Equal(1, provider.CommitCleanupCount);
    }

    [Fact]
    public async Task Cancellation_during_post_commit_authorization_still_writes_success_report()
    {
        var root = NewRoot("post-commit-cancel");
        var state = new MutableState("before");
        var provider = new StateSnapshotProvider(state);
        var authentication = new CancellableAuthenticationCoordinator();
        var engine = Engine(
            root,
            SyntheticOperations(state),
            Coordinator(root, provider),
            DeepSeekModels(),
            authentication);
        var request = DeepSeekRequest() with
        {
            AuthenticationMode = AuthenticationMode.OpenAIAccountWithApi
        };
        using var cancellation = new CancellationTokenSource();

        var install = engine.InstallAsync(
            request,
            new Progress<InstallerEvent>(_ => { }),
            cancellation.Token);
        await authentication.Started.Task.WaitAsync(TimeSpan.FromSeconds(10));
        cancellation.Cancel();
        var result = await install;

        Assert.True(result.Succeeded, result.FailureCode);
        Assert.Equal(
            "cancelled_after_commit",
            engine.LastReport!.AuthorizationStatus);
        Assert.True(File.Exists(engine.LastReportPath));
        Assert.True(authentication.CancelCalled);
        Assert.Equal(0, provider.RestoreCount);
        Assert.Equal(1, provider.CommitCleanupCount);
    }

    private InstallerEngine Engine(
        string root,
        InstallerEngineOperations operations,
        ExternalMutationCoordinator coordinator,
        IReadOnlyList<ModelDefinition> models,
        IAuthenticationCoordinator? authentication = null,
        RedactingLogger? logger = null) =>
        new(
            new InstallerEngineOptions(
                PayloadRoot(),
                root,
                Path.Combine(root, "reports"),
                FixtureMode: true),
            new PreflightService(new SupportedEnvironment()),
            new PayloadCatalogService(),
            new InstallPlanner(),
            operations,
            coordinator,
            [StateSnapshotProvider.TargetKey],
            _ => models,
            new InstallerReportWriter(Path.Combine(root, "reports")),
            authentication,
            logger);

    private static InstallerEngineOperations SyntheticOperations(
        MutableState state,
        string? faultPhase = null,
        Func<CancellationToken, Task>? applications = null)
    {
        applications ??= _ => Task.CompletedTask;
        return new InstallerEngineOperations(
            async (plan, _, _, cancellationToken) =>
            {
                await applications(cancellationToken);
                state.Value = "applications";
                ThrowIfFault("applications");
                return new ApplicationInstallSummary(
                    new ApplicationInstallResult(
                        plan[0].Action,
                        Changed: false),
                    new ApplicationInstallResult(
                        plan[1].Action,
                        Changed: true));
            },
            (request, _, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                state.Value = "configuration";
                ThrowIfFault("configuration");
                return Task.FromResult(new ConfigurationApplyResult(
                    InstallerConfig.Provider(request.Provider).ManagedProviderId,
                    CommittedTransaction()));
            },
            (_, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                state.Value = "plugins";
                ThrowIfFault("plugins");
                return Task.FromResult(new PluginInstallResult(
                    3,
                    9,
                    Enumerable.Repeat(true, 9).ToArray(),
                    CommittedTransaction()));
            },
            (_, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                state.Value = "scripts";
                ThrowIfFault("scripts");
                return Task.FromResult(new ScriptMarketInstallResult(
                    4,
                    ["context.js", "tokens.js", "daily.js", "cost.js"],
                    CommittedTransaction()));
            },
            (request, _, _, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                state.Value = "verification";
                ThrowIfFault("verification");
                return Task.FromResult(PassingVerification(request));
            });

        void ThrowIfFault(string phase)
        {
            if (string.Equals(faultPhase, phase, StringComparison.Ordinal))
                throw new InvalidOperationException($"{phase} fixture fault");
        }
    }

    private static InstallationVerification PassingVerification(
        InstallRequest request) =>
        new(
            "pass",
            new Dictionary<string, object>(),
            new ConfigurationVerification(
                "pass",
                request.Provider,
                request.DefaultModel,
                request.AvailableModels.Count,
                request.AuthenticationMode),
            new PluginVerification("pass", 3, 9, 2, 5, 4, "configured"),
            new ScriptVerification(
                "pass",
                TranslationEnabled: true,
                ContextMeterEnabled: true,
                TokenUsageEnabled: true,
                DailyUsageEnabled: false,
                LiveCostEnabled: false,
                InstalledCount: 4));

    private static TransactionResult CommittedTransaction() =>
        new(Guid.NewGuid(), TransactionState.Committed);

    private static IReadOnlyList<ModelDefinition> DeepSeekModels() =>
        [new("deepseek-v4-flash", "DeepSeek V4 Flash", null)];

    private static InstallRequest DeepSeekRequest() =>
        new(
            ProviderKind.DeepSeek,
            new SensitiveString("fixture-engine-secret"),
            "deepseek-v4-flash",
            ["deepseek-v4-flash"]);

    private static ExternalMutationCoordinator Coordinator(
        string root,
        StateSnapshotProvider provider) =>
        new(
            Path.Combine(root, "engine-transactions"),
            new ExternalMutationCatalog(
            [
                new ExternalMutationTargetDefinition(
                    StateSnapshotProvider.TargetKey,
                    provider)
            ]));

    private static PayloadCatalog OperationalCatalog(string payloadRoot)
    {
        var entries = new List<PayloadEntry>();
        foreach (var component in new[]
                 {
                     (Id: "plugin-marketplaces", RelativePath: "plugins"),
                     (Id: "script-market", RelativePath: "script-market")
                 })
        {
            var path = Path.Combine(payloadRoot, component.RelativePath);
            var hash = TrustedPayloadComponent.HashDirectory(path);
            entries.Add(new PayloadEntry(
                component.Id,
                "fixture",
                "any",
                component.RelativePath,
                hash.Sha256,
                hash.Size,
                new Uri("https://example.invalid/end-to-end"),
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

    private static WindowsConfigurationPaths Paths(string root) =>
        WindowsConfigurationPaths.Create(
            Path.Combine(root, "user"),
            Path.Combine(root, "appdata"),
            Path.Combine(root, "local"));

    private string NewRoot(string name)
    {
        var root = Path.Combine(
            temporaryRoot,
            $"{name}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        return root;
    }

    private static string PayloadRoot() =>
        RepositoryPath(
            "windows",
            "tests",
            "fixtures",
            "payload-root");

    private static string EndToEndScriptMarket() =>
        RepositoryPath(
            "windows",
            "tests",
            "fixtures",
            "end-to-end",
            "script-market");

    private static string CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var directory in Directory.EnumerateDirectories(
                     source,
                     "*",
                     SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(
                destination,
                Path.GetRelativePath(source, directory)));
        }
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

    private static void AssertScenario(
        ProviderKind provider,
        string model)
    {
        var scenario = RepositoryPath(
            "windows",
            "tests",
            "fixtures",
            "end-to-end",
            "scenario.json");
        using var document = JsonDocument.Parse(File.ReadAllBytes(scenario));
        var expected = document.RootElement.GetProperty("expected");
        Assert.Equal(3, expected.GetProperty("marketplaceCount").GetInt32());
        Assert.Equal(9, expected.GetProperty("pluginCount").GetInt32());
        Assert.Equal(2, expected.GetProperty("offlineMarketplaceCount").GetInt32());
        Assert.Equal(5, expected.GetProperty("offlinePluginCount").GetInt32());
        Assert.Equal(4, expected.GetProperty("runtimePluginCount").GetInt32());
        Assert.Equal("configured", expected.GetProperty("runtimeStatus").GetString());
        Assert.Equal(5, expected.GetProperty("scriptCount").GetInt32());
        Assert.True(expected.GetProperty("translationEnabled").GetBoolean());
        Assert.True(expected.GetProperty("contextMeterEnabled").GetBoolean());
        Assert.True(expected.GetProperty("tokenUsageEnabled").GetBoolean());
        Assert.False(expected.GetProperty("dailyUsageEnabled").GetBoolean());
        Assert.False(expected.GetProperty("liveCostEnabled").GetBoolean());
        var providerId = provider switch
        {
            ProviderKind.DeepSeek => "deepseek",
            ProviderKind.KimiOpen => "kimi-open",
            ProviderKind.KimiCode => "kimi-code",
            _ => throw new ArgumentOutOfRangeException(nameof(provider))
        };
        Assert.Contains(
            document.RootElement.GetProperty("providers").EnumerateArray(),
            item =>
                item.GetProperty("provider").GetString() == providerId
                && item.GetProperty("defaultModel").GetString() == model);
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

    private static string Sha256(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)))
            .ToLowerInvariant();

    private sealed class MutableState(string value)
    {
        public string Value { get; set; } = value;
    }

    private sealed class StateSnapshotProvider : IExternalMutationProvider
    {
        public const string TargetKey = "engine-test.state";
        private const string SnapshotSchema = "engine-test.state.v1";
        private readonly MutableState state;
        private readonly List<string>? order;

        public StateSnapshotProvider(
            MutableState state,
            List<string>? order = null)
        {
            this.state = state;
            this.order = order;
        }

        public int RestoreCount { get; private set; }

        public int CommitCleanupCount { get; private set; }

        public ExternalMutationTargetKind Kind =>
            ExternalMutationTargetKind.File;

        public ExternalMutationProviderScope Scope =>
            ExternalMutationProviderScope.None;

        public Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
            ManagedSnapshotWriter writer,
            CancellationToken cancellationToken)
        {
            order?.Add("stage");
            return writer.WriteAsync(
                SnapshotSchema,
                Encoding.UTF8.GetBytes(state.Value),
                cancellationToken);
        }

        public async Task ValidateSnapshotAsync(
            ManagedSnapshotReader snapshot,
            CancellationToken cancellationToken)
        {
            Assert.Equal(SnapshotSchema, snapshot.Descriptor.Schema);
            _ = await snapshot.ReadAllBytesAsync(cancellationToken);
        }

        public async Task RestoreSnapshotAsync(
            ManagedSnapshotReader snapshot,
            CancellationToken cancellationToken)
        {
            state.Value = Encoding.UTF8.GetString(
                await snapshot.ReadAllBytesAsync(cancellationToken));
            RestoreCount++;
        }

        public Task CleanupSnapshotAsync(
            ManagedSnapshotReader? snapshot,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (RestoreCount == 0)
            {
                CommitCleanupCount++;
                order?.Add("commit");
            }
            return Task.CompletedTask;
        }
    }

    private sealed class SupportedEnvironment : IWindowsEnvironment
    {
        public Version OSVersion => new(10, 0, 22631);

        public Architecture OSArchitecture => Architecture.X64;

        public long GetAvailableBytes(string path) => long.MaxValue;

        public IReadOnlyList<InstalledPackage> FindPackages(
            string packageFamilyName) =>
            packageFamilyName == PreflightService.CodexPackageFamilyName
                ?
                [
                    new InstalledPackage(
                        PreflightService.CodexPackageFamilyName,
                        "26.7.27.0",
                        IsSignatureValid: true,
                        ExecutablePath: @"C:\fixture\codex.exe")
                ]
                : [];

        public IReadOnlyList<RunningComponent> FindRunningComponents() => [];
    }

    private sealed class AcceptingAclPolicy : ISecretFileAclPolicy
    {
        private readonly HashSet<string> compliant = new(StringComparer.Ordinal);

        public void PrepareForPublish(string temporaryPath, string finalPath) =>
            compliant.Add(finalPath);

        public bool IsCompliant(string path) => compliant.Contains(path);
    }

    private sealed class ThrowingAuthenticationCoordinator(string message)
        : IAuthenticationCoordinator
    {
        public AuthorizationState State =>
            throw new NotSupportedException();

        public Task<AuthorizationState> RefreshStatusAsync(
            CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<AuthorizationState> AuthorizeAsync(
            AuthorizationMethod method,
            IProgress<AuthorizationState> progress,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException(message);

        public void Cancel()
        {
        }
    }

    private sealed class CancellableAuthenticationCoordinator
        : IAuthenticationCoordinator
    {
        private readonly TaskCompletionSource cancelled = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource Started { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public bool CancelCalled { get; private set; }

        public AuthorizationState State =>
            throw new NotSupportedException();

        public Task<AuthorizationState> RefreshStatusAsync(
            CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public async Task<AuthorizationState> AuthorizeAsync(
            AuthorizationMethod method,
            IProgress<AuthorizationState> progress,
            CancellationToken cancellationToken)
        {
            Assert.False(cancellationToken.CanBeCanceled);
            Started.TrySetResult();
            await cancelled.Task;
            throw new OperationCanceledException();
        }

        public void Cancel()
        {
            CancelCalled = true;
            cancelled.TrySetResult();
        }
    }
}
