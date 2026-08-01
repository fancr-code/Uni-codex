using Xunit;

namespace CodexOneClickInstaller;

public sealed class ViewModelTests
{
    [Fact]
    public void Defaults_are_PureApi_DeepSeek_and_first_offline_model()
    {
        var viewModel = Create();

        Assert.Equal(ProviderKind.DeepSeek, viewModel.SelectedProvider.Value);
        Assert.Equal(
            AuthenticationMode.PureApi,
            viewModel.SelectedAuthentication.Value);
        Assert.Equal("deepseek-v4-flash", viewModel.SelectedModel?.Id);
        Assert.Equal("内置离线模型", viewModel.ModelSourceText);
    }

    [Fact]
    public void Kimi_open_platform_contains_kimi_k3()
    {
        var viewModel = Create();

        viewModel.SelectedProvider = viewModel.Providers.Single(
            provider => provider.Value == ProviderKind.KimiOpen);

        Assert.Contains(viewModel.Models, model => model.Id == "kimi-k3");
    }

    [Theory]
    [InlineData(ProviderKind.Zhipu, "智谱 GLM", "glm-5.2", "https://bigmodel.cn/usercenter/apikeys")]
    [InlineData(ProviderKind.Qwen, "阿里千问", "qwen3.7-max", "https://bailian.console.aliyun.com/cn-beijing?tab=model")]
    [InlineData(ProviderKind.XiaomiMiMo, "小米 MiMo", "mimo-v2.5-pro", "https://platform.xiaomimimo.com/")]
    public void New_provider_selects_preferred_model_and_opens_exact_application_url(
        ProviderKind provider,
        string displayName,
        string preferredModel,
        string expectedUrl)
    {
        var launcher = new FakeLauncher();
        var viewModel = Create(launcher: launcher);

        viewModel.SelectedProvider = viewModel.Providers.Single(choice => choice.Value == provider);
        viewModel.OpenApiKeyPageCommand.Execute(null);

        Assert.Equal(displayName, viewModel.SelectedProvider.DisplayName);
        Assert.Equal(preferredModel, viewModel.SelectedModel?.Id);
        Assert.Equal(expectedUrl, launcher.Targets.Single());
    }

    [Fact]
    public void Hybrid_preserves_provider_and_model_and_shows_direct_authorization()
    {
        var viewModel = Create();
        viewModel.SelectedProvider = viewModel.Providers.Single(
            provider => provider.Value == ProviderKind.KimiOpen);
        viewModel.SelectedModel = viewModel.Models.Single(
            model => model.Id == "kimi-k3");
        var provider = viewModel.SelectedProvider;
        var model = viewModel.SelectedModel;

        viewModel.SelectedAuthentication = viewModel.AuthenticationModes.Single(
            mode => mode.Value == AuthenticationMode.OpenAIAccountWithApi);

        Assert.Same(provider, viewModel.SelectedProvider);
        Assert.Same(model, viewModel.SelectedModel);
        Assert.True(viewModel.ShowAuthorizationRecommendation);
        Assert.Equal(InstallerViewModel.HybridRecommendation,
            viewModel.AuthorizationRecommendation);
        Assert.Equal("获取 OpenAI 授权", viewModel.OpenAIButtonText);
    }

    [Theory]
    [InlineData(ProviderKind.Zhipu)]
    [InlineData(ProviderKind.Qwen)]
    [InlineData(ProviderKind.XiaomiMiMo)]
    public void OpenAI_hybrid_can_pair_with_each_new_provider(ProviderKind provider)
    {
        var viewModel = Create();
        viewModel.SelectedProvider = viewModel.Providers.Single(choice => choice.Value == provider);
        var selectedModel = viewModel.SelectedModel;

        viewModel.SelectedAuthentication = viewModel.AuthenticationModes.Single(
            mode => mode.Value == AuthenticationMode.OpenAIAccountWithApi);

        Assert.Equal(provider, viewModel.SelectedProvider.Value);
        Assert.Same(selectedModel, viewModel.SelectedModel);
        Assert.True(viewModel.IsHybridMode);
    }

    [Fact]
    public async Task Successful_authorization_updates_label_without_manual_check()
    {
        var backend = new FakeBackend
        {
            AuthorizationResult =
                new(true, true, "OpenAI 已授权")
        };
        var viewModel = Create(backend);
        viewModel.SelectedAuthentication = viewModel.AuthenticationModes.Single(
            mode => mode.Value == AuthenticationMode.OpenAIAccountWithApi);

        await viewModel.AuthorizeOpenAICommand.ExecuteAsync();

        Assert.Equal("OpenAI 已授权", viewModel.OpenAIButtonText);
        Assert.Equal("OpenAI 已授权", viewModel.StatusText);
        Assert.Equal(1, backend.AuthorizationCalls);
    }

    [Fact]
    public void Missing_Codex_explains_that_installation_must_happen_first()
    {
        var backend = new FakeBackend
        {
            Authorization = new(false, false, "安装 Codex 后获取授权", false)
        };
        var viewModel = Create(backend);
        viewModel.SelectedAuthentication = viewModel.AuthenticationModes.Single(
            mode => mode.Value == AuthenticationMode.OpenAIAccountWithApi);

        Assert.Equal("安装 Codex 后获取授权", viewModel.OpenAIButtonText);
        Assert.False(viewModel.AuthorizeOpenAICommand.CanExecute(null));
    }

    [Fact]
    public async Task Install_refresh_authorize_and_restore_are_mutually_exclusive()
    {
        var backend = new FakeBackend();
        var started = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        backend.InstallHandler = async (_, _, cancellationToken) =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return new InstallerUiResult(true);
        };
        var viewModel = Create(backend);
        InstallerOutcome? outcome = null;
        viewModel.InstallFinished += value => outcome = value;
        viewModel.ApiKey = "valid-key";
        viewModel.SelectedAuthentication = viewModel.AuthenticationModes.Single(
            mode => mode.Value == AuthenticationMode.OpenAIAccountWithApi);

        var installation = viewModel.InstallCommand.ExecuteAsync();
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.True(viewModel.IsBusy);
        Assert.False(viewModel.InstallCommand.CanExecute(null));
        Assert.False(viewModel.RefreshModelsCommand.CanExecute(null));
        Assert.False(viewModel.AuthorizeOpenAICommand.CanExecute(null));
        Assert.False(viewModel.RestoreCommand.CanExecute(null));
        Assert.True(viewModel.CancelCommand.CanExecute(null));

        viewModel.CancelCommand.Execute(null);
        await installation;

        Assert.True(backend.InstallCancellationObserved);
        Assert.Equal(InstallerOutcome.Cancelled, outcome);
        Assert.False(backend.AuthorizationCancelCalled);
        Assert.Equal(InstallerOperationKind.None, viewModel.CurrentOperation);
    }

    [Fact]
    public async Task Cancelling_authorization_cancels_only_the_current_auth_operation()
    {
        var backend = new FakeBackend();
        var started = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        backend.AuthorizationHandler = async (_, cancellationToken) =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return backend.Authorization;
        };
        var viewModel = Create(backend);
        viewModel.SelectedAuthentication = viewModel.AuthenticationModes.Single(
            mode => mode.Value == AuthenticationMode.OpenAIAccountWithApi);

        var authorization = viewModel.AuthorizeOpenAICommand.ExecuteAsync();
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        viewModel.CancelCommand.Execute(null);
        await authorization;

        Assert.True(backend.AuthorizationCancelCalled);
        Assert.False(backend.InstallCancellationObserved);
        Assert.Equal("当前操作已取消", viewModel.StatusText);
    }

    [Fact]
    public async Task Completion_lists_toolkits_monitors_and_report_entry()
    {
        var backend = new FakeBackend
        {
            InstallHandler = (_, _, _) => Task.FromResult(
                new InstallerUiResult(true, ReportPath: "C:\\report.html"))
        };
        var launcher = new FakeLauncher();
        var viewModel = Create(backend, launcher);
        InstallerOutcome? outcome = null;
        viewModel.InstallFinished += value => outcome = value;
        viewModel.ApiKey = "valid-key";

        await viewModel.InstallCommand.ExecuteAsync();

        Assert.True(viewModel.IsCompletionVisible);
        Assert.Equal(InstallerOutcome.Succeeded, outcome);
        Assert.Contains(viewModel.CompletionItems,
            item => item.Name == "Uni-Scholar" && item.Status == "已安装");
        Assert.Contains(viewModel.CompletionItems,
            item => item.Name == "Research Kit" && item.Status == "已安装");
        Assert.Contains(viewModel.CompletionItems,
            item => item.Name == "context used meter" && item.Status == "已启用");
        Assert.Contains(viewModel.CompletionItems,
            item => item.Name == "token monitor" && item.Status == "已启用");
        Assert.True(viewModel.OpenReportCommand.CanExecute(null));

        viewModel.OpenReportCommand.Execute(null);
        Assert.Equal(["C:\\report.html"], launcher.Targets);
    }

    [Fact]
    public async Task Failed_install_requests_failure_exit_code()
    {
        var backend = new FakeBackend
        {
            InstallHandler = (_, _, _) => Task.FromResult(
                new InstallerUiResult(false, "fixture_failure"))
        };
        var viewModel = Create(backend);
        InstallerOutcome? outcome = null;
        viewModel.InstallFinished += value => outcome = value;
        viewModel.ApiKey = "valid-key";

        await viewModel.InstallCommand.ExecuteAsync();

        Assert.Equal(InstallerOutcome.Failed, outcome);
        Assert.False(viewModel.IsCompletionVisible);
    }

    [Fact]
    public async Task Cancel_stops_authorization_refresh_after_install_has_returned()
    {
        var refreshStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var backend = new FakeBackend
        {
            InstallHandler = (_, _, _) => Task.FromResult(
                new InstallerUiResult(true, ReportPath: "C:\\report.html")),
            RefreshAuthorizationHandler = async cancellationToken =>
            {
                refreshStarted.SetResult();
                await Task.Delay(Timeout.Infinite, cancellationToken);
                return new OpenAIAuthorizationSnapshot(
                    true,
                    false,
                    "获取 OpenAI 授权");
            }
        };
        var viewModel = Create(backend);
        viewModel.ApiKey = "valid-key";

        var installation = viewModel.InstallCommand.ExecuteAsync();
        await refreshStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(
            InstallerOperationKind.Install,
            viewModel.CurrentOperation);

        viewModel.CancelCommand.Execute(null);
        await installation;

        Assert.True(backend.RefreshAuthorizationCancellationObserved);
        Assert.Equal(InstallerOperationKind.None, viewModel.CurrentOperation);
        Assert.Equal("当前操作已取消", viewModel.StatusText);
        Assert.False(viewModel.IsCompletionVisible);
    }

    private static InstallerViewModel Create(
        FakeBackend? backend = null,
        IExternalLauncher? launcher = null) =>
        new(backend ?? new FakeBackend(), launcher ?? new FakeLauncher());

    private sealed class FakeLauncher : IExternalLauncher
    {
        public List<string> Targets { get; } = [];

        public void Open(string target) => Targets.Add(target);
    }

    private sealed class FakeBackend : IInstallerBackend
    {
        private readonly IReadOnlyDictionary<
            ProviderKind,
            IReadOnlyList<ModelDefinition>> models =
            new Dictionary<ProviderKind, IReadOnlyList<ModelDefinition>>
            {
                [ProviderKind.DeepSeek] =
                [
                    new("deepseek-v4-flash", "DeepSeek V4 Flash", 1_000_000),
                    new("deepseek-v4-pro", "DeepSeek V4 Pro", 1_000_000)
                ],
                [ProviderKind.KimiOpen] =
                [
                    new("kimi-k2.6", "Kimi K2.6", 262_144),
                    new("kimi-k3", "Kimi K3", 1_000_000)
                ],
                [ProviderKind.KimiCode] =
                [
                    new("k3", "Kimi K3", 1_048_576)
                ],
                [ProviderKind.Zhipu] =
                [
                    new("glm-4.7", "GLM-4.7", null),
                    new("glm-5.2", "GLM-5.2", 1_000_000)
                ],
                [ProviderKind.Qwen] =
                [
                    new("qwen3.7-flash", "Qwen3.7-Flash", 1_000_000),
                    new("qwen3.7-max", "Qwen3.7-Max", 1_000_000)
                ],
                [ProviderKind.XiaomiMiMo] =
                [
                    new("mimo-v2.5", "MiMo-V2.5", 1_000_000),
                    new("mimo-v2.5-pro", "MiMo-V2.5-Pro", 1_000_000)
                ]
            };

        public OpenAIAuthorizationSnapshot Authorization { get; set; } =
            new(true, false, "获取 OpenAI 授权");

        public OpenAIAuthorizationSnapshot AuthorizationResult { get; set; } =
            new(true, false, "获取 OpenAI 授权");

        public bool CanRestore => true;

        public int AuthorizationCalls { get; private set; }

        public bool AuthorizationCancelCalled { get; private set; }

        public bool InstallCancellationObserved { get; private set; }

        public Func<
            InstallRequest,
            IProgress<InstallerEvent>,
            CancellationToken,
            Task<InstallerUiResult>>? InstallHandler { get; set; }

        public Func<
            IProgress<OpenAIAuthorizationSnapshot>,
            CancellationToken,
            Task<OpenAIAuthorizationSnapshot>>? AuthorizationHandler { get; set; }

        public Func<
            CancellationToken,
            Task<OpenAIAuthorizationSnapshot>>?
            RefreshAuthorizationHandler { get; set; }

        public bool RefreshAuthorizationCancellationObserved { get; private set; }

        public IReadOnlyList<ModelDefinition> OfflineModels(
            ProviderKind provider) =>
            models[provider];

        public Task<ModelResolution> RefreshModelsAsync(
            ProviderKind provider,
            SensitiveString apiKey,
            CancellationToken cancellationToken) =>
            Task.FromResult(new ModelResolution(
                models[provider],
                ModelSource.UpstreamRefresh));

        public async Task<OpenAIAuthorizationSnapshot> RefreshAuthorizationAsync(
            CancellationToken cancellationToken)
        {
            try
            {
                return RefreshAuthorizationHandler is null
                    ? Authorization
                    : await RefreshAuthorizationHandler(cancellationToken);
            }
            catch (OperationCanceledException)
                when (cancellationToken.IsCancellationRequested)
            {
                RefreshAuthorizationCancellationObserved = true;
                throw;
            }
        }

        public async Task<OpenAIAuthorizationSnapshot> AuthorizeAsync(
            IProgress<OpenAIAuthorizationSnapshot> progress,
            CancellationToken cancellationToken)
        {
            AuthorizationCalls++;
            if (AuthorizationHandler is not null)
                return await AuthorizationHandler(progress, cancellationToken);
            progress.Report(AuthorizationResult);
            Authorization = AuthorizationResult;
            return AuthorizationResult;
        }

        public async Task<InstallerUiResult> InstallAsync(
            InstallRequest request,
            IProgress<InstallerEvent> progress,
            CancellationToken cancellationToken)
        {
            try
            {
                return InstallHandler is null
                    ? new InstallerUiResult(true, ReportPath: "C:\\report.html")
                    : await InstallHandler(request, progress, cancellationToken);
            }
            catch (OperationCanceledException)
                when (cancellationToken.IsCancellationRequested)
            {
                InstallCancellationObserved = true;
                throw;
            }
        }

        public Task<RestoreResult> RestoreLatestAsync(
            CancellationToken cancellationToken) =>
            Task.FromResult(new RestoreResult(true, "C:\\backup"));

        public void CancelAuthorization() => AuthorizationCancelCalled = true;
    }
}
