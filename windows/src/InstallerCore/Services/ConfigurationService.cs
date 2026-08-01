using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace CodexOneClickInstaller;

public sealed record WindowsConfigurationPaths(
    string UserProfile,
    string AppData,
    string LocalAppData,
    string CodexConfig,
    string CodexAuth,
    string CodexPlusSettings,
    string UserScriptsConfig,
    string UserScriptsDirectory,
    string OfflineMarketplaces,
    string PluginCache,
    string InstallExpectation,
    string TransactionsRoot)
{
    public IReadOnlyList<string> ConfigurationFiles =>
    [
        CodexConfig,
        CodexAuth,
        CodexPlusSettings,
        InstallExpectation
    ];

    public string ConfigurationTransactionsRoot =>
        Path.Combine(TransactionsRoot, "config");

    public string PluginTransactionsRoot =>
        Path.Combine(TransactionsRoot, "plugins");

    public string ScriptTransactionsRoot =>
        Path.Combine(TransactionsRoot, "scripts");

    public static WindowsConfigurationPaths Create(
        string userProfile,
        string appData,
        string localAppData)
    {
        userProfile = CanonicalizeExistingAncestors(userProfile);
        appData = CanonicalizeExistingAncestors(appData);
        localAppData = CanonicalizeExistingAncestors(localAppData);
        var installerData = Path.Combine(
            localAppData,
            "Codex One Click Installer");
        return new WindowsConfigurationPaths(
            userProfile,
            appData,
            localAppData,
            Path.Combine(userProfile, ".codex", "config.toml"),
            Path.Combine(userProfile, ".codex", "auth.json"),
            Path.Combine(userProfile, ".codex-session-delete", "settings.json"),
            Path.Combine(appData, "Codex++", "user_scripts.json"),
            Path.Combine(appData, "Codex++", "user_scripts"),
            Path.Combine(userProfile, ".codex", "offline-marketplaces"),
            Path.Combine(userProfile, ".codex", "plugins", "cache"),
            Path.Combine(installerData, "install-expectation.json"),
            Path.Combine(installerData, "transactions"));
    }

    public static WindowsConfigurationPaths CurrentUser() =>
        Create(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));

    private static string CanonicalizeExistingAncestors(string path)
    {
        var full = Path.GetFullPath(path);
        if (OperatingSystem.IsWindows())
            return full;
        var root = Path.GetPathRoot(full)
                   ?? throw new ArgumentException(
                       "Path has no filesystem root.",
                       nameof(path));
        var current = root;
        var components = full[root.Length..]
            .Split(
                Path.DirectorySeparatorChar,
                StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index < components.Length; index++)
        {
            var candidate = Path.Combine(current, components[index]);
            if (Directory.Exists(candidate)
                && (File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0)
            {
                var resolved = new DirectoryInfo(candidate)
                    .ResolveLinkTarget(returnFinalTarget: true);
                if (resolved is not null)
                    candidate = resolved.FullName;
            }
            current = candidate;
        }
        return Path.GetFullPath(current);
    }
}

public interface ISecretFileAclPolicy
{
    void PrepareForPublish(string temporaryPath, string finalPath);

    bool IsCompliant(string path);
}

public sealed class WindowsSecretFileAclPolicy : ISecretFileAclPolicy
{
    public static IReadOnlyList<string> ExpectedTrustees { get; } =
        Array.AsReadOnly(["CURRENT_USER", "S-1-5-18", "S-1-5-32-544"]);

    public static bool ProtectsDacl => true;

    public void PrepareForPublish(string temporaryPath, string finalPath)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException(
                "Windows file ACLs can only be applied on Windows.");
#if WINDOWS
        var user = WindowsIdentity.GetCurrent().User
                   ?? throw new UnauthorizedAccessException(
                       "The current Windows user SID is unavailable.");
        ApplySecurity(temporaryPath, user);
        // ReplaceFile can retain destination metadata. Tighten the old
        // destination before publishing new bytes so either metadata outcome
        // remains private throughout the atomic replacement.
        if (File.Exists(finalPath))
            ApplySecurity(finalPath, user);
#endif
    }

#if WINDOWS
    private static void ApplySecurity(
        string path,
        SecurityIdentifier user)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in Trustees(user))
        {
            security.AddAccessRule(new FileSystemAccessRule(
                sid,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
        }
        new FileInfo(path).SetAccessControl(security);
    }
#endif

    public bool IsCompliant(string path)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException(
                "Windows file ACLs can only be verified on Windows.");
#if WINDOWS
        var user = WindowsIdentity.GetCurrent().User;
        if (user is null)
            return false;
        var expected = Trustees(user)
            .Select(sid => sid.Value)
            .ToHashSet(StringComparer.Ordinal);
        var security = new FileInfo(path).GetAccessControl(
            AccessControlSections.Access);
        if (!security.AreAccessRulesProtected)
            return false;
        var actual = new HashSet<string>(StringComparer.Ordinal);
        foreach (FileSystemAccessRule rule in security.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: false,
                     typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow
                || (rule.FileSystemRights & FileSystemRights.FullControl)
                    != FileSystemRights.FullControl
                || rule.IdentityReference is not SecurityIdentifier sid)
            {
                return false;
            }
            actual.Add(sid.Value);
        }
        return actual.SetEquals(expected);
#else
        return false;
#endif
    }

#if WINDOWS
    private static SecurityIdentifier[] Trustees(SecurityIdentifier user) =>
    [
        user,
        new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)
    ];
#endif
}

public sealed record ConfigurationApplyResult(
    string ManagedProviderId,
    TransactionResult Transaction);

public sealed class ConfigurationService
{
    private const string ConfigKey = "configuration.codex-config";
    private const string AuthKey = "configuration.codex-auth";
    private const string SettingsKey = "configuration.codex-plus-settings";
    private const string ExpectationKey = "configuration.expectation";

    private readonly WindowsConfigurationPaths paths;
    private readonly ISecretFileAclPolicy aclPolicy;
    private readonly TransactionService transaction;

    public ConfigurationService(
        WindowsConfigurationPaths paths,
        string? transactionsRoot = null,
        ISecretFileAclPolicy? aclPolicy = null,
        ITransactionFileSystem? fileSystem = null)
    {
        this.paths = paths ?? throw new ArgumentNullException(nameof(paths));
        this.aclPolicy = aclPolicy ?? new WindowsSecretFileAclPolicy();
        EnsureRoots();
        var atomic = new AtomicConfigurationFileSystem(
            fileSystem ?? new PhysicalTransactionFileSystem(),
            this.aclPolicy,
            _ => true);
        transaction = new TransactionService(
            Path.Combine(
                transactionsRoot ?? paths.TransactionsRoot,
                "config"),
            new ManagedTargetCatalog(
            [
                new(ConfigKey, paths.UserProfile, paths.CodexConfig),
                new(AuthKey, paths.UserProfile, paths.CodexAuth),
                new(SettingsKey, paths.UserProfile, paths.CodexPlusSettings),
                new(ExpectationKey, paths.LocalAppData, paths.InstallExpectation)
            ]),
            atomic);
    }

    public async Task<ConfigurationApplyResult> ApplyAsync(
        InstallRequest request,
        IReadOnlyList<ModelDefinition> catalog,
        CancellationToken cancellationToken = default)
    {
        await transaction.RecoverIncompleteAsync(cancellationToken)
            .ConfigureAwait(false);
        ValidateRequest(request, catalog);
        var existingConfig = ReadText(paths.CodexConfig);
        var config = InstallerConfig.GenerateConfigToml(
            request,
            existingConfig ?? string.Empty);
        var auth = InstallerConfig.GenerateAuthJson(
            request,
            ReadText(paths.CodexAuth));
        var settings = InstallerConfig.GenerateCodexPlusSettings(
            request,
            catalog,
            config,
            Encoding.UTF8.GetString(auth),
            ReadText(paths.CodexPlusSettings));
        var expectation = InstallerConfig.GenerateExpectation(request);
        var changes = new[]
        {
            TransactionChange.ReplaceFile(ConfigKey, Encoding.UTF8.GetBytes(config)),
            TransactionChange.ReplaceFile(AuthKey, auth),
            TransactionChange.ReplaceFile(SettingsKey, settings),
            TransactionChange.ReplaceFile(ExpectationKey, expectation)
        };

        var result = await transaction.ExecuteAsync(
                changes,
                ignoredCancellationToken =>
                {
                    new VerificationService(aclPolicy)
                        .VerifyConfiguration(paths, request, catalog);
                    return Task.CompletedTask;
                },
                cancellationToken)
            .ConfigureAwait(false);
        return new ConfigurationApplyResult(
            InstallerConfig.Provider(request.Provider).ManagedProviderId,
            result);
    }

    public Task<IReadOnlyList<Guid>> RecoverIncompleteAsync(
        CancellationToken cancellationToken = default) =>
        transaction.RecoverIncompleteAsync(cancellationToken);

    private void EnsureRoots()
    {
        Directory.CreateDirectory(paths.UserProfile);
        Directory.CreateDirectory(paths.AppData);
        Directory.CreateDirectory(paths.LocalAppData);
        foreach (var file in paths.ConfigurationFiles)
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
    }

    private static void ValidateRequest(
        InstallRequest request,
        IReadOnlyList<ModelDefinition> catalog)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(catalog);
        _ = InstallerConfig.NormalizedKey(request);
        if (!InstallerConfig.IsLegalModelId(request.DefaultModel)
            || request.AvailableModels.Count == 0
            || request.AvailableModels.Any(model =>
                !InstallerConfig.IsLegalModelId(model))
            || request.AvailableModels.Distinct(StringComparer.Ordinal).Count()
                != request.AvailableModels.Count
            || !request.AvailableModels.Contains(
                request.DefaultModel,
                StringComparer.Ordinal))
        {
            throw new InvalidDataException("Install request model selection is invalid.");
        }
        var catalogIds = catalog
            .Select(model => model.Id)
            .ToHashSet(StringComparer.Ordinal);
        if (!request.AvailableModels.All(catalogIds.Contains))
        {
            throw new InvalidDataException(
                "Install request models do not match the resolved catalog.");
        }
    }

    private static string? ReadText(string path) =>
        File.Exists(path) ? File.ReadAllText(path) : null;
}

internal sealed class AtomicConfigurationFileSystem : ITransactionFileSystem
{
    private readonly ITransactionFileSystem inner;
    private readonly ISecretFileAclPolicy? aclPolicy;
    private readonly Func<string, bool> protectTarget;

    public AtomicConfigurationFileSystem(
        ITransactionFileSystem? inner = null,
        ISecretFileAclPolicy? aclPolicy = null,
        Func<string, bool>? protectTarget = null)
    {
        this.inner = inner ?? new PhysicalTransactionFileSystem();
        this.aclPolicy = aclPolicy;
        this.protectTarget = protectTarget ?? (_ => false);
    }

    public bool Exists(string rootPath, string path) =>
        inner.Exists(rootPath, path);

    public bool HasReparsePoint(string rootPath, string targetPath) =>
        inner.HasReparsePoint(rootPath, targetPath);

    public Task<FileBackupMetadata> BackupAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        CancellationToken cancellationToken) =>
        inner.BackupAsync(
            targetRootPath,
            targetPath,
            backupRootPath,
            backupPath,
            cancellationToken);

    public async Task ReplaceFileAsync(
        string rootPath,
        string targetPath,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureSafe(rootPath, targetPath);
        var parent = Path.GetDirectoryName(targetPath)
                     ?? throw new UnauthorizedAccessException(
                         "Configuration path has no parent.");
        Directory.CreateDirectory(parent);
        EnsureSafe(rootPath, targetPath);
        var temporary = Path.Combine(
            parent,
            $".codex-one-click-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                             temporary,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             bufferSize: 81920,
                             FileOptions.WriteThrough))
            {
                await stream.WriteAsync(content, cancellationToken)
                    .ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            if (protectTarget(targetPath))
                aclPolicy?.PrepareForPublish(temporary, targetPath);
            EnsureSafe(rootPath, targetPath);
            if (File.Exists(targetPath))
                File.Replace(temporary, targetPath, null, ignoreMetadataErrors: false);
            else
                File.Move(temporary, targetPath);
        }
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }

    private void EnsureSafe(string rootPath, string targetPath)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        var target = Path.GetFullPath(targetPath);
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (!target.StartsWith(
                root + Path.DirectorySeparatorChar,
                comparison))
        {
            throw new UnauthorizedAccessException(
                "Configuration path is outside its managed root.");
        }
        var volumeRoot = Path.GetPathRoot(target)
                         ?? throw new UnauthorizedAccessException(
                             "Configuration path has no volume root.");
        if (inner.HasReparsePoint(volumeRoot, target))
        {
            throw new UnauthorizedAccessException(
                "Configuration path traverses a reparse point.");
        }
    }

    public Task<string> ComputeSha256Async(
        string rootPath,
        string path,
        CancellationToken cancellationToken) =>
        inner.ComputeSha256Async(rootPath, path, cancellationToken);

    public Task RestoreAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        FileBackupMetadata metadata,
        string expectedSha256,
        CancellationToken cancellationToken) =>
        inner.RestoreAsync(
            targetRootPath,
            targetPath,
            backupRootPath,
            backupPath,
            metadata,
            expectedSha256,
            cancellationToken);

    public Task DeleteIfExistsAsync(
        string rootPath,
        string targetPath,
        CancellationToken cancellationToken) =>
        inner.DeleteIfExistsAsync(rootPath, targetPath, cancellationToken);
}
