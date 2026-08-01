using System.Runtime.InteropServices;
using System.Text.Json;

namespace CodexOneClickInstaller;

public sealed record InstallerEngineOptions(
    string PayloadRoot,
    string InstallPath,
    string ReportDirectory,
    long PayloadExtractionPeakBytes = 0,
    bool FixtureMode = false,
    bool Unsigned = false);

public sealed record ApplicationInstallSummary(
    ApplicationInstallResult Codex,
    ApplicationInstallResult CodexPlusPlus);

public sealed record InstallerSystemReport(
    string OperatingSystem,
    string Architecture);

public sealed record InstallerReport(
    int SchemaVersion,
    DateTimeOffset CreatedAt,
    InstallerSystemReport System,
    IReadOnlyList<ComponentPlan> Plan,
    ProviderKind Provider,
    string Model,
    int MarketplaceCount,
    int PluginCount,
    int ScriptCount,
    string AuthorizationStatus,
    InstallationVerification Verification,
    bool Unsigned,
    bool CleanupPending,
    IReadOnlyList<string> Messages);

public delegate Task<ApplicationInstallSummary> ApplyApplicationsStep(
    IReadOnlyList<ComponentPlan> plan,
    PayloadCatalog catalog,
    IProgress<InstallerEvent> progress,
    CancellationToken cancellationToken);

public delegate Task<ConfigurationApplyResult> ApplyConfigurationStep(
    InstallRequest request,
    IReadOnlyList<ModelDefinition> models,
    CancellationToken cancellationToken);

public delegate Task<PluginInstallResult> ApplyPluginsStep(
    PayloadCatalog catalog,
    CancellationToken cancellationToken);

public delegate Task<ScriptMarketInstallResult> ApplyScriptsStep(
    PayloadCatalog catalog,
    CancellationToken cancellationToken);

public delegate Task<InstallationVerification> VerifyInstallationStep(
    InstallRequest request,
    IReadOnlyList<ModelDefinition> models,
    PayloadCatalog catalog,
    CancellationToken cancellationToken);

public sealed class InstallerEngineOperations
{
    public InstallerEngineOperations(
        ApplyApplicationsStep applications,
        ApplyConfigurationStep configuration,
        ApplyPluginsStep plugins,
        ApplyScriptsStep scripts,
        VerifyInstallationStep verification)
    {
        Applications =
            applications ?? throw new ArgumentNullException(nameof(applications));
        Configuration =
            configuration ?? throw new ArgumentNullException(nameof(configuration));
        Plugins = plugins ?? throw new ArgumentNullException(nameof(plugins));
        Scripts = scripts ?? throw new ArgumentNullException(nameof(scripts));
        Verification =
            verification ?? throw new ArgumentNullException(nameof(verification));
    }

    public ApplyApplicationsStep Applications { get; }

    public ApplyConfigurationStep Configuration { get; }

    public ApplyPluginsStep Plugins { get; }

    public ApplyScriptsStep Scripts { get; }

    public VerifyInstallationStep Verification { get; }

    public static InstallerEngineOperations FromServices(
        CodexInstaller codex,
        CodexPlusPlusInstaller codexPlusPlus,
        ConfigurationService configuration,
        PluginInstaller plugins,
        ScriptMarketInstaller scripts,
        VerificationService verification,
        WindowsConfigurationPaths paths,
        string payloadRoot)
    {
        ArgumentNullException.ThrowIfNull(codex);
        ArgumentNullException.ThrowIfNull(codexPlusPlus);
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(plugins);
        ArgumentNullException.ThrowIfNull(scripts);
        ArgumentNullException.ThrowIfNull(verification);
        ArgumentNullException.ThrowIfNull(paths);
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadRoot);

        return new InstallerEngineOperations(
            async (plan, catalog, progress, cancellationToken) =>
            {
                var codexPlan = RequiredPlan(plan, "codex-windows-x64");
                var codexPlusPlusPlan = RequiredPlan(
                    plan,
                    "codex-plus-plus-windows-x64");
                progress.Report(new InstallerEvent(
                    "application",
                    0.30,
                    "正在处理 Codex",
                    null));
                var codexResult = await codex.ApplyAsync(
                        codexPlan,
                        catalog,
                        cancellationToken)
                    .ConfigureAwait(false);
                progress.Report(new InstallerEvent(
                    "application",
                    0.40,
                    "正在处理 Codex++",
                    null));
                var codexPlusPlusResult = await codexPlusPlus.ApplyAsync(
                        codexPlusPlusPlan,
                        catalog,
                        cancellationToken)
                    .ConfigureAwait(false);
                return new ApplicationInstallSummary(
                    codexResult,
                    codexPlusPlusResult);
            },
            (request, models, cancellationToken) =>
                configuration.ApplyAsync(
                    request,
                    models,
                    cancellationToken),
            (catalog, cancellationToken) =>
                plugins.InstallAsync(
                    payloadRoot,
                    catalog,
                    cancellationToken),
            (catalog, cancellationToken) =>
                scripts.InstallAsync(
                    payloadRoot,
                    catalog,
                    cancellationToken),
            (request, models, catalog, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                return Task.FromResult(verification.VerifyInstallation(
                    paths,
                    request,
                    models,
                    payloadRoot,
                    catalog));
            });
    }

    private static ComponentPlan RequiredPlan(
        IReadOnlyList<ComponentPlan> plan,
        string component)
    {
        var matches = plan.Where(item => string.Equals(
                item.Component,
                component,
                StringComparison.Ordinal))
            .ToArray();
        return matches.Length == 1
            ? matches[0]
            : throw new InvalidDataException(
                $"Install plan must contain exactly one {component} entry.");
    }
}

public sealed class InstallerEngine : IInstallerEngine
{
    private const string CodexTransactionTarget = "engine.codex-package";
    private readonly InstallerEngineOptions options;
    private readonly PreflightService preflight;
    private readonly PayloadCatalogService payloadCatalog;
    private readonly InstallPlanner planner;
    private readonly InstallerEngineOperations operations;
    private readonly ExternalMutationCoordinator transaction;
    private readonly IReadOnlyList<string> transactionTargets;
    private readonly Func<
        ProviderKind,
        IReadOnlyList<ModelDefinition>> modelResolver;
    private readonly InstallerReportWriter reportWriter;
    private readonly IAuthenticationCoordinator? authentication;
    private readonly RedactingLogger logger;
    private readonly SemaphoreSlim operationGate = new(1, 1);

    public InstallerEngine(
        InstallerEngineOptions options,
        PreflightService preflight,
        PayloadCatalogService payloadCatalog,
        InstallPlanner planner,
        InstallerEngineOperations operations,
        ExternalMutationCoordinator transaction,
        IReadOnlyList<string> transactionTargets,
        Func<ProviderKind, IReadOnlyList<ModelDefinition>> modelResolver,
        InstallerReportWriter reportWriter,
        IAuthenticationCoordinator? authentication = null,
        RedactingLogger? logger = null)
    {
        this.options = options
                       ?? throw new ArgumentNullException(nameof(options));
        ArgumentException.ThrowIfNullOrWhiteSpace(options.PayloadRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.InstallPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.ReportDirectory);
        if (options.PayloadExtractionPeakBytes < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "Payload extraction peak cannot be negative.");
        }
        this.preflight =
            preflight ?? throw new ArgumentNullException(nameof(preflight));
        this.payloadCatalog =
            payloadCatalog
            ?? throw new ArgumentNullException(nameof(payloadCatalog));
        this.planner = planner ?? throw new ArgumentNullException(nameof(planner));
        this.operations =
            operations ?? throw new ArgumentNullException(nameof(operations));
        this.transaction =
            transaction ?? throw new ArgumentNullException(nameof(transaction));
        ArgumentNullException.ThrowIfNull(transactionTargets);
        if (transactionTargets.Count == 0)
        {
            throw new ArgumentException(
                "Installer engine requires transaction targets.",
                nameof(transactionTargets));
        }
        this.transactionTargets = Array.AsReadOnly(
            transactionTargets.ToArray());
        this.modelResolver =
            modelResolver ?? throw new ArgumentNullException(nameof(modelResolver));
        this.reportWriter =
            reportWriter ?? throw new ArgumentNullException(nameof(reportWriter));
        this.authentication = authentication;
        this.logger = logger ?? new RedactingLogger();
        this.logger.AddSensitivePath(Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile));
        this.logger.AddSensitivePath(options.PayloadRoot);
        this.logger.AddSensitivePath(options.InstallPath);
        this.logger.AddSensitivePath(options.ReportDirectory);
        this.logger.AddSensitivePath(transaction.TransactionsRoot);
    }

    public string? LastReportPath { get; private set; }

    public InstallerReport? LastReport { get; private set; }

    public IReadOnlyList<Guid> LastRecoveredTransactions { get; private set; } = [];

    public static InstallerEngine CreateDefault(
        InstallerEngineOptions options,
        WindowsConfigurationPaths? paths = null,
        IAuthenticationCoordinator? authentication = null)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The default installer engine requires Windows.");
        }

        paths ??= WindowsConfigurationPaths.CurrentUser();
        var payloadRoot = Path.GetFullPath(options.PayloadRoot);
        var deployment = new WindowsCodexPackageDeployment();
        var codex = new CodexInstaller(
            payloadRoot,
            deployment: deployment);
        var codexPlusPlus = new CodexPlusPlusInstaller(
            payloadRoot,
            paths.LocalAppData);
        var configuration = new ConfigurationService(paths);
        var plugins = new PluginInstaller(paths);
        var scripts = new ScriptMarketInstaller(paths);
        var verification = new VerificationService(
            new WindowsSecretFileAclPolicy());
        var modelCatalog = new ModelCatalogService(
            Path.Combine(payloadRoot, "model-catalog.json"));
        var boundary = CreateDefaultTransactionBoundary(
            paths,
            deployment);

        return new InstallerEngine(
            options,
            new PreflightService(new WindowsEnvironment()),
            new PayloadCatalogService(),
            new InstallPlanner(),
            InstallerEngineOperations.FromServices(
                codex,
                codexPlusPlus,
                configuration,
                plugins,
                scripts,
                verification,
                paths,
                payloadRoot),
            boundary.Coordinator,
            boundary.TargetKeys,
            modelCatalog.OfflineModels,
            new InstallerReportWriter(options.ReportDirectory),
            authentication);
    }

    public Task<PreflightResult> PreflightAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(preflight.Evaluate(
            options.InstallPath,
            options.PayloadExtractionPeakBytes));
    }

    public async Task<InstallResult> InstallAsync(
        InstallRequest request,
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(progress);
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        ExternalMutationSession? session = null;
        var committed = false;
        var phase = "recovery";
        try
        {
            LastReport = null;
            LastReportPath = null;
            logger.AddSecret(request.ApiKey);
            LastRecoveredTransactions =
                await transaction.RecoverIncompleteAsync(cancellationToken)
                    .ConfigureAwait(false);
            _ = await transaction.RetryPendingCleanupAsync(cancellationToken)
                .ConfigureAwait(false);

            phase = "preflight";
            Report(progress, "preflight", 0.05, "正在执行安装前检查");
            var preflightResult = await PreflightAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!preflightResult.IsSupported)
            {
                return new InstallResult(
                    false,
                    preflightResult.FailureCode ?? "preflight_failed");
            }

            phase = "manifest";
            Report(progress, "manifest", 0.10, "正在验证离线载荷");
            var catalog = await payloadCatalog.ValidateAsync(
                    options.PayloadRoot,
                    options.FixtureMode,
                    cancellationToken)
                .ConfigureAwait(false);

            phase = "plan";
            Report(progress, "plan", 0.15, "正在生成安装计划");
            var plan = planner.CreatePlan(preflightResult, catalog);
            var models = modelResolver(request.Provider);
            ValidateRequestModels(request, models);

            phase = "stage";
            Report(progress, "stage", 0.20, "正在创建事务快照");
            session = await transaction.BeginExternalMutationAsync(
                    transactionTargets,
                    cancellationToken)
                .ConfigureAwait(false);
            await session.MarkApplyingAsync(cancellationToken)
                .ConfigureAwait(false);

            phase = "applications";
            Report(progress, "applications", 0.25, "正在安装应用");
            var applications = await operations.Applications(
                    plan,
                    catalog,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);

            phase = "configuration";
            Report(progress, "configuration", 0.50, "正在写入模型配置");
            _ = await operations.Configuration(
                    request,
                    models,
                    cancellationToken)
                .ConfigureAwait(false);

            phase = "plugins";
            Report(
                progress,
                "plugins",
                0.62,
                "正在配置插件：5 个离线实装，4 个由 Codex 运行时供应");
            var pluginResult = await operations.Plugins(
                    catalog,
                    cancellationToken)
                .ConfigureAwait(false);

            phase = "scripts";
            Report(progress, "scripts", 0.74, "正在安装脚本市场");
            var scriptResult = await operations.Scripts(
                    catalog,
                    cancellationToken)
                .ConfigureAwait(false);

            phase = "verification";
            Report(progress, "verification", 0.86, "正在验证安装结果");
            var verification = await operations.Verification(
                    request,
                    models,
                    catalog,
                    cancellationToken)
                .ConfigureAwait(false);
            ValidateVerification(verification);

            phase = "commit";
            cancellationToken.ThrowIfCancellationRequested();
            var commit = await session.CommitAsync(cancellationToken)
                .ConfigureAwait(false);
            committed = true;
            ReportAfterCommit(progress, "commit", 0.94, "安装事务已提交");

            phase = "authorization";
            var authorizationStatus = await AuthorizeAfterCommitAsync(
                    request,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);

            phase = "report";
            var report = new InstallerReport(
                1,
                DateTimeOffset.UtcNow,
                new InstallerSystemReport(
                    RuntimeInformation.OSDescription,
                    RuntimeInformation.OSArchitecture.ToString()),
                plan,
                request.Provider,
                request.DefaultModel,
                pluginResult.MarketplaceCount,
                pluginResult.PluginCount,
                scriptResult.InstalledCount,
                authorizationStatus,
                verification,
                options.Unsigned,
                commit.CleanupPending
                || applications.Codex.CleanupPending
                || applications.CodexPlusPlus.CleanupPending,
                logger.Messages);
            LastReportPath = await reportWriter.WriteAsync(
                    report,
                    logger,
                    CancellationToken.None)
                .ConfigureAwait(false);
            LastReport = report;
            ReportAfterCommit(progress, "completed", 1.0, "安装完成");
            return new InstallResult(true);
        }
        catch (OperationCanceledException error)
        {
            await RollBackAsync(session, committed, error).ConfigureAwait(false);
            throw;
        }
        catch (Exception error)
        {
            await RollBackAsync(session, committed, error).ConfigureAwait(false);
            logger.Log($"{phase} failed: {error.Message}");
            return new InstallResult(false, $"{phase}_failed");
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task<RestoreResult> RestoreLatestAsync(
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(progress);
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Report(progress, "recovery", null, "正在恢复未完成事务");
            var recovered = await transaction.RecoverIncompleteAsync(
                    cancellationToken)
                .ConfigureAwait(false);
            LastRecoveredTransactions = recovered;
            return recovered.Count == 0
                ? new RestoreResult(false, FailureCode: "no_incomplete_transaction")
                : new RestoreResult(true);
        }
        finally
        {
            operationGate.Release();
        }
    }

    private async Task<string> AuthorizeAfterCommitAsync(
        InstallRequest request,
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationSignal)
    {
        if (request.AuthenticationMode != AuthenticationMode.OpenAIAccountWithApi)
            return "not_requested";
        if (cancellationSignal.IsCancellationRequested)
        {
            if (authentication is not null)
                SafeCancelAuthentication(authentication);
            return "cancelled_after_commit";
        }
        if (authentication is null)
            return "unavailable";

        ReportAfterCommit(progress, "authorization", 0.97, "正在获取 OpenAI 授权");
        using var cancellationRegistration = cancellationSignal.Register(
            static state => SafeCancelAuthentication(
                (IAuthenticationCoordinator)state!),
            authentication);
        try
        {
            var state = await authentication.AuthorizeAsync(
                    AuthorizationMethod.Browser,
                    new Progress<AuthorizationState>(_ => { }),
                    CancellationToken.None)
                .ConfigureAwait(false);
            return AuthorizationCategory(state);
        }
        catch (OperationCanceledException)
        {
            return "cancelled_after_commit";
        }
        catch (Exception error)
        {
            logger.Log($"authorization failed: {error.Message}");
            return "recoverable_failure";
        }
    }

    private static void SafeCancelAuthentication(
        IAuthenticationCoordinator authentication)
    {
        try
        {
            authentication.Cancel();
        }
        catch
        {
            // A post-commit cancellation signal must never invalidate install.
        }
    }

    private void ReportAfterCommit(
        IProgress<InstallerEvent> progress,
        string kind,
        double? value,
        string message)
    {
        try
        {
            Report(progress, kind, value, message);
        }
        catch (Exception error)
        {
            logger.Log($"post-commit progress failed: {error.Message}");
        }
    }

    private static string AuthorizationCategory(AuthorizationState state) =>
        state.Kind switch
        {
            AuthorizationStateKind.Authorized => "authorized",
            AuthorizationStateKind.Unavailable => "unavailable",
            AuthorizationStateKind.Cancelled => "cancelled_after_commit",
            AuthorizationStateKind.RecoverableFailure => "recoverable_failure",
            _ => "not_authorized"
        };

    private static async Task RollBackAsync(
        ExternalMutationSession? session,
        bool committed,
        Exception primaryError)
    {
        if (session is null || committed
            || session.State is TransactionState.Committed
                or TransactionState.RolledBack)
        {
            return;
        }

        try
        {
            await session.RollBackAsync(CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (Exception rollbackError)
        {
            if (primaryError is OperationCanceledException)
            {
                primaryError.Data["InstallerEngineRollbackError"] = rollbackError;
                return;
            }
            throw new AggregateException(
                "Installer engine failed and rollback did not complete.",
                primaryError,
                rollbackError);
        }
    }

    private static void ValidateRequestModels(
        InstallRequest request,
        IReadOnlyList<ModelDefinition> models)
    {
        var ids = models.Select(model => model.Id)
            .ToHashSet(StringComparer.Ordinal);
        if (!ids.Contains(request.DefaultModel)
            || request.AvailableModels.Count == 0
            || !request.AvailableModels.All(ids.Contains))
        {
            throw new InvalidDataException(
                "Install request does not match the validated model catalog.");
        }
    }

    private static void ValidateVerification(
        InstallationVerification verification)
    {
        ArgumentNullException.ThrowIfNull(verification);
        if (!string.Equals(
                verification.Overall,
                "pass",
                StringComparison.Ordinal)
            || verification.Plugins.MarketplaceCount != 3
            || verification.Plugins.PluginCount != 9
            || verification.Plugins.OfflineMarketplaceCount != 2
            || verification.Plugins.OfflinePluginCount != 5
            || verification.Plugins.RuntimePluginCount != 4
            || !string.Equals(
                verification.Plugins.RuntimeStatus,
                "configured",
                StringComparison.Ordinal)
            || !verification.Scripts.ContextMeterEnabled
            || !verification.Scripts.TokenUsageEnabled)
        {
            throw new InvalidDataException(
                "Installation verification did not satisfy the release contract.");
        }
    }

    private static void Report(
        IProgress<InstallerEvent> progress,
        string kind,
        double? value,
        string message) =>
        progress.Report(new InstallerEvent(kind, value, message, null));

    private static (
        ExternalMutationCoordinator Coordinator,
        IReadOnlyList<string> TargetKeys) CreateDefaultTransactionBoundary(
        WindowsConfigurationPaths paths,
        ICodexPackageDeployment deployment)
    {
        var localPrograms = Path.Combine(
            paths.LocalAppData,
            "Programs",
            "Codex++");
        var startMenuRoot = Environment.GetFolderPath(
            Environment.SpecialFolder.StartMenu);
        var desktopRoot = Environment.GetFolderPath(
            Environment.SpecialFolder.DesktopDirectory);
        if (string.IsNullOrWhiteSpace(startMenuRoot))
        {
            startMenuRoot = Path.Combine(
                paths.LocalAppData,
                "Microsoft",
                "Windows",
                "Start Menu");
        }
        if (string.IsNullOrWhiteSpace(desktopRoot))
            desktopRoot = Path.Combine(paths.LocalAppData, "Desktop");

        var targets = new List<ExternalMutationTargetDefinition>
        {
            new(
                CodexTransactionTarget,
                new CodexPackageGraphExternalMutationProvider(deployment)),
            new(
                CodexPlusPlusManagedTargets.ProgramDirectory,
                new DirectoryExternalMutationProvider(localPrograms)),
            new(
                CodexPlusPlusManagedTargets.ProductRegistration,
                new CurrentUserRegistryExternalMutationProvider(
                    CodexPlusPlusRegistryPaths.Product)),
            new(
                CodexPlusPlusManagedTargets.UninstallRegistration,
                new CurrentUserRegistryExternalMutationProvider(
                    CodexPlusPlusRegistryPaths.Uninstall)),
            new(
                CodexPlusPlusManagedTargets.StartMenuShortcut,
                new ShortcutSetExternalMutationProvider(
                [
                    (
                        startMenuRoot,
                        Path.Combine(
                            startMenuRoot,
                            "Programs",
                            "Codex++",
                            "Codex++.lnk")),
                    (
                        startMenuRoot,
                        Path.Combine(
                            startMenuRoot,
                            "Programs",
                            "Codex++",
                            "Codex++ 管理工具.lnk")),
                    (
                        startMenuRoot,
                        Path.Combine(
                            startMenuRoot,
                            "Programs",
                            "Codex++",
                            "卸载 Codex++.lnk"))
                ])),
            new(
                CodexPlusPlusManagedTargets.DesktopShortcut,
                new ShortcutSetExternalMutationProvider(
                [
                    (desktopRoot, Path.Combine(desktopRoot, "Codex++.lnk")),
                    (
                        desktopRoot,
                        Path.Combine(
                            desktopRoot,
                            "Codex++ 管理工具.lnk"))
                ]))
        };

        AddFileTarget(
            targets,
            "engine.configuration.codex",
            paths.UserProfile,
            paths.CodexConfig);
        AddFileTarget(
            targets,
            "engine.configuration.auth",
            paths.UserProfile,
            paths.CodexAuth);
        AddFileTarget(
            targets,
            "engine.configuration.codex-plus",
            paths.UserProfile,
            paths.CodexPlusSettings);
        AddFileTarget(
            targets,
            "engine.configuration.expectation",
            paths.LocalAppData,
            paths.InstallExpectation);
        targets.Add(new(
            "engine.plugins.marketplaces",
            new DirectoryExternalMutationProvider(paths.OfflineMarketplaces)));
        targets.Add(new(
            "engine.plugins.cache",
            new DirectoryExternalMutationProvider(paths.PluginCache)));
        AddFileTarget(
            targets,
            "engine.scripts.configuration",
            paths.AppData,
            paths.UserScriptsConfig);
        targets.Add(new(
            "engine.scripts.directory",
            new DirectoryExternalMutationProvider(paths.UserScriptsDirectory)));

        var transactionRoot = Path.Combine(
            paths.TransactionsRoot,
            "engine");
        return (
            new ExternalMutationCoordinator(
                transactionRoot,
                new ExternalMutationCatalog(targets)),
            targets.Select(target => target.TargetKey).ToArray());
    }

    private static void AddFileTarget(
        ICollection<ExternalMutationTargetDefinition> targets,
        string key,
        string root,
        string path) =>
        targets.Add(new ExternalMutationTargetDefinition(
            key,
            new FileExternalMutationProvider(root, path)));
}

public sealed class CodexPackageGraphExternalMutationProvider
    : IExternalMutationProvider
{
    private const string SnapshotSchema = "codex.package-graph.v1";
    private readonly ICodexPackageDeployment deployment;

    public CodexPackageGraphExternalMutationProvider(
        ICodexPackageDeployment deployment) =>
        this.deployment =
            deployment ?? throw new ArgumentNullException(nameof(deployment));

    public ExternalMutationTargetKind Kind =>
        ExternalMutationTargetKind.Directory;

    public ExternalMutationProviderScope Scope =>
        ExternalMutationProviderScope.None;

    public async Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
        ManagedSnapshotWriter writer,
        CancellationToken cancellationToken)
    {
        var snapshot = await deployment.CaptureSnapshotAsync(
                CodexInstaller.PackageFamilyName,
                cancellationToken)
            .ConfigureAwait(false);
        return await writer.WriteAsync(
                SnapshotSchema,
                JsonSerializer.SerializeToUtf8Bytes(snapshot),
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ValidateSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken) =>
        await deployment.ValidateSnapshotRestorableAsync(
                await ReadAsync(snapshot, cancellationToken).ConfigureAwait(false),
                cancellationToken)
            .ConfigureAwait(false);

    public async Task RestoreSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken) =>
        await deployment.RestoreSnapshotAsync(
                await ReadAsync(snapshot, cancellationToken).ConfigureAwait(false),
                cancellationToken)
            .ConfigureAwait(false);

    public async Task CleanupSnapshotAsync(
        ManagedSnapshotReader? snapshot,
        CancellationToken cancellationToken)
    {
        if (snapshot is null)
            return;
        _ = await deployment.DiscardSnapshotAsync(
                await ReadAsync(snapshot, cancellationToken).ConfigureAwait(false),
                cancellationToken)
            .ConfigureAwait(false);
    }

    private static async Task<CodexPackageGraphSnapshot> ReadAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken)
    {
        var value = JsonSerializer.Deserialize<CodexPackageGraphSnapshot>(
            await snapshot.ReadAllBytesAsync(cancellationToken)
                .ConfigureAwait(false));
        return value
               ?? throw new InvalidDataException(
                   "Codex package graph snapshot is invalid.");
    }
}
