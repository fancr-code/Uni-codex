using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
#if WINDOWS
using Windows.ApplicationModel;
using Windows.Management.Deployment;
using Windows.System;
#endif

namespace CodexOneClickInstaller;

public sealed record ApplicationInstallResult(
    PlanAction Action,
    bool Changed,
    bool CleanupPending = false);

public enum CodexPackageArchitecture
{
    Unknown,
    Neutral,
    X86,
    X64,
    Arm,
    Arm64
}

public enum CodexPackageSignatureKind
{
    Unknown,
    Store,
    Developer,
    System
}

public sealed record CodexPackageInstallation(
    string PackageFamilyName,
    string Version,
    CodexPackageArchitecture Architecture,
    string Publisher,
    CodexPackageSignatureKind SignatureKind,
    bool IsPackageStatusHealthy,
    string? CliPath,
    string? InstallRoot = null);

public sealed record CodexPackageRegistration(
    string PackageFullName,
    string PackageFamilyName,
    string ManifestPath,
    bool IsMainPackage);

public sealed record CodexPackageGraphSnapshot(
    IReadOnlyList<CodexPackageRegistration> Registrations,
    string? StorageRoot = null);

public sealed record VerifiedManagedFile(
    string TargetKey,
    string RootPath,
    string FullPath,
    long Size,
    string Sha256);

public sealed class VerifiedManagedFileLease : IAsyncDisposable
{
    private readonly IAsyncDisposable _owner;

    public VerifiedManagedFileLease(
        VerifiedManagedFile file,
        IAsyncDisposable owner)
    {
        File = file ?? throw new ArgumentNullException(nameof(file));
        _owner = owner ?? throw new ArgumentNullException(nameof(owner));
    }

    public VerifiedManagedFile File { get; }

    public bool IsDisposed { get; private set; }

    public string FullPath => File.FullPath;

    public string Sha256 => File.Sha256;

    public async ValueTask DisposeAsync()
    {
        if (IsDisposed)
            return;
        IsDisposed = true;
        await _owner.DisposeAsync().ConfigureAwait(false);
    }
}

public interface IManagedApplicationPathPolicy
{
    Task<VerifiedManagedFileLease> VerifyPayloadAsync(
        string targetKey,
        string payloadRoot,
        PayloadEntry entry,
        CancellationToken cancellationToken);

    Task<VerifiedManagedFileLease> VerifyFileAsync(
        string targetKey,
        string rootPath,
        string path,
        string? expectedSha256,
        CancellationToken cancellationToken);

    void ValidatePath(string targetKey, string rootPath, string path);
}

public interface ICodexPackageDeployment
{
    Task<CodexPackageGraphSnapshot> CaptureSnapshotAsync(
        string packageFamilyName,
        CancellationToken cancellationToken);

    Task ValidateSnapshotRestorableAsync(
        CodexPackageGraphSnapshot snapshot,
        CancellationToken cancellationToken);

    Task AddPackageAsync(
        VerifiedManagedFileLease mainPackage,
        IReadOnlyList<VerifiedManagedFileLease> dependencyPackages,
        CancellationToken cancellationToken);

    Task RegisterPackageByManifestAsync(
        string mainManifestPath,
        IReadOnlyList<string> dependencyManifestPaths,
        CancellationToken cancellationToken);

    Task RestoreSnapshotAsync(
        CodexPackageGraphSnapshot snapshot,
        CancellationToken cancellationToken);

    Task<bool> DiscardSnapshotAsync(
        CodexPackageGraphSnapshot snapshot,
        CancellationToken cancellationToken);

    IReadOnlyList<CodexPackageInstallation> FindPackages(string packageFamilyName);
}

public interface IAuthenticodeVerifier
{
    bool IsTrusted(string path);
}

public sealed class CodexInstaller
{
    public const string PackageFamilyName = "OpenAI.Codex_2p2nqsd0c76g0";
    private const string PayloadId = "codex-windows-x64";
    private const string DependencyPrefix = "codex-dependency-";

    private readonly string _payloadRoot;
    private readonly ICodexPackageDeployment _deployment;
    private readonly IAuthenticodeVerifier _authenticode;
    private readonly IManagedApplicationPathPolicy _paths;

    public CodexInstaller(
        string payloadRoot,
        ICodexPackageDeployment? deployment = null,
        IAuthenticodeVerifier? authenticode = null,
        IManagedApplicationPathPolicy? pathPolicy = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadRoot);
        _payloadRoot = Path.GetFullPath(payloadRoot);
        _deployment = deployment ?? new WindowsCodexPackageDeployment();
        _authenticode = authenticode ?? new WinVerifyTrustAuthenticodeVerifier();
        _paths = pathPolicy ?? new PhysicalManagedApplicationPathPolicy();
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
                $"Codex installer cannot apply component '{plan.Component}'.",
                nameof(plan));
        }

        if (plan.Action == PlanAction.Preserve)
            return new ApplicationInstallResult(plan.Action, Changed: false);
        if (plan.Action is not (PlanAction.Install or PlanAction.Repair))
        {
            throw new ArgumentException(
                $"Codex installer cannot apply action '{plan.Action}'.",
                nameof(plan));
        }

        var mainEntry = RequiredEntry(catalog, PayloadId);
        ValidateMainEntry(mainEntry);
        var dependencyEntries = catalog.Entries
            .Where(entry => entry.Id.StartsWith(
                DependencyPrefix,
                StringComparison.Ordinal))
            .OrderBy(entry => entry.Id, StringComparer.Ordinal)
            .ToArray();
        var payloadLeases = new List<VerifiedManagedFileLease>(
            dependencyEntries.Length + 1);
        try
        {
            var main = await _paths.VerifyPayloadAsync(
                    PayloadId,
                    _payloadRoot,
                    mainEntry,
                    cancellationToken)
                .ConfigureAwait(false);
            payloadLeases.Add(main);
            var dependencies = new List<VerifiedManagedFileLease>(
                dependencyEntries.Length);
            foreach (var entry in dependencyEntries)
            {
                var dependency = await _paths.VerifyPayloadAsync(
                        entry.Id,
                        _payloadRoot,
                        entry,
                        cancellationToken)
                    .ConfigureAwait(false);
                dependencies.Add(dependency);
                payloadLeases.Add(dependency);
            }

            foreach (var payload in payloadLeases)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!_authenticode.IsTrusted(payload.FullPath))
                {
                    throw new InvalidDataException(
                        $"Codex payload failed WinVerifyTrust: " +
                        Path.GetFileName(payload.FullPath));
                }
            }

            var snapshot = await _deployment.CaptureSnapshotAsync(
                    PackageFamilyName,
                    cancellationToken)
                .ConfigureAwait(false);
            try
            {
                await _deployment.ValidateSnapshotRestorableAsync(
                        snapshot,
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch
            {
                _ = await _deployment.DiscardSnapshotAsync(
                        snapshot,
                        CancellationToken.None)
                    .ConfigureAwait(false);
                throw;
            }

            try
            {
                await _deployment.AddPackageAsync(
                        main,
                        Array.AsReadOnly(dependencies.ToArray()),
                        cancellationToken)
                    .ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();

                var candidates = _deployment.FindPackages(PackageFamilyName);
                var installed = candidates.FirstOrDefault(package =>
                    HasFixedIdentity(package, mainEntry.Publisher!));
                if (installed is null)
                {
                    throw new InvalidDataException(
                        "Codex installation failed Package Family, x64, Publisher, " +
                        "package signature, or package status verification.");
                }

                if (string.IsNullOrWhiteSpace(installed.InstallRoot)
                    || string.IsNullOrWhiteSpace(installed.CliPath)
                    || !File.Exists(installed.CliPath))
                {
                    throw new InvalidDataException(
                        "Codex installation did not expose the installed CLI and root.");
                }

                _paths.ValidatePath(
                    "codex.installed-cli",
                    installed.InstallRoot,
                    installed.CliPath);
                var cliPath = Path.GetFullPath(installed.CliPath);
                if (!_authenticode.IsTrusted(cliPath))
                {
                    throw new InvalidDataException(
                        "Codex installed CLI failed WinVerifyTrust.");
                }
            }
            catch (Exception error)
            {
                await RestorePackageGraphAsync(snapshot, error)
                    .ConfigureAwait(false);
                ExceptionDispatchInfo.Capture(error).Throw();
                throw;
            }

            var discarded = await _deployment.DiscardSnapshotAsync(
                    snapshot,
                    CancellationToken.None)
                .ConfigureAwait(false);
            return new ApplicationInstallResult(
                plan.Action,
                Changed: true,
                CleanupPending: !discarded);
        }
        finally
        {
            for (var index = payloadLeases.Count - 1; index >= 0; index--)
                await payloadLeases[index].DisposeAsync().ConfigureAwait(false);
        }
    }

    private async Task RestorePackageGraphAsync(
        CodexPackageGraphSnapshot snapshot,
        Exception primaryError)
    {
        try
        {
            await _deployment.RestoreSnapshotAsync(
                    snapshot,
                    CancellationToken.None)
                .ConfigureAwait(false);
            _ = await _deployment.DiscardSnapshotAsync(
                    snapshot,
                    CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (Exception rollbackError)
        {
            if (primaryError is OperationCanceledException)
            {
                primaryError.Data["CodexPackageRollbackError"] = rollbackError;
                return;
            }

            throw new AggregateException(
                "Codex installation failed and the package graph rollback did not complete.",
                primaryError,
                rollbackError);
        }
    }

    private static bool HasFixedIdentity(
        CodexPackageInstallation package,
        string expectedPublisher) =>
        string.Equals(
            package.PackageFamilyName,
            PackageFamilyName,
            StringComparison.Ordinal)
        && package.Architecture == CodexPackageArchitecture.X64
        && string.Equals(
            package.Publisher,
            expectedPublisher,
            StringComparison.Ordinal)
        && package.SignatureKind is CodexPackageSignatureKind.Store
            or CodexPackageSignatureKind.Developer
        && package.IsPackageStatusHealthy;

    private static void ValidateMainEntry(PayloadEntry entry)
    {
        if (!string.Equals(
                entry.PackageFamilyName,
                PackageFamilyName,
                StringComparison.Ordinal)
            || !string.Equals(entry.Architecture, "x64", StringComparison.Ordinal)
            || string.IsNullOrWhiteSpace(entry.Publisher)
            || entry.Format is not ("msix" or "msixbundle"))
        {
            throw new InvalidDataException(
                "Codex payload identity is inconsistent with the validated manifest.");
        }
    }

    private static PayloadEntry RequiredEntry(PayloadCatalog catalog, string id)
    {
        var matches = catalog.Entries
            .Where(entry => string.Equals(entry.Id, id, StringComparison.Ordinal))
            .ToArray();
        return matches.Length == 1
            ? matches[0]
            : throw new InvalidDataException(
                $"Validated payload catalog must contain exactly one {id} entry.");
    }
}

public sealed class PhysicalManagedApplicationPathPolicy
    : IManagedApplicationPathPolicy
{
    private readonly ManagedPathGuard _guard;

    public PhysicalManagedApplicationPathPolicy(
        ManagedPathGuard? guard = null) =>
        _guard = guard ?? new ManagedPathGuard();

    public Task<VerifiedManagedFileLease> VerifyPayloadAsync(
        string targetKey,
        string payloadRoot,
        PayloadEntry entry,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(targetKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadRoot);
        ArgumentNullException.ThrowIfNull(entry);
        var root = Path.GetFullPath(payloadRoot);
        var path = Path.GetFullPath(Path.Combine(
            root,
            entry.RelativePath
                .Replace('/', Path.DirectorySeparatorChar)
                .Replace('\\', Path.DirectorySeparatorChar)));
        return VerifyFileCoreAsync(
            targetKey,
            root,
            path,
            entry.Size,
            entry.Sha256,
            cancellationToken);
    }

    public Task<VerifiedManagedFileLease> VerifyFileAsync(
        string targetKey,
        string rootPath,
        string path,
        string? expectedSha256,
        CancellationToken cancellationToken) =>
        VerifyFileCoreAsync(
            targetKey,
            Path.GetFullPath(rootPath),
            Path.GetFullPath(path),
            expectedSize: null,
            expectedSha256,
            cancellationToken);

    public void ValidatePath(string targetKey, string rootPath, string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(targetKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _ = _guard.ValidateManagedPath(
            ManagedApplicationPathAliases.Normalize(rootPath),
            ManagedApplicationPathAliases.Normalize(path));
    }

    private async Task<VerifiedManagedFileLease> VerifyFileCoreAsync(
        string targetKey,
        string root,
        string path,
        long? expectedSize,
        string? expectedSha256,
        CancellationToken cancellationToken)
    {
        ValidatePath(targetKey, root, path);
        var file = new FileInfo(path);
        if (!file.Exists)
            throw new FileNotFoundException("Managed application file is missing.", path);

        var verified = _guard.OpenVerifiedRead(
            ManagedApplicationPathAliases.Normalize(root),
            ManagedApplicationPathAliases.Normalize(path));
        try
        {
            var stream = verified.Stream;
            var verifiedSize = stream.Length;
            if (expectedSize.HasValue && verifiedSize != expectedSize.Value)
            {
                throw new InvalidDataException(
                    $"Managed application file size mismatch: {targetKey}");
            }

            var digest = Convert.ToHexString(
                    await SHA256.HashDataAsync(stream, cancellationToken)
                        .ConfigureAwait(false))
                .ToLowerInvariant();
            if (expectedSha256 is not null
                && !CryptographicOperations.FixedTimeEquals(
                    Convert.FromHexString(digest),
                    Convert.FromHexString(expectedSha256)))
            {
                throw new InvalidDataException(
                    $"Managed application file SHA-256 mismatch: {targetKey}");
            }

            stream.Position = 0;
            return new VerifiedManagedFileLease(
                new VerifiedManagedFile(
                    targetKey,
                    root,
                    path,
                    verifiedSize,
                    digest),
                verified);
        }
        catch
        {
            await verified.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

}

internal static class ManagedApplicationPathAliases
{
    public static string Normalize(string path)
    {
        var fullPath = Path.GetFullPath(path);
        return !OperatingSystem.IsWindows()
               && (string.Equals(fullPath, "/var", StringComparison.Ordinal)
                   || fullPath.StartsWith("/var/", StringComparison.Ordinal))
            ? "/private" + fullPath
            : fullPath;
    }
}

public sealed class WindowsCodexPackageDeployment : ICodexPackageDeployment
{
    public Task<CodexPackageGraphSnapshot> CaptureSnapshotAsync(
        string packageFamilyName,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageFamilyName);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Codex package snapshotting requires Windows.");
        }

#if WINDOWS
        cancellationToken.ThrowIfCancellationRequested();
        var manager = new PackageManager();
        string? storageRoot = Path.Combine(
            PackageRollbackStorageRoot(),
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(storageRoot);
        var registrations = new Dictionary<string, CodexPackageRegistration>(
            StringComparer.Ordinal);
        try
        {
            foreach (var package in manager.FindPackagesForUser(
                         string.Empty,
                         packageFamilyName))
            {
                AddRegistration(package, isMainPackage: true);
                foreach (var dependency in package.Dependencies)
                    AddRegistration(dependency, isMainPackage: false);
            }

            if (registrations.Count == 0)
            {
                Directory.Delete(storageRoot, recursive: true);
                storageRoot = null;
            }

            return Task.FromResult(new CodexPackageGraphSnapshot(
                registrations.Values
                    .OrderByDescending(item => item.IsMainPackage)
                    .ThenBy(item => item.PackageFullName, StringComparer.Ordinal)
                    .ToArray(),
                storageRoot));
        }
        catch
        {
            if (Directory.Exists(storageRoot))
                Directory.Delete(storageRoot, recursive: true);
            throw;
        }

        void AddRegistration(Package package, bool isMainPackage)
        {
            if (registrations.ContainsKey(package.Id.FullName))
                return;
            cancellationToken.ThrowIfCancellationRequested();
            var packageStorage = Path.Combine(
                storageRoot!,
                registrations.Count.ToString("D4"));
            CopyPackageDirectory(
                package.InstalledLocation.Path,
                packageStorage,
                cancellationToken);
            var manifestPath = Path.Combine(
                packageStorage,
                "AppxManifest.xml");
            if (!File.Exists(manifestPath))
            {
                throw new InvalidDataException(
                    $"Codex rollback snapshot omitted {package.Id.FullName} manifest.");
            }

            registrations[package.Id.FullName] = new CodexPackageRegistration(
                package.Id.FullName,
                package.Id.FamilyName,
                manifestPath,
                isMainPackage);
        }
#else
        throw new PlatformNotSupportedException(
            "Use the Windows-targeted core asset for Codex package snapshotting.");
#endif
    }

    public Task ValidateSnapshotRestorableAsync(
        CodexPackageGraphSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        cancellationToken.ThrowIfCancellationRequested();
        if (snapshot.Registrations.Count == 0)
            return Task.CompletedTask;
        if (string.IsNullOrWhiteSpace(snapshot.StorageRoot)
            || !Directory.Exists(snapshot.StorageRoot))
        {
            throw new InvalidDataException(
                "Codex rollback package graph storage is missing.");
        }

        var storageRoot = Path.GetFullPath(snapshot.StorageRoot);
        foreach (var registration in snapshot.Registrations)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var manifest = Path.GetFullPath(registration.ManifestPath);
            EnsureUnderStorageRoot(storageRoot, manifest);
            using var stream = new FileStream(
                manifest,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read);
            if (stream.Length == 0)
            {
                throw new InvalidDataException(
                    "Codex rollback package manifest is empty.");
            }
        }

        return Task.CompletedTask;
    }

    public async Task AddPackageAsync(
        VerifiedManagedFileLease mainPackage,
        IReadOnlyList<VerifiedManagedFileLease> dependencyPackages,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(mainPackage);
        ArgumentNullException.ThrowIfNull(dependencyPackages);
        if (mainPackage.IsDisposed
            || dependencyPackages.Any(package => package.IsDisposed))
        {
            throw new ObjectDisposedException(
                nameof(mainPackage),
                "Codex payload verification leases must remain open during deployment.");
        }

        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Codex package deployment requires Windows.");
        }

#if WINDOWS
        cancellationToken.ThrowIfCancellationRequested();
        var mainPackageUri = LocalFileUri(mainPackage.FullPath);
        var dependencyPackageUris = dependencyPackages
            .Select(package => LocalFileUri(package.FullPath))
            .ToArray();
        var operation = new PackageManager().AddPackageAsync(
            mainPackageUri,
            dependencyPackageUris,
            DeploymentOptions.None);
        using var cancellationRegistration = cancellationToken.Register(
            operation.Cancel);
        var result = await operation;
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfCancelled(result.ExtendedErrorCode, cancellationToken);
        if (result.ExtendedErrorCode is { HResult: not 0 } deploymentError)
        {
            throw new InvalidDataException(
                $"Offline Codex package deployment failed: {result.ErrorText}",
                deploymentError);
        }
#else
        await Task.CompletedTask;
        throw new PlatformNotSupportedException(
            "Use the Windows-targeted core asset for Codex package deployment.");
#endif
    }

    public async Task RegisterPackageByManifestAsync(
        string mainManifestPath,
        IReadOnlyList<string> dependencyManifestPaths,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(mainManifestPath);
        ArgumentNullException.ThrowIfNull(dependencyManifestPaths);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Codex manifest registration requires Windows.");
        }

#if WINDOWS
        var paths = new[] { mainManifestPath }
            .Concat(dependencyManifestPaths)
            .Select(Path.GetFullPath)
            .ToArray();
        var verified = new List<ManagedVerifiedRead>(paths.Length);
        try
        {
            foreach (var path in paths)
            {
                var root = Path.GetDirectoryName(path)
                           ?? throw new InvalidDataException(
                               "Codex package manifest has no package root.");
                verified.Add(new ManagedPathGuard().OpenVerifiedRead(root, path));
            }

            cancellationToken.ThrowIfCancellationRequested();
            var operation = new PackageManager().RegisterPackageAsync(
                LocalFileUri(paths[0]),
                paths.Skip(1).Select(LocalFileUri).ToArray(),
                DeploymentOptions.ForceUpdateFromAnyVersion
                | DeploymentOptions.ForceApplicationShutdown);
            using var cancellationRegistration = cancellationToken.Register(
                operation.Cancel);
            var result = await operation;
            cancellationToken.ThrowIfCancellationRequested();
            ThrowIfCancelled(result.ExtendedErrorCode, cancellationToken);
            ThrowIfDeploymentFailed(result, "re-register package from snapshot manifest");
        }
        finally
        {
            for (var index = verified.Count - 1; index >= 0; index--)
                await verified[index].DisposeAsync().ConfigureAwait(false);
        }
#else
        await Task.CompletedTask;
        throw new PlatformNotSupportedException(
            "Use the Windows-targeted core asset for Codex manifest registration.");
#endif
    }

    public IReadOnlyList<CodexPackageInstallation> FindPackages(
        string packageFamilyName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageFamilyName);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Codex package inspection requires Windows.");
        }

#if WINDOWS
        var manager = new PackageManager();
        return manager.FindPackagesForUser(string.Empty, packageFamilyName)
            .Where(package => string.Equals(
                package.Id.FamilyName,
                packageFamilyName,
                StringComparison.Ordinal))
            .Select(ToInstallation)
            .ToArray();
#else
        throw new PlatformNotSupportedException(
            "Use the Windows-targeted core asset for Codex package inspection.");
#endif
    }

    public async Task RestoreSnapshotAsync(
        CodexPackageGraphSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Codex package rollback requires Windows.");
        }

#if WINDOWS
        await ValidateSnapshotRestorableAsync(snapshot, cancellationToken)
            .ConfigureAwait(false);
        var manager = new PackageManager();
        var expectedMain = snapshot.Registrations
            .Where(item => item.IsMainPackage)
            .ToArray();
        var expectedFullNames = expectedMain
            .Select(item => item.PackageFullName)
            .ToHashSet(StringComparer.Ordinal);
        var addedFullNames = manager.FindPackagesForUser(
                string.Empty,
                CodexInstaller.PackageFamilyName)
            .Where(package => !expectedFullNames.Contains(package.Id.FullName))
            .Select(package => package.Id.FullName)
            .ToHashSet(StringComparer.Ordinal);
        if (expectedMain.Length == 0)
        {
            foreach (var fullName in addedFullNames)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var result = await manager.RemovePackageAsync(fullName);
                cancellationToken.ThrowIfCancellationRequested();
                ThrowIfCancelled(result.ExtendedErrorCode, cancellationToken);
                ThrowIfDeploymentFailed(result, "remove package during rollback");
            }

            return;
        }

        var dependencyManifests = snapshot.Registrations
            .Where(item => !item.IsMainPackage)
            .Select(item => item.ManifestPath)
            .ToArray();
        foreach (var registration in expectedMain)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await RegisterPackageByManifestAsync(
                    registration.ManifestPath,
                    dependencyManifests,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        var restoredFullNames = manager.FindPackagesForUser(
                string.Empty,
                CodexInstaller.PackageFamilyName)
            .Select(package => package.Id.FullName)
            .ToHashSet(StringComparer.Ordinal);
        if (!expectedFullNames.IsSubsetOf(restoredFullNames))
        {
            throw new InvalidDataException(
                "Codex rollback manifest registration did not restore the old package graph.");
        }

        foreach (var fullName in addedFullNames
                     .Where(restoredFullNames.Contains))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = await manager.RemovePackageAsync(fullName);
            cancellationToken.ThrowIfCancellationRequested();
            ThrowIfCancelled(result.ExtendedErrorCode, cancellationToken);
            ThrowIfDeploymentFailed(result, "remove added package after rollback registration");
        }
#else
        await Task.CompletedTask;
        throw new PlatformNotSupportedException(
            "Use the Windows-targeted core asset for Codex package rollback.");
#endif
    }

    public Task<bool> DiscardSnapshotAsync(
        CodexPackageGraphSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(snapshot.StorageRoot))
            return Task.FromResult(true);
        try
        {
            var storageRoot = Path.GetFullPath(snapshot.StorageRoot);
            EnsureUnderStorageRoot(PackageRollbackStorageRoot(), storageRoot);
            if (Directory.Exists(storageRoot))
                Directory.Delete(storageRoot, recursive: true);
            return Task.FromResult(true);
        }
        catch
        {
            return Task.FromResult(false);
        }
    }

#if WINDOWS
    private static CodexPackageInstallation ToInstallation(Package package)
    {
        var version = package.Id.Version;
        return new CodexPackageInstallation(
            package.Id.FamilyName,
            $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}",
            package.Id.Architecture switch
            {
                ProcessorArchitecture.Neutral => CodexPackageArchitecture.Neutral,
                ProcessorArchitecture.X86 => CodexPackageArchitecture.X86,
                ProcessorArchitecture.X64 => CodexPackageArchitecture.X64,
                ProcessorArchitecture.Arm => CodexPackageArchitecture.Arm,
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
            FindCli(package.InstalledLocation.Path),
            package.InstalledLocation.Path);
    }

    private static string? FindCli(string installRoot)
    {
        if (string.IsNullOrWhiteSpace(installRoot) || !Directory.Exists(installRoot))
            return null;
        foreach (var name in new[] { "codex.exe", "Codex.exe" })
        {
            var direct = Path.Combine(installRoot, name);
            if (File.Exists(direct))
                return direct;
        }

        try
        {
            return Directory.EnumerateFiles(
                    installRoot,
                    "*.exe",
                    SearchOption.AllDirectories)
                .FirstOrDefault(path => string.Equals(
                    Path.GetFileName(path),
                    "codex.exe",
                    StringComparison.OrdinalIgnoreCase));
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }
#endif

#if WINDOWS
    private static void ThrowIfDeploymentFailed(
        DeploymentResult result,
        string operation)
    {
        if (result.ExtendedErrorCode is { HResult: not 0 } error)
        {
            throw new InvalidDataException(
                $"Failed to {operation}: {result.ErrorText}",
                error);
        }
    }

    private static void ThrowIfCancelled(
        Exception? deploymentError,
        CancellationToken cancellationToken)
    {
        if (deploymentError is null)
            return;
        var hResult = deploymentError.HResult;
        if (hResult is unchecked((int)0x80004004)
            or unchecked((int)0x800704C7)
            or unchecked((int)0x800703E3))
        {
            throw new OperationCanceledException(
                "Windows package deployment was cancelled.",
                deploymentError,
                cancellationToken);
        }
    }
#endif

    private static string PackageRollbackStorageRoot() =>
        Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            "CodexKit",
            "package-rollback");

#if WINDOWS
    private static void CopyPackageDirectory(
        string sourceRoot,
        string destinationRoot,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(destinationRoot);
        foreach (var directory in Directory.EnumerateDirectories(
                     sourceRoot,
                     "*",
                     SearchOption.AllDirectories))
        {
            cancellationToken.ThrowIfCancellationRequested();
            Directory.CreateDirectory(Path.Combine(
                destinationRoot,
                Path.GetRelativePath(sourceRoot, directory)));
        }

        foreach (var file in Directory.EnumerateFiles(
                     sourceRoot,
                     "*",
                     SearchOption.AllDirectories))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var destination = Path.Combine(
                destinationRoot,
                Path.GetRelativePath(sourceRoot, file));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file, destination, overwrite: false);
        }
    }
#endif

    private static void EnsureUnderStorageRoot(
        string storageRoot,
        string path)
    {
        var root = Path.TrimEndingDirectorySeparator(
            Path.GetFullPath(storageRoot));
        var candidate = Path.GetFullPath(path);
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (!candidate.StartsWith(
                root + Path.DirectorySeparatorChar,
                comparison))
        {
            throw new UnauthorizedAccessException(
                "Codex package snapshot path escapes rollback storage.");
        }
    }

    private static Uri LocalFileUri(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
            throw new FileNotFoundException("Offline package is missing.", fullPath);
        var uri = new Uri(fullPath);
        if (!uri.IsFile)
            throw new InvalidDataException("Only local offline package files are allowed.");
        return uri;
    }
}

public sealed class WinVerifyTrustAuthenticodeVerifier : IAuthenticodeVerifier
{
    private const uint WTD_UI_NONE = 2;
    private const uint WTD_REVOKE_NONE = 0;
    private const uint WTD_CHOICE_FILE = 1;
    private const uint WTD_STATEACTION_IGNORE = 0;
    private const uint WTD_REVOCATION_CHECK_NONE = 0x00000010;
    private const uint WTD_CACHE_ONLY_URL_RETRIEVAL = 0x00001000;
    private const int ERROR_SUCCESS = 0;

    private static readonly Guid WinTrustActionGenericVerifyV2 =
        new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    public bool IsTrusted(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "WinVerifyTrust is only available on Windows.");
        }

        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
            return false;

        var filePath = Marshal.StringToCoTaskMemUni(fullPath);
        var fileInfoPointer = IntPtr.Zero;
        var trustDataPointer = IntPtr.Zero;
        try
        {
            var fileInfo = new WinTrustFileInfo
            {
                StructureSize = (uint)Marshal.SizeOf<WinTrustFileInfo>(),
                FilePath = filePath
            };
            fileInfoPointer = Marshal.AllocCoTaskMem(
                Marshal.SizeOf<WinTrustFileInfo>());
            Marshal.StructureToPtr(fileInfo, fileInfoPointer, fDeleteOld: false);

            var trustData = new WinTrustData
            {
                StructureSize = (uint)Marshal.SizeOf<WinTrustData>(),
                UiChoice = WTD_UI_NONE,
                RevocationChecks = WTD_REVOKE_NONE,
                UnionChoice = WTD_CHOICE_FILE,
                FileInfo = fileInfoPointer,
                StateAction = WTD_STATEACTION_IGNORE,
                ProviderFlags =
                    WTD_REVOCATION_CHECK_NONE | WTD_CACHE_ONLY_URL_RETRIEVAL
            };
            trustDataPointer = Marshal.AllocCoTaskMem(
                Marshal.SizeOf<WinTrustData>());
            Marshal.StructureToPtr(trustData, trustDataPointer, fDeleteOld: false);

            return WinVerifyTrust(
                       new IntPtr(-1),
                       WinTrustActionGenericVerifyV2,
                       trustDataPointer)
                   == ERROR_SUCCESS;
        }
        finally
        {
            if (trustDataPointer != IntPtr.Zero)
                Marshal.FreeCoTaskMem(trustDataPointer);
            if (fileInfoPointer != IntPtr.Zero)
                Marshal.FreeCoTaskMem(fileInfoPointer);
            Marshal.FreeCoTaskMem(filePath);
        }
    }

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(
        IntPtr windowHandle,
        [MarshalAs(UnmanagedType.LPStruct)] Guid actionId,
        IntPtr trustData);

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustFileInfo
    {
        public uint StructureSize;
        public IntPtr FilePath;
        public IntPtr FileHandle;
        public IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustData
    {
        public uint StructureSize;
        public IntPtr PolicyCallbackData;
        public IntPtr SipClientData;
        public uint UiChoice;
        public uint RevocationChecks;
        public uint UnionChoice;
        public IntPtr FileInfo;
        public uint StateAction;
        public IntPtr StateData;
        public IntPtr UrlReference;
        public uint ProviderFlags;
        public uint UiContext;
        public IntPtr SignatureSettings;
    }
}
