using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
#if WINDOWS
using System.Security.Principal;
#endif

namespace CodexOneClickInstaller;

public sealed record ApplicationTransactionCommitResult(bool CleanupPending);

public interface IApplicationTransactionSession
{
    bool IsCommitted { get; }

    Task<ApplicationTransactionCommitResult> CommitAsync(
        CancellationToken cancellationToken);

    Task RollBackAsync(CancellationToken cancellationToken);
}

public interface IApplicationTransactionCoordinator
{
    Task RecoverIncompleteAsync(CancellationToken cancellationToken);

    Task<IApplicationTransactionSession> BeginAsync(
        IReadOnlyList<string> targetKeys,
        CancellationToken cancellationToken);
}

public interface IProcessSecurityContext
{
    bool IsElevated { get; }

    bool IsCurrentUser { get; }
}

public static class CodexPlusPlusManagedTargets
{
    public const string ProgramDirectory = "codex-plus-plus.program-directory";
    public const string ProductRegistration = "codex-plus-plus.product-registration";
    public const string UninstallRegistration = "codex-plus-plus.uninstall-registration";
    public const string StartMenuShortcut = "codex-plus-plus.start-menu-shortcut";
    public const string DesktopShortcut = "codex-plus-plus.desktop-shortcut";

    public static IReadOnlyList<string> All { get; } = Array.AsReadOnly(
    [
        ProgramDirectory,
        ProductRegistration,
        UninstallRegistration,
        StartMenuShortcut,
        DesktopShortcut
    ]);
}

public sealed record CodexKitExecutableMetadata(
    int SchemaVersion,
    string PayloadVersion,
    string CompatibilityRevision,
    string Architecture,
    string Component,
    bool FixtureOnly);

public sealed record CodexPlusPlusSetupProvenance(
    string Schema,
    int SchemaVersion,
    string SetupFileName,
    string UpstreamTag,
    string PatchSha256,
    string PayloadVersion,
    string CompatibilityRevision,
    string Architecture,
    bool PerUser,
    string ExecutionLevel,
    string InstallDir,
    string RegistryHive,
    string ShortcutScope,
    bool RequiresElevation,
    bool RawCreateProcessCompatible,
    bool FixtureOnly,
    IReadOnlyList<CodexPlusPlusSetupExecutable> Executables);

public sealed record CodexPlusPlusSetupExecutable(
    string Name,
    string Component,
    string Sha256,
    string PayloadVersion,
    string CompatibilityRevision,
    string Architecture,
    string MetadataMagic);

public interface ICodexPlusPlusSetupInspector
{
    CodexPlusPlusSetupProvenance Inspect(VerifiedManagedFile setup);
}

public sealed record CodexPlusPlusInstallationState(
    string InstallRoot,
    bool LauncherPresent,
    bool ManagerPresent,
    string? DisplayVersion,
    bool HasUninstallEntry,
    CodexKitExecutableMetadata? LauncherMetadata,
    CodexKitExecutableMetadata? ManagerMetadata,
    bool LauncherIsPeX64 = false,
    bool ManagerIsPeX64 = false,
    string? LauncherFileVersion = null,
    string? ManagerFileVersion = null,
    string? LauncherSha256 = null,
    string? ManagerSha256 = null,
    bool ProductRegistrationIsCurrentUser = false,
    bool UninstallRegistrationIsCurrentUser = false,
    string? ProductInstallDirectory = null,
    string? UninstallDisplayVersion = null,
    string? UninstallInstallLocation = null,
    string? UninstallString = null,
    bool UninstallerPresent = false,
    bool CurrentUserShortcutsPresent = false);

public interface ICodexPlusPlusInstallationProbe
{
    Task<CodexPlusPlusInstallationState> InspectAsync(
        string installRoot,
        CodexPlusPlusSetupProvenance provenance,
        CancellationToken cancellationToken);
}

public sealed class CodexPlusPlusInstaller
{
    public const string PayloadVersion = "1.2.44+codexkit.1";
    public const string CompatibilityRevision = "cross-provider-content-v1";
    public const string UpstreamTag = "v1.2.44";
    public const string PatchSha256 =
        "4a5d84b215ecf729b61a1b675d29af8f11dc3c86698edeebbe03d0c732a53e15";
    public const string SetupProvenanceSchema =
        "CODEXKIT-SETUP-PROVENANCE-V1";
    public const string SetupFileName =
        "CodexPlusPlus-1.2.44-codexkit.1-windows-x64-setup.exe";
    private const string PayloadId = "codex-plus-plus-windows-x64";
    private const string CanonicalRelativePath =
        "apps/CodexPlusPlus-1.2.44-codexkit.1-windows-x64-setup.exe";

    private readonly string _payloadRoot;
    private readonly string _installRoot;
    private readonly ProcessRunner _processRunner;
    private readonly IApplicationTransactionCoordinator _transactions;
    private readonly ICodexPlusPlusInstallationProbe _probe;
    private readonly IManagedApplicationPathPolicy _paths;
    private readonly ICodexPlusPlusSetupInspector _setupInspector;
    private readonly IProcessSecurityContext _processSecurityContext;

    public CodexPlusPlusInstaller(
        string payloadRoot,
        string? localApplicationData = null,
        ProcessRunner? processRunner = null,
        IApplicationTransactionCoordinator? transactionCoordinator = null,
        ICodexPlusPlusInstallationProbe? probe = null,
        IManagedApplicationPathPolicy? pathPolicy = null,
        ICodexPlusPlusSetupInspector? setupInspector = null,
        IProcessSecurityContext? processSecurityContext = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadRoot);
        _payloadRoot = Path.GetFullPath(payloadRoot);
        var localRoot = string.IsNullOrWhiteSpace(localApplicationData)
            ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            : localApplicationData;
        ArgumentException.ThrowIfNullOrWhiteSpace(localRoot);
        _installRoot = Path.GetFullPath(
            Path.Combine(localRoot, "Programs", "Codex++"));
        _processRunner = processRunner ?? new ProcessRunner();
        _paths = pathPolicy ?? new PhysicalManagedApplicationPathPolicy();
        _transactions = transactionCoordinator
                        ?? PersistentApplicationTransactionCoordinator.CreateDefault(
                            localRoot,
                            _installRoot);
        _probe = probe ?? new WindowsCodexPlusPlusInstallationProbe(_paths);
        _setupInspector = setupInspector ?? new CodexPlusPlusSetupInspector();
        _processSecurityContext =
            processSecurityContext ?? new WindowsProcessSecurityContext();
    }

    public async Task<ApplicationInstallResult> ApplyAsync(
        ComponentPlan plan,
        PayloadCatalog catalog,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(catalog);
        if (!string.Equals(plan.Component, PayloadId, StringComparison.Ordinal))
        {
            throw new ArgumentException(
                $"Codex++ installer cannot apply component '{plan.Component}'.",
                nameof(plan));
        }

        await _transactions.RecoverIncompleteAsync(cancellationToken)
            .ConfigureAwait(false);
        if (plan.Action == PlanAction.Preserve)
            return new ApplicationInstallResult(plan.Action, Changed: false);
        if (plan.Action is not (
                PlanAction.Install
                or PlanAction.Upgrade
                or PlanAction.Repair))
        {
            throw new ArgumentException(
                $"Codex++ installer cannot apply action '{plan.Action}'.",
                nameof(plan));
        }

        var entry = RequiredEntry(catalog);
        ValidatePayloadEntry(entry);
        await using var setup = await _paths.VerifyPayloadAsync(
                PayloadId,
                _payloadRoot,
                entry,
                cancellationToken)
            .ConfigureAwait(false);
        if (!string.Equals(
                Path.GetFileName(setup.FullPath),
                SetupFileName,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ reviewed offline setup path is not canonical.");
        }

        var provenance = _setupInspector.Inspect(setup.File);
        ValidateSetupProvenance(provenance);
        if (_processSecurityContext.IsElevated
            || !_processSecurityContext.IsCurrentUser)
        {
            throw new InvalidDataException(
                "Codex++ silent setup requires a non-elevated current-user process.");
        }

        var transaction = await _transactions.BeginAsync(
                CodexPlusPlusManagedTargets.All,
                cancellationToken)
            .ConfigureAwait(false);
        try
        {
            var execution = await _processRunner.RunAsync(
                    new ProcessRunRequest(
                        setup.FullPath,
                        ["/S"],
                        environment: null,
                        apiKey: null),
                    _ => { },
                    cancellationToken)
                .ConfigureAwait(false);
            if (execution.WasCancelled)
                throw new OperationCanceledException(cancellationToken);
            if (execution.ExitCode != 0)
            {
                throw new InvalidDataException(
                    $"Codex++ setup failed with exit code {execution.ExitCode}.");
            }

            var installed = await _probe.InspectAsync(
                    _installRoot,
                    provenance,
                    cancellationToken)
                .ConfigureAwait(false);
            ValidateInstallation(installed, provenance);
            cancellationToken.ThrowIfCancellationRequested();
            var commit = await transaction.CommitAsync(cancellationToken)
                .ConfigureAwait(false);
            return new ApplicationInstallResult(
                plan.Action,
                Changed: true,
                commit.CleanupPending);
        }
        catch (Exception error)
        {
            if (!transaction.IsCommitted)
            {
                try
                {
                    await transaction.RollBackAsync(CancellationToken.None)
                        .ConfigureAwait(false);
                }
                catch (Exception rollbackError)
                {
                    if (error is OperationCanceledException)
                    {
                        error.Data["CodexPlusPlusRollbackError"] = rollbackError;
                    }
                    else
                    {
                        throw new AggregateException(
                            "Codex++ installation failed and rollback did not complete.",
                            error,
                            rollbackError);
                    }
                }
            }

            ExceptionDispatchInfo.Capture(error).Throw();
            throw;
        }
    }

    private void ValidateInstallation(
        CodexPlusPlusInstallationState state,
        CodexPlusPlusSetupProvenance provenance)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (!SamePath(state.InstallRoot, _installRoot))
        {
            throw new InvalidDataException(
                "Codex++ installation was not written to the fixed per-user target.");
        }

        if (!state.LauncherPresent || !state.ManagerPresent)
        {
            throw new InvalidDataException(
                "Codex++ installation omitted the launcher or manager.");
        }

        if (!state.LauncherIsPeX64 || !state.ManagerIsPeX64)
        {
            throw new InvalidDataException(
                "Codex++ launcher or manager is not an x64 PE image.");
        }
        if (!string.Equals(
                state.LauncherFileVersion,
                PayloadVersion,
                StringComparison.Ordinal)
            || !string.Equals(
                state.ManagerFileVersion,
                PayloadVersion,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ launcher or manager file version is not the reviewed version.");
        }
        var launcherHash = RequiredExecutableHash(
            provenance,
            "codex-plus-plus.exe",
            "launcher");
        var managerHash = RequiredExecutableHash(
            provenance,
            "codex-plus-plus-manager.exe",
            "manager");
        if (!Sha256Equals(state.LauncherSha256, launcherHash)
            || !Sha256Equals(state.ManagerSha256, managerHash))
        {
            throw new InvalidDataException(
                "Codex++ launcher or manager differs from the reviewed setup provenance.");
        }

        if (!string.Equals(
                state.DisplayVersion,
                PayloadVersion,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ installed or uninstall-entry version is not the reviewed downstream version.");
        }

        ValidateMetadata(state.LauncherMetadata, "launcher");
        ValidateMetadata(state.ManagerMetadata, "manager");
        if (!state.ProductRegistrationIsCurrentUser
            || !state.UninstallRegistrationIsCurrentUser
            || !state.HasUninstallEntry
            || !SamePath(state.ProductInstallDirectory, _installRoot)
            || !string.Equals(
                state.UninstallDisplayVersion,
                PayloadVersion,
                StringComparison.Ordinal)
            || !SamePath(state.UninstallInstallLocation, _installRoot)
            || !IsFixedUninstallString(state.UninstallString, _installRoot)
            || !state.UninstallerPresent
            || !state.CurrentUserShortcutsPresent)
        {
            throw new InvalidDataException(
                "Codex++ HKCU product or uninstall registration is invalid.");
        }
    }

    private static void ValidateSetupProvenance(
        CodexPlusPlusSetupProvenance provenance)
    {
        ArgumentNullException.ThrowIfNull(provenance);
        if (!string.Equals(
                provenance.Schema,
                SetupProvenanceSchema,
                StringComparison.Ordinal)
            || provenance.SchemaVersion != 1
            || !string.Equals(
                provenance.SetupFileName,
                SetupFileName,
                StringComparison.Ordinal)
            || !string.Equals(
                provenance.UpstreamTag,
                UpstreamTag,
                StringComparison.Ordinal)
            || !string.Equals(
                provenance.PatchSha256,
                PatchSha256,
                StringComparison.Ordinal)
            || !string.Equals(
                provenance.PayloadVersion,
                PayloadVersion,
                StringComparison.Ordinal)
            || !string.Equals(
                provenance.CompatibilityRevision,
                CompatibilityRevision,
                StringComparison.Ordinal)
            || !string.Equals(provenance.Architecture, "x64", StringComparison.Ordinal)
            || !provenance.PerUser
            || !string.Equals(
                provenance.ExecutionLevel,
                "user",
                StringComparison.Ordinal)
            || !string.Equals(
                provenance.InstallDir,
                @"$LOCALAPPDATA\Programs\Codex++",
                StringComparison.Ordinal)
            || !string.Equals(
                provenance.RegistryHive,
                "HKCU",
                StringComparison.Ordinal)
            || !string.Equals(
                provenance.ShortcutScope,
                "currentUser",
                StringComparison.Ordinal)
            || provenance.RequiresElevation
            || !provenance.RawCreateProcessCompatible
            || provenance.FixtureOnly
            || provenance.Executables.Count != 2)
        {
            throw new InvalidDataException(
                "Codex++ setup does not satisfy the reviewed per-user provenance contract.");
        }

        _ = RequiredExecutableHash(
            provenance,
            "codex-plus-plus.exe",
            "launcher");
        _ = RequiredExecutableHash(
            provenance,
            "codex-plus-plus-manager.exe",
            "manager");
    }

    private static void ValidateMetadata(
        CodexKitExecutableMetadata? metadata,
        string component)
    {
        if (metadata is null
            || metadata.SchemaVersion != 1
            || !string.Equals(
                metadata.PayloadVersion,
                PayloadVersion,
                StringComparison.Ordinal)
            || !string.Equals(
                metadata.CompatibilityRevision,
                CompatibilityRevision,
                StringComparison.Ordinal)
            || !string.Equals(
                metadata.Architecture,
                "x64",
                StringComparison.Ordinal)
            || !string.Equals(
                metadata.Component,
                component,
                StringComparison.Ordinal)
            || metadata.FixtureOnly)
        {
            throw new InvalidDataException(
                $"Codex++ {component} failed the reviewed executable metadata contract.");
        }
    }

    private static void ValidatePayloadEntry(PayloadEntry entry)
    {
        if (!string.Equals(entry.Version, PayloadVersion, StringComparison.Ordinal)
            || !string.Equals(
                entry.CompatibilityRevision,
                CompatibilityRevision,
                StringComparison.Ordinal)
            || !string.Equals(entry.Architecture, "x64", StringComparison.Ordinal)
            || !string.Equals(entry.Format, "exe", StringComparison.Ordinal)
            || !string.Equals(
                entry.RelativePath,
                CanonicalRelativePath,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ payload is not the fixed reviewed CodexKit setup.");
        }
    }

    private static PayloadEntry RequiredEntry(PayloadCatalog catalog)
    {
        var matches = catalog.Entries
            .Where(entry => string.Equals(entry.Id, PayloadId, StringComparison.Ordinal))
            .ToArray();
        return matches.Length == 1
            ? matches[0]
            : throw new InvalidDataException(
                $"Validated payload catalog must contain exactly one {PayloadId} entry.");
    }

    private static bool SamePath(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right))
            return false;
        return string.Equals(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)),
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)),
            OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase
                : StringComparison.Ordinal);
    }

    private static bool IsFixedUninstallString(
        string? uninstallString,
        string installRoot)
    {
        if (string.IsNullOrWhiteSpace(uninstallString))
            return false;
        var value = uninstallString.Trim();
        if (value.Length >= 2 && value[0] == '"' && value[^1] == '"')
            value = value[1..^1];
        return SamePath(value, Path.Combine(installRoot, "uninstall.exe"));
    }

    private static bool IsCanonicalSha256(string? value) =>
        value is { Length: 64 }
        && value.All(character => character is >= '0' and <= '9'
            or >= 'a' and <= 'f');

    private static bool Sha256Equals(string? actual, string expected) =>
        IsCanonicalSha256(actual)
        && IsCanonicalSha256(expected)
        && CryptographicOperations.FixedTimeEquals(
            Convert.FromHexString(actual!),
            Convert.FromHexString(expected));

    private static string RequiredExecutableHash(
        CodexPlusPlusSetupProvenance provenance,
        string fileName,
        string component)
    {
        var matches = provenance.Executables
            .Where(executable =>
                string.Equals(
                    executable.Name,
                    fileName,
                    StringComparison.Ordinal)
                && string.Equals(
                    executable.Component,
                    component,
                    StringComparison.Ordinal)
                && string.Equals(
                    executable.PayloadVersion,
                    PayloadVersion,
                    StringComparison.Ordinal)
                && string.Equals(
                    executable.CompatibilityRevision,
                    CompatibilityRevision,
                    StringComparison.Ordinal)
                && string.Equals(
                    executable.Architecture,
                    "x64",
                    StringComparison.Ordinal)
                && string.Equals(
                    executable.MetadataMagic,
                    CodexKitExecutableMetadataReader.Magic,
                    StringComparison.Ordinal))
            .ToArray();
        if (matches.Length != 1 || !IsCanonicalSha256(matches[0].Sha256))
        {
            throw new InvalidDataException(
                $"Codex++ setup provenance has no unique reviewed {component} hash.");
        }

        return matches[0].Sha256;
    }
}

public sealed class PersistentApplicationTransactionCoordinator
    : IApplicationTransactionCoordinator
{
    private readonly ExternalMutationCoordinator _coordinator;

    public PersistentApplicationTransactionCoordinator(
        ExternalMutationCoordinator coordinator) =>
        _coordinator = coordinator
                       ?? throw new ArgumentNullException(nameof(coordinator));

    public static PersistentApplicationTransactionCoordinator CreateDefault(
        string localApplicationData,
        string installRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(localApplicationData);
        ArgumentException.ThrowIfNullOrWhiteSpace(installRoot);
        var startMenuRoot = Environment.GetFolderPath(
            Environment.SpecialFolder.StartMenu);
        var desktopRoot = Environment.GetFolderPath(
            Environment.SpecialFolder.DesktopDirectory);
        if (string.IsNullOrWhiteSpace(startMenuRoot))
        {
            startMenuRoot = Path.Combine(
                localApplicationData,
                "Microsoft",
                "Windows",
                "Start Menu");
        }

        if (string.IsNullOrWhiteSpace(desktopRoot))
            desktopRoot = Path.Combine(localApplicationData, "Desktop");
        var catalog = new ExternalMutationCatalog(
        [
            new(
                CodexPlusPlusManagedTargets.ProgramDirectory,
                new DirectoryExternalMutationProvider(installRoot)),
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
                        Path.Combine(desktopRoot, "Codex++ 管理工具.lnk"))
                ]))
        ]);
        var transactionRoot = Path.Combine(
            localApplicationData,
            "CodexKit",
            "transactions",
            "applications");
        return new PersistentApplicationTransactionCoordinator(
            new ExternalMutationCoordinator(transactionRoot, catalog));
    }

    public async Task RecoverIncompleteAsync(CancellationToken cancellationToken)
    {
        await _coordinator.RecoverIncompleteAsync(cancellationToken)
            .ConfigureAwait(false);
        await _coordinator.RetryPendingCleanupAsync(cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<IApplicationTransactionSession> BeginAsync(
        IReadOnlyList<string> targetKeys,
        CancellationToken cancellationToken)
    {
        var session = await _coordinator.BeginExternalMutationAsync(
                targetKeys,
                cancellationToken)
            .ConfigureAwait(false);
        await session.MarkApplyingAsync(cancellationToken)
            .ConfigureAwait(false);
        return new PersistentApplicationTransactionSession(session);
    }
}

internal sealed class PersistentApplicationTransactionSession
    : IApplicationTransactionSession
{
    private readonly ExternalMutationSession _session;

    public PersistentApplicationTransactionSession(
        ExternalMutationSession session) =>
        _session = session ?? throw new ArgumentNullException(nameof(session));

    public bool IsCommitted => _session.State == TransactionState.Committed;

    public async Task<ApplicationTransactionCommitResult> CommitAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var result = await _session.CommitAsync(CancellationToken.None)
            .ConfigureAwait(false);
        return new ApplicationTransactionCommitResult(result.CleanupPending);
    }

    public Task RollBackAsync(CancellationToken cancellationToken) =>
        _session.RollBackAsync(cancellationToken);
}

internal static class CodexPlusPlusRegistryPaths
{
    public const string Product = @"Software\Codex++";
    public const string Uninstall =
        @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++";
}

public sealed class DirectoryExternalMutationProvider
    : IExternalMutationProvider
{
    private const string SnapshotSchema = "codex-plus-plus.directory.v1";
    private readonly string _target;
    private readonly ManagedPathGuard _guard;

    public DirectoryExternalMutationProvider(
        string target,
        ManagedPathGuard? guard = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        _target = ManagedApplicationPathAliases.Normalize(target);
        _guard = guard ?? new ManagedPathGuard();
    }

    public ExternalMutationTargetKind Kind =>
        ExternalMutationTargetKind.Directory;

    public ExternalMutationProviderScope Scope =>
        ExternalMutationProviderScope.None;

    public async Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
        ManagedSnapshotWriter writer,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(writer);
        ValidateTargetRoot();
        if (File.Exists(_target))
        {
            throw new IOException(
                "Codex++ program-directory target is a file.");
        }

        var exists = Directory.Exists(_target);
        var directories = new List<string>();
        var files = new List<DirectorySnapshotFile>();
        if (exists)
        {
            foreach (var entry in EnumerateTreeSafely(_target, cancellationToken))
            {
                var relative = Path.GetRelativePath(_target, entry);
                if (Directory.Exists(entry))
                {
                    directories.Add(relative);
                    continue;
                }

                await using var verified = _guard.OpenVerifiedRead(_target, entry);
                using var memory = new MemoryStream();
                await verified.Stream.CopyToAsync(memory, cancellationToken)
                    .ConfigureAwait(false);
                files.Add(new DirectorySnapshotFile(
                    relative,
                    memory.ToArray()));
            }
        }

        var content = JsonSerializer.SerializeToUtf8Bytes(
            new DirectorySnapshot(
                exists,
                directories.OrderBy(
                        path => path,
                        StringComparer.Ordinal)
                    .ToArray(),
                files.OrderBy(
                        file => file.RelativePath,
                        StringComparer.Ordinal)
                    .ToArray()));
        return await writer.WriteAsync(
                SnapshotSchema,
                content,
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ValidateSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken) =>
        _ = await ReadSnapshotAsync(snapshot, cancellationToken)
            .ConfigureAwait(false);

    public async Task RestoreSnapshotAsync(
        ManagedSnapshotReader snapshotReader,
        CancellationToken cancellationToken)
    {
        var snapshot = await ReadSnapshotAsync(
                snapshotReader,
                cancellationToken)
            .ConfigureAwait(false);
        ValidateTargetRoot();
        if (Directory.Exists(_target))
        {
            ValidateDirectoryTree(_target);
            Directory.Delete(_target, recursive: true);
        }
        else if (File.Exists(_target))
        {
            throw new IOException(
                "Codex++ program-directory target was replaced by a file.");
        }

        if (snapshot.Exists)
        {
            var volumeRoot = Path.GetPathRoot(_target)
                             ?? throw new UnauthorizedAccessException(
                                 "Codex++ program-directory target has no filesystem root.");
            _guard.EnsureManagedDirectory(volumeRoot, _target);
            foreach (var relativeDirectory in snapshot.Directories)
            {
                cancellationToken.ThrowIfCancellationRequested();
                _guard.EnsureManagedDirectory(
                    _target,
                    ResolveSnapshotPath(relativeDirectory));
            }

            foreach (var file in snapshot.Files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var target = ResolveSnapshotPath(file.RelativePath);
                _guard.EnsureManagedDirectory(
                    _target,
                    Path.GetDirectoryName(target)!);
                await _guard.WriteDurableFileAsync(
                        _target,
                        target,
                        file.Content,
                        cancellationToken)
                    .ConfigureAwait(false);
            }
        }
    }

    public Task CleanupSnapshotAsync(
        ManagedSnapshotReader? snapshot,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    private IEnumerable<string> EnumerateTreeSafely(
        string root,
        CancellationToken cancellationToken)
    {
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            foreach (var entry in Directory.EnumerateFileSystemEntries(
                         current,
                         "*",
                         SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                ValidateSourcePath(root, entry);
                if (Directory.Exists(entry))
                {
                    pending.Push(entry);
                }
                else if (!File.Exists(entry))
                {
                    throw new IOException(
                        "Managed directory entry changed during snapshot.");
                }

                yield return entry;
            }
        }
    }

    private void ValidateDirectoryTree(string root)
    {
        ValidateSourcePath(root, root, allowRoot: true);
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(
                         pending.Pop(),
                         "*",
                         SearchOption.TopDirectoryOnly))
            {
                ValidateSourcePath(root, entry);
                if (Directory.Exists(entry))
                    pending.Push(entry);
            }
        }
    }

    private string ValidateSourcePath(
        string root,
        string path,
        bool allowRoot = false) =>
        _guard.ValidateManagedPath(root, path, allowRoot);

    private void ValidateTargetRoot() =>
        _ = _guard.ValidateManagedPath(_target, _target, allowRoot: true);

    private async Task<DirectorySnapshot> ReadSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!string.Equals(
                snapshot.Descriptor.Schema,
                SnapshotSchema,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ directory snapshot schema is invalid.");
        }

        var value = JsonSerializer.Deserialize<DirectorySnapshot>(
                        await snapshot.ReadAllBytesAsync(cancellationToken)
                            .ConfigureAwait(false))
                    ?? throw new InvalidDataException(
                        "Codex++ directory snapshot is empty.");
        if (!value.Exists
            && (value.Directories.Count != 0 || value.Files.Count != 0))
        {
            throw new InvalidDataException(
                "Missing Codex++ directory snapshot contains entries.");
        }

        var paths = new HashSet<string>(
            OperatingSystem.IsWindows()
                ? StringComparer.OrdinalIgnoreCase
                : StringComparer.Ordinal);
        foreach (var path in value.Directories)
        {
            _ = ResolveSnapshotPath(path);
            if (!paths.Add(path))
            {
                throw new InvalidDataException(
                    "Codex++ directory snapshot contains duplicate paths.");
            }
        }

        foreach (var file in value.Files)
        {
            _ = ResolveSnapshotPath(file.RelativePath);
            if (!paths.Add(file.RelativePath))
            {
                throw new InvalidDataException(
                    "Codex++ directory snapshot contains duplicate paths.");
            }
        }

        return value;
    }

    private string ResolveSnapshotPath(string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath)
            || Path.IsPathRooted(relativePath))
        {
            throw new InvalidDataException(
                "Codex++ directory snapshot path is invalid.");
        }

        return _guard.ValidateManagedPath(
            _target,
            Path.GetFullPath(Path.Combine(_target, relativePath)));
    }

    private sealed record DirectorySnapshot(
        bool Exists,
        IReadOnlyList<string> Directories,
        IReadOnlyList<DirectorySnapshotFile> Files);

    private sealed record DirectorySnapshotFile(
        string RelativePath,
        byte[] Content);
}

public sealed class FileExternalMutationProvider
    : IExternalMutationProvider
{
    private const string SnapshotSchema = "codex-plus-plus.file.v1";
    private readonly string _root;
    private readonly string _target;
    private readonly ManagedPathGuard _guard;

    public FileExternalMutationProvider(
        string root,
        string target,
        ManagedPathGuard? guard = null)
    {
        _root = ManagedApplicationPathAliases.Normalize(root);
        _target = ManagedApplicationPathAliases.Normalize(target);
        _guard = guard ?? new ManagedPathGuard();
        _ = _guard.ValidateManagedPath(_root, _target);
    }

    public ExternalMutationTargetKind Kind =>
        ExternalMutationTargetKind.File;

    public ExternalMutationProviderScope Scope =>
        ExternalMutationProviderScope.None;

    public async Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
        ManagedSnapshotWriter writer,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(writer);
        var value = await CaptureValueAsync(cancellationToken)
            .ConfigureAwait(false);
        return await writer.WriteAsync(
                SnapshotSchema,
                JsonSerializer.SerializeToUtf8Bytes(value),
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ValidateSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken) =>
        _ = await ReadSnapshotAsync(snapshot, cancellationToken)
            .ConfigureAwait(false);

    public async Task RestoreSnapshotAsync(
        ManagedSnapshotReader snapshotReader,
        CancellationToken cancellationToken)
    {
        var snapshot = await ReadSnapshotAsync(snapshotReader, cancellationToken)
            .ConfigureAwait(false);
        await RestoreValueAsync(snapshot, cancellationToken)
            .ConfigureAwait(false);
    }

    public Task CleanupSnapshotAsync(
        ManagedSnapshotReader? snapshot,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    internal async Task<FileSnapshotValue> CaptureValueAsync(
        CancellationToken cancellationToken)
    {
        _ = _guard.ValidateManagedPath(_root, _target);
        if (Directory.Exists(_target))
        {
            throw new IOException(
                "Managed file target was replaced by a directory.");
        }

        if (!File.Exists(_target))
            return new FileSnapshotValue(Exists: false, Content: null);
        await using var verified = _guard.OpenVerifiedRead(_root, _target);
        using var memory = new MemoryStream();
        await verified.Stream.CopyToAsync(memory, cancellationToken)
            .ConfigureAwait(false);
        return new FileSnapshotValue(Exists: true, memory.ToArray());
    }

    internal async Task RestoreValueAsync(
        FileSnapshotValue snapshot,
        CancellationToken cancellationToken)
    {
        ValidateValue(snapshot);
        _ = _guard.ValidateManagedPath(_root, _target);
        if (Directory.Exists(_target))
        {
            throw new IOException(
                "Managed file target was replaced by a directory.");
        }

        await _guard.DeleteManagedFileAsync(
                _root,
                _target,
                cancellationToken)
            .ConfigureAwait(false);
        if (!snapshot.Exists)
            return;

        _guard.EnsureManagedDirectory(
            _root,
            Path.GetDirectoryName(_target)!);
        await _guard.WriteDurableFileAsync(
                _root,
                _target,
                snapshot.Content!,
                cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task<FileSnapshotValue> ReadSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!string.Equals(
                snapshot.Descriptor.Schema,
                SnapshotSchema,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Managed file snapshot schema is invalid.");
        }

        var value = JsonSerializer.Deserialize<FileSnapshotValue>(
                        await snapshot.ReadAllBytesAsync(cancellationToken)
                            .ConfigureAwait(false))
                    ?? throw new InvalidDataException(
                        "Managed file snapshot is empty.");
        ValidateValue(value);
        return value;
    }

    private static void ValidateValue(FileSnapshotValue value)
    {
        if (value.Exists != (value.Content is not null))
        {
            throw new InvalidDataException(
                "Managed file snapshot existence and content disagree.");
        }
    }
}

internal sealed record FileSnapshotValue(bool Exists, byte[]? Content);

public sealed class ShortcutSetExternalMutationProvider
    : IExternalMutationProvider
{
    private const string SnapshotSchema = "codex-plus-plus.shortcuts.v1";
    private readonly IReadOnlyList<FileExternalMutationProvider> _providers;

    public ShortcutSetExternalMutationProvider(
        IEnumerable<(string Root, string Path)> shortcuts)
    {
        ArgumentNullException.ThrowIfNull(shortcuts);
        _providers = shortcuts
            .Select(shortcut => new FileExternalMutationProvider(
                shortcut.Root,
                shortcut.Path))
            .ToArray();
        if (_providers.Count == 0)
        {
            throw new ArgumentException(
                "A shortcut set must contain at least one path.",
                nameof(shortcuts));
        }
    }

    public ExternalMutationTargetKind Kind =>
        ExternalMutationTargetKind.File;

    public ExternalMutationProviderScope Scope =>
        ExternalMutationProviderScope.None;

    public async Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
        ManagedSnapshotWriter writer,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(writer);
        var values = new List<FileSnapshotValue>(_providers.Count);
        foreach (var provider in _providers)
        {
            values.Add(await provider.CaptureValueAsync(
                    cancellationToken)
                .ConfigureAwait(false));
        }

        return await writer.WriteAsync(
                SnapshotSchema,
                JsonSerializer.SerializeToUtf8Bytes(
                    new ShortcutSetSnapshot(values.AsReadOnly())),
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ValidateSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken) =>
        _ = await ReadSnapshotAsync(snapshot, cancellationToken)
            .ConfigureAwait(false);

    public async Task RestoreSnapshotAsync(
        ManagedSnapshotReader snapshotReader,
        CancellationToken cancellationToken)
    {
        var snapshot = await ReadSnapshotAsync(
                snapshotReader,
                cancellationToken)
            .ConfigureAwait(false);
        for (var index = _providers.Count - 1; index >= 0; index--)
        {
            await _providers[index].RestoreValueAsync(
                    snapshot.Files[index],
                    cancellationToken)
                .ConfigureAwait(false);
        }
    }

    public Task CleanupSnapshotAsync(
        ManagedSnapshotReader? snapshot,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    private async Task<ShortcutSetSnapshot> ReadSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!string.Equals(
                snapshot.Descriptor.Schema,
                SnapshotSchema,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ shortcut snapshot schema is invalid.");
        }

        var value = JsonSerializer.Deserialize<ShortcutSetSnapshot>(
                        await snapshot.ReadAllBytesAsync(cancellationToken)
                            .ConfigureAwait(false))
                    ?? throw new InvalidDataException(
                        "Codex++ shortcut snapshot is empty.");
        if (value.Files.Count != _providers.Count
            || value.Files.Any(file =>
                file.Exists != (file.Content is not null)))
        {
            throw new InvalidDataException(
                "Codex++ shortcut snapshot does not match its stable target set.");
        }

        return value;
    }

    private sealed record ShortcutSetSnapshot(
        IReadOnlyList<FileSnapshotValue> Files);
}

#pragma warning disable CA1416 // Every registry entry point is runtime-guarded by EnsureWindows.
public sealed class CurrentUserRegistryExternalMutationProvider
    : IExternalMutationProvider
{
    private const string SnapshotSchema = "codex-plus-plus.hkcu.v1";
    private readonly string _subKeyPath;

    public CurrentUserRegistryExternalMutationProvider(string subKeyPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(subKeyPath);
        if (subKeyPath.StartsWith('\\')
            || subKeyPath.Contains("..", StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "HKCU snapshot path must be a stable relative registry path.",
                nameof(subKeyPath));
        }

        _subKeyPath = subKeyPath;
    }

    public ExternalMutationTargetKind Kind =>
        ExternalMutationTargetKind.RegistryKey;

    public ExternalMutationProviderScope Scope =>
        ExternalMutationProviderScope.CurrentUser;

    public Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
        ManagedSnapshotWriter writer,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(writer);
        EnsureWindows();
        cancellationToken.ThrowIfCancellationRequested();
        using var key = Registry.CurrentUser.OpenSubKey(_subKeyPath);
        var snapshot = new RegistrySnapshot(
            key is not null,
            key is null ? null : CaptureKey(key));
        return writer.WriteAsync(
            SnapshotSchema,
            JsonSerializer.SerializeToUtf8Bytes(snapshot),
            cancellationToken);
    }

    public async Task ValidateSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken) =>
        _ = await ReadSnapshotAsync(snapshot, cancellationToken)
            .ConfigureAwait(false);

    public async Task RestoreSnapshotAsync(
        ManagedSnapshotReader snapshotReader,
        CancellationToken cancellationToken)
    {
        EnsureWindows();
        var snapshot = await ReadSnapshotAsync(
                snapshotReader,
                cancellationToken)
            .ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        Registry.CurrentUser.DeleteSubKeyTree(
            _subKeyPath,
            throwOnMissingSubKey: false);
        if (!snapshot.Exists)
            return;
        using var key = Registry.CurrentUser.CreateSubKey(
            _subKeyPath,
            writable: true);
        RestoreKey(
            key ?? throw new IOException("Unable to recreate HKCU registry key."),
            snapshot.Root
            ?? throw new InvalidDataException("Registry snapshot root is missing."));
    }

    public Task CleanupSnapshotAsync(
        ManagedSnapshotReader? snapshot,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    private static async Task<RegistrySnapshot> ReadSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!string.Equals(
                snapshot.Descriptor.Schema,
                SnapshotSchema,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ HKCU snapshot schema is invalid.");
        }

        var value = JsonSerializer.Deserialize<RegistrySnapshot>(
                        await snapshot.ReadAllBytesAsync(cancellationToken)
                            .ConfigureAwait(false))
                    ?? throw new InvalidDataException(
                        "Codex++ HKCU snapshot is empty.");
        if (value.Exists != (value.Root is not null))
        {
            throw new InvalidDataException(
                "Codex++ HKCU snapshot existence and content disagree.");
        }

        return value;
    }

    private static RegistryNode CaptureKey(RegistryKey key)
    {
        var values = key.GetValueNames()
            .Select(name =>
            {
                var kind = key.GetValueKind(name);
                var value = key.GetValue(
                    name,
                    null,
                    RegistryValueOptions.DoNotExpandEnvironmentNames);
                return RegistryValue.From(name, kind, value);
            })
            .ToArray();
        var subKeys = key.GetSubKeyNames()
            .Select(name =>
            {
                using var subKey = key.OpenSubKey(name)
                                   ?? throw new IOException(
                                       $"Unable to read HKCU subkey '{name}'.");
                return new RegistrySubKey(name, CaptureKey(subKey));
            })
            .ToArray();
        return new RegistryNode(values, subKeys);
    }

    private static void RestoreKey(RegistryKey key, RegistryNode node)
    {
        foreach (var value in node.Values)
            key.SetValue(value.Name, value.ToValue(), value.Kind);
        foreach (var subKey in node.SubKeys)
        {
            using var child = key.CreateSubKey(subKey.Name, writable: true)
                              ?? throw new IOException(
                                  $"Unable to recreate HKCU subkey '{subKey.Name}'.");
            RestoreKey(child, subKey.Node);
        }
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "HKCU application snapshots require Windows.");
        }
    }

    private sealed record RegistrySnapshot(bool Exists, RegistryNode? Root);

    private sealed record RegistryNode(
        IReadOnlyList<RegistryValue> Values,
        IReadOnlyList<RegistrySubKey> SubKeys);

    private sealed record RegistrySubKey(string Name, RegistryNode Node);

    private sealed record RegistryValue(
        string Name,
        RegistryValueKind Kind,
        string? Text,
        string[]? Texts,
        long? Number,
        string? Base64)
    {
        public static RegistryValue From(
            string name,
            RegistryValueKind kind,
            object? value) =>
            kind switch
            {
                RegistryValueKind.String or RegistryValueKind.ExpandString =>
                    new(name, kind, value?.ToString(), null, null, null),
                RegistryValueKind.MultiString =>
                    new(name, kind, null, (string[]?)value, null, null),
                RegistryValueKind.DWord or RegistryValueKind.QWord =>
                    new(
                        name,
                        kind,
                        null,
                        null,
                        Convert.ToInt64(
                            value,
                            System.Globalization.CultureInfo.InvariantCulture),
                        null),
                RegistryValueKind.Binary or RegistryValueKind.None =>
                    new(
                        name,
                        kind,
                        null,
                        null,
                        null,
                        Convert.ToBase64String((byte[]?)value ?? [])),
                _ => throw new InvalidDataException(
                    $"Unsupported registry value kind '{kind}'.")
            };

        public object ToValue() =>
            Kind switch
            {
                RegistryValueKind.String or RegistryValueKind.ExpandString =>
                    Text ?? string.Empty,
                RegistryValueKind.MultiString => Texts ?? [],
                RegistryValueKind.DWord => checked((int)(Number ?? 0)),
                RegistryValueKind.QWord => Number ?? 0,
                RegistryValueKind.Binary or RegistryValueKind.None =>
                    Convert.FromBase64String(Base64 ?? string.Empty),
                _ => throw new InvalidDataException(
                    $"Unsupported registry value kind '{Kind}'.")
            };
    }
}
#pragma warning restore CA1416

public sealed class WindowsProcessSecurityContext : IProcessSecurityContext
{
    public bool IsElevated
    {
        get
        {
            EnsureWindows();
#if WINDOWS
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity)
                .IsInRole(WindowsBuiltInRole.Administrator);
#else
            return false;
#endif
        }
    }

    public bool IsCurrentUser
    {
        get
        {
            EnsureWindows();
#if WINDOWS
            using var identity = WindowsIdentity.GetCurrent();
            return identity.User is not null
                   && !identity.IsSystem
                   && !identity.IsAnonymous
                   && !identity.IsGuest;
#else
            return false;
#endif
        }
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Codex++ process token inspection requires Windows.");
        }
    }
}

public sealed class CodexPlusPlusSetupInspector
    : ICodexPlusPlusSetupInspector
{
    public CodexPlusPlusSetupProvenance Inspect(VerifiedManagedFile setup)
    {
        ArgumentNullException.ThrowIfNull(setup);
        PeImageInspector.RequireX64(setup.FullPath);
        var version = FileVersionInfo.GetVersionInfo(setup.FullPath);
        if (!string.Equals(
                version.ProductVersion,
                CodexPlusPlusInstaller.PayloadVersion,
                StringComparison.Ordinal)
            || !string.Equals(
                version.FileVersion,
                CodexPlusPlusInstaller.PayloadVersion,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ setup file version is not the reviewed downstream version.");
        }

        return CodexPlusPlusSetupProvenanceReader.Read(setup.FullPath);
    }
}

public sealed class WindowsCodexPlusPlusInstallationProbe
    : ICodexPlusPlusInstallationProbe
{
    private readonly IManagedApplicationPathPolicy _paths;

    public WindowsCodexPlusPlusInstallationProbe(
        IManagedApplicationPathPolicy? pathPolicy = null) =>
        _paths = pathPolicy ?? new PhysicalManagedApplicationPathPolicy();

    public async Task<CodexPlusPlusInstallationState> InspectAsync(
        string installRoot,
        CodexPlusPlusSetupProvenance provenance,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(installRoot);
        ArgumentNullException.ThrowIfNull(provenance);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Codex++ installation inspection requires Windows.");
        }

        var root = Path.GetFullPath(installRoot);
        var launcher = Path.Combine(root, "codex-plus-plus.exe");
        var manager = Path.Combine(root, "codex-plus-plus-manager.exe");
        await using var launcherFile = await _paths.VerifyFileAsync(
                "codex-plus-plus.launcher",
                root,
                launcher,
                RequiredExecutableHash(
                    provenance,
                    "codex-plus-plus.exe",
                    "launcher"),
                cancellationToken)
            .ConfigureAwait(false);
        await using var managerFile = await _paths.VerifyFileAsync(
                "codex-plus-plus.manager",
                root,
                manager,
                RequiredExecutableHash(
                    provenance,
                    "codex-plus-plus-manager.exe",
                    "manager"),
                cancellationToken)
            .ConfigureAwait(false);
        PeImageInspector.RequireX64(launcher);
        PeImageInspector.RequireX64(manager);
        var launcherVersion = ReadProductVersion(launcher);
        var managerVersion = ReadProductVersion(manager);
        using var productKey = Registry.CurrentUser.OpenSubKey(
            CodexPlusPlusRegistryPaths.Product);
        using var uninstallKey = Registry.CurrentUser.OpenSubKey(
            CodexPlusPlusRegistryPaths.Uninstall);
        var productInstallDirectory =
            productKey?.GetValue("InstallDir")?.ToString();
        var uninstallVersion = uninstallKey?.GetValue("DisplayVersion")?.ToString();
        var installLocation = uninstallKey?.GetValue("InstallLocation")?.ToString();
        var uninstallString = uninstallKey?.GetValue("UninstallString")?.ToString();
        var uninstaller = Path.Combine(root, "uninstall.exe");
        var uninstallerPresent = File.Exists(uninstaller);
        if (uninstallerPresent)
            _paths.ValidatePath("codex-plus-plus.uninstaller", root, uninstaller);
        var startMenuRoot = Environment.GetFolderPath(
            Environment.SpecialFolder.StartMenu);
        var desktopRoot = Environment.GetFolderPath(
            Environment.SpecialFolder.DesktopDirectory);
        var shortcutTargets = new[]
        {
            (
                "codex-plus-plus.shortcut.start.launcher",
                startMenuRoot,
                Path.Combine(
                    startMenuRoot,
                    "Programs",
                    "Codex++",
                    "Codex++.lnk")),
            (
                "codex-plus-plus.shortcut.start.manager",
                startMenuRoot,
                Path.Combine(
                    startMenuRoot,
                    "Programs",
                    "Codex++",
                    "Codex++ 管理工具.lnk")),
            (
                "codex-plus-plus.shortcut.start.uninstall",
                startMenuRoot,
                Path.Combine(
                    startMenuRoot,
                    "Programs",
                    "Codex++",
                    "卸载 Codex++.lnk")),
            (
                "codex-plus-plus.shortcut.desktop.launcher",
                desktopRoot,
                Path.Combine(desktopRoot, "Codex++.lnk")),
            (
                "codex-plus-plus.shortcut.desktop.manager",
                desktopRoot,
                Path.Combine(desktopRoot, "Codex++ 管理工具.lnk"))
        };
        var shortcutsPresent =
            !string.IsNullOrWhiteSpace(startMenuRoot)
            && !string.IsNullOrWhiteSpace(desktopRoot)
            && shortcutTargets.All(shortcut => File.Exists(shortcut.Item3));
        if (shortcutsPresent)
        {
            foreach (var shortcut in shortcutTargets)
                _paths.ValidatePath(shortcut.Item1, shortcut.Item2, shortcut.Item3);
        }

        return new CodexPlusPlusInstallationState(
            root,
            LauncherPresent: true,
            ManagerPresent: true,
            DisplayVersion: uninstallVersion,
            uninstallKey is not null
            && !string.IsNullOrWhiteSpace(uninstallVersion)
            && !string.IsNullOrWhiteSpace(uninstallString),
            CodexKitExecutableMetadataReader.Read(launcher),
            CodexKitExecutableMetadataReader.Read(manager),
            LauncherIsPeX64: true,
            ManagerIsPeX64: true,
            LauncherFileVersion: launcherVersion,
            ManagerFileVersion: managerVersion,
            LauncherSha256: launcherFile.Sha256,
            ManagerSha256: managerFile.Sha256,
            ProductRegistrationIsCurrentUser: productKey is not null,
            UninstallRegistrationIsCurrentUser: uninstallKey is not null,
            ProductInstallDirectory: productInstallDirectory,
            UninstallDisplayVersion: uninstallVersion,
            UninstallInstallLocation: installLocation,
            UninstallString: uninstallString,
            UninstallerPresent: uninstallerPresent,
            CurrentUserShortcutsPresent: shortcutsPresent);
    }

    private static string? ReadProductVersion(string path)
    {
        var version = FileVersionInfo.GetVersionInfo(path);
        return version.ProductVersion ?? version.FileVersion;
    }

    private static string RequiredExecutableHash(
        CodexPlusPlusSetupProvenance provenance,
        string fileName,
        string component)
    {
        var executable = provenance.Executables.SingleOrDefault(candidate =>
            string.Equals(candidate.Name, fileName, StringComparison.Ordinal)
            && string.Equals(candidate.Component, component, StringComparison.Ordinal));
        return executable is not null && executable.Sha256.Length == 64
            ? executable.Sha256
            : throw new InvalidDataException(
                $"Codex++ setup provenance omitted the {component} hash.");
    }
}

public static class CodexKitExecutableMetadataReader
{
    public const string Magic = "CODEXKIT-EXECUTABLE-METADATA-V1:";
    private const int TailSize = 16 * 1024;

    public static CodexKitExecutableMetadata Read(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!File.Exists(path))
            throw new FileNotFoundException("CodexKit executable is missing.", path);
        PeImageInspector.RequireX64(path);

        byte[] bytes;
        using (var stream = new FileStream(
                   path,
                   FileMode.Open,
                   FileAccess.Read,
                   FileShare.Read))
        {
            var length = (int)Math.Min(TailSize, stream.Length);
            bytes = new byte[length];
            stream.Position = stream.Length - length;
            stream.ReadExactly(bytes);
        }

        var tail = Encoding.UTF8.GetString(bytes);
        var marker = tail.LastIndexOf(Magic, StringComparison.Ordinal);
        if (marker < 0)
        {
            throw new InvalidDataException(
                "CodexKit executable metadata marker is missing.");
        }

        var jsonStart = marker + Magic.Length;
        var jsonEnd = tail.IndexOf('\n', jsonStart);
        if (jsonEnd <= jsonStart)
        {
            throw new InvalidDataException(
                "CodexKit executable metadata is truncated.");
        }

        try
        {
            using var document = JsonDocument.Parse(
                tail.Substring(jsonStart, jsonEnd - jsonStart));
            var root = document.RootElement;
            return new CodexKitExecutableMetadata(
                root.GetProperty("schemaVersion").GetInt32(),
                RequiredString(root, "payloadVersion"),
                RequiredString(root, "compatibilityRevision"),
                RequiredString(root, "architecture"),
                RequiredString(root, "component"),
                root.GetProperty("fixtureOnly").GetBoolean());
        }
        catch (Exception exception)
            when (exception is JsonException
                  or InvalidOperationException
                  or KeyNotFoundException)
        {
            throw new InvalidDataException(
                "CodexKit executable metadata is invalid.",
                exception);
        }
    }

    private static string RequiredString(JsonElement root, string name)
    {
        var value = root.GetProperty(name).GetString();
        return !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new InvalidDataException(
                $"CodexKit executable metadata {name} is empty.");
    }
}

public static class CodexPlusPlusSetupProvenanceReader
{
    public const string Magic = "CODEXKIT-SETUP-PROVENANCE-V1:";

    public static CodexPlusPlusSetupProvenance Read(string path)
    {
        var json = ExecutableOverlayReader.ReadJson(path, Magic);
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            RequireExactProperties(
                root,
            [
                "schema",
                "schemaVersion",
                "setupFileName",
                "upstreamTag",
                "patchSha256",
                "payloadVersion",
                "compatibilityRevision",
                "architecture",
                "perUser",
                "executionLevel",
                "installDir",
                "registryHive",
                "shortcutScope",
                "requiresElevation",
                "rawCreateProcessCompatible",
                "fixtureOnly",
                "executables"
            ]);
            var executableElements = root.GetProperty("executables")
                .EnumerateArray()
                .ToArray();
            foreach (var executable in executableElements)
            {
                RequireExactProperties(
                    executable,
                [
                    "name",
                    "component",
                    "sha256",
                    "payloadVersion",
                    "compatibilityRevision",
                    "architecture",
                    "metadataMagic"
                ]);
            }

            return new CodexPlusPlusSetupProvenance(
                RequiredString(root, "schema"),
                root.GetProperty("schemaVersion").GetInt32(),
                RequiredString(root, "setupFileName"),
                RequiredString(root, "upstreamTag"),
                RequiredString(root, "patchSha256"),
                RequiredString(root, "payloadVersion"),
                RequiredString(root, "compatibilityRevision"),
                RequiredString(root, "architecture"),
                root.GetProperty("perUser").GetBoolean(),
                RequiredString(root, "executionLevel"),
                RequiredString(root, "installDir"),
                RequiredString(root, "registryHive"),
                RequiredString(root, "shortcutScope"),
                root.GetProperty("requiresElevation").GetBoolean(),
                root.GetProperty("rawCreateProcessCompatible").GetBoolean(),
                root.GetProperty("fixtureOnly").GetBoolean(),
                executableElements
                    .Select(executable => new CodexPlusPlusSetupExecutable(
                        RequiredString(executable, "name"),
                        RequiredString(executable, "component"),
                        RequiredString(executable, "sha256"),
                        RequiredString(executable, "payloadVersion"),
                        RequiredString(executable, "compatibilityRevision"),
                        RequiredString(executable, "architecture"),
                        RequiredString(executable, "metadataMagic")))
                    .ToArray());
        }
        catch (Exception exception)
            when (exception is JsonException
                  or InvalidOperationException
                  or KeyNotFoundException)
        {
            throw new InvalidDataException(
                "Codex++ setup provenance is invalid.",
                exception);
        }
    }

    private static string RequiredString(JsonElement root, string name)
    {
        var value = root.GetProperty(name).GetString();
        return !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new InvalidDataException(
                $"Codex++ setup provenance {name} is empty.");
    }

    private static void RequireExactProperties(
        JsonElement element,
        IReadOnlyList<string> expected)
    {
        var actual = element.EnumerateObject()
            .Select(property => property.Name)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        var required = expected
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        if (!actual.SequenceEqual(required, StringComparer.Ordinal))
        {
            throw new InvalidDataException(
                "Codex++ setup provenance properties do not match the fixed schema.");
        }
    }
}

internal static class ExecutableOverlayReader
{
    private const int TailSize = 64 * 1024;

    public static string ReadJson(string path, string magic)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentException.ThrowIfNullOrWhiteSpace(magic);
        PeImageInspector.RequireX64(path);
        byte[] bytes;
        using (var stream = new FileStream(
                   path,
                   FileMode.Open,
                   FileAccess.Read,
                   FileShare.Read))
        {
            var length = (int)Math.Min(TailSize, stream.Length);
            bytes = new byte[length];
            stream.Position = stream.Length - length;
            stream.ReadExactly(bytes);
        }

        var tail = Encoding.UTF8.GetString(bytes);
        var marker = tail.LastIndexOf(magic, StringComparison.Ordinal);
        if (marker < 0)
            throw new InvalidDataException("Executable overlay marker is missing.");
        var jsonStart = marker + magic.Length;
        var jsonEnd = tail.IndexOf('\n', jsonStart);
        if (jsonEnd <= jsonStart)
            throw new InvalidDataException("Executable overlay metadata is truncated.");
        return tail.Substring(jsonStart, jsonEnd - jsonStart);
    }
}

public static class PeImageInspector
{
    private const ushort ImageFileMachineAmd64 = 0x8664;

    public static void RequireX64(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read);
        Span<byte> dosHeader = stackalloc byte[64];
        if (stream.Read(dosHeader) != dosHeader.Length
            || dosHeader[0] != (byte)'M'
            || dosHeader[1] != (byte)'Z')
        {
            throw new InvalidDataException("Executable is not a PE image.");
        }

        var peOffset = BitConverter.ToInt32(dosHeader[0x3c..0x40]);
        if (peOffset < 64 || peOffset > stream.Length - 6)
            throw new InvalidDataException("Executable PE header offset is invalid.");
        stream.Position = peOffset;
        Span<byte> peHeader = stackalloc byte[6];
        stream.ReadExactly(peHeader);
        if (peHeader[0] != (byte)'P'
            || peHeader[1] != (byte)'E'
            || peHeader[2] != 0
            || peHeader[3] != 0)
        {
            throw new InvalidDataException("Executable PE signature is invalid.");
        }

        var machine = BitConverter.ToUInt16(peHeader[4..6]);
        if (machine != ImageFileMachineAmd64)
            throw new InvalidDataException("Executable PE architecture is not x64.");
    }
}
