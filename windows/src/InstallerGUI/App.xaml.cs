using System.IO;
using System.Windows;

namespace CodexOneClickInstaller;

public partial class App : Application
{
    private const string OfficialCodexPublisher =
        "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B";
    private readonly InstallerExitCodeCoordinator exitCodes = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (Environment.OSVersion.Version.Build < PreflightService.MinimumWindowsBuild)
        {
            MessageBox.Show(
                "需要 Windows 10 1809 或更高版本。",
                "系统不兼容",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            exitCodes.RecordFailure();
            Shutdown(StartupContract.FailureExitCode);
            return;
        }

        StartupOptions startup;
        try
        {
            startup = StartupContract.Parse(
                e.Args,
                AppContext.BaseDirectory);
        }
        catch (Exception error)
            when (error is ArgumentException or IOException)
        {
            MessageBox.Show(
                error.Message,
                "离线载荷路径无效",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            exitCodes.RecordFailure();
            Shutdown(StartupContract.FailureExitCode);
            return;
        }
        if (startup.CiSmokeReport is not null)
        {
            var permitted =
                string.Equals(
                    Environment.GetEnvironmentVariable("GITHUB_ACTIONS"),
                    "true",
                    StringComparison.OrdinalIgnoreCase)
                || Environment.GetEnvironmentVariable("CODEX_ALLOW_CI_SMOKE") == "1";
            try
            {
                if (!permitted)
                    throw new InvalidOperationException("CI smoke mode is not permitted.");
                StartupContract.WriteCiSmokeEvidence(startup);
                exitCodes.RecordSuccess();
                Shutdown(StartupContract.SuccessExitCode);
            }
            catch
            {
                exitCodes.RecordFailure();
                Shutdown(StartupContract.FailureExitCode);
            }
            return;
        }
        var payloadRoot = startup.PayloadRoot;
        var catalogPath = Path.Combine(payloadRoot, "model-catalog.json");
        var localAppData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        var authentication =
            new AuthenticationCoordinator(OfficialCodexPublisher);
        var engine = InstallerEngine.CreateDefault(
            new InstallerEngineOptions(
                payloadRoot,
                Path.Combine(localAppData, "Programs", "Codex++"),
                Path.Combine(
                    localAppData,
                    "Codex One Click Installer",
                    "reports")),
            authentication: authentication);
        var backend = new CoreInstallerBackend(
            new ModelCatalogService(catalogPath),
            authentication,
            async (request, progress, cancellationToken) =>
            {
                var result = await engine.InstallAsync(
                    request,
                    progress,
                    cancellationToken);
                if (!result.Succeeded)
                {
                    return new InstallerUiResult(
                        result.Succeeded,
                        result.FailureCode,
                        engine.LastReportPath);
                }
                try
                {
                    await DreamSkinInstaller.InstallAsync(
                        startup.DreamSkinSetupPath,
                        request.DreamSkinPreset,
                        progress,
                        cancellationToken);
                }
                catch (FileNotFoundException)
                {
                    return new InstallerUiResult(
                        false,
                        "dream_skin_setup_missing",
                        engine.LastReportPath);
                }
                catch (Exception error)
                {
                    progress.Report(new InstallerEvent(
                        "dream_skin_failed",
                        null,
                        InstallerConfig.Redact(error.Message),
                        "dream_skin_install_failed"));
                    return new InstallerUiResult(
                        false,
                        "dream_skin_install_failed",
                        engine.LastReportPath);
                }
                var capabilities = new[]
                {
                    new CapabilityStatus("Uni-Scholar", "已安装"),
                    new CapabilityStatus("Research Kit", "已安装"),
                    new CapabilityStatus("Codex Dream Skin",
                        request.DreamSkinPreset == DreamSkinInstaller.NonePreset
                            ? "未启用（官方默认外观）"
                            : request.DreamSkinPreset == DreamSkinInstaller.GalleryPreset
                                ? "已安装（10 套精选主题，可在线继续选择）"
                                : "已安装（Gothic Void Crusade + 10 套精选主题）")
                };
                return new InstallerUiResult(
                    result.Succeeded,
                    result.FailureCode,
                    engine.LastReportPath,
                    capabilities);
            },
            cancellationToken => engine.RestoreLatestAsync(
                new Progress<InstallerEvent>(_ => { }),
                cancellationToken),
            canRestore: true);
        var viewModel = new InstallerViewModel(backend);
        viewModel.InstallFinished += outcome =>
        {
            switch (outcome)
            {
                case InstallerOutcome.Succeeded:
                    exitCodes.RecordSuccess();
                    break;
                case InstallerOutcome.Cancelled:
                    exitCodes.RecordCancellation();
                    break;
                case InstallerOutcome.Failed:
                    exitCodes.RecordFailure();
                    break;
            }
        };
        var window = new MainWindow(viewModel);
        MainWindow = window;
        window.Show();
        _ = viewModel.InitializeAsync();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        e.ApplicationExitCode = exitCodes.ExitCode;
        base.OnExit(e);
    }
}
