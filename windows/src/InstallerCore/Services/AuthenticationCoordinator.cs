using System.Collections;
using System.Collections.ObjectModel;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
#if WINDOWS
using Windows.ApplicationModel;
using Windows.Management.Deployment;
using Windows.System;
#endif

namespace CodexOneClickInstaller;

public enum AuthorizationMethod
{
    Browser,
    DeviceCode
}

public enum AuthorizationStateKind
{
    Unavailable,
    Ready,
    Launching,
    WaitingForBrowser,
    Verifying,
    Authorized,
    Cancelled,
    RecoverableFailure
}

public enum AuthorizationUnavailableReason
{
    CodexNotInstalled,
    UntrustedCodex,
    UnsupportedCodex
}

public enum AuthorizationFailureCode
{
    LoginFailed,
    StatusUnconfirmed,
    ProcessUnavailable
}

public sealed class AuthorizationState
{
    private readonly EphemeralAuthorizationData? _ephemeral;

    internal AuthorizationState(
        AuthorizationStateKind kind,
        AuthorizationUnavailableReason? unavailableReason = null,
        AuthorizationFailureCode? failureCode = null,
        EphemeralAuthorizationData? ephemeral = null)
    {
        Kind = kind;
        UnavailableReason = unavailableReason;
        FailureCode = failureCode;
        _ephemeral = ephemeral;
    }

    public AuthorizationStateKind Kind { get; }

    public AuthorizationStateKind Status => Kind;

    public AuthorizationUnavailableReason? UnavailableReason { get; }

    public AuthorizationFailureCode? FailureCode { get; }

    public Uri? AuthorizationUrl => _ephemeral?.AuthorizationUrl;

    public string? DeviceCode => _ephemeral?.DeviceCode;

    public override string ToString() =>
        UnavailableReason is not null
            ? $"{Kind}: {UnavailableReason}"
            : FailureCode is not null
                ? $"{Kind}: {FailureCode}"
                : Kind.ToString();
}

internal sealed class EphemeralAuthorizationData
{
    private readonly object _gate = new();
    private char[]? _url;
    private char[]? _code;

    public Uri? AuthorizationUrl
    {
        get
        {
            lock (_gate)
                return _url is null ? null : new Uri(new string(_url));
        }
    }

    public string? DeviceCode
    {
        get
        {
            lock (_gate)
                return _code is null ? null : new string(_code);
        }
    }

    public bool Update(Uri? authorizationUrl, string? deviceCode)
    {
        lock (_gate)
        {
            if (authorizationUrl is not null)
            {
                if (_url is not null)
                    Array.Fill(_url, '\0');
                _url = authorizationUrl.AbsoluteUri.ToCharArray();
            }
            if (deviceCode is not null)
            {
                if (_code is not null)
                    Array.Fill(_code, '\0');
                _code = deviceCode.ToCharArray();
            }
            return _url is not null && _code is not null;
        }
    }

    public void Clear()
    {
        lock (_gate)
            ClearCore();
    }

    private void ClearCore()
    {
        if (_url is not null)
            Array.Fill(_url, '\0');
        if (_code is not null)
            Array.Fill(_code, '\0');
        _url = null;
        _code = null;
    }
}

public sealed record OfficialCodexPackage(
    string PackageFamilyName,
    CodexPackageArchitecture Architecture,
    string Publisher,
    CodexPackageSignatureKind SignatureKind,
    bool IsPackageStatusHealthy,
    string InstalledLocation);

public enum OfficialCodexCliInspectionResult
{
    Trusted,
    Missing,
    OutsidePackage,
    ReparsePoint,
    NotX64,
    InvalidSignature,
    WrongSigner
}

public sealed record CodexCliLocationResult(
    string? CliPath,
    AuthorizationUnavailableReason? Failure)
{
    public bool IsSuccess => CliPath is not null && Failure is null;

    public static CodexCliLocationResult Success(string cliPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(cliPath);
        return new CodexCliLocationResult(Path.GetFullPath(cliPath), null);
    }

    public static CodexCliLocationResult Unavailable(
        AuthorizationUnavailableReason reason) =>
        new(null, reason);
}

public interface IOfficialCodexPackageSource
{
    IReadOnlyList<OfficialCodexPackage> FindPackages(string packageFamilyName);
}

public interface IOfficialCodexCliVerifier
{
    OfficialCodexCliInspectionResult Inspect(
        string packageRoot,
        string cliPath,
        string expectedPublisher);
}

public interface IOfficialCodexCliLocator
{
    CodexCliLocationResult Locate();
}

public sealed class OfficialCodexCliCandidateValidator
{
    private readonly IOfficialCodexCliVerifier _verifier;

    public OfficialCodexCliCandidateValidator(
        IOfficialCodexCliVerifier? verifier = null) =>
        _verifier = verifier ?? new PhysicalOfficialCodexCliVerifier();

    public CodexCliLocationResult Validate(
        OfficialCodexPackage package,
        string expectedPublisher)
    {
        ArgumentNullException.ThrowIfNull(package);
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedPublisher);
        if (!HasExpectedIdentity(package, expectedPublisher))
        {
            return CodexCliLocationResult.Unavailable(
                AuthorizationUnavailableReason.UntrustedCodex);
        }

        try
        {
            var packageRoot = Path.GetFullPath(package.InstalledLocation);
            var cliPath = Path.GetFullPath(Path.Combine(
                packageRoot,
                OfficialCodexCliLocator.CliRelativePath));
            return _verifier.Inspect(packageRoot, cliPath, expectedPublisher)
                   == OfficialCodexCliInspectionResult.Trusted
                ? CodexCliLocationResult.Success(cliPath)
                : CodexCliLocationResult.Unavailable(
                    AuthorizationUnavailableReason.UntrustedCodex);
        }
        catch
        {
            return CodexCliLocationResult.Unavailable(
                AuthorizationUnavailableReason.UntrustedCodex);
        }
    }

    private static bool HasExpectedIdentity(
        OfficialCodexPackage package,
        string expectedPublisher) =>
        string.Equals(
            package.PackageFamilyName,
            CodexInstaller.PackageFamilyName,
            StringComparison.Ordinal)
        && package.Architecture == CodexPackageArchitecture.X64
        && string.Equals(
            package.Publisher,
            expectedPublisher,
            StringComparison.Ordinal)
        && package.SignatureKind is CodexPackageSignatureKind.Store
            or CodexPackageSignatureKind.Developer
        && package.IsPackageStatusHealthy
        && !string.IsNullOrWhiteSpace(package.InstalledLocation);
}

public sealed class OfficialCodexCliLocator : IOfficialCodexCliLocator
{
    public const string CliRelativePath = "codex.exe";

    private readonly string _expectedPublisher;
    private readonly IOfficialCodexPackageSource _packages;
    private readonly OfficialCodexCliCandidateValidator _candidateValidator;

    public OfficialCodexCliLocator(
        string expectedPublisher,
        IOfficialCodexPackageSource? packages = null,
        IOfficialCodexCliVerifier? verifier = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedPublisher);
        _expectedPublisher = expectedPublisher;
        _packages = packages ?? new WindowsOfficialCodexPackageSource();
        _candidateValidator = new OfficialCodexCliCandidateValidator(verifier);
    }

    public CodexCliLocationResult Locate()
    {
        IReadOnlyList<OfficialCodexPackage> packages;
        try
        {
            packages = _packages.FindPackages(CodexInstaller.PackageFamilyName);
        }
        catch (PlatformNotSupportedException)
        {
            return CodexCliLocationResult.Unavailable(
                AuthorizationUnavailableReason.UnsupportedCodex);
        }
        catch
        {
            return CodexCliLocationResult.Unavailable(
                AuthorizationUnavailableReason.UntrustedCodex);
        }

        if (packages.Count == 0)
        {
            return CodexCliLocationResult.Unavailable(
                AuthorizationUnavailableReason.CodexNotInstalled);
        }

        foreach (var package in packages)
        {
            var candidate = _candidateValidator.Validate(
                package,
                _expectedPublisher);
            if (candidate.IsSuccess)
                return candidate;
        }

        return CodexCliLocationResult.Unavailable(
            AuthorizationUnavailableReason.UntrustedCodex);
    }
}

public sealed class WindowsOfficialCodexPackageSource
    : IOfficialCodexPackageSource
{
    public IReadOnlyList<OfficialCodexPackage> FindPackages(
        string packageFamilyName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageFamilyName);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "PackageManager lookup requires Windows.");
        }

#if WINDOWS
        return new PackageManager()
            .FindPackagesForUser(string.Empty, packageFamilyName)
            .Select(package => new OfficialCodexPackage(
                package.Id.FamilyName,
                package.Id.Architecture switch
                {
                    ProcessorArchitecture.X64 => CodexPackageArchitecture.X64,
                    ProcessorArchitecture.X86 => CodexPackageArchitecture.X86,
                    ProcessorArchitecture.Arm => CodexPackageArchitecture.Arm,
                    ProcessorArchitecture.Neutral => CodexPackageArchitecture.Neutral,
                    _ => CodexPackageArchitecture.Unknown
                },
                package.Id.Publisher,
                package.SignatureKind switch
                {
                    PackageSignatureKind.Store => CodexPackageSignatureKind.Store,
                    PackageSignatureKind.Developer => CodexPackageSignatureKind.Developer,
                    PackageSignatureKind.System => CodexPackageSignatureKind.System,
                    _ => CodexPackageSignatureKind.Unknown
                },
                package.Status.VerifyIsOK(),
                package.InstalledLocation.Path))
            .ToArray();
#else
        throw new PlatformNotSupportedException(
            "Use the Windows-targeted core asset for PackageManager lookup.");
#endif
    }
}

public interface IAuthenticodeSignerReader
{
    string? ReadSignerSubject(string path);
}

public sealed class SignedFileAuthenticodeSignerReader
    : IAuthenticodeSignerReader
{
    public string? ReadSignerSubject(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Authenticode signer inspection requires Windows.");
        }

#pragma warning disable SYSLIB0057
        using var certificate = new X509Certificate2(
            X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
        return certificate.Subject;
    }
}

public sealed class PhysicalOfficialCodexCliVerifier
    : IOfficialCodexCliVerifier
{
    private readonly ManagedPathGuard _paths;
    private readonly IAuthenticodeVerifier _trust;
    private readonly IAuthenticodeSignerReader _signer;

    public PhysicalOfficialCodexCliVerifier(
        ManagedPathGuard? paths = null,
        IAuthenticodeVerifier? trust = null,
        IAuthenticodeSignerReader? signer = null)
    {
        _paths = paths ?? new ManagedPathGuard();
        _trust = trust ?? new WinVerifyTrustAuthenticodeVerifier();
        _signer = signer ?? new SignedFileAuthenticodeSignerReader();
    }

    public OfficialCodexCliInspectionResult Inspect(
        string packageRoot,
        string cliPath,
        string expectedPublisher)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(cliPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedPublisher);
        string candidate;
        try
        {
            candidate = _paths.ValidateManagedPath(packageRoot, cliPath);
        }
        catch (UnauthorizedAccessException error)
        {
            return error.Message.Contains("reparse", StringComparison.OrdinalIgnoreCase)
                ? OfficialCodexCliInspectionResult.ReparsePoint
                : OfficialCodexCliInspectionResult.OutsidePackage;
        }

        if (!File.Exists(candidate))
            return OfficialCodexCliInspectionResult.Missing;
        try
        {
            PeImageInspector.RequireX64(candidate);
        }
        catch (InvalidDataException)
        {
            return OfficialCodexCliInspectionResult.NotX64;
        }

        if (!_trust.IsTrusted(candidate))
            return OfficialCodexCliInspectionResult.InvalidSignature;
        try
        {
            var signer = _signer.ReadSignerSubject(candidate);
            if (!DistinguishedNamesEqual(signer, expectedPublisher))
                return OfficialCodexCliInspectionResult.WrongSigner;
        }
        catch
        {
            return OfficialCodexCliInspectionResult.WrongSigner;
        }

        return OfficialCodexCliInspectionResult.Trusted;
    }

    private static bool DistinguishedNamesEqual(
        string? actual,
        string expected)
    {
        if (string.IsNullOrWhiteSpace(actual))
            return false;
        try
        {
            return new X500DistinguishedName(actual).RawData.AsSpan()
                .SequenceEqual(new X500DistinguishedName(expected).RawData);
        }
        catch (CryptographicException)
        {
            return false;
        }
    }
}

public sealed record AuthenticationProcessResult(
    int ExitCode,
    bool WasCancelled);

public interface IAuthenticationProcessRunner
{
    Task<AuthenticationProcessResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        Action<string> onOutput,
        CancellationToken cancellationToken);
}

public sealed class JobAuthenticationProcessRunner
    : IAuthenticationProcessRunner
{
    private readonly IProcessExecutionBackend _backend;

    public JobAuthenticationProcessRunner(
        IProcessExecutionBackend? backend = null) =>
        _backend = backend ?? new WindowsJobProcessBackend();

    public async Task<AuthenticationProcessResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        Action<string> onOutput,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(fileName);
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentNullException.ThrowIfNull(onOutput);
        var request = new ProcessExecutionRequest(
            fileName,
            arguments.ToArray(),
            SafeEnvironment(),
            StandardInput: null);
        var gate = new object();
        var result = await _backend.ExecuteAsync(
                request,
                PublishAsync,
                PublishAsync,
                cancellationToken)
            .ConfigureAwait(false);
        return new AuthenticationProcessResult(
            result.ExitCode,
            result.WasCancelled);

        Task PublishAsync(string line)
        {
            lock (gate)
                onOutput(line);
            return Task.CompletedTask;
        }
    }

    private static IReadOnlyDictionary<string, string> SafeEnvironment()
    {
        var environment =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry pair in Environment.GetEnvironmentVariables())
        {
            var name = pair.Key?.ToString();
            var value = pair.Value?.ToString();
            if (!string.IsNullOrEmpty(name)
                && value is not null
                && !SensitiveEnvironmentName.IsMatch(name))
            {
                environment[name] = value;
            }
        }
        return new ReadOnlyDictionary<string, string>(environment);
    }

    private static readonly Regex SensitiveEnvironmentName = new(
        @"(?:^|_)(?:API_?KEY|TOKEN|SECRET|PASSWORD|BEARER|AUTHORIZATION|DEVICE_?CODE)(?:$|_)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

public interface IAuthenticationLogger
{
    void Log(string message);
}

public sealed class NullAuthenticationLogger : IAuthenticationLogger
{
    public void Log(string message)
    {
    }
}

internal static class AuthenticationOutputCleaner
{
    private static readonly Regex OperatingSystemCommand = new(
        @"(?:\x1B\]|\x9D).*?(?:\x07|\x1B\\)",
        RegexOptions.CultureInvariant | RegexOptions.Singleline);
    private static readonly Regex UnterminatedOperatingSystemCommand = new(
        @"(?:\x1B\]|\x9D)[^\x07]*$",
        RegexOptions.CultureInvariant | RegexOptions.Singleline);
    private static readonly Regex ControlSequence = new(
        @"(?:\x1B\[|\x9B)[0-?]*[ -/]*[@-~]",
        RegexOptions.CultureInvariant);
    private static readonly Regex RemainingEscapeSequence = new(
        @"\x1B[@-_]",
        RegexOptions.CultureInvariant);

    public static string Clean(string? value)
    {
        if (string.IsNullOrEmpty(value))
            return string.Empty;
        var withoutAnsi = OperatingSystemCommand.Replace(value, string.Empty);
        withoutAnsi = UnterminatedOperatingSystemCommand.Replace(
            withoutAnsi,
            string.Empty);
        withoutAnsi = ControlSequence.Replace(withoutAnsi, string.Empty);
        withoutAnsi = RemainingEscapeSequence.Replace(
            withoutAnsi,
            string.Empty);
        var clean = new StringBuilder(withoutAnsi.Length);
        foreach (var character in withoutAnsi)
        {
            if (!char.IsControl(character))
                clean.Append(character);
            else if (character is '\t' or '\r' or '\n')
                clean.Append(' ');
        }
        return clean.ToString().Trim();
    }
}

public interface IAuthenticationCoordinator
{
    AuthorizationState State { get; }

    Task<AuthorizationState> RefreshStatusAsync(
        CancellationToken cancellationToken);

    Task<AuthorizationState> AuthorizeAsync(
        AuthorizationMethod method,
        IProgress<AuthorizationState> progress,
        CancellationToken cancellationToken);

    void Cancel();
}

public sealed class AuthenticationCoordinator : IAuthenticationCoordinator
{
    private static readonly Regex UrlPattern = new(
        @"https://[^\s<>""']+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex DeviceCodePattern = new(
        @"\b[A-Z0-9]{4}(?:-[A-Z0-9]{4}){1,3}\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private readonly IOfficialCodexCliLocator _locator;
    private readonly IAuthenticationProcessRunner _runner;
    private readonly IAuthenticationLogger _logger;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly object _stateGate = new();
    private CancellationTokenSource? _activeProcess;
    private AuthorizationState _state;
    private long _cancelGeneration;
    private long _outputGeneration;

    public AuthenticationCoordinator(
        IOfficialCodexCliLocator locator,
        IAuthenticationProcessRunner? runner = null,
        IAuthenticationLogger? logger = null)
    {
        _locator = locator ?? throw new ArgumentNullException(nameof(locator));
        _runner = runner ?? new JobAuthenticationProcessRunner();
        _logger = logger ?? new NullAuthenticationLogger();
        var location = SafeLocate();
        _state = location.IsSuccess
            ? new AuthorizationState(AuthorizationStateKind.Ready)
            : new AuthorizationState(
                AuthorizationStateKind.Unavailable,
                location.Failure);
    }

    public AuthenticationCoordinator(
        string expectedPublisher,
        IAuthenticationLogger? logger = null)
        : this(
            new OfficialCodexCliLocator(expectedPublisher),
            new JobAuthenticationProcessRunner(),
            logger)
    {
    }

    public AuthorizationState State
    {
        get
        {
            lock (_stateGate)
                return _state;
        }
    }

    public async Task<AuthorizationState> RefreshStatusAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return Transition(
                new AuthorizationState(AuthorizationStateKind.Cancelled),
                progress: null);
        }

        try
        {
            var location = ResolveCli();
            if (!location.IsSuccess)
                return State;
            var generation = Volatile.Read(ref _cancelGeneration);
            Transition(
                new AuthorizationState(AuthorizationStateKind.Verifying),
                progress: null);
            var status = await RunStatusAsync(
                    location.CliPath!,
                    cancellationToken,
                    generation,
                    cancellable: true)
                .ConfigureAwait(false);
            if (status.Authorized)
            {
                return Transition(
                    new AuthorizationState(AuthorizationStateKind.Authorized),
                    progress: null);
            }
            if (status.Process.WasCancelled
                || generation != Volatile.Read(ref _cancelGeneration))
            {
                var final = await RunStatusAsync(
                        location.CliPath!,
                        CancellationToken.None,
                        generation,
                        cancellable: false)
                    .ConfigureAwait(false);
                return Transition(
                    new AuthorizationState(
                        final.Authorized
                            ? AuthorizationStateKind.Authorized
                            : AuthorizationStateKind.Cancelled),
                    progress: null);
            }
            if (status.Process.ExitCode == -1)
            {
                return Transition(
                    new AuthorizationState(
                        AuthorizationStateKind.RecoverableFailure,
                        failureCode: AuthorizationFailureCode.ProcessUnavailable),
                    progress: null);
            }
            return Transition(
                new AuthorizationState(AuthorizationStateKind.Ready),
                progress: null);
        }
        catch
        {
            return Transition(
                new AuthorizationState(
                    AuthorizationStateKind.RecoverableFailure,
                    failureCode: AuthorizationFailureCode.ProcessUnavailable),
                progress: null);
        }
        finally
        {
            _operationGate.Release();
        }
    }

    public async Task<AuthorizationState> AuthorizeAsync(
        AuthorizationMethod method,
        IProgress<AuthorizationState> progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(progress);
        try
        {
            await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return Transition(
                new AuthorizationState(AuthorizationStateKind.Cancelled),
                progress);
        }

        EphemeralAuthorizationData? ephemeral = null;
        try
        {
            var location = ResolveCli();
            if (!location.IsSuccess)
                return State;
            var cancelGeneration = Volatile.Read(ref _cancelGeneration);

            Transition(
                new AuthorizationState(AuthorizationStateKind.Verifying),
                progress);
            var existing = await RunStatusAsync(
                    location.CliPath!,
                    cancellationToken,
                    cancelGeneration,
                    cancellable: true)
                .ConfigureAwait(false);
            if (existing.Authorized)
            {
                return Transition(
                    new AuthorizationState(AuthorizationStateKind.Authorized),
                    progress);
            }
            if (existing.Process.WasCancelled
                || cancelGeneration != Volatile.Read(ref _cancelGeneration))
            {
                return await FinalStateAfterCancellationAsync(
                        location.CliPath!,
                        cancelGeneration,
                        progress)
                    .ConfigureAwait(false);
            }
            if (existing.Process.ExitCode == -1)
            {
                return Transition(
                    new AuthorizationState(
                        AuthorizationStateKind.RecoverableFailure,
                        failureCode: AuthorizationFailureCode.ProcessUnavailable),
                    progress);
            }

            Transition(
                new AuthorizationState(AuthorizationStateKind.Ready),
                progress);
            Transition(
                new AuthorizationState(AuthorizationStateKind.Launching),
                progress);
            if (method == AuthorizationMethod.Browser)
            {
                Transition(
                    new AuthorizationState(
                        AuthorizationStateKind.WaitingForBrowser),
                    progress);
            }

            ephemeral = new EphemeralAuthorizationData();
            var outputGeneration = Interlocked.Increment(ref _outputGeneration);
            var login = await RunCancelableAsync(
                    location.CliPath!,
                    method == AuthorizationMethod.Browser
                        ? ["login"]
                        : ["login", "--device-auth"],
                    line =>
                    {
                        if (method == AuthorizationMethod.DeviceCode
                            && outputGeneration
                            == Volatile.Read(ref _outputGeneration)
                            && TryReadDeviceAuthorization(
                                line,
                                out var url,
                                out var code)
                            && ephemeral.Update(url, code))
                        {
                            Transition(
                                new AuthorizationState(
                                    AuthorizationStateKind.WaitingForBrowser,
                                    ephemeral: ephemeral),
                                progress);
                        }
                    },
                    cancellationToken,
                    cancelGeneration)
                .ConfigureAwait(false);
            Interlocked.Increment(ref _outputGeneration);
            ephemeral.Clear();

            Transition(
                new AuthorizationState(AuthorizationStateKind.Verifying),
                progress);
            var finalStatus = await RunStatusAsync(
                    location.CliPath!,
                    CancellationToken.None,
                    cancelGeneration,
                    cancellable: false)
                .ConfigureAwait(false);
            if (finalStatus.Authorized)
            {
                return Transition(
                    new AuthorizationState(AuthorizationStateKind.Authorized),
                    progress);
            }

            var cancelled = login.WasCancelled
                            || cancelGeneration
                            != Volatile.Read(ref _cancelGeneration)
                            || cancellationToken.IsCancellationRequested;
            if (cancelled)
            {
                return Transition(
                    new AuthorizationState(AuthorizationStateKind.Cancelled),
                    progress);
            }
            if (finalStatus.Process.ExitCode == -1)
            {
                return Transition(
                    new AuthorizationState(
                        AuthorizationStateKind.RecoverableFailure,
                        failureCode: AuthorizationFailureCode.ProcessUnavailable),
                    progress);
            }
            if (login.ExitCode == 0)
            {
                return Transition(
                    new AuthorizationState(AuthorizationStateKind.Ready),
                    progress);
            }
            return Transition(
                new AuthorizationState(
                    AuthorizationStateKind.RecoverableFailure,
                    failureCode: AuthorizationFailureCode.LoginFailed),
                progress);
        }
        catch
        {
            return Transition(
                new AuthorizationState(
                    AuthorizationStateKind.RecoverableFailure,
                    failureCode: AuthorizationFailureCode.ProcessUnavailable),
                progress);
        }
        finally
        {
            Interlocked.Increment(ref _outputGeneration);
            ephemeral?.Clear();
            _operationGate.Release();
        }
    }

    public void Cancel()
    {
        Interlocked.Increment(ref _cancelGeneration);
        lock (_stateGate)
        {
            _activeProcess?.Cancel();
            _state = new AuthorizationState(AuthorizationStateKind.Cancelled);
        }
        _logger.Log("OpenAI authorization state: Cancelled");
    }

    private async Task<AuthorizationState> FinalStateAfterCancellationAsync(
        string cliPath,
        long generation,
        IProgress<AuthorizationState> progress)
    {
        Transition(
            new AuthorizationState(AuthorizationStateKind.Verifying),
            progress);
        var status = await RunStatusAsync(
                cliPath,
                CancellationToken.None,
                generation,
                cancellable: false)
            .ConfigureAwait(false);
        return Transition(
            new AuthorizationState(
                status.Authorized
                    ? AuthorizationStateKind.Authorized
                    : AuthorizationStateKind.Cancelled),
            progress);
    }

    private async Task<StatusResult> RunStatusAsync(
        string cliPath,
        CancellationToken cancellationToken,
        long cancelGeneration,
        bool cancellable)
    {
        var authorized = 0;
        var contradictoryAuthentication = 0;
        AuthenticationProcessResult process;
        if (cancellable)
        {
            process = await RunCancelableAsync(
                    cliPath,
                    ["login", "status"],
                    line =>
                    {
                        if (ConfirmsAuthorized(line))
                            Interlocked.Exchange(ref authorized, 1);
                        else if (IsNonChatGptAuthenticationStatus(line))
                            Interlocked.Exchange(
                                ref contradictoryAuthentication,
                                1);
                    },
                    cancellationToken,
                    cancelGeneration)
                .ConfigureAwait(false);
        }
        else
        {
            process = await SafeRunAsync(
                    cliPath,
                    ["login", "status"],
                    line =>
                    {
                        if (ConfirmsAuthorized(line))
                            Interlocked.Exchange(ref authorized, 1);
                        else if (IsNonChatGptAuthenticationStatus(line))
                            Interlocked.Exchange(
                                ref contradictoryAuthentication,
                                1);
                    },
                    CancellationToken.None)
                .ConfigureAwait(false);
        }
        return new StatusResult(
            process,
            process.ExitCode == 0
            && Volatile.Read(ref authorized) != 0
            && Volatile.Read(ref contradictoryAuthentication) == 0);
    }

    private async Task<AuthenticationProcessResult> RunCancelableAsync(
        string cliPath,
        IReadOnlyList<string> arguments,
        Action<string> onOutput,
        CancellationToken cancellationToken,
        long cancelGeneration)
    {
        using var linked =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        lock (_stateGate)
        {
            _activeProcess = linked;
            if (cancelGeneration != Volatile.Read(ref _cancelGeneration))
                linked.Cancel();
        }
        try
        {
            return await SafeRunAsync(
                    cliPath,
                    arguments,
                    onOutput,
                    linked.Token)
                .ConfigureAwait(false);
        }
        finally
        {
            lock (_stateGate)
            {
                if (ReferenceEquals(_activeProcess, linked))
                    _activeProcess = null;
            }
        }
    }

    private async Task<AuthenticationProcessResult> SafeRunAsync(
        string cliPath,
        IReadOnlyList<string> arguments,
        Action<string> onOutput,
        CancellationToken cancellationToken)
    {
        try
        {
            return await _runner.RunAsync(
                    cliPath,
                    arguments,
                    line => onOutput(AuthenticationOutputCleaner.Clean(line)),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new AuthenticationProcessResult(-1, true);
        }
        catch
        {
            _logger.Log("OpenAI authorization process failed");
            return new AuthenticationProcessResult(-1, false);
        }
    }

    private CodexCliLocationResult ResolveCli()
    {
        var location = SafeLocate();
        if (!location.IsSuccess)
        {
            Transition(
                new AuthorizationState(
                    AuthorizationStateKind.Unavailable,
                    location.Failure),
                progress: null);
        }
        return location;
    }

    private CodexCliLocationResult SafeLocate()
    {
        try
        {
            return _locator.Locate();
        }
        catch
        {
            return CodexCliLocationResult.Unavailable(
                AuthorizationUnavailableReason.UntrustedCodex);
        }
    }

    private AuthorizationState Transition(
        AuthorizationState next,
        IProgress<AuthorizationState>? progress)
    {
        lock (_stateGate)
            _state = next;
        _logger.Log($"OpenAI authorization state: {next.Kind}");
        try
        {
            progress?.Report(next);
        }
        catch
        {
            // UI observers cannot make authentication fail.
        }
        return next;
    }

    private static bool ConfirmsAuthorized(string line)
    {
        return string.Equals(
            line,
            "Logged in using ChatGPT",
            StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsNonChatGptAuthenticationStatus(string line) =>
        line.StartsWith(
            "Logged in using ",
            StringComparison.OrdinalIgnoreCase)
        || line.StartsWith(
            "Logged in as ",
            StringComparison.OrdinalIgnoreCase)
        || line.StartsWith(
            "Authentication status:",
            StringComparison.OrdinalIgnoreCase);

    private static bool TryReadDeviceAuthorization(
        string line,
        out Uri? authorizationUrl,
        out string? deviceCode)
    {
        authorizationUrl = null;
        deviceCode = null;
        var urlMatch = UrlPattern.Match(line);
        var codeMatch = DeviceCodePattern.Match(line);
        if (urlMatch.Success
            && Uri.TryCreate(
                urlMatch.Value.TrimEnd('.', ',', ';', ')', ']'),
                UriKind.Absolute,
                out var candidate)
            && IsOfficialAuthorizationUrl(candidate))
        {
            authorizationUrl = candidate;
        }
        if (codeMatch.Success)
            deviceCode = codeMatch.Value.ToUpperInvariant();
        return authorizationUrl is not null || deviceCode is not null;
    }

    private static bool IsOfficialAuthorizationUrl(Uri url)
    {
        if (!string.Equals(url.Scheme, Uri.UriSchemeHttps, StringComparison.Ordinal))
            return false;
        var host = url.IdnHost;
        return string.Equals(host, "openai.com", StringComparison.OrdinalIgnoreCase)
               || host.EndsWith(".openai.com", StringComparison.OrdinalIgnoreCase)
               || string.Equals(host, "chatgpt.com", StringComparison.OrdinalIgnoreCase)
               || host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase);
    }

    private sealed record StatusResult(
        AuthenticationProcessResult Process,
        bool Authorized);
}
