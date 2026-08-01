using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class AuthenticationCoordinatorTests : IDisposable
{
    private const string Publisher =
        "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B";

    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "codex-authentication-tests",
        Guid.NewGuid().ToString("N"));

    [Fact]
    public void Missing_official_package_is_CodexNotInstalled()
    {
        var locator = new OfficialCodexCliLocator(
            Publisher,
            new FakePackageSource(),
            new FakeCliVerifier());

        var result = locator.Locate();

        Assert.False(result.IsSuccess);
        Assert.Equal(
            AuthorizationUnavailableReason.CodexNotInstalled,
            result.Failure);
    }

    [Fact]
    public void Locator_uses_only_fixed_package_family_location_and_relative_cli()
    {
        var root = Directory.CreateDirectory(Path.Combine(_root, "package")).FullName;
        var verifier = new FakeCliVerifier();
        var source = new FakePackageSource(
            Package(root),
            Package(root) with { PackageFamilyName = "OpenAI.Decoy_fixture" });
        var locator = new OfficialCodexCliLocator(Publisher, source, verifier);

        var result = locator.Locate();

        Assert.True(result.IsSuccess);
        Assert.Equal(
            Path.GetFullPath(Path.Combine(root, OfficialCodexCliLocator.CliRelativePath)),
            result.CliPath);
        Assert.Equal([CodexInstaller.PackageFamilyName], source.Queries);
        Assert.Equal(
            Path.GetFullPath(Path.Combine(root, OfficialCodexCliLocator.CliRelativePath)),
            Assert.Single(verifier.Paths));
    }

    [Theory]
    [InlineData("family")]
    [InlineData("architecture")]
    [InlineData("publisher")]
    [InlineData("signature-kind")]
    [InlineData("package-health")]
    public void Locator_rejects_wrong_package_identity(string mutation)
    {
        var package = Package(Path.Combine(_root, "package"));
        package = mutation switch
        {
            "family" => package with { PackageFamilyName = "OpenAI.Decoy_fixture" },
            "architecture" => package with { Architecture = CodexPackageArchitecture.X86 },
            "publisher" => package with { Publisher = "CN=Decoy" },
            "signature-kind" => package with { SignatureKind = CodexPackageSignatureKind.System },
            "package-health" => package with { IsPackageStatusHealthy = false },
            _ => throw new ArgumentOutOfRangeException(nameof(mutation))
        };
        var verifier = new FakeCliVerifier();
        var locator = new OfficialCodexCliLocator(
            Publisher,
            new FakePackageSource(package),
            verifier);

        var result = locator.Locate();

        Assert.False(result.IsSuccess);
        Assert.Equal(AuthorizationUnavailableReason.UntrustedCodex, result.Failure);
        Assert.Empty(verifier.Paths);
    }

    [Theory]
    [InlineData(OfficialCodexCliInspectionResult.OutsidePackage)]
    [InlineData(OfficialCodexCliInspectionResult.ReparsePoint)]
    [InlineData(OfficialCodexCliInspectionResult.NotX64)]
    [InlineData(OfficialCodexCliInspectionResult.InvalidSignature)]
    [InlineData(OfficialCodexCliInspectionResult.WrongSigner)]
    public void Locator_rejects_unsafe_or_untrusted_cli(
        OfficialCodexCliInspectionResult inspection)
    {
        var verifier = new FakeCliVerifier { Result = inspection };
        var locator = new OfficialCodexCliLocator(
            Publisher,
            new FakePackageSource(Package(Path.Combine(_root, "package"))),
            verifier);

        var result = locator.Locate();

        Assert.False(result.IsSuccess);
        Assert.Equal(AuthorizationUnavailableReason.UntrustedCodex, result.Failure);
    }

    [Fact]
    public async Task Already_authorized_checks_status_and_does_not_repeat_login()
    {
        var runner = new FakeAuthenticationProcessRunner(
            Step(
                0,
                "\x1b]0;untrusted-title\x07\x00" +
                "\x1b[32mLogged in using ChatGPT\x1b[0m"));
        var coordinator = Coordinator(runner);

        var state = await coordinator.AuthorizeAsync(
            AuthorizationMethod.Browser,
            NullProgress.Instance,
            CancellationToken.None);

        Assert.Equal(AuthorizationStateKind.Authorized, state.Kind);
        Assert.Equal([Args("login", "status")], runner.Invocations);
    }

    [Fact]
    public async Task Browser_flow_is_status_then_login_then_status()
    {
        var runner = new FakeAuthenticationProcessRunner(
            Step(1, "Not logged in"),
            Step(0, "Opened browser"),
            Step(0, "Logged in using ChatGPT"));
        var states = new RecordingProgress();
        var coordinator = Coordinator(runner);

        var result = await coordinator.AuthorizeAsync(
            AuthorizationMethod.Browser,
            states,
            CancellationToken.None);

        Assert.Equal(AuthorizationStateKind.Authorized, result.Kind);
        Assert.Equal(
            [
                Args("login", "status"),
                Args("login"),
                Args("login", "status")
            ],
            runner.Invocations);
        AssertSubsequence(
            states.Kinds,
            AuthorizationStateKind.Launching,
            AuthorizationStateKind.WaitingForBrowser,
            AuthorizationStateKind.Verifying,
            AuthorizationStateKind.Authorized);
    }

    [Fact]
    public async Task Device_flow_uses_only_device_auth_then_final_status()
    {
        var runner = new FakeAuthenticationProcessRunner(
            Step(1, "Not logged in"),
            Step(
                0,
                "Visit \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m",
                "Then enter code \x1b[93mABCD-EFGH\x1b[0m"),
            Step(0, "Logged in using ChatGPT"));
        var coordinator = Coordinator(runner);

        var result = await coordinator.AuthorizeAsync(
            AuthorizationMethod.DeviceCode,
            NullProgress.Instance,
            CancellationToken.None);

        Assert.Equal(AuthorizationStateKind.Authorized, result.Kind);
        Assert.Equal(
            [
                Args("login", "status"),
                Args("login", "--device-auth"),
                Args("login", "status")
            ],
            runner.Invocations);
    }

    [Fact]
    public async Task Device_code_is_memory_only_and_is_cleared_before_completion()
    {
        var login = new BlockingStep(
            "Visit \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m " +
            "and enter code \x1b[93mABCD-EFGH\x1b[0m " +
            "for person@example.com token sk-test-secret-value");
        var runner = new FakeAuthenticationProcessRunner(
            Step(1, "Not logged in"),
            login,
            Step(0, "Logged in using ChatGPT"));
        var logger = new RecordingAuthenticationLogger();
        var progress = new RecordingProgress();
        var coordinator = Coordinator(runner, logger);

        var authorization = coordinator.AuthorizeAsync(
            AuthorizationMethod.DeviceCode,
            progress,
            CancellationToken.None);
        await login.OutputPublished.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var waiting = coordinator.State;
        Assert.Equal(AuthorizationStateKind.WaitingForBrowser, waiting.Kind);
        Assert.Equal("https://auth.openai.com/codex/device", waiting.AuthorizationUrl?.AbsoluteUri);
        Assert.Equal("ABCD-EFGH", waiting.DeviceCode);

        login.Complete();
        var result = await authorization;

        Assert.Equal(AuthorizationStateKind.Authorized, result.Kind);
        Assert.Null(waiting.AuthorizationUrl);
        Assert.Null(waiting.DeviceCode);
        var log = string.Join("\n", logger.Messages);
        Assert.DoesNotContain("ABCD-EFGH", log, StringComparison.Ordinal);
        Assert.DoesNotContain("person@example.com", log, StringComparison.Ordinal);
        Assert.DoesNotContain("sk-test-secret-value", log, StringComparison.Ordinal);
        Assert.DoesNotContain("auth.openai.com", log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Cancel_closes_active_job_never_logs_out_and_final_status_wins_race()
    {
        var login = new BlockingStep("Opened browser");
        var runner = new FakeAuthenticationProcessRunner(
            Step(1, "Not logged in"),
            login,
            Step(0, "Logged in using ChatGPT"));
        var coordinator = Coordinator(runner);

        var authorization = coordinator.AuthorizeAsync(
            AuthorizationMethod.Browser,
            NullProgress.Instance,
            CancellationToken.None);
        await login.OutputPublished.Task.WaitAsync(TimeSpan.FromSeconds(5));
        coordinator.Cancel();
        var result = await authorization;

        Assert.True(login.CancellationObserved);
        Assert.Equal(AuthorizationStateKind.Authorized, result.Kind);
        Assert.DoesNotContain(
            runner.Invocations,
            invocation => invocation.Contains("logout", StringComparer.Ordinal));
        Assert.Equal(Args("login", "status"), runner.Invocations[^1]);
    }

    [Theory]
    [InlineData("Logged in using an API key")]
    [InlineData("Logged in using Agent Identity")]
    [InlineData("Logged in using Amazon Bedrock")]
    [InlineData("Logged in using arbitrary-provider")]
    [InlineData("You are logged in")]
    [InlineData("Logged in as person@example.com")]
    [InlineData("Authentication status: authenticated")]
    public async Task Non_ChatGPT_status_is_not_authorized_and_returns_ready(
        string statusOutput)
    {
        var runner = new FakeAuthenticationProcessRunner(Step(0, statusOutput));
        var coordinator = Coordinator(runner);

        var state = await coordinator.RefreshStatusAsync(CancellationToken.None);

        Assert.Equal(AuthorizationStateKind.Ready, state.Kind);
        Assert.Equal([Args("login", "status")], runner.Invocations);
    }

    [Fact]
    public async Task Conflicting_provider_status_cannot_override_to_authorized()
    {
        var runner = new FakeAuthenticationProcessRunner(
            Step(
                0,
                "Logged in using ChatGPT",
                "Logged in using an API key"));
        var coordinator = Coordinator(runner);

        var state = await coordinator.RefreshStatusAsync(CancellationToken.None);

        Assert.Equal(AuthorizationStateKind.Ready, state.Kind);
    }

    [Fact]
    public async Task Failed_login_returns_recoverable_state_without_throwing()
    {
        var runner = new FakeAuthenticationProcessRunner(
            Step(1, "Not logged in"),
            Step(9, "Bearer secret-value"),
            Step(1, "Not logged in"));
        var coordinator = Coordinator(runner);

        var state = await coordinator.AuthorizeAsync(
            AuthorizationMethod.Browser,
            NullProgress.Instance,
            CancellationToken.None);

        Assert.Equal(AuthorizationStateKind.RecoverableFailure, state.Kind);
        Assert.Equal(AuthorizationFailureCode.LoginFailed, state.FailureCode);
        Assert.DoesNotContain("secret-value", state.ToString(), StringComparison.Ordinal);
    }

#if WINDOWS
    [Fact]
    public async Task Windows_job_runner_cancels_a_real_process()
    {
        if (!OperatingSystem.IsWindows())
            return;

        var runner = new JobAuthenticationProcessRunner();
        using var cancellation = new CancellationTokenSource();
        var powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        var process = runner.RunAsync(
            powershell,
            ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"],
            _ => { },
            cancellation.Token);
        cancellation.CancelAfter(TimeSpan.FromMilliseconds(150));

        var result = await process.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.True(result.WasCancelled);
    }

    [Fact]
    public void Windows_candidate_validator_uses_real_paths_PE_trust_and_signer()
    {
        if (!OperatingSystem.IsWindows())
            return;

        var packageRoot = Directory.CreateDirectory(
            Path.Combine(_root, "physical-package")).FullName;
        var outside = Path.Combine(_root, "outside.exe");
        File.WriteAllBytes(outside, []);
        var verifier = new PhysicalOfficialCodexCliVerifier();
        Assert.Equal(
            OfficialCodexCliInspectionResult.OutsidePackage,
            verifier.Inspect(packageRoot, outside, Publisher));

        var cli = Path.Combine(
            packageRoot,
            OfficialCodexCliLocator.CliRelativePath);
        File.WriteAllText(cli, "not a PE image");
        Assert.Equal(
            OfficialCodexCliInspectionResult.NotX64,
            verifier.Inspect(packageRoot, cli, Publisher));
        WritePeFixture(cli, machine: 0x014c);
        Assert.Equal(
            OfficialCodexCliInspectionResult.NotX64,
            verifier.Inspect(packageRoot, cli, Publisher));

        var junctionTarget = Directory.CreateDirectory(
            Path.Combine(_root, "junction-target")).FullName;
        File.WriteAllText(
            Path.Combine(
                junctionTarget,
                OfficialCodexCliLocator.CliRelativePath),
            "fixture");
        var junctionRoot = Path.Combine(_root, "package-junction");
        CreateJunction(junctionRoot, junctionTarget);
        try
        {
            Assert.Equal(
                OfficialCodexCliInspectionResult.ReparsePoint,
                verifier.Inspect(
                    junctionRoot,
                    Path.Combine(
                        junctionRoot,
                        OfficialCodexCliLocator.CliRelativePath),
                    Publisher));
        }
        finally
        {
            if (Directory.Exists(junctionRoot))
                Directory.Delete(junctionRoot);
        }

        if (RuntimeInformation.OSArchitecture != Architecture.X64)
            return;
        var runtimeVersionDirectory = new DirectoryInfo(
            RuntimeEnvironment.GetRuntimeDirectory());
        var dotnetRoot = runtimeVersionDirectory.Parent?.Parent?.Parent?.FullName;
        Assert.False(string.IsNullOrWhiteSpace(dotnetRoot));
        var embeddedSignedExecutable = Path.Combine(dotnetRoot!, "dotnet.exe");
        Assert.True(File.Exists(embeddedSignedExecutable));
        File.Copy(embeddedSignedExecutable, cli, overwrite: true);
        var signerReader = new SignedFileAuthenticodeSignerReader();
        var signer = signerReader.ReadSignerSubject(cli);
        Assert.False(string.IsNullOrWhiteSpace(signer));
        var validator = new OfficialCodexCliCandidateValidator(
            new PhysicalOfficialCodexCliVerifier());

        var trusted = validator.Validate(
            Package(packageRoot) with { Publisher = signer! },
            signer!);
        var wrongSigner = validator.Validate(
            Package(packageRoot),
            Publisher);

        Assert.True(trusted.IsSuccess);
        Assert.Equal(Path.GetFullPath(cli), trusted.CliPath);
        Assert.False(wrongSigner.IsSuccess);
        Assert.Equal(
            AuthorizationUnavailableReason.UntrustedCodex,
            wrongSigner.Failure);
    }

    [Fact]
    public async Task Windows_real_runner_scrubs_known_secret_and_drains_both_large_streams()
    {
        if (!OperatingSystem.IsWindows())
            return;

        const string environmentName = "CODEX_AUTH_REAL_RUNNER_FIXTURE";
        const string secret = "fixture/auth/private-value-9zQ1";
        var previous = Environment.GetEnvironmentVariable(environmentName);
        Environment.SetEnvironmentVariable(environmentName, secret);
        var powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        const string script =
            "$inherited = [Environment]::GetEnvironmentVariable("
            + "'CODEX_AUTH_REAL_RUNNER_FIXTURE'); "
            + "if ([string]::IsNullOrEmpty($inherited)) "
            + "{ [Console]::Out.WriteLine('ENV_CLEAN') } "
            + "else { [Console]::Out.WriteLine('ENV_LEAK=' + $inherited) }; "
            + "$stdinSecret = [Console]::In.ReadToEnd().Trim(); "
            + "[Console]::Out.WriteLine('STDOUT_SECRET=' + $stdinSecret); "
            + "[Console]::Error.WriteLine('STDERR_SECRET=' + $stdinSecret); "
            + "for ($i = 0; $i -lt 4000; $i++) { "
            + "[Console]::Out.WriteLine('OUT-' + $i); "
            + "[Console]::Error.WriteLine('ERR-' + $i) }";
        var lines = new ConcurrentQueue<ProcessOutputLine>();
        try
        {
            var result = await new ProcessRunner().RunAsync(
                    new ProcessRunRequest(
                        powershell,
                        [
                            "-NoLogo",
                            "-NoProfile",
                            "-NonInteractive",
                            "-Command",
                            script
                        ],
                        environment: null,
                        new SensitiveString(secret),
                        knownSensitiveValues: [new SensitiveString(secret)]),
                    lines.Enqueue)
                .WaitAsync(TimeSpan.FromSeconds(30));

            Assert.Equal(0, result.ExitCode);
            Assert.False(result.WasCancelled);
            Assert.Contains(
                lines,
                line => line.Text == "ENV_CLEAN");
            Assert.DoesNotContain(
                lines,
                line => line.Text.StartsWith(
                    "ENV_LEAK=",
                    StringComparison.Ordinal));
            Assert.True(
                lines.Count(line =>
                    line.Stream == ProcessOutputStream.StandardOutput
                    && line.Text.StartsWith("OUT-", StringComparison.Ordinal))
                >= 4000);
            Assert.True(
                lines.Count(line =>
                    line.Stream == ProcessOutputStream.StandardError
                    && line.Text.StartsWith("ERR-", StringComparison.Ordinal))
                >= 4000);
            var logged = string.Join('\n', lines.Select(line => line.Text));
            Assert.DoesNotContain(secret, logged, StringComparison.Ordinal);
            Assert.Contains("[REDACTED]", logged, StringComparison.Ordinal);
        }
        finally
        {
            Environment.SetEnvironmentVariable(environmentName, previous);
        }
    }
#endif

    public void Dispose()
    {
        if (Directory.Exists(_root))
            Directory.Delete(_root, recursive: true);
    }

    private static AuthenticationCoordinator Coordinator(
        IAuthenticationProcessRunner runner,
        IAuthenticationLogger? logger = null) =>
        new(
            new FakeLocator(CodexCliLocationResult.Success(
                Path.GetFullPath(Path.Combine(Path.GetTempPath(), "official-codex.exe")))),
            runner,
            logger);

    private static OfficialCodexPackage Package(string root) =>
        new(
            CodexInstaller.PackageFamilyName,
            CodexPackageArchitecture.X64,
            Publisher,
            CodexPackageSignatureKind.Store,
            IsPackageStatusHealthy: true,
            root);

    private static ProcessStep Step(int exitCode, params string[] output) =>
        new(exitCode, output);

    private static string[] Args(params string[] values) => values;

    private static void WritePeFixture(string path, ushort machine)
    {
        var bytes = new byte[70];
        bytes[0] = (byte)'M';
        bytes[1] = (byte)'Z';
        BitConverter.GetBytes(64).CopyTo(bytes, 0x3c);
        bytes[64] = (byte)'P';
        bytes[65] = (byte)'E';
        BitConverter.GetBytes(machine).CopyTo(bytes, 68);
        File.WriteAllBytes(path, bytes);
    }

    private static void CreateJunction(string junctionPath, string targetPath)
    {
        var command = Environment.GetEnvironmentVariable("ComSpec")
                      ?? Path.Combine(
                          Environment.GetFolderPath(
                              Environment.SpecialFolder.System),
                          "cmd.exe");
        var start = new ProcessStartInfo(command)
        {
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            UseShellExecute = false
        };
        start.ArgumentList.Add("/d");
        start.ArgumentList.Add("/c");
        start.ArgumentList.Add("mklink");
        start.ArgumentList.Add("/J");
        start.ArgumentList.Add(junctionPath);
        start.ArgumentList.Add(targetPath);
        using var process = Process.Start(start)
                            ?? throw new InvalidOperationException(
                                "Could not start mklink.");
        var standardOutput = process.StandardOutput.ReadToEnd();
        var standardError = process.StandardError.ReadToEnd();
        Assert.True(process.WaitForExit(milliseconds: 10_000));
        Assert.True(
            process.ExitCode == 0,
            $"mklink failed: {standardOutput} {standardError}");
    }

    private static void AssertSubsequence(
        IReadOnlyList<AuthorizationStateKind> actual,
        params AuthorizationStateKind[] expected)
    {
        var position = 0;
        foreach (var item in actual)
        {
            if (position < expected.Length && item == expected[position])
                position++;
        }
        Assert.Equal(expected.Length, position);
    }

    private sealed class FakePackageSource(
        params OfficialCodexPackage[] packages) : IOfficialCodexPackageSource
    {
        public List<string> Queries { get; } = [];

        public IReadOnlyList<OfficialCodexPackage> FindPackages(string packageFamilyName)
        {
            Queries.Add(packageFamilyName);
            return packages;
        }
    }

    private sealed class FakeCliVerifier : IOfficialCodexCliVerifier
    {
        public OfficialCodexCliInspectionResult Result { get; set; } =
            OfficialCodexCliInspectionResult.Trusted;

        public List<string> Paths { get; } = [];

        public OfficialCodexCliInspectionResult Inspect(
            string packageRoot,
            string cliPath,
            string expectedPublisher)
        {
            Paths.Add(cliPath);
            return Result;
        }
    }

    private sealed class FakeLocator(CodexCliLocationResult result)
        : IOfficialCodexCliLocator
    {
        public CodexCliLocationResult Locate() => result;
    }

    private record ProcessStep(int ExitCode, IReadOnlyList<string> Output)
    {
        public virtual async Task<AuthenticationProcessResult> RunAsync(
            Action<string> onOutput,
            CancellationToken cancellationToken)
        {
            foreach (var line in Output)
                onOutput(line);
            await Task.Yield();
            return new AuthenticationProcessResult(ExitCode, false);
        }
    }

    private sealed record BlockingStep(string Line) : ProcessStep(0, [Line])
    {
        private readonly TaskCompletionSource _completion =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource OutputPublished { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool CancellationObserved { get; private set; }

        public void Complete() => _completion.TrySetResult();

        public override async Task<AuthenticationProcessResult> RunAsync(
            Action<string> onOutput,
            CancellationToken cancellationToken)
        {
            onOutput(Line);
            OutputPublished.TrySetResult();
            try
            {
                await _completion.Task.WaitAsync(cancellationToken);
                return new AuthenticationProcessResult(0, false);
            }
            catch (OperationCanceledException)
            {
                CancellationObserved = true;
                return new AuthenticationProcessResult(-1, true);
            }
        }
    }

    private sealed class FakeAuthenticationProcessRunner(params ProcessStep[] steps)
        : IAuthenticationProcessRunner
    {
        private readonly ConcurrentQueue<ProcessStep> _steps = new(steps);

        public List<IReadOnlyList<string>> Invocations { get; } = [];

        public Task<AuthenticationProcessResult> RunAsync(
            string fileName,
            IReadOnlyList<string> arguments,
            Action<string> onOutput,
            CancellationToken cancellationToken)
        {
            lock (Invocations)
                Invocations.Add(arguments.ToArray());
            if (!_steps.TryDequeue(out var step))
                throw new InvalidOperationException("No process step was configured.");
            return step.RunAsync(onOutput, cancellationToken);
        }
    }

    private sealed class RecordingProgress : IProgress<AuthorizationState>
    {
        public List<AuthorizationState> States { get; } = [];

        public IReadOnlyList<AuthorizationStateKind> Kinds =>
            States.Select(state => state.Kind).ToArray();

        public void Report(AuthorizationState value) => States.Add(value);
    }

    private sealed class RecordingAuthenticationLogger : IAuthenticationLogger
    {
        public List<string> Messages { get; } = [];

        public void Log(string message) => Messages.Add(message);
    }

    private sealed class NullProgress : IProgress<AuthorizationState>
    {
        public static NullProgress Instance { get; } = new();

        public void Report(AuthorizationState value)
        {
        }
    }
}
