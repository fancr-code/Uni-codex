using System.Collections;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
#if WINDOWS
using Microsoft.Win32.SafeHandles;
#endif

namespace CodexOneClickInstaller;

public enum ProcessOutputStream
{
    StandardOutput,
    StandardError
}

public sealed record ProcessOutputLine(ProcessOutputStream Stream, string Text);

public sealed record ProcessExecutionResult(int ExitCode, bool WasCancelled);

public sealed class ProcessRunRequest
{
    public ProcessRunRequest(
        string fileName,
        IEnumerable<string> arguments,
        IReadOnlyDictionary<string, string>? environment,
        SensitiveString? apiKey,
        IEnumerable<SensitiveString>? knownSensitiveValues = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(fileName);
        ArgumentNullException.ThrowIfNull(arguments);
        FileName = fileName;
        Arguments = Array.AsReadOnly(arguments
            .Select(argument => argument
                ?? throw new ArgumentException("Process arguments cannot contain null.", nameof(arguments)))
            .ToArray());
        Environment = new ReadOnlyDictionary<string, string>(
            environment is null
                ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, string>(environment, StringComparer.OrdinalIgnoreCase));
        ApiKey = apiKey;
        KnownSensitiveValues = Array.AsReadOnly(
            (knownSensitiveValues ?? Enumerable.Empty<SensitiveString>())
                .Select(value => value
                    ?? throw new ArgumentException(
                        "Known sensitive values cannot contain null.",
                        nameof(knownSensitiveValues)))
                .ToArray());
    }

    public string FileName { get; }

    public IReadOnlyList<string> Arguments { get; }

    public IReadOnlyDictionary<string, string> Environment { get; }

    public SensitiveString? ApiKey { get; }

    public IReadOnlyList<SensitiveString> KnownSensitiveValues { get; }
}

public sealed record ProcessExecutionRequest(
    string FileName,
    IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string> Environment,
    string? StandardInput);

public interface IProcessExecutionBackend
{
    Task<ProcessExecutionResult> ExecuteAsync(
        ProcessExecutionRequest request,
        Func<string, Task> onStandardOutput,
        Func<string, Task> onStandardError,
        CancellationToken cancellationToken);
}

public sealed class ProcessRunner
{
    private readonly IProcessExecutionBackend _backend;

    public ProcessRunner(IProcessExecutionBackend? backend = null) =>
        _backend = backend ?? new WindowsJobProcessBackend();

    public Task<ProcessExecutionResult> RunAsync(
        ProcessRunRequest request,
        Action<ProcessOutputLine> onOutput,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onOutput);

        var apiKey = request.ApiKey?.RevealForConfigurationWrite();
        var sensitiveValues = request.KnownSensitiveValues
            .Select(value => value.RevealForConfigurationWrite())
            .Append(apiKey)
            .Where(value => value is not null)
            .Select(value => value!)
            .Distinct(StringComparer.Ordinal)
            .OrderByDescending(value => value.Length)
            .ToArray();
        if (sensitiveValues.Any(value => value.Length == 0))
            throw new ArgumentException("Sensitive values cannot be empty.", nameof(request));
        foreach (var sensitiveValue in sensitiveValues)
        {
            if (request.Arguments.Any(argument =>
                    argument.Contains(sensitiveValue, StringComparison.Ordinal)))
            {
                throw new ArgumentException(
                    "Sensitive values must not be passed in process arguments.",
                    nameof(request));
            }

            if (request.Environment.Any(pair =>
                    pair.Value.Contains(sensitiveValue, StringComparison.Ordinal)))
            {
                throw new ArgumentException(
                    "Sensitive values must not be passed in the process environment.",
                    nameof(request));
            }
        }

        foreach (var pair in request.Environment)
        {
            if (IsSensitiveEnvironmentName(pair.Key))
            {
                throw new ArgumentException(
                    $"Sensitive process environment variable '{pair.Key}' is not allowed.",
                    nameof(request));
            }
        }

        var executionRequest = new ProcessExecutionRequest(
            request.FileName,
            request.Arguments,
            BuildSanitizedEnvironment(request.Environment, sensitiveValues),
            apiKey is null ? null : apiKey + Environment.NewLine);
        var outputGate = new object();
        return _backend.ExecuteAsync(
            executionRequest,
            line => PublishAsync(ProcessOutputStream.StandardOutput, line),
            line => PublishAsync(ProcessOutputStream.StandardError, line),
            cancellationToken);

        Task PublishAsync(ProcessOutputStream stream, string line)
        {
            var safeLine = SecretRedactor.Redact(line, sensitiveValues);
            lock (outputGate)
                onOutput(new ProcessOutputLine(stream, safeLine));
            return Task.CompletedTask;
        }
    }

    private static IReadOnlyDictionary<string, string> BuildSanitizedEnvironment(
        IReadOnlyDictionary<string, string> additions,
        IReadOnlyList<string> sensitiveValues)
    {
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry pair in System.Environment.GetEnvironmentVariables())
        {
            var name = pair.Key?.ToString();
            var value = pair.Value?.ToString();
            if (string.IsNullOrEmpty(name)
                || value is null
                || IsSensitiveEnvironmentName(name)
                || sensitiveValues.Any(sensitiveValue =>
                    value.Contains(sensitiveValue, StringComparison.Ordinal)))
            {
                continue;
            }

            environment[name] = value;
        }

        foreach (var pair in additions)
            environment[pair.Key] = pair.Value;
        return new ReadOnlyDictionary<string, string>(environment);
    }

    private static bool IsSensitiveEnvironmentName(string name) =>
        Regex.IsMatch(
            name,
            @"(?:^|_)(?:API_?KEY|TOKEN|SECRET|PASSWORD|BEARER|AUTHORIZATION|DEVICE_?CODE)(?:$|_)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

public static class SecretRedactor
{
    private static readonly Regex[] SensitivePatterns =
    [
        new(
            @"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(
            @"\bBearer\s+[A-Z0-9._~+/\-]+=*",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(
            @"\b(?:api[_\- ]?key|apikey)\s*[:=]\s*[^\s,;]+",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(
            @"\bsk-[A-Z0-9._\-]{8,}\b",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(
            @"\bdevice\s*code\s*[:=]\s*[A-Z0-9]{4}(?:-[A-Z0-9]{4}){1,3}\b",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
    ];

    public static string Redact(
        string? value,
        IEnumerable<string>? knownSensitiveValues = null)
    {
        if (string.IsNullOrEmpty(value))
            return value ?? string.Empty;
        var redacted = value;
        if (knownSensitiveValues is not null)
        {
            foreach (var sensitiveValue in knownSensitiveValues
                         .Where(sensitiveValue => !string.IsNullOrEmpty(sensitiveValue))
                         .Distinct(StringComparer.Ordinal)
                         .OrderByDescending(sensitiveValue => sensitiveValue.Length))
            {
                redacted = redacted.Replace(
                    sensitiveValue,
                    "[REDACTED]",
                    StringComparison.Ordinal);
            }
        }

        foreach (var pattern in SensitivePatterns)
            redacted = pattern.Replace(redacted, "[REDACTED]");
        return redacted;
    }
}

public sealed class WindowsJobProcessBackend : IProcessExecutionBackend
{
    public Task<ProcessExecutionResult> ExecuteAsync(
        ProcessExecutionRequest request,
        Func<string, Task> onStandardOutput,
        Func<string, Task> onStandardError,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onStandardOutput);
        ArgumentNullException.ThrowIfNull(onStandardError);
#if WINDOWS
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("The Windows process backend requires Windows.");
        return ExecuteWindowsAsync(
            request,
            onStandardOutput,
            onStandardError,
            cancellationToken);
#else
        throw new PlatformNotSupportedException(
            "Use an injected process backend when running outside Windows.");
#endif
    }

#if WINDOWS
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint HANDLE_FLAG_INHERIT = 0x00000001;
    private const uint INFINITE = 0xFFFFFFFF;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const uint CANCELLED_EXIT_CODE = 137;
    private const int JobObjectBasicAccountingInformation = 1;
    private const int JobObjectExtendedLimitInformation = 9;
    private static readonly TimeSpan JobDrainTimeout = TimeSpan.FromSeconds(5);
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST =
        new(0x00020002);

    private static async Task<ProcessExecutionResult> ExecuteWindowsAsync(
        ProcessExecutionRequest request,
        Func<string, Task> onStandardOutput,
        Func<string, Task> onStandardError,
        CancellationToken cancellationToken)
    {
        IntPtr stdoutRead = IntPtr.Zero;
        IntPtr stdoutWrite = IntPtr.Zero;
        IntPtr stderrRead = IntPtr.Zero;
        IntPtr stderrWrite = IntPtr.Zero;
        IntPtr stdinRead = IntPtr.Zero;
        IntPtr stdinWrite = IntPtr.Zero;
        IntPtr processHandle = IntPtr.Zero;
        IntPtr threadHandle = IntPtr.Zero;
        IntPtr environmentBlock = IntPtr.Zero;
        IntPtr jobHandle = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr inheritedHandleList = IntPtr.Zero;
        var jobGate = new object();
        var cancellationObserved = 0;
        var processExited = false;
        var processAssignedToJob = false;
        var jobDrained = false;

        void CloseJob()
        {
            lock (jobGate)
            {
                if (jobHandle == IntPtr.Zero)
                    return;
                CloseHandle(jobHandle);
                jobHandle = IntPtr.Zero;
            }
        }

        void TerminateJob()
        {
            lock (jobGate)
            {
                if (jobHandle != IntPtr.Zero)
                    _ = TerminateJobObject(jobHandle, CANCELLED_EXIT_CODE);
            }
        }

        try
        {
            CreateParentReadPipe(out stdoutRead, out stdoutWrite);
            CreateParentReadPipe(out stderrRead, out stderrWrite);
            CreateParentWritePipe(out stdinRead, out stdinWrite);

            jobHandle = CreateJobObjectW(IntPtr.Zero, null);
            if (jobHandle == IntPtr.Zero)
                ThrowLastWin32("CreateJobObject");
            var jobInformation = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            {
                BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION
                {
                    LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                }
            };
            if (!SetInformationJobObject(
                    jobHandle,
                    JobObjectExtendedLimitInformation,
                    ref jobInformation,
                    (uint)Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()))
            {
                ThrowLastWin32("SetInformationJobObject");
            }

            var startupInfo = new STARTUPINFOEX
            {
                StartupInfo = new STARTUPINFO
                {
                    cb = Marshal.SizeOf<STARTUPINFOEX>(),
                    dwFlags = STARTF_USESTDHANDLES,
                    hStdInput = stdinRead,
                    hStdOutput = stdoutWrite,
                    hStdError = stderrWrite
                }
            };
            CreateInheritedHandleList(
                [stdinRead, stdoutWrite, stderrWrite],
                out attributeList,
                out inheritedHandleList);
            startupInfo.lpAttributeList = attributeList;
            var commandLine = new StringBuilder(BuildCommandLine(
                request.FileName,
                request.Arguments));
            environmentBlock = Marshal.StringToHGlobalUni(
                BuildEnvironmentBlock(request.Environment));
            if (!CreateProcessW(
                    request.FileName,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    bInheritHandles: true,
                    CREATE_SUSPENDED
                        | CREATE_UNICODE_ENVIRONMENT
                        | CREATE_NO_WINDOW
                        | EXTENDED_STARTUPINFO_PRESENT,
                    environmentBlock,
                    null,
                    ref startupInfo,
                    out var processInformation))
            {
                ThrowLastWin32("CreateProcess");
            }

            processHandle = processInformation.hProcess;
            threadHandle = processInformation.hThread;
            CloseNativeHandle(ref stdoutWrite);
            CloseNativeHandle(ref stderrWrite);
            CloseNativeHandle(ref stdinRead);

            if (!AssignProcessToJobObject(jobHandle, processHandle))
            {
                var assignError = Marshal.GetLastWin32Error();
                TerminateProcessAndWait(processHandle);
                processExited = true;
                throw new Win32Exception(
                    assignError,
                    "AssignProcessToJobObject failed.");
            }
            processAssignedToJob = true;
            if (ResumeThread(threadHandle) == uint.MaxValue)
                ThrowLastWin32("ResumeThread");

            using var cancellationRegistration = cancellationToken.Register(() =>
            {
                Interlocked.Exchange(ref cancellationObserved, 1);
                TerminateJob();
            });
            using var stdoutSafe = TakeOwnership(ref stdoutRead);
            using var stderrSafe = TakeOwnership(ref stderrRead);
            using var stdinSafe = TakeOwnership(ref stdinWrite);
            var stdoutTask = PumpLinesAsync(stdoutSafe, onStandardOutput);
            var stderrTask = PumpLinesAsync(stderrSafe, onStandardError);
            try
            {
                await WriteStandardInputAsync(stdinSafe, request.StandardInput).ConfigureAwait(false);
            }
            catch (IOException) when (Volatile.Read(ref cancellationObserved) != 0)
            {
                // Terminating the job closes the child's standard-input pipe.
            }

            var waitResult = await Task.Run(
                () => WaitForSingleObject(processHandle, INFINITE)).ConfigureAwait(false);
            if (waitResult == WAIT_FAILED)
                ThrowLastWin32("WaitForSingleObject");
            processExited = true;
            if (!GetExitCodeProcess(processHandle, out var exitCode))
                ThrowLastWin32("GetExitCodeProcess");

            // The root can exit before helpers. Terminate any remaining helpers and
            // do not return until the job reports that every descendant is gone.
            TerminateJob();
            var drained = await WaitForJobToBecomeEmptyAsync(
                jobHandle,
                jobGate,
                JobDrainTimeout).ConfigureAwait(false);
            if (!drained)
            {
                CloseJob();
                throw new TimeoutException(
                    "Windows Job Object did not drain after termination.");
            }
            jobDrained = true;
            CloseJob();
            try
            {
                await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);
            }
            catch (IOException) when (Volatile.Read(ref cancellationObserved) != 0)
            {
                // Job teardown can break an inherited pipe instead of returning EOF.
            }
            return new ProcessExecutionResult(
                unchecked((int)exitCode),
                Volatile.Read(ref cancellationObserved) != 0);
        }
        finally
        {
            try
            {
                if (processHandle != IntPtr.Zero && !processExited)
                {
                    if (processAssignedToJob)
                        TerminateJob();
                    TerminateProcessAndWait(processHandle);
                    processExited = true;
                }

                if (processAssignedToJob
                    && jobHandle != IntPtr.Zero
                    && !jobDrained)
                {
                    TerminateJob();
                    var drained = await WaitForJobToBecomeEmptyAsync(
                        jobHandle,
                        jobGate,
                        JobDrainTimeout).ConfigureAwait(false);
                    if (!drained)
                    {
                        CloseJob();
                        throw new TimeoutException(
                            "Windows Job Object did not drain after termination.");
                    }
                    jobDrained = true;
                }
            }
            finally
            {
                CloseJob();
                ReleaseInheritedHandleList(
                    ref attributeList,
                    ref inheritedHandleList);
                CloseNativeHandle(ref stdoutRead);
                CloseNativeHandle(ref stdoutWrite);
                CloseNativeHandle(ref stderrRead);
                CloseNativeHandle(ref stderrWrite);
                CloseNativeHandle(ref stdinRead);
                CloseNativeHandle(ref stdinWrite);
                CloseNativeHandle(ref threadHandle);
                CloseNativeHandle(ref processHandle);
                if (environmentBlock != IntPtr.Zero)
                    Marshal.FreeHGlobal(environmentBlock);
            }
        }
    }

    private static async Task<bool> WaitForJobToBecomeEmptyAsync(
        IntPtr jobHandle,
        object jobGate,
        TimeSpan timeout)
    {
        var deadline = Environment.TickCount64 + checked((long)timeout.TotalMilliseconds);
        while (true)
        {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
            lock (jobGate)
            {
                if (!QueryInformationJobObject(
                        jobHandle,
                        JobObjectBasicAccountingInformation,
                        out accounting,
                        (uint)Marshal.SizeOf<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>(),
                        IntPtr.Zero))
                {
                    ThrowLastWin32("QueryInformationJobObject");
                }
            }

            if (accounting.ActiveProcesses == 0)
                return true;
            if (Environment.TickCount64 >= deadline)
                return false;
            await Task.Delay(TimeSpan.FromMilliseconds(10)).ConfigureAwait(false);
        }
    }

    private static void CreateInheritedHandleList(
        IReadOnlyList<IntPtr> inheritedHandles,
        out IntPtr attributeList,
        out IntPtr handleList)
    {
        attributeList = IntPtr.Zero;
        handleList = IntPtr.Zero;
        var attributeListSize = IntPtr.Zero;
        _ = InitializeProcThreadAttributeList(
            IntPtr.Zero,
            1,
            0,
            ref attributeListSize);
        if (attributeListSize == IntPtr.Zero)
            ThrowLastWin32("InitializeProcThreadAttributeList");

        var localAttributeList = Marshal.AllocHGlobal(attributeListSize);
        var localHandleList = IntPtr.Zero;
        var initialized = false;
        try
        {
            if (!InitializeProcThreadAttributeList(
                    localAttributeList,
                    1,
                    0,
                    ref attributeListSize))
            {
                ThrowLastWin32("InitializeProcThreadAttributeList");
            }
            initialized = true;

            var handles = inheritedHandles.ToArray();
            localHandleList = Marshal.AllocHGlobal(handles.Length * IntPtr.Size);
            Marshal.Copy(handles, 0, localHandleList, handles.Length);
            if (!UpdateProcThreadAttribute(
                    localAttributeList,
                    0,
                    PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                    localHandleList,
                    new IntPtr(handles.Length * IntPtr.Size),
                    IntPtr.Zero,
                    IntPtr.Zero))
            {
                ThrowLastWin32("UpdateProcThreadAttribute");
            }

            attributeList = localAttributeList;
            handleList = localHandleList;
            localAttributeList = IntPtr.Zero;
            localHandleList = IntPtr.Zero;
        }
        finally
        {
            if (initialized && localAttributeList != IntPtr.Zero)
                DeleteProcThreadAttributeList(localAttributeList);
            if (localAttributeList != IntPtr.Zero)
                Marshal.FreeHGlobal(localAttributeList);
            if (localHandleList != IntPtr.Zero)
                Marshal.FreeHGlobal(localHandleList);
        }
    }

    private static void ReleaseInheritedHandleList(
        ref IntPtr attributeList,
        ref IntPtr handleList)
    {
        if (attributeList != IntPtr.Zero)
        {
            DeleteProcThreadAttributeList(attributeList);
            Marshal.FreeHGlobal(attributeList);
            attributeList = IntPtr.Zero;
        }

        if (handleList != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(handleList);
            handleList = IntPtr.Zero;
        }
    }

    private static void TerminateProcessAndWait(IntPtr processHandle)
    {
        if (!TerminateProcess(processHandle, CANCELLED_EXIT_CODE))
        {
            var error = Marshal.GetLastWin32Error();
            var alreadyExited = WaitForSingleObject(processHandle, 0);
            if (alreadyExited != 0)
            {
                throw new Win32Exception(
                    error,
                    "TerminateProcess failed.");
            }
        }

        if (WaitForSingleObject(processHandle, INFINITE) == WAIT_FAILED)
            ThrowLastWin32("WaitForSingleObject");
    }

    private static Task PumpLinesAsync(
        SafeFileHandle pipe,
        Func<string, Task> publish) =>
        Task.Run(async () =>
        {
            using var stream = new FileStream(
                pipe,
                FileAccess.Read,
                bufferSize: 4096,
                isAsync: false);
            using var reader = new StreamReader(
                stream,
                Encoding.UTF8,
                detectEncodingFromByteOrderMarks: true,
                bufferSize: 4096,
                leaveOpen: true);
            while (reader.ReadLine() is { } line)
                await publish(line).ConfigureAwait(false);
        });

    private static Task WriteStandardInputAsync(
        SafeFileHandle pipe,
        string? input) =>
        Task.Run(() =>
        {
            using var stream = new FileStream(
                pipe,
                FileAccess.Write,
                bufferSize: 4096,
                isAsync: false);
            if (input is null)
                return;
            var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)
                .GetBytes(input);
            stream.Write(bytes);
            stream.Flush();
        });

    private static SafeFileHandle TakeOwnership(ref IntPtr handle)
    {
        var owned = new SafeFileHandle(handle, ownsHandle: true);
        handle = IntPtr.Zero;
        return owned;
    }

    private static void CreateParentReadPipe(
        out IntPtr parentRead,
        out IntPtr childWrite)
    {
        var attributes = InheritableSecurityAttributes();
        if (!CreatePipe(out parentRead, out childWrite, ref attributes, 0))
            ThrowLastWin32("CreatePipe");
        if (!SetHandleInformation(parentRead, HANDLE_FLAG_INHERIT, 0))
        {
            CloseNativeHandle(ref parentRead);
            CloseNativeHandle(ref childWrite);
            ThrowLastWin32("SetHandleInformation");
        }
    }

    private static void CreateParentWritePipe(
        out IntPtr childRead,
        out IntPtr parentWrite)
    {
        var attributes = InheritableSecurityAttributes();
        if (!CreatePipe(out childRead, out parentWrite, ref attributes, 0))
            ThrowLastWin32("CreatePipe");
        if (!SetHandleInformation(parentWrite, HANDLE_FLAG_INHERIT, 0))
        {
            CloseNativeHandle(ref childRead);
            CloseNativeHandle(ref parentWrite);
            ThrowLastWin32("SetHandleInformation");
        }
    }

    private static SECURITY_ATTRIBUTES InheritableSecurityAttributes() =>
        new()
        {
            nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
            bInheritHandle = true
        };

    private static string BuildCommandLine(
        string fileName,
        IReadOnlyList<string> arguments) =>
        string.Join(
            " ",
            new[] { QuoteWindowsArgument(fileName) }
                .Concat(arguments.Select(QuoteWindowsArgument)));

    private static string QuoteWindowsArgument(string argument)
    {
        if (argument.IndexOf('\0') >= 0)
            throw new ArgumentException("Process arguments cannot contain NUL.", nameof(argument));
        var result = new StringBuilder(argument.Length + 2);
        result.Append('"');
        var backslashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static string BuildEnvironmentBlock(
        IReadOnlyDictionary<string, string> environment)
    {
        var entries = environment
            .Where(pair =>
                !pair.Key.Contains('=') && !pair.Key.Contains('\0')
                && !pair.Value.Contains('\0'))
            .OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
            .Select(pair => $"{pair.Key}={pair.Value}");
        return string.Join('\0', entries) + "\0\0";
    }

    private static void CloseNativeHandle(ref IntPtr handle)
    {
        if (handle == IntPtr.Zero)
            return;
        _ = CloseHandle(handle);
        handle = IntPtr.Zero;
    }

    private static void ThrowLastWin32(string operation) =>
        throw new Win32Exception(
            Marshal.GetLastWin32Error(),
            $"{operation} failed.");

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;

        [MarshalAs(UnmanagedType.Bool)]
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreatePipe(
        out IntPtr hReadPipe,
        out IntPtr hWritePipe,
        ref SECURITY_ATTRIBUTES lpPipeAttributes,
        uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetHandleInformation(
        IntPtr hObject,
        uint dwMask,
        uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr lpAttributeList,
        int dwAttributeCount,
        uint dwFlags,
        ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList,
        uint dwFlags,
        IntPtr attribute,
        IntPtr lpValue,
        IntPtr cbSize,
        IntPtr lpPreviousValue,
        IntPtr lpReturnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(
        IntPtr lpAttributeList);

    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(
        IntPtr lpJobAttributes,
        string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob,
        int jobObjectInformationClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInformation,
        uint cbJobObjectInformationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryInformationJobObject(
        IntPtr hJob,
        int jobObjectInformationClass,
        out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION lpJobObjectInformation,
        uint cbJobObjectInformationLength,
        IntPtr lpReturnLength);

    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(
        string? lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(
        IntPtr hJob,
        IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateJobObject(
        IntPtr hJob,
        uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(
        IntPtr hProcess,
        uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr hThread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(
        IntPtr hHandle,
        uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(
        IntPtr hProcess,
        out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);
#endif
}
