using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace CodexOneClickInstaller;

public sealed record ProviderChoice(ProviderKind Value, string DisplayName);
public enum InstallerOutcome { Succeeded, Cancelled, Failed }

public sealed record AuthenticationChoice(
    AuthenticationMode Value,
    string DisplayName);

public sealed record DreamSkinChoice(string Value, string DisplayName);

public sealed record CapabilityStatus(string Name, string Status);

public sealed record OpenAIAuthorizationSnapshot(
    bool CodexInstalled,
    bool IsAuthorized,
    string StatusText,
    bool IsAvailable = true);

public sealed record InstallerUiResult(
    bool Succeeded,
    string? FailureCode = null,
    string? ReportPath = null,
    IReadOnlyList<CapabilityStatus>? Capabilities = null);

public enum InstallerOperationKind
{
    None,
    Install,
    RefreshModels,
    RefreshAuthorization,
    Authorize,
    Restore
}

public interface IInstallerBackend
{
    OpenAIAuthorizationSnapshot Authorization { get; }

    bool CanRestore { get; }

    IReadOnlyList<ModelDefinition> OfflineModels(ProviderKind provider);

    Task<ModelResolution> RefreshModelsAsync(
        ProviderKind provider,
        SensitiveString apiKey,
        CancellationToken cancellationToken);

    Task<OpenAIAuthorizationSnapshot> RefreshAuthorizationAsync(
        CancellationToken cancellationToken);

    Task<OpenAIAuthorizationSnapshot> AuthorizeAsync(
        IProgress<OpenAIAuthorizationSnapshot> progress,
        CancellationToken cancellationToken);

    Task<InstallerUiResult> InstallAsync(
        InstallRequest request,
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationToken);

    Task<RestoreResult> RestoreLatestAsync(CancellationToken cancellationToken);

    void CancelAuthorization();
}

public interface IExternalLauncher
{
    void Open(string target);
}

public sealed class ShellExternalLauncher : IExternalLauncher
{
    public void Open(string target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
    }
}

public sealed class CoreInstallerBackend : IInstallerBackend
{
    private readonly ModelCatalogService modelCatalog;
    private readonly IAuthenticationCoordinator authentication;
    private readonly Func<
        InstallRequest,
        IProgress<InstallerEvent>,
        CancellationToken,
        Task<InstallerUiResult>> install;
    private readonly Func<CancellationToken, Task<RestoreResult>> restore;

    public CoreInstallerBackend(
        ModelCatalogService modelCatalog,
        IAuthenticationCoordinator authentication,
        Func<
            InstallRequest,
            IProgress<InstallerEvent>,
            CancellationToken,
            Task<InstallerUiResult>>? install = null,
        Func<CancellationToken, Task<RestoreResult>>? restore = null,
        bool canRestore = false)
    {
        this.modelCatalog =
            modelCatalog ?? throw new ArgumentNullException(nameof(modelCatalog));
        this.authentication =
            authentication ?? throw new ArgumentNullException(nameof(authentication));
        this.install = install ?? ((_, _, _) => Task.FromResult(
            new InstallerUiResult(
                false,
                "installer_engine_not_ready")));
        this.restore = restore ?? (_ => Task.FromResult(
            new RestoreResult(false, FailureCode: "no_backup")));
        CanRestore = canRestore;
    }

    public OpenAIAuthorizationSnapshot Authorization =>
        ToSnapshot(authentication.State);

    public bool CanRestore { get; }

    public IReadOnlyList<ModelDefinition> OfflineModels(ProviderKind provider) =>
        modelCatalog.OfflineModels(provider);

    public Task<ModelResolution> RefreshModelsAsync(
        ProviderKind provider,
        SensitiveString apiKey,
        CancellationToken cancellationToken) =>
        modelCatalog.ResolveModelsAsync(
            provider,
            apiKey,
            cancellationToken: cancellationToken);

    public async Task<OpenAIAuthorizationSnapshot> RefreshAuthorizationAsync(
        CancellationToken cancellationToken) =>
        ToSnapshot(await authentication.RefreshStatusAsync(cancellationToken));

    public async Task<OpenAIAuthorizationSnapshot> AuthorizeAsync(
        IProgress<OpenAIAuthorizationSnapshot> progress,
        CancellationToken cancellationToken)
    {
        var adapter = new Progress<AuthorizationState>(
            state => progress.Report(ToSnapshot(state)));
        return ToSnapshot(await authentication.AuthorizeAsync(
            AuthorizationMethod.Browser,
            adapter,
            cancellationToken));
    }

    public Task<InstallerUiResult> InstallAsync(
        InstallRequest request,
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationToken) =>
        install(request, progress, cancellationToken);

    public Task<RestoreResult> RestoreLatestAsync(
        CancellationToken cancellationToken) =>
        restore(cancellationToken);

    public void CancelAuthorization() => authentication.Cancel();

    private static OpenAIAuthorizationSnapshot ToSnapshot(
        AuthorizationState state)
    {
        var installed = state.UnavailableReason
                        != AuthorizationUnavailableReason.CodexNotInstalled;
        var available = state.Kind != AuthorizationStateKind.Unavailable;
        var status = state.Kind switch
        {
            AuthorizationStateKind.Authorized => "OpenAI 已授权",
            AuthorizationStateKind.Unavailable
                when state.UnavailableReason
                     == AuthorizationUnavailableReason.CodexNotInstalled =>
                "安装 Codex 后获取授权",
            AuthorizationStateKind.Unavailable => "OpenAI 授权不可用",
            AuthorizationStateKind.Launching => "正在打开 OpenAI 授权",
            AuthorizationStateKind.WaitingForBrowser => "请在浏览器中完成授权",
            AuthorizationStateKind.Verifying => "正在确认 OpenAI 授权",
            AuthorizationStateKind.Cancelled => "OpenAI 授权已取消",
            AuthorizationStateKind.RecoverableFailure => "授权未完成，可重试",
            _ => "获取 OpenAI 授权"
        };
        return new OpenAIAuthorizationSnapshot(
            installed,
            state.Kind == AuthorizationStateKind.Authorized,
            status,
            available);
    }
}

public sealed class InstallerViewModel : INotifyPropertyChanged
{
    public const string HybridRecommendation =
        "默认使用所选国产模型 API。有 OpenAI 账号？推荐同时授权；" +
        "模型仍使用当前 API 运行，并解锁全部官方插件入口与最佳兼容性。";

    private static readonly IReadOnlyList<CapabilityStatus> DefaultCapabilities =
        Array.AsReadOnly<CapabilityStatus>(
        [
            new("Uni-Scholar", "已安装"),
            new("Research Kit", "已安装"),
            new("context used meter", "已启用"),
            new("token monitor", "已启用")
        ]);

    private readonly IInstallerBackend backend;
    private readonly IExternalLauncher launcher;
    private ProviderChoice selectedProvider;
    private AuthenticationChoice selectedAuthentication;
    private DreamSkinChoice selectedDreamSkin;
    private ModelDefinition? selectedModel;
    private string apiKey = string.Empty;
    private string statusText = "就绪";
    private string modelSourceText = "内置离线模型";
    private string progressText = "等待开始";
    private double progress;
    private bool isProgressIndeterminate;
    private bool isCompletionVisible;
    private string? reportPath;
    private OpenAIAuthorizationSnapshot authorization;
    private InstallerOperationKind currentOperation;
    private CancellationTokenSource? currentCancellation;

    public InstallerViewModel(
        IInstallerBackend backend,
        IExternalLauncher? launcher = null)
    {
        this.backend = backend ?? throw new ArgumentNullException(nameof(backend));
        this.launcher = launcher ?? new ShellExternalLauncher();

        Providers = Array.AsReadOnly(
        [
            new ProviderChoice(ProviderKind.DeepSeek, "DeepSeek"),
            new ProviderChoice(ProviderKind.KimiOpen, "Kimi 开放平台"),
            new ProviderChoice(ProviderKind.KimiCode, "Kimi Code 会员"),
            new ProviderChoice(ProviderKind.Zhipu, "智谱 GLM"),
            new ProviderChoice(ProviderKind.Qwen, "阿里千问"),
            new ProviderChoice(ProviderKind.XiaomiMiMo, "小米 MiMo")
        ]);
        AuthenticationModes = Array.AsReadOnly(
        [
            new AuthenticationChoice(AuthenticationMode.PureApi, "仅 API（默认）"),
            new AuthenticationChoice(
                AuthenticationMode.OpenAIAccountWithApi,
                "API + OpenAI 账号（推荐）")
        ]);
        DreamSkinPresets = Array.AsReadOnly(
        [
            new DreamSkinChoice(
                "preset-gothic-void-crusade",
                "Gothic Void Crusade（推荐）"),
            new DreamSkinChoice(
                "gallery",
                "DreamSkin.cc 主题库（安装时连接 API）"),
            new DreamSkinChoice(
                "none",
                "官方默认外观（不启用 Dream Skin）")
        ]);
        selectedProvider = Providers[0];
        selectedAuthentication = AuthenticationModes[0];
        selectedDreamSkin = DreamSkinPresets[0];
        authorization = backend.Authorization;

        InstallCommand = new AsyncCommand(
            InstallAsync,
            () => !IsBusy && HasValidApiKey && SelectedModel is not null);
        RefreshModelsCommand = new AsyncCommand(
            RefreshModelsAsync,
            () => !IsBusy && HasValidApiKey);
        AuthorizeOpenAICommand = new AsyncCommand(
            AuthorizeOpenAIAsync,
            () => !IsBusy
                  && IsHybridMode
                  && authorization.CodexInstalled
                  && !authorization.IsAuthorized
                  && authorization.IsAvailable);
        RestoreCommand = new AsyncCommand(
            RestoreAsync,
            () => !IsBusy && backend.CanRestore);
        CancelCommand = new DelegateCommand(
            CancelCurrentOperation,
            () => IsBusy);
        OpenApiKeyPageCommand = new DelegateCommand(OpenApiKeyPage);
        OpenReportCommand = new DelegateCommand(
            OpenReport,
            () => HasReport);

        LoadOfflineModels();
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<InstallerOutcome>? InstallFinished;

    public IReadOnlyList<ProviderChoice> Providers { get; }

    public IReadOnlyList<AuthenticationChoice> AuthenticationModes { get; }

    public IReadOnlyList<DreamSkinChoice> DreamSkinPresets { get; }

    public ObservableCollection<ModelDefinition> Models { get; } = [];

    public ObservableCollection<string> LogLines { get; } = [];

    public ObservableCollection<CapabilityStatus> CompletionItems { get; } = [];

    public AsyncCommand InstallCommand { get; }

    public AsyncCommand RefreshModelsCommand { get; }

    public AsyncCommand AuthorizeOpenAICommand { get; }

    public AsyncCommand RestoreCommand { get; }

    public DelegateCommand CancelCommand { get; }

    public DelegateCommand OpenApiKeyPageCommand { get; }

    public DelegateCommand OpenReportCommand { get; }

    public ProviderChoice SelectedProvider
    {
        get => selectedProvider;
        set
        {
            if (value is null || selectedProvider == value)
                return;
            selectedProvider = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ApiKeyButtonText));
            LoadOfflineModels();
        }
    }

    public AuthenticationChoice SelectedAuthentication
    {
        get => selectedAuthentication;
        set
        {
            if (value is null || selectedAuthentication == value)
                return;

            // Deliberately preserve provider and model when switching to Hybrid.
            selectedAuthentication = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsHybridMode));
            OnPropertyChanged(nameof(ShowAuthorizationRecommendation));
            OnPropertyChanged(nameof(AuthorizationRecommendation));
            OnPropertyChanged(nameof(OpenAIButtonText));
            NotifyCommandStates();
        }
    }

    public DreamSkinChoice SelectedDreamSkin
    {
        get => selectedDreamSkin;
        set
        {
            if (value is null || selectedDreamSkin == value)
                return;
            selectedDreamSkin = value;
            OnPropertyChanged();
        }
    }

    public ModelDefinition? SelectedModel
    {
        get => selectedModel;
        set
        {
            if (selectedModel == value)
                return;
            selectedModel = value;
            OnPropertyChanged();
            NotifyCommandStates();
        }
    }

    public string ApiKey
    {
        get => apiKey;
        set
        {
            if (apiKey == value)
                return;
            apiKey = value ?? string.Empty;
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasValidApiKey));
            NotifyCommandStates();
        }
    }

    public bool HasValidApiKey => ApiKey.Trim().Length >= 8;

    public bool IsHybridMode =>
        SelectedAuthentication.Value
        == AuthenticationMode.OpenAIAccountWithApi;

    public bool ShowAuthorizationRecommendation => IsHybridMode;

    public string AuthorizationRecommendation => HybridRecommendation;

    public string OpenAIButtonText =>
        authorization.IsAuthorized
            ? "OpenAI 已授权"
            : !authorization.CodexInstalled
                ? "安装 Codex 后获取授权"
                : authorization.StatusText;

    public string AuthorizationStatusText => authorization.StatusText;

    public string ApiKeyButtonText => SelectedProvider.Value switch
    {
        ProviderKind.DeepSeek => "获取 DeepSeek API Key",
        ProviderKind.KimiOpen => "获取 Kimi API Key",
        ProviderKind.KimiCode => "打开 Kimi Code 控制台",
        ProviderKind.Zhipu => "获取智谱 GLM API Key",
        ProviderKind.Qwen => "获取阿里千问 API Key",
        ProviderKind.XiaomiMiMo => "获取小米 MiMo API Key",
        _ => "获取 API Key"
    };

    public string ModelSourceText
    {
        get => modelSourceText;
        private set => SetField(ref modelSourceText, value);
    }

    public string StatusText
    {
        get => statusText;
        private set => SetField(ref statusText, value);
    }

    public string ProgressText
    {
        get => progressText;
        private set => SetField(ref progressText, value);
    }

    public double Progress
    {
        get => progress;
        private set => SetField(ref progress, Math.Clamp(value, 0, 1));
    }

    public bool IsProgressIndeterminate
    {
        get => isProgressIndeterminate;
        private set => SetField(ref isProgressIndeterminate, value);
    }

    public bool IsCompletionVisible
    {
        get => isCompletionVisible;
        private set => SetField(ref isCompletionVisible, value);
    }

    public bool HasReport => !string.IsNullOrWhiteSpace(reportPath);

    public bool IsBusy => CurrentOperation != InstallerOperationKind.None;

    public InstallerOperationKind CurrentOperation
    {
        get => currentOperation;
        private set
        {
            if (!SetField(ref currentOperation, value))
                return;
            OnPropertyChanged(nameof(IsBusy));
            NotifyCommandStates();
        }
    }

    public async Task InitializeAsync()
    {
        await RunExclusiveAsync(
            InstallerOperationKind.RefreshAuthorization,
            async cancellationToken =>
            {
                StatusText = "正在检查 Codex 与 OpenAI 授权状态";
                SetAuthorization(
                    await backend.RefreshAuthorizationAsync(cancellationToken));
                StatusText = "就绪";
            });
    }

    private async Task InstallAsync()
    {
        await RunExclusiveAsync(
            InstallerOperationKind.Install,
            async cancellationToken =>
            {
                var models = Models.Select(model => model.Id).ToArray();
                var model = SelectedModel
                            ?? throw new InvalidOperationException("请选择模型。");
                var request = new InstallRequest(
                    SelectedProvider.Value,
                    new SensitiveString(ApiKey.Trim()),
                    model.Id,
                    Array.AsReadOnly(models),
                    ModelSourceText == "已从服务商刷新"
                        ? ModelSource.UpstreamRefresh
                        : ModelSource.OfflineSnapshot,
                    SelectedAuthentication.Value,
                    SelectedDreamSkin.Value);
                IsCompletionVisible = false;
                IsProgressIndeterminate = true;
                Progress = 0;
                ProgressText = "正在安装";
                StatusText = "安装、配置与验证正在进行";
                LogLines.Clear();
                var eventProgress = new Progress<InstallerEvent>(ApplyInstallerEvent);
                var result = await backend.InstallAsync(
                    request,
                    eventProgress,
                    cancellationToken);
                IsProgressIndeterminate = false;

                if (!result.Succeeded)
                {
                    ProgressText = "安装未完成";
                    StatusText = FailureText(result.FailureCode);
                    AppendLog($"安装失败：{result.FailureCode ?? "unknown"}");
                    InstallFinished?.Invoke(InstallerOutcome.Failed);
                    return;
                }

                Progress = 1;
                ProgressText = "安装完成";
                StatusText = "所有组件已安装并通过验证";
                SetAuthorization(
                    await backend.RefreshAuthorizationAsync(
                        cancellationToken));
                reportPath = result.ReportPath;
                OnPropertyChanged(nameof(HasReport));
                OpenReportCommand.RaiseCanExecuteChanged();
                CompletionItems.Clear();
                foreach (var item in result.Capabilities ?? DefaultCapabilities)
                    CompletionItems.Add(item);
                IsCompletionVisible = true;
                InstallFinished?.Invoke(InstallerOutcome.Succeeded);
            });
    }

    private async Task RefreshModelsAsync()
    {
        await RunExclusiveAsync(
            InstallerOperationKind.RefreshModels,
            async cancellationToken =>
            {
                StatusText = "正在刷新模型列表";
                ProgressText = "连接服务商";
                IsProgressIndeterminate = true;
                var provider = SelectedProvider;
                var selectedId = SelectedModel?.Id;
                var resolution = await backend.RefreshModelsAsync(
                    provider.Value,
                    new SensitiveString(ApiKey.Trim()),
                    cancellationToken);

                // Do not apply a late response after the provider changed.
                if (SelectedProvider != provider)
                    return;
                ReplaceModels(resolution.Models, selectedId);
                ModelSourceText = resolution.Source == ModelSource.UpstreamRefresh
                    ? "已从服务商刷新"
                    : "刷新失败，继续使用内置离线模型";
                StatusText = "模型列表已更新";
                ProgressText = "就绪";
                IsProgressIndeterminate = false;
            });
    }

    private async Task AuthorizeOpenAIAsync()
    {
        await RunExclusiveAsync(
            InstallerOperationKind.Authorize,
            async cancellationToken =>
            {
                StatusText = "正在获取 OpenAI 授权";
                IsProgressIndeterminate = true;
                var progress = new Progress<OpenAIAuthorizationSnapshot>(
                    SetAuthorization);
                SetAuthorization(
                    await backend.AuthorizeAsync(progress, cancellationToken));
                StatusText = authorization.IsAuthorized
                    ? "OpenAI 已授权"
                    : authorization.StatusText;
                IsProgressIndeterminate = false;
            });
    }

    private async Task RestoreAsync()
    {
        await RunExclusiveAsync(
            InstallerOperationKind.Restore,
            async cancellationToken =>
            {
                StatusText = "正在恢复最近备份";
                ProgressText = "恢复中";
                IsProgressIndeterminate = true;
                var result = await backend.RestoreLatestAsync(cancellationToken);
                IsProgressIndeterminate = false;
                ProgressText = result.Restored ? "恢复完成" : "恢复未完成";
                StatusText = result.Restored
                    ? "最近备份已恢复"
                    : FailureText(result.FailureCode);
            });
    }

    private async Task RunExclusiveAsync(
        InstallerOperationKind operation,
        Func<CancellationToken, Task> action)
    {
        if (IsBusy)
            return;

        using var cancellation = new CancellationTokenSource();
        currentCancellation = cancellation;
        CurrentOperation = operation;
        try
        {
            await action(cancellation.Token);
        }
        catch (OperationCanceledException)
            when (cancellation.IsCancellationRequested)
        {
            IsProgressIndeterminate = false;
            ProgressText = "已取消";
            StatusText = "当前操作已取消";
            if (operation == InstallerOperationKind.Install)
                InstallFinished?.Invoke(InstallerOutcome.Cancelled);
        }
        catch (Exception error)
        {
            IsProgressIndeterminate = false;
            ProgressText = "操作失败";
            StatusText = "操作失败，请查看日志后重试";
            AppendLog(InstallerConfig.Redact(error.Message));
            if (operation == InstallerOperationKind.Install)
                InstallFinished?.Invoke(InstallerOutcome.Failed);
        }
        finally
        {
            currentCancellation = null;
            CurrentOperation = InstallerOperationKind.None;
        }
    }

    private void CancelCurrentOperation()
    {
        if (!IsBusy)
            return;
        var operation = CurrentOperation;
        currentCancellation?.Cancel();
        if (operation == InstallerOperationKind.Authorize)
            backend.CancelAuthorization();
        StatusText = "正在取消当前操作";
    }

    private void LoadOfflineModels()
    {
        var models = backend.OfflineModels(SelectedProvider.Value);
        var preferred = SelectedProvider.Value switch
        {
            ProviderKind.Zhipu => "glm-5.2",
            ProviderKind.Qwen => "qwen3.7-max",
            ProviderKind.XiaomiMiMo => "mimo-v2.5-pro",
            _ => null
        };
        ReplaceModels(models, selectedId: preferred);
        ModelSourceText = "内置离线模型";
        StatusText = "就绪";
    }

    private void ReplaceModels(
        IReadOnlyList<ModelDefinition> models,
        string? selectedId)
    {
        Models.Clear();
        foreach (var model in models)
            Models.Add(model);
        SelectedModel = Models.FirstOrDefault(
                            model => model.Id == selectedId)
                        ?? Models.FirstOrDefault();
    }

    private void SetAuthorization(OpenAIAuthorizationSnapshot snapshot)
    {
        authorization = snapshot;
        OnPropertyChanged(nameof(OpenAIButtonText));
        OnPropertyChanged(nameof(AuthorizationStatusText));
        NotifyCommandStates();
    }

    private void ApplyInstallerEvent(InstallerEvent installerEvent)
    {
        if (installerEvent.Progress is not null)
        {
            Progress = installerEvent.Progress.Value;
            IsProgressIndeterminate = false;
        }
        if (!string.IsNullOrWhiteSpace(installerEvent.Message))
        {
            ProgressText = installerEvent.Message;
            AppendLog(InstallerConfig.Redact(installerEvent.Message));
        }
    }

    private void OpenApiKeyPage()
    {
        var url = SelectedProvider.Value switch
        {
            ProviderKind.DeepSeek => "https://platform.deepseek.com/api_keys",
            ProviderKind.KimiOpen =>
                "https://platform.moonshot.cn/console/api-keys",
            ProviderKind.KimiCode => "https://www.kimi.com/code/console",
            ProviderKind.Zhipu => "https://bigmodel.cn/usercenter/apikeys",
            ProviderKind.Qwen =>
                "https://bailian.console.aliyun.com/cn-beijing?tab=model",
            ProviderKind.XiaomiMiMo => "https://platform.xiaomimimo.com/",
            _ => throw new ArgumentOutOfRangeException()
        };
        launcher.Open(url);
    }

    private void OpenReport()
    {
        if (HasReport)
            launcher.Open(reportPath!);
    }

    private void AppendLog(string text)
    {
        if (!string.IsNullOrWhiteSpace(text))
            LogLines.Add(text);
    }

    private static string FailureText(string? failureCode) => failureCode switch
    {
        "installer_engine_not_ready" => "安装引擎尚未连接",
        "no_backup" => "没有可恢复的备份",
        null or "" => "操作未完成，请重试",
        _ => $"操作未完成（{failureCode}）"
    };

    private void NotifyCommandStates()
    {
        InstallCommand.RaiseCanExecuteChanged();
        RefreshModelsCommand.RaiseCanExecuteChanged();
        AuthorizeOpenAICommand.RaiseCanExecuteChanged();
        RestoreCommand.RaiseCanExecuteChanged();
        CancelCommand.RaiseCanExecuteChanged();
    }

    private bool SetField<T>(
        ref T field,
        T value,
        [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return false;
        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged(
        [CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(
            this,
            new PropertyChangedEventArgs(propertyName));
}
