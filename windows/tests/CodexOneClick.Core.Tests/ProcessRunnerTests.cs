using Xunit;

namespace CodexOneClickInstaller;

public sealed class ProcessRunnerTests
{
    [Fact]
    public async Task Api_key_is_sent_only_over_standard_input()
    {
        const string secret = "sk-fixture-super-secret-value";
        var backend = new FakeProcessExecutionBackend();
        var runner = new ProcessRunner(backend);
        var request = new ProcessRunRequest(
            "fixture.exe",
            ["auth", "--provider", "deepseek"],
            new Dictionary<string, string> { ["MODE"] = "offline" },
            new SensitiveString(secret));

        await runner.RunAsync(request, _ => { });

        Assert.DoesNotContain(
            backend.Request!.Arguments,
            argument => argument.Contains(secret, StringComparison.Ordinal));
        Assert.DoesNotContain(
            backend.Request.Environment,
            pair => pair.Value.Contains(secret, StringComparison.Ordinal));
        Assert.Equal(secret + Environment.NewLine, backend.Request.StandardInput);
    }

    [Fact]
    public async Task Api_key_in_arguments_or_environment_is_rejected()
    {
        const string secret = "fixture-api-key-value";
        var runner = new ProcessRunner(new FakeProcessExecutionBackend());

        await Assert.ThrowsAsync<ArgumentException>(() => runner.RunAsync(
            new ProcessRunRequest(
                "fixture.exe",
                ["--api-key", secret],
                null,
                new SensitiveString(secret)),
            _ => { }));
        await Assert.ThrowsAsync<ArgumentException>(() => runner.RunAsync(
            new ProcessRunRequest(
                "fixture.exe",
                [],
                new Dictionary<string, string> { ["OPENAI_API_KEY"] = secret },
                new SensitiveString(secret)),
            _ => { }));
    }

    [Fact]
    public async Task Stdout_and_stderr_are_redacted_line_by_line()
    {
        var backend = new FakeProcessExecutionBackend
        {
            StandardOutput =
            [
                "api_key=sk-fixture-123456",
                "Bearer eyJhbGciOiJIUzI1NiJ9.fixture.signature"
            ],
            StandardError =
            [
                "device code: ABCD-EFGH",
                "contact person@example.com"
            ]
        };
        var lines = new List<ProcessOutputLine>();
        var runner = new ProcessRunner(backend);

        await runner.RunAsync(
            new ProcessRunRequest("fixture.exe", [], null, null),
            lines.Add);

        Assert.Equal(4, lines.Count);
        Assert.All(lines, line => Assert.Contains("[REDACTED]", line.Text));
        var combined = string.Join('\n', lines.Select(line => line.Text));
        Assert.DoesNotContain("sk-fixture", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("eyJhbG", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("ABCD-EFGH", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("person@example.com", combined, StringComparison.Ordinal);
        Assert.Contains(lines, line => line.Stream == ProcessOutputStream.StandardError);
    }

    [Fact]
    public async Task Known_sensitive_values_are_redacted_exactly_and_never_enter_args_or_environment()
    {
        const string apiKey = "kimi_live/Not-A-Recognizable-Key";
        const string deviceCode = "9zQ1.custom-device-code";
        const string email = "owner+fixture@private.invalid";
        var backend = new FakeProcessExecutionBackend
        {
            StandardOutput =
            [
                $"key={apiKey}",
                $"device={deviceCode}",
                $"account={email}"
            ]
        };
        var lines = new List<ProcessOutputLine>();
        var runner = new ProcessRunner(backend);
        var knownSensitiveValues = new[]
        {
            new SensitiveString(deviceCode),
            new SensitiveString(email)
        };

        await runner.RunAsync(
            new ProcessRunRequest(
                "fixture.exe",
                ["auth"],
                new Dictionary<string, string> { ["MODE"] = "offline" },
                new SensitiveString(apiKey),
                knownSensitiveValues),
            lines.Add);

        var combined = string.Join('\n', lines.Select(line => line.Text));
        Assert.DoesNotContain(apiKey, combined, StringComparison.Ordinal);
        Assert.DoesNotContain(deviceCode, combined, StringComparison.Ordinal);
        Assert.DoesNotContain(email, combined, StringComparison.Ordinal);
        Assert.Equal(3, lines.Count(line => line.Text.Contains(
            "[REDACTED]",
            StringComparison.Ordinal)));
        Assert.DoesNotContain(
            backend.Request!.Arguments,
            argument => argument.Contains(apiKey, StringComparison.Ordinal));
        Assert.DoesNotContain(
            backend.Request.Environment,
            pair => pair.Value.Contains(apiKey, StringComparison.Ordinal));

        await Assert.ThrowsAsync<ArgumentException>(() => runner.RunAsync(
            new ProcessRunRequest(
                "fixture.exe",
                ["--device", deviceCode],
                null,
                null,
                knownSensitiveValues),
            _ => { }));
        await Assert.ThrowsAsync<ArgumentException>(() => runner.RunAsync(
            new ProcessRunRequest(
                "fixture.exe",
                [],
                new Dictionary<string, string> { ["CONTACT"] = email },
                null,
                knownSensitiveValues),
            _ => { }));
    }

    [Fact]
    public async Task Cancellation_waits_for_the_backend_to_finish_terminating_the_tree()
    {
        var backend = new FakeProcessExecutionBackend
        {
            WaitForTerminationAfterCancellation = true
        };
        var runner = new ProcessRunner(backend);
        using var cancellation = new CancellationTokenSource();

        var running = runner.RunAsync(
            new ProcessRunRequest("fixture.exe", [], null, null),
            _ => { },
            cancellation.Token);
        await backend.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        await backend.CancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.False(running.IsCompleted);
        Assert.True(backend.RootExited);
        Assert.False(backend.DescendantsExited);
        backend.AllowDescendantsToExit.TrySetResult();

        var result = await running;
        Assert.True(backend.DescendantsExited);
        Assert.True(result.WasCancelled);
        Assert.Equal(137, result.ExitCode);
    }

#if WINDOWS
    [Fact]
    public async Task Windows_backend_cancellation_reaps_a_real_spawned_descendant()
    {
        if (!OperatingSystem.IsWindows())
            return;

        var powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        const string script =
            "$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') "
            + "-ArgumentList @('-NoProfile','-NonInteractive','-Command',"
            + "'Start-Sleep -Seconds 300') -PassThru; "
            + "Write-Output $child.Id; Wait-Process -Id $child.Id";
        var childPid = new TaskCompletionSource<int>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using var cancellation = new CancellationTokenSource();
        var runner = new ProcessRunner();
        var running = runner.RunAsync(
            new ProcessRunRequest(
                powershell,
                ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                null,
                null),
            line =>
            {
                if (int.TryParse(line.Text, out var pid))
                    childPid.TrySetResult(pid);
            },
            cancellation.Token);

        try
        {
            var pid = await childPid.Task.WaitAsync(TimeSpan.FromSeconds(15));
            cancellation.Cancel();
            var result = await running.WaitAsync(TimeSpan.FromSeconds(15));

            Assert.True(result.WasCancelled);
            try
            {
                using var child = System.Diagnostics.Process.GetProcessById(pid);
                Assert.True(child.WaitForExit(milliseconds: 2_000));
            }
            catch (ArgumentException)
            {
                // GetProcessById throws once the descendant is fully reaped.
            }
        }
        finally
        {
            if (!cancellation.IsCancellationRequested)
                cancellation.Cancel();
            try
            {
                await running.WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch
            {
                // Preserve the primary assertion; process disposal closes the job.
            }
        }
    }

    [Fact]
    public void Windows_backend_compiles_job_wait_handle_list_and_orphan_cleanup_contract()
    {
        var backendType = typeof(WindowsJobProcessBackend);
        var privateStatic = System.Reflection.BindingFlags.NonPublic
            | System.Reflection.BindingFlags.Static;

        var createProcess = NativeMethod("CreateProcessW");
        AssertNativeMethod("AssignProcessToJobObject");
        AssertNativeMethod("TerminateJobObject");
        AssertNativeMethod("QueryInformationJobObject");
        AssertNativeMethod("InitializeProcThreadAttributeList");
        AssertNativeMethod("UpdateProcThreadAttribute");
        AssertNativeMethod("DeleteProcThreadAttributeList");
        AssertNativeMethod("TerminateProcess");
        Assert.NotNull(backendType.GetField(
            "PROC_THREAD_ATTRIBUTE_HANDLE_LIST",
            privateStatic));
        Assert.NotNull(backendType.GetField(
            "EXTENDED_STARTUPINFO_PRESENT",
            privateStatic));
        Assert.NotNull(backendType.GetField(
            "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE",
            privateStatic));
        Assert.Equal(
            "STARTUPINFOEX",
            createProcess.GetParameters()[8]
                .ParameterType.GetElementType()!.Name);

        void AssertNativeMethod(string name) => _ = NativeMethod(name);

        System.Reflection.MethodInfo NativeMethod(string name)
        {
            var method = backendType.GetMethod(name, privateStatic);
            Assert.NotNull(method);
            Assert.NotNull(method!.GetCustomAttributes(
                typeof(System.Runtime.InteropServices.DllImportAttribute),
                inherit: false).SingleOrDefault());
            return method;
        }
    }
#endif

    private sealed class FakeProcessExecutionBackend : IProcessExecutionBackend
    {
        public ProcessExecutionRequest? Request { get; private set; }

        public IReadOnlyList<string> StandardOutput { get; init; } = [];

        public IReadOnlyList<string> StandardError { get; init; } = [];

        public bool WaitForTerminationAfterCancellation { get; init; }

        public bool RootExited { get; private set; }

        public bool DescendantsExited { get; private set; }

        public TaskCompletionSource Started { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource CancellationObserved { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource AllowDescendantsToExit { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<ProcessExecutionResult> ExecuteAsync(
            ProcessExecutionRequest request,
            Func<string, Task> onStandardOutput,
            Func<string, Task> onStandardError,
            CancellationToken cancellationToken)
        {
            Request = request;
            Started.TrySetResult();
            foreach (var line in StandardOutput)
                await onStandardOutput(line);
            foreach (var line in StandardError)
                await onStandardError(line);

            if (WaitForTerminationAfterCancellation)
            {
                try
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    RootExited = true;
                    CancellationObserved.TrySetResult();
                }

                await AllowDescendantsToExit.Task;
                DescendantsExited = true;
                return new ProcessExecutionResult(137, WasCancelled: true);
            }

            RootExited = true;
            DescendantsExited = true;
            return new ProcessExecutionResult(0, WasCancelled: false);
        }
    }
}
