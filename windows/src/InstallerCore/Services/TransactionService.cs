using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
#if WINDOWS
using Microsoft.Win32.SafeHandles;
#endif

namespace CodexOneClickInstaller;

public enum TransactionState
{
    Planned,
    Staged,
    Applying,
    Verifying,
    Committed,
    RollingBack,
    RolledBack
}

public sealed record TransactionResult(Guid TransactionId, TransactionState State);

public sealed record TransactionChange
{
    private TransactionChange(string targetKey, byte[] content)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(targetKey);
        ArgumentNullException.ThrowIfNull(content);
        TargetKey = targetKey;
        Content = content.ToArray();
    }

    public string TargetKey { get; }

    public byte[] Content { get; }

    public static TransactionChange ReplaceFile(
        string targetKey,
        ReadOnlySpan<byte> content) =>
        new(targetKey, content.ToArray());
}

public sealed record ManagedTargetDefinition(
    string TargetKey,
    string RootPath,
    string TargetPath,
    bool AllowWindowsApps = false);

public sealed class ManagedTargetCatalog
{
    private readonly IReadOnlyDictionary<string, ManagedTargetDefinition> _targets;

    public ManagedTargetCatalog(IEnumerable<ManagedTargetDefinition> targets)
    {
        ArgumentNullException.ThrowIfNull(targets);
        var mapped = new Dictionary<string, ManagedTargetDefinition>(StringComparer.Ordinal);
        foreach (var target in targets)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(target.TargetKey);
            ArgumentException.ThrowIfNullOrWhiteSpace(target.RootPath);
            ArgumentException.ThrowIfNullOrWhiteSpace(target.TargetPath);
            if (!mapped.TryAdd(target.TargetKey, target))
                throw new ArgumentException($"Duplicate managed target key '{target.TargetKey}'.", nameof(targets));
        }

        _targets = mapped;
    }

    public ManagedTargetDefinition Resolve(string targetKey) =>
        _targets.TryGetValue(targetKey, out var target)
            ? target
            : throw new KeyNotFoundException($"Unknown managed target key '{targetKey}'.");
}

public sealed record FileBackupMetadata(
    bool Existed,
    long Attributes,
    DateTime? CreationTimeUtc,
    DateTime? LastWriteTimeUtc,
    DateTime? LastAccessTimeUtc,
    string? SecurityDescriptor)
{
    public static FileBackupMetadata Missing { get; } =
        new(false, 0, null, null, null, null);
}

public interface ITransactionFileSystem
{
    bool Exists(string rootPath, string path);

    bool HasReparsePoint(string rootPath, string targetPath);

    Task<FileBackupMetadata> BackupAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        CancellationToken cancellationToken);

    Task ReplaceFileAsync(
        string rootPath,
        string targetPath,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken);

    Task<string> ComputeSha256Async(
        string rootPath,
        string path,
        CancellationToken cancellationToken);

    Task RestoreAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        FileBackupMetadata metadata,
        string expectedSha256,
        CancellationToken cancellationToken);

    Task DeleteIfExistsAsync(
        string rootPath,
        string targetPath,
        CancellationToken cancellationToken);
}

public sealed class TransactionService
{
    private const string JournalFileName = "journal.jsonl";
    private const string StateFileName = "state.json";
    private const string StateHistoryFileName = "state-history.jsonl";

    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();
    private readonly string _transactionsRoot;
    private readonly ManagedTargetCatalog _catalog;
    private readonly ITransactionFileSystem _fileSystem;
    private readonly ManagedPathGuard _pathGuard;

    public TransactionService(
        string transactionsRoot,
        ManagedTargetCatalog catalog,
        ITransactionFileSystem? fileSystem = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(transactionsRoot);
        _transactionsRoot = Path.GetFullPath(transactionsRoot);
        _catalog = catalog ?? throw new ArgumentNullException(nameof(catalog));
        _fileSystem = fileSystem ?? new PhysicalTransactionFileSystem();
        _pathGuard = new ManagedPathGuard(_fileSystem);
    }

    public static string GetDefaultTransactionsRoot() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Codex One Click Installer",
            "transactions");

    public async Task<TransactionResult> ExecuteAsync(
        IReadOnlyList<TransactionChange> changes,
        Func<CancellationToken, Task>? verifyAsync = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(changes);
        if (changes.Count == 0)
            throw new ArgumentException("At least one transaction change is required.", nameof(changes));

        var resolved = ResolveAndValidateChanges(changes);
        ValidateTransactionStoragePath(_transactionsRoot);
        var transactionId = Guid.NewGuid();
        var transactionDirectory = Path.Combine(
            _transactionsRoot,
            transactionId.ToString("N"));
        Directory.CreateDirectory(Path.Combine(transactionDirectory, "backups"));
        ValidateTransactionStoragePath(transactionDirectory);
        ValidateTransactionStoragePath(Path.Combine(transactionDirectory, "backups"));

        var state = (TransactionState?)null;
        var journalEntries = new List<TransactionJournalEntry>(changes.Count);
        try
        {
            Transition(transactionDirectory, ref state, TransactionState.Planned);
            for (var index = 0; index < resolved.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var item = resolved[index];
                ValidateTarget(item.Target);
                var sequence = index + 1;
                var relativeBackup = $"backups/{sequence:D4}";
                var backupPath = ResolveBackupPath(transactionDirectory, relativeBackup);
                ValidateTransactionStoragePath(backupPath);
                var metadata = await _fileSystem.BackupAsync(
                    item.Target.RootPath,
                    item.Target.TargetPath,
                    transactionDirectory,
                    backupPath,
                    cancellationToken).ConfigureAwait(false);
                ValidateTransactionStoragePath(backupPath);
                var beforeSha256 = metadata.Existed
                    ? await _fileSystem.ComputeSha256Async(
                            transactionDirectory,
                            backupPath,
                            cancellationToken)
                        .ConfigureAwait(false)
                    : null;
                if (metadata.Existed && !IsCanonicalSha256(beforeSha256))
                    throw new InvalidDataException("Backup filesystem returned an invalid SHA-256.");
                var entry = new TransactionJournalEntry(
                    sequence,
                    "replaceFile",
                    item.Change.TargetKey,
                    relativeBackup,
                    beforeSha256,
                    Completed: false,
                    metadata);
                ValidateTransactionStoragePath(
                    Path.Combine(transactionDirectory, JournalFileName));
                AppendDurable(
                    Path.Combine(transactionDirectory, JournalFileName),
                    entry);
                journalEntries.Add(entry);
            }

            Transition(transactionDirectory, ref state, TransactionState.Staged);
            Transition(transactionDirectory, ref state, TransactionState.Applying);
            for (var index = 0; index < resolved.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var item = resolved[index];
                ValidateTarget(item.Target);
                await _fileSystem.ReplaceFileAsync(
                    item.Target.RootPath,
                    item.Target.TargetPath,
                    item.Change.Content,
                    cancellationToken).ConfigureAwait(false);
                journalEntries[index] = journalEntries[index] with { Completed = true };
                ValidateTransactionStoragePath(
                    Path.Combine(transactionDirectory, JournalFileName));
                AppendDurable(
                    Path.Combine(transactionDirectory, JournalFileName),
                    journalEntries[index]);
            }

            Transition(transactionDirectory, ref state, TransactionState.Verifying);
            if (verifyAsync is not null)
                await verifyAsync(cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            Transition(transactionDirectory, ref state, TransactionState.Committed);
            return new TransactionResult(transactionId, TransactionState.Committed);
        }
        catch (Exception error)
        {
            try
            {
                await RollBackAsync(
                    transactionDirectory,
                    journalEntries,
                    state,
                    CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception rollbackError)
            {
                throw new AggregateException(
                    "The transaction failed and rollback did not complete.",
                    error,
                    rollbackError);
            }

            ExceptionDispatchInfo.Capture(error).Throw();
            throw;
        }
    }

    public async Task<IReadOnlyList<Guid>> RecoverIncompleteAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(_transactionsRoot))
            return [];

        ValidateTransactionStoragePath(_transactionsRoot);
        var recovered = new List<Guid>();
        foreach (var directory in Directory.EnumerateDirectories(_transactionsRoot)
                     .OrderBy(path => path, StringComparer.Ordinal))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Guid.TryParseExact(Path.GetFileName(directory), "N", out var transactionId))
                continue;
            ValidateTransactionStoragePath(directory);
            TransactionState? state = ReadState(directory);
            if (state is not (TransactionState.Applying
                or TransactionState.Verifying
                or TransactionState.RollingBack))
            {
                continue;
            }

            var entries = ReadJournal(directory);
            await RollBackAsync(
                directory,
                entries,
                state,
                CancellationToken.None).ConfigureAwait(false);
            recovered.Add(transactionId);
        }

        return recovered.AsReadOnly();
    }

    private IReadOnlyList<ResolvedChange> ResolveAndValidateChanges(
        IReadOnlyList<TransactionChange> changes)
    {
        var resolved = new List<ResolvedChange>(changes.Count);
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var change in changes)
        {
            ArgumentNullException.ThrowIfNull(change);
            if (!keys.Add(change.TargetKey))
            {
                throw new ArgumentException(
                    $"Managed target '{change.TargetKey}' occurs more than once.",
                    nameof(changes));
            }

            var target = _catalog.Resolve(change.TargetKey);
            ValidateTarget(target);
            resolved.Add(new ResolvedChange(change, target));
        }

        return resolved;
    }

    private void ValidateTarget(ManagedTargetDefinition target)
    {
        var path = _pathGuard.ValidateManagedPath(
            target.RootPath,
            target.TargetPath);

        if (!target.AllowWindowsApps && ContainsWindowsAppsSegment(path))
        {
            throw new UnauthorizedAccessException(
                $"Managed target '{target.TargetKey}' requires WindowsApps authorization.");
        }

    }

    private async Task RollBackAsync(
        string transactionDirectory,
        IReadOnlyList<TransactionJournalEntry> entries,
        TransactionState? currentState,
        CancellationToken cancellationToken)
    {
        var rollbackEntries = entries
            .GroupBy(item => item.Sequence)
            .Select(group => group.Last())
            .OrderByDescending(item => item.Sequence)
            .ToArray();
        foreach (var entry in rollbackEntries)
        {
            await ValidateRollbackEntryAsync(
                transactionDirectory,
                entry,
                cancellationToken).ConfigureAwait(false);
        }

        TransactionState? state = currentState ?? ReadState(transactionDirectory);
        if (state != TransactionState.RollingBack)
            Transition(transactionDirectory, ref state, TransactionState.RollingBack);

        foreach (var entry in rollbackEntries)
        {
            var target = _catalog.Resolve(entry.TargetKey);
            ValidateTarget(target);
            var backupPath = ResolveBackupPath(transactionDirectory, entry.Backup);
            if (entry.BackupMetadata.Existed)
            {
                ValidateTransactionStoragePath(backupPath);
                await _fileSystem.RestoreAsync(
                    target.RootPath,
                    target.TargetPath,
                    transactionDirectory,
                    backupPath,
                    entry.BackupMetadata,
                    entry.BeforeSha256!,
                    cancellationToken).ConfigureAwait(false);
            }
            else
            {
                await _fileSystem.DeleteIfExistsAsync(
                    target.RootPath,
                    target.TargetPath,
                    cancellationToken).ConfigureAwait(false);
            }
        }

        Transition(transactionDirectory, ref state, TransactionState.RolledBack);
    }

    private async Task ValidateRollbackEntryAsync(
        string transactionDirectory,
        TransactionJournalEntry entry,
        CancellationToken cancellationToken)
    {
        if (entry.Sequence <= 0)
            throw new InvalidDataException("Journal sequence must be positive.");
        if (!string.Equals(entry.Action, "replaceFile", StringComparison.Ordinal))
            throw new InvalidDataException($"Unsupported journal action '{entry.Action}'.");
        if (string.IsNullOrWhiteSpace(entry.TargetKey))
            throw new InvalidDataException("Journal target key is missing.");
        var expectedBackup = $"backups/{entry.Sequence:D4}";
        if (!string.Equals(entry.Backup, expectedBackup, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Journal backup '{entry.Backup}' does not match sequence {entry.Sequence}.");
        }

        var target = _catalog.Resolve(entry.TargetKey);
        ValidateTarget(target);
        var backupPath = ResolveBackupPath(transactionDirectory, entry.Backup);
        ValidateTransactionStoragePath(backupPath);
        if (entry.BackupMetadata.Existed)
        {
            if (!IsCanonicalSha256(entry.BeforeSha256))
                throw new InvalidDataException("Journal beforeSha256 is missing or malformed.");
            if (!_fileSystem.Exists(transactionDirectory, backupPath))
                throw new InvalidDataException("Transaction backup file is missing.");
            var actualSha256 = await _fileSystem.ComputeSha256Async(
                    transactionDirectory,
                    backupPath,
                    cancellationToken)
                .ConfigureAwait(false);
            if (!Sha256Equals(entry.BeforeSha256!, actualSha256))
                throw new InvalidDataException("Transaction backup hash does not match the journal.");
        }
        else
        {
            if (entry.BeforeSha256 is not null)
                throw new InvalidDataException("Missing-file journal entry cannot have a backup hash.");
            if (_fileSystem.Exists(transactionDirectory, backupPath))
                throw new InvalidDataException("Unexpected backup exists for a new-file journal entry.");
        }
    }

    private static bool ContainsWindowsAppsSegment(string path) =>
        path.Split(
                [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar, '\\', '/'],
                StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => string.Equals(
                segment,
                "WindowsApps",
                StringComparison.OrdinalIgnoreCase));

    private static string ResolveBackupPath(
        string transactionDirectory,
        string relativeBackup)
    {
        if (string.IsNullOrWhiteSpace(relativeBackup) || Path.IsPathRooted(relativeBackup))
            throw new InvalidDataException("Journal backup path must be relative.");
        var backupRoot = Path.GetFullPath(Path.Combine(transactionDirectory, "backups"));
        var candidate = Path.GetFullPath(Path.Combine(
            transactionDirectory,
            relativeBackup.Replace('/', Path.DirectorySeparatorChar)));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        var rootWithSeparator = Path.TrimEndingDirectorySeparator(backupRoot)
                                + Path.DirectorySeparatorChar;
        if (!candidate.StartsWith(rootWithSeparator, comparison))
            throw new InvalidDataException("Journal backup path escapes the transaction.");
        return candidate;
    }

    private void ValidateTransactionStoragePath(string path)
    {
        _ = _pathGuard.ValidateManagedPath(
            _transactionsRoot,
            path,
            allowRoot: true);
    }

    private static bool IsCanonicalSha256(string? value) =>
        value is { Length: 64 }
        && value.All(character =>
            character is >= '0' and <= '9'
            or >= 'a' and <= 'f');

    private static bool Sha256Equals(string expected, string actual)
    {
        if (!IsCanonicalSha256(actual))
            return false;
        return CryptographicOperations.FixedTimeEquals(
            Convert.FromHexString(expected),
            Convert.FromHexString(actual));
    }

    private void Transition(
        string transactionDirectory,
        ref TransactionState? current,
        TransactionState next)
    {
        if (!IsAllowedTransition(current, next))
        {
            throw new InvalidOperationException(
                $"Invalid transaction state transition {current?.ToString() ?? "<none>"} -> {next}.");
        }

        var stateRecord = new TransactionStateRecord(ToWireName(next));
        ValidateTransactionStoragePath(
            Path.Combine(transactionDirectory, StateHistoryFileName));
        AppendDurable(
            Path.Combine(transactionDirectory, StateHistoryFileName),
            stateRecord);
        ValidateTransactionStoragePath(
            Path.Combine(transactionDirectory, StateFileName));
        WriteDurableJson(
            Path.Combine(transactionDirectory, StateFileName),
            stateRecord);
        current = next;
    }

    private static bool IsAllowedTransition(
        TransactionState? current,
        TransactionState next) =>
        (current, next) switch
        {
            (null, TransactionState.Planned) => true,
            (TransactionState.Planned, TransactionState.Staged) => true,
            (TransactionState.Staged, TransactionState.Applying) => true,
            (TransactionState.Applying, TransactionState.Verifying) => true,
            (TransactionState.Verifying, TransactionState.Committed) => true,
            (TransactionState.Planned
                or TransactionState.Staged
                or TransactionState.Applying
                or TransactionState.Verifying,
                TransactionState.RollingBack) => true,
            (TransactionState.RollingBack, TransactionState.RolledBack) => true,
            _ => false
        };

    private TransactionState ReadState(string transactionDirectory)
    {
        var path = Path.Combine(transactionDirectory, StateFileName);
        ValidateTransactionStoragePath(path);
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var wireName = document.RootElement.GetProperty("state").GetString();
        return wireName switch
        {
            "planned" => TransactionState.Planned,
            "staged" => TransactionState.Staged,
            "applying" => TransactionState.Applying,
            "verifying" => TransactionState.Verifying,
            "committed" => TransactionState.Committed,
            "rolling_back" => TransactionState.RollingBack,
            "rolled_back" => TransactionState.RolledBack,
            _ => throw new InvalidDataException($"Unknown transaction state '{wireName}'.")
        };
    }

    private static string ToWireName(TransactionState state) => state switch
    {
        TransactionState.Planned => "planned",
        TransactionState.Staged => "staged",
        TransactionState.Applying => "applying",
        TransactionState.Verifying => "verifying",
        TransactionState.Committed => "committed",
        TransactionState.RollingBack => "rolling_back",
        TransactionState.RolledBack => "rolled_back",
        _ => throw new ArgumentOutOfRangeException(nameof(state))
    };

    private IReadOnlyList<TransactionJournalEntry> ReadJournal(
        string transactionDirectory)
    {
        var path = Path.Combine(transactionDirectory, JournalFileName);
        ValidateTransactionStoragePath(path);
        if (!File.Exists(path))
            return [];
        var text = File.ReadAllText(path);
        var terminated = text.EndsWith('\n');
        var lines = text.Split('\n');
        var lastContentIndex = lines.Length - 1;
        if (terminated)
            lastContentIndex--;
        var entries = new List<TransactionJournalEntry>();
        for (var index = 0; index <= lastContentIndex; index++)
        {
            var line = lines[index].TrimEnd('\r');
            if (string.IsNullOrWhiteSpace(line))
            {
                throw new InvalidDataException(
                    $"Journal record {index + 1} is empty.");
            }
            try
            {
                entries.Add(JsonSerializer.Deserialize<TransactionJournalEntry>(
                                line,
                                JsonOptions)
                            ?? throw new InvalidDataException("Journal entry was empty."));
            }
            catch (JsonException error)
            {
                var isTruncatedTail = index == lastContentIndex && !terminated;
                if (isTruncatedTail)
                    break;
                throw new InvalidDataException(
                    $"Journal record {index + 1} is corrupt.",
                    error);
            }
        }

        ValidateJournalHistory(entries);
        return entries;
    }

    private static void ValidateJournalHistory(
        IReadOnlyList<TransactionJournalEntry> entries)
    {
        var staged = new Dictionary<int, TransactionJournalEntry>();
        var expectedStagedSequence = 1;
        var expectedCompletedSequence = 1;
        var completing = false;
        foreach (var entry in entries)
        {
            if (entry.BackupMetadata is null
                || string.IsNullOrWhiteSpace(entry.Action)
                || string.IsNullOrWhiteSpace(entry.TargetKey)
                || string.IsNullOrWhiteSpace(entry.Backup))
            {
                throw new InvalidDataException("Journal record is missing required fields.");
            }

            if (!completing && !entry.Completed)
            {
                if (entry.Sequence != expectedStagedSequence)
                {
                    throw new InvalidDataException(
                        "Journal staged sequence history is inconsistent.");
                }

                staged.Add(entry.Sequence, entry);
                expectedStagedSequence++;
                continue;
            }

            completing = true;
            if (!entry.Completed
                || entry.Sequence != expectedCompletedSequence
                || !staged.TryGetValue(entry.Sequence, out var original)
                || !JournalIdentityEquals(original, entry))
            {
                throw new InvalidDataException("Journal sequence history is inconsistent.");
            }

            expectedCompletedSequence++;
        }

        if (entries.Count == 0)
            throw new InvalidDataException("Transaction journal has no durable records.");
    }

    private static bool JournalIdentityEquals(
        TransactionJournalEntry first,
        TransactionJournalEntry second) =>
        first.Sequence == second.Sequence
        && string.Equals(first.Action, second.Action, StringComparison.Ordinal)
        && string.Equals(first.TargetKey, second.TargetKey, StringComparison.Ordinal)
        && string.Equals(first.Backup, second.Backup, StringComparison.Ordinal)
        && string.Equals(first.BeforeSha256, second.BeforeSha256, StringComparison.Ordinal)
        && first.BackupMetadata == second.BackupMetadata;

    private static void AppendDurable<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = new FileStream(
            path,
            FileMode.Append,
            FileAccess.Write,
            FileShare.Read,
            bufferSize: 4096,
            FileOptions.WriteThrough);
        JsonSerializer.Serialize(stream, value, JsonOptions);
        stream.WriteByte((byte)'\n');
        stream.Flush(flushToDisk: true);
    }

    private static void WriteDurableJson<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporaryPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            {
                JsonSerializer.Serialize(stream, value, JsonOptions);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);
        }
    }

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }

    private sealed record ResolvedChange(
        TransactionChange Change,
        ManagedTargetDefinition Target);

    private sealed record TransactionStateRecord(string State);

    private sealed record TransactionJournalEntry(
        int Sequence,
        string Action,
        string TargetKey,
        string Backup,
        string? BeforeSha256,
        bool Completed,
        FileBackupMetadata BackupMetadata);
}

public enum ExternalMutationTargetKind
{
    Directory,
    RegistryKey,
    File
}

public enum ExternalMutationProviderScope
{
    None,
    CurrentUser,
    LocalMachine
}

public interface IExternalMutationProvider
{
    ExternalMutationTargetKind Kind { get; }

    ExternalMutationProviderScope Scope { get; }

    Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
        ManagedSnapshotWriter writer,
        CancellationToken cancellationToken);

    Task ValidateSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken);

    Task RestoreSnapshotAsync(
        ManagedSnapshotReader snapshot,
        CancellationToken cancellationToken);

    /// <summary>
    /// Removes provider-owned snapshot data. Implementations must be idempotent
    /// because committed cleanup is deliberately retried after a crash.
    /// </summary>
    Task CleanupSnapshotAsync(
        ManagedSnapshotReader? snapshot,
        CancellationToken cancellationToken);
}

public sealed record ManagedSnapshotDescriptor(
    string Schema,
    long Length,
    string Sha256);

public sealed class ManagedSnapshotWriter
{
    private const string SnapshotFileName = "snapshot.bin";
    private readonly string _backupDirectory;
    private readonly ManagedPathGuard _pathGuard;
    private int _writeStarted;
    private ManagedSnapshotDescriptor? _writtenDescriptor;

    internal ManagedSnapshotWriter(
        string backupDirectory,
        ManagedPathGuard pathGuard)
    {
        _backupDirectory = Path.GetFullPath(backupDirectory);
        _pathGuard = pathGuard;
    }

    internal ManagedSnapshotDescriptor? WrittenDescriptor => _writtenDescriptor;

    public async Task<ManagedSnapshotDescriptor> WriteAsync(
        string schema,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken = default)
    {
        ValidateSchema(schema);
        if (Interlocked.Exchange(ref _writeStarted, 1) != 0)
            throw new InvalidOperationException("A snapshot has already been written.");

        var descriptor = new ManagedSnapshotDescriptor(
            schema,
            content.Length,
            Convert.ToHexString(SHA256.HashData(content.Span)).ToLowerInvariant());
        var snapshotPath = Path.Combine(_backupDirectory, SnapshotFileName);
        await _pathGuard.WriteDurableFileAsync(
                _backupDirectory,
                snapshotPath,
                content,
                cancellationToken)
            .ConfigureAwait(false);
        var durableHash = await _pathGuard.ComputeVerifiedSha256Async(
                _backupDirectory,
                snapshotPath,
                cancellationToken)
            .ConfigureAwait(false);
        if (!string.Equals(
                durableHash,
                descriptor.Sha256,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("Durable snapshot hash does not match its content.");
        }

        _writtenDescriptor = descriptor;
        return descriptor;
    }

    internal static void ValidateSchema(string schema)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(schema);
        if (schema.Length > 128
            || !schema.All(character =>
                character is >= 'a' and <= 'z'
                or >= 'A' and <= 'Z'
                or >= '0' and <= '9'
                or '.'
                or '_'
                or '-'))
        {
            throw new ArgumentException("Snapshot schema is invalid.", nameof(schema));
        }
    }
}

public sealed class ManagedSnapshotReader
{
    private const string SnapshotFileName = "snapshot.bin";
    private readonly string _backupDirectory;
    private readonly ManagedPathGuard _pathGuard;

    internal ManagedSnapshotReader(
        string backupDirectory,
        ManagedSnapshotDescriptor descriptor,
        ManagedPathGuard pathGuard)
    {
        _backupDirectory = Path.GetFullPath(backupDirectory);
        Descriptor = descriptor
                     ?? throw new ArgumentNullException(nameof(descriptor));
        _pathGuard = pathGuard;
        ValidateDescriptor(descriptor);
    }

    public ManagedSnapshotDescriptor Descriptor { get; }

    public async Task<byte[]> ReadAllBytesAsync(
        CancellationToken cancellationToken = default)
    {
        var snapshotPath = Path.Combine(_backupDirectory, SnapshotFileName);
        await using var verified = _pathGuard.OpenVerifiedRead(
            _backupDirectory,
            snapshotPath);
        // Do not preallocate from journal-controlled metadata. The final
        // length is checked after the handle-bound read completes.
        using var memory = new MemoryStream();
        await verified.Stream.CopyToAsync(memory, cancellationToken)
            .ConfigureAwait(false);
        var content = memory.ToArray();
        if (content.LongLength != Descriptor.Length)
            throw new InvalidDataException("Snapshot length does not match its descriptor.");
        var actualHash = Convert.ToHexString(SHA256.HashData(content))
            .ToLowerInvariant();
        if (!string.Equals(
                actualHash,
                Descriptor.Sha256,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("Snapshot hash does not match its descriptor.");
        }

        return content;
    }

    internal async Task ValidateDurableAsync(
        CancellationToken cancellationToken)
    {
        _ = await ReadAllBytesAsync(cancellationToken).ConfigureAwait(false);
    }

    internal Task DeleteAsync(CancellationToken cancellationToken) =>
        _pathGuard.DeleteManagedFileAsync(
            _backupDirectory,
            Path.Combine(_backupDirectory, SnapshotFileName),
            cancellationToken);

    private static void ValidateDescriptor(ManagedSnapshotDescriptor descriptor)
    {
        ManagedSnapshotWriter.ValidateSchema(descriptor.Schema);
        if (descriptor.Length < 0 || descriptor.Length > int.MaxValue)
            throw new InvalidDataException("Snapshot length is invalid.");
        if (descriptor.Sha256.Length != 64
            || descriptor.Sha256.Any(character =>
                character is not (>= '0' and <= '9')
                and not (>= 'a' and <= 'f')))
        {
            throw new InvalidDataException("Snapshot SHA-256 is invalid.");
        }
    }
}

public sealed record ExternalMutationTargetDefinition(
    string TargetKey,
    IExternalMutationProvider Provider);

public sealed class ExternalMutationCatalog
{
    private readonly IReadOnlyDictionary<string, ExternalMutationTargetDefinition> _targets;

    public ExternalMutationCatalog(
        IEnumerable<ExternalMutationTargetDefinition> targets)
    {
        ArgumentNullException.ThrowIfNull(targets);
        var mapped = new Dictionary<string, ExternalMutationTargetDefinition>(
            StringComparer.Ordinal);
        foreach (var target in targets)
        {
            ArgumentNullException.ThrowIfNull(target);
            ArgumentException.ThrowIfNullOrWhiteSpace(target.TargetKey);
            ArgumentNullException.ThrowIfNull(target.Provider);
            if (!IsStableTargetKey(target.TargetKey))
            {
                throw new ArgumentException(
                    $"External target key '{target.TargetKey}' is not stable.",
                    nameof(targets));
            }

            if (!Enum.IsDefined(target.Provider.Kind)
                || !Enum.IsDefined(target.Provider.Scope))
            {
                throw new ArgumentException(
                    "External mutation provider kind or scope is undefined.",
                    nameof(targets));
            }

            switch (target.Provider.Kind)
            {
                case ExternalMutationTargetKind.RegistryKey
                    when target.Provider.Scope != ExternalMutationProviderScope.CurrentUser:
                    throw new ArgumentException(
                        "Registry mutation providers must be scoped to HKCU.",
                        nameof(targets));
                case ExternalMutationTargetKind.Directory
                    or ExternalMutationTargetKind.File
                    when target.Provider.Scope != ExternalMutationProviderScope.None:
                    throw new ArgumentException(
                        "Only registry mutation providers may declare a registry scope.",
                        nameof(targets));
                case ExternalMutationTargetKind.Directory
                    or ExternalMutationTargetKind.RegistryKey
                    or ExternalMutationTargetKind.File:
                    break;
                default:
                    throw new ArgumentException(
                        "External mutation provider kind is unsupported.",
                        nameof(targets));
            }

            if (!mapped.TryAdd(target.TargetKey, target))
            {
                throw new ArgumentException(
                    $"Duplicate external target key '{target.TargetKey}'.",
                    nameof(targets));
            }
        }

        _targets = mapped;
    }

    public ExternalMutationTargetDefinition Resolve(string targetKey) =>
        _targets.TryGetValue(targetKey, out var target)
            ? target
            : throw new KeyNotFoundException(
                $"Unknown external mutation target key '{targetKey}'.");

    private static bool IsStableTargetKey(string value) =>
        value.All(character =>
            character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '.'
            or '_'
            or '-');
}

public sealed record ExternalMutationCommitResult(
    bool CleanupPending,
    IReadOnlyList<string> PendingTargetKeys);

public sealed class ExternalMutationSession
{
    private readonly ExternalMutationCoordinator _coordinator;
    private readonly string _transactionDirectory;
    private readonly IReadOnlyList<ExternalMutationJournalEntry> _entries;

    internal ExternalMutationSession(
        ExternalMutationCoordinator coordinator,
        Guid transactionId,
        string transactionDirectory,
        IReadOnlyList<ExternalMutationJournalEntry> entries,
        TransactionState state)
    {
        _coordinator = coordinator;
        TransactionId = transactionId;
        _transactionDirectory = transactionDirectory;
        _entries = entries;
        State = state;
    }

    public Guid TransactionId { get; }

    public TransactionState State { get; internal set; }

    public Task MarkApplyingAsync(CancellationToken cancellationToken = default) =>
        _coordinator.MarkApplyingAsync(this, _transactionDirectory, cancellationToken);

    public Task<ExternalMutationCommitResult> CommitAsync(
        CancellationToken cancellationToken = default) =>
        _coordinator.CommitAsync(
            this,
            _transactionDirectory,
            _entries,
            cancellationToken);

    public Task RollBackAsync(CancellationToken cancellationToken = default) =>
        _coordinator.RollBackSessionAsync(
            this,
            _transactionDirectory,
            _entries,
            cancellationToken);
}

internal sealed record ExternalMutationJournalEntry(
    int Sequence,
    string Action,
    string TargetKey,
    string Backup,
    bool Completed,
    ManagedSnapshotDescriptor? Snapshot);

public sealed class ExternalMutationCoordinator
{
    private const string TransactionsIndexFileName = "transactions.index.jsonl";
    private const string JournalFileName = "journal.jsonl";
    private const string StateFileName = "state.json";
    private const string StateHistoryFileName = "state-history.jsonl";
    private const string CleanupPendingFileName = "cleanup-pending.json";
    private const string CleanupCompleteFileName = "cleanup-complete.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly string _transactionsRoot;
    private readonly ExternalMutationCatalog _catalog;
    private readonly ManagedPathGuard _pathGuard = new();

    public ExternalMutationCoordinator(
        string transactionsRoot,
        ExternalMutationCatalog catalog)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(transactionsRoot);
        var fullRoot = Path.GetFullPath(transactionsRoot);
        _transactionsRoot =
            OperatingSystem.IsMacOS()
            && fullRoot.StartsWith("/var/", StringComparison.Ordinal)
                ? "/private" + fullRoot
                : fullRoot;
        _catalog = catalog ?? throw new ArgumentNullException(nameof(catalog));
    }

    public string TransactionsRoot => _transactionsRoot;

    public async Task<ExternalMutationSession> BeginExternalMutationAsync(
        IReadOnlyList<string> stableTargetKeys,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stableTargetKeys);
        if (stableTargetKeys.Count == 0)
        {
            throw new ArgumentException(
                "At least one external mutation target is required.",
                nameof(stableTargetKeys));
        }

        var targets = new List<ExternalMutationTargetDefinition>(
            stableTargetKeys.Count);
        var uniqueKeys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var key in stableTargetKeys)
        {
            if (!uniqueKeys.Add(key))
                throw new ArgumentException($"Duplicate external target key '{key}'.");
            targets.Add(_catalog.Resolve(key));
        }

        var transactionId = Guid.NewGuid();
        var transactionDirectory = Path.Combine(
            _transactionsRoot,
            transactionId.ToString("N"));
        EnsureTransactionsRoot();
        _pathGuard.EnsureManagedDirectory(_transactionsRoot, transactionDirectory);
        _pathGuard.EnsureManagedDirectory(
            transactionDirectory,
            Path.Combine(transactionDirectory, "backups"));
        await AppendDurableAsync(
                _transactionsRoot,
                Path.Combine(_transactionsRoot, TransactionsIndexFileName),
                new TransactionIndexRecord(transactionId.ToString("N")),
                cancellationToken)
            .ConfigureAwait(false);
        var state = (TransactionState?)null;
        var entries = new List<ExternalMutationJournalEntry>(targets.Count);
        try
        {
            state = await TransitionAsync(
                    transactionDirectory,
                    state,
                    TransactionState.Planned,
                    cancellationToken)
                .ConfigureAwait(false);
            for (var index = 0; index < targets.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var sequence = index + 1;
                var relativeBackup = $"backups/{sequence:D4}";
                var backupPath = ResolveBackupPath(
                    transactionDirectory,
                    relativeBackup,
                    sequence);
                _pathGuard.EnsureManagedDirectory(
                    transactionDirectory,
                    backupPath);
                var entry = new ExternalMutationJournalEntry(
                    sequence,
                    "externalSnapshot",
                    targets[index].TargetKey,
                    relativeBackup,
                    Completed: false,
                    Snapshot: null);
                await AppendDurableAsync(
                        transactionDirectory,
                        Path.Combine(transactionDirectory, JournalFileName),
                        entry,
                        cancellationToken)
                    .ConfigureAwait(false);
                entries.Add(entry);
                var writer = new ManagedSnapshotWriter(backupPath, _pathGuard);
                var descriptor = await targets[index].Provider.CaptureSnapshotAsync(
                        writer,
                        cancellationToken)
                    .ConfigureAwait(false);
                if (writer.WrittenDescriptor is null
                    || descriptor != writer.WrittenDescriptor)
                {
                    throw new InvalidDataException(
                        "Snapshot provider returned an unbound descriptor.");
                }

                var reader = new ManagedSnapshotReader(
                    backupPath,
                    descriptor,
                    _pathGuard);
                await reader.ValidateDurableAsync(cancellationToken)
                    .ConfigureAwait(false);
                await targets[index].Provider.ValidateSnapshotAsync(
                        reader,
                        cancellationToken)
                    .ConfigureAwait(false);
                entries[index] = entry with
                {
                    Completed = true,
                    Snapshot = descriptor
                };
                await AppendDurableAsync(
                        transactionDirectory,
                        Path.Combine(transactionDirectory, JournalFileName),
                        entries[index],
                        cancellationToken)
                    .ConfigureAwait(false);
            }

            state = await TransitionAsync(
                    transactionDirectory,
                    state,
                    TransactionState.Staged,
                    cancellationToken)
                .ConfigureAwait(false);
            return new ExternalMutationSession(
                this,
                transactionId,
                transactionDirectory,
                entries.AsReadOnly(),
                TransactionState.Staged);
        }
        catch (Exception error)
        {
            try
            {
                if (state.HasValue)
                {
                    state = await TransitionAsync(
                        transactionDirectory,
                        state,
                        TransactionState.RollingBack,
                        CancellationToken.None).ConfigureAwait(false);
                }

                await CleanupEntriesAsync(
                        transactionDirectory,
                        entries,
                        cancellationToken: CancellationToken.None,
                        swallowFailures: false)
                    .ConfigureAwait(false);
                if (state.HasValue)
                {
                    state = await TransitionAsync(
                        transactionDirectory,
                        state,
                        TransactionState.RolledBack,
                        CancellationToken.None).ConfigureAwait(false);
                }
            }
            catch (Exception cleanupError)
            {
                throw new AggregateException(
                    "External snapshot staging and cleanup both failed.",
                    error,
                    cleanupError);
            }

            ExceptionDispatchInfo.Capture(error).Throw();
            throw;
        }
    }

    public async Task<IReadOnlyList<Guid>> RecoverIncompleteAsync(
        CancellationToken cancellationToken = default)
    {
        EnsureTransactionsRoot();
        var recovered = new List<Guid>();
        foreach (var id in await ReadTransactionIdsAsync(cancellationToken)
                     .ConfigureAwait(false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = Path.Combine(_transactionsRoot, id.ToString("N"));
            var stateHistoryPath = Path.Combine(
                directory,
                StateHistoryFileName);
            if (!_pathGuard.ManagedFileExists(_transactionsRoot, stateHistoryPath))
                continue;
            ValidateTransactionDirectories(directory);
            TransactionState? state = await ReadStateAsync(
                    directory,
                    cancellationToken)
                .ConfigureAwait(false);
            if (state is not (TransactionState.Staged
                or TransactionState.Applying
                or TransactionState.Verifying
                or TransactionState.RollingBack))
            {
                continue;
            }

            var entries = await ReadJournalAsync(directory, cancellationToken)
                .ConfigureAwait(false);
            if (state != TransactionState.RollingBack)
            {
                state = await TransitionAsync(
                        directory,
                        state,
                        TransactionState.RollingBack,
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            await RestoreEntriesAsync(
                    directory,
                    entries,
                    CancellationToken.None)
                .ConfigureAwait(false);
            await CleanupEntriesAsync(
                    directory,
                    entries,
                    CancellationToken.None,
                    swallowFailures: false)
                .ConfigureAwait(false);
            state = await TransitionAsync(
                    directory,
                    state,
                    TransactionState.RolledBack,
                    CancellationToken.None)
                .ConfigureAwait(false);
            recovered.Add(id);
        }

        return recovered.AsReadOnly();
    }

    public async Task<IReadOnlyList<Guid>> RetryPendingCleanupAsync(
        CancellationToken cancellationToken = default)
    {
        EnsureTransactionsRoot();
        var pendingTransactions = new List<Guid>();
        foreach (var id in await ReadTransactionIdsAsync(cancellationToken)
                     .ConfigureAwait(false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = Path.Combine(_transactionsRoot, id.ToString("N"));
            var stateHistoryPath = Path.Combine(
                directory,
                StateHistoryFileName);
            if (!_pathGuard.ManagedFileExists(_transactionsRoot, stateHistoryPath))
                continue;
            ValidateTransactionDirectories(directory);
            if (await ReadStateAsync(directory, cancellationToken)
                    .ConfigureAwait(false) != TransactionState.Committed
                || _pathGuard.ManagedFileExists(
                    directory,
                    Path.Combine(directory, CleanupCompleteFileName)))
            {
                continue;
            }

            var entries = await ReadJournalAsync(directory, cancellationToken)
                .ConfigureAwait(false);
            List<string> pending;
            try
            {
                pending = await CleanupCommittedEntriesAsync(
                        directory,
                        entries,
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch
            {
                // Committed cleanup is best effort. The durable pending record
                // remains authoritative for a later retry.
                pendingTransactions.Add(id);
                continue;
            }
            if (pending.Count > 0)
                pendingTransactions.Add(id);
        }

        return pendingTransactions.AsReadOnly();
    }

    internal async Task MarkApplyingAsync(
        ExternalMutationSession session,
        string transactionDirectory,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = (TransactionState?)session.State;
        state = await TransitionAsync(
                transactionDirectory,
                state,
                TransactionState.Applying,
                cancellationToken)
            .ConfigureAwait(false);
        session.State = TransactionState.Applying;
    }

    internal async Task<ExternalMutationCommitResult> CommitAsync(
        ExternalMutationSession session,
        string transactionDirectory,
        IReadOnlyList<ExternalMutationJournalEntry> entries,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (session.State != TransactionState.Applying)
            throw new InvalidOperationException("External mutation must be applying before commit.");
        var state = (TransactionState?)session.State;
        var initiallyPending = LatestEntries(entries)
            .Where(entry => entry.Completed)
            .OrderBy(entry => entry.Sequence)
            .Select(entry => entry.TargetKey)
            .ToArray();
        await WritePendingKeysAsync(
                transactionDirectory,
                initiallyPending,
                cancellationToken)
            .ConfigureAwait(false);
        state = await TransitionAsync(
                transactionDirectory,
                state,
                TransactionState.Verifying,
                cancellationToken)
            .ConfigureAwait(false);
        state = await TransitionAsync(
                transactionDirectory,
                state,
                TransactionState.Committed,
                cancellationToken)
            .ConfigureAwait(false);
        session.State = TransactionState.Committed;

        // Committed is durable before cleanup begins. A crash before or during
        // cleanup is therefore a retry, never a rollback.
        List<string> pending;
        try
        {
            pending = await CleanupCommittedEntriesAsync(
                    transactionDirectory,
                    entries,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch
        {
            // Every key was durably marked pending before the committed state.
            // No cleanup failure may turn a committed install into an error or
            // trigger rollback.
            pending = initiallyPending.ToList();
        }
        return new ExternalMutationCommitResult(
            pending.Count > 0,
            pending.AsReadOnly());
    }

    internal async Task RollBackSessionAsync(
        ExternalMutationSession session,
        string transactionDirectory,
        IReadOnlyList<ExternalMutationJournalEntry> entries,
        CancellationToken cancellationToken)
    {
        if (session.State == TransactionState.Committed)
            throw new InvalidOperationException("A committed mutation cannot be rolled back.");
        var state = (TransactionState?)session.State;
        state = await TransitionAsync(
                transactionDirectory,
                state,
                TransactionState.RollingBack,
                cancellationToken)
            .ConfigureAwait(false);
        await RestoreEntriesAsync(
                transactionDirectory,
                entries,
                cancellationToken)
            .ConfigureAwait(false);
        await CleanupEntriesAsync(
                transactionDirectory,
                entries,
                cancellationToken,
                swallowFailures: false)
            .ConfigureAwait(false);
        state = await TransitionAsync(
                transactionDirectory,
                state,
                TransactionState.RolledBack,
                cancellationToken)
            .ConfigureAwait(false);
        session.State = TransactionState.RolledBack;
    }

    private async Task RestoreEntriesAsync(
        string transactionDirectory,
        IReadOnlyList<ExternalMutationJournalEntry> entries,
        CancellationToken cancellationToken)
    {
        foreach (var entry in LatestEntries(entries)
                     .Where(entry => entry.Completed)
                     .OrderByDescending(entry => entry.Sequence))
        {
            var target = _catalog.Resolve(entry.TargetKey);
            var reader = CreateSnapshotReader(transactionDirectory, entry);
            await reader.ValidateDurableAsync(cancellationToken)
                .ConfigureAwait(false);
            await target.Provider.ValidateSnapshotAsync(
                    reader,
                    cancellationToken)
                .ConfigureAwait(false);
            await target.Provider.RestoreSnapshotAsync(
                    reader,
                    cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private async Task CleanupEntriesAsync(
        string transactionDirectory,
        IReadOnlyList<ExternalMutationJournalEntry> entries,
        CancellationToken cancellationToken,
        bool swallowFailures)
    {
        var failures = new List<Exception>();
        foreach (var entry in LatestEntries(entries)
                     .OrderByDescending(entry => entry.Sequence))
        {
            var target = _catalog.Resolve(entry.TargetKey);
            var backupPath = ResolveBackupPath(
                transactionDirectory,
                entry.Backup,
                entry.Sequence);
            _pathGuard.ValidateExistingDirectory(
                transactionDirectory,
                backupPath);
            var snapshot = entry.Completed
                ? CreateSnapshotReader(transactionDirectory, entry)
                : null;
            try
            {
                await target.Provider.CleanupSnapshotAsync(
                        snapshot,
                        cancellationToken)
                    .ConfigureAwait(false);
                await _pathGuard.DeleteManagedFileAsync(
                        backupPath,
                        Path.Combine(backupPath, "snapshot.bin"),
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (Exception error)
            {
                failures.Add(error);
            }
        }

        if (!swallowFailures && failures.Count > 0)
            throw new AggregateException("External snapshot cleanup failed.", failures);
    }

    private async Task<List<string>> CleanupCommittedEntriesAsync(
        string transactionDirectory,
        IReadOnlyList<ExternalMutationJournalEntry> entries,
        CancellationToken cancellationToken)
    {
        var latest = LatestEntries(entries)
            .Where(entry => entry.Completed)
            .OrderBy(entry => entry.Sequence)
            .ToArray();
        var pending = await ReadPendingKeysAsync(transactionDirectory, latest)
            .ConfigureAwait(false);
        await WritePendingKeysAsync(
                transactionDirectory,
                pending,
                CancellationToken.None)
            .ConfigureAwait(false);
        foreach (var entry in latest.Where(entry => pending.Contains(entry.TargetKey)))
        {
            var target = _catalog.Resolve(entry.TargetKey);
            try
            {
                var snapshot = CreateSnapshotReader(transactionDirectory, entry);
                await target.Provider.CleanupSnapshotAsync(
                        snapshot,
                        cancellationToken)
                    .ConfigureAwait(false);
                await snapshot.DeleteAsync(CancellationToken.None)
                    .ConfigureAwait(false);
                var nextPending = pending
                    .Where(key => !string.Equals(
                        key,
                        entry.TargetKey,
                        StringComparison.Ordinal))
                    .ToList();
                await WritePendingKeysAsync(
                        transactionDirectory,
                        nextPending,
                        CancellationToken.None)
                    .ConfigureAwait(false);
                pending = nextPending;
            }
            catch
            {
                // The committed installation is authoritative. Record the key
                // for retry without exposing a provider path or rolling back.
            }
        }

        if (pending.Count == 0)
        {
            try
            {
                await WriteDurableJsonAsync(
                        transactionDirectory,
                        Path.Combine(
                            transactionDirectory,
                            CleanupCompleteFileName),
                        new CleanupCompleteRecord(true),
                        CancellationToken.None)
                    .ConfigureAwait(false);
                await _pathGuard.DeleteManagedFileAsync(
                        transactionDirectory,
                        Path.Combine(
                            transactionDirectory,
                            CleanupPendingFileName),
                        CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch
            {
                // The committed transaction remains retryable if completion
                // bookkeeping itself cannot be finalized.
                return latest.Select(entry => entry.TargetKey).ToList();
            }
        }
        else
        {
            try
            {
                await WritePendingKeysAsync(
                        transactionDirectory,
                        pending,
                        CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch
            {
                // The pre-commit pending record still contains every key.
            }
        }

        return pending;
    }

    private async Task<List<string>> ReadPendingKeysAsync(
        string transactionDirectory,
        IReadOnlyList<ExternalMutationJournalEntry> entries)
    {
        var path = Path.Combine(transactionDirectory, CleanupPendingFileName);
        if (!_pathGuard.ManagedFileExists(transactionDirectory, path))
            return entries.Select(entry => entry.TargetKey).ToList();
        var record = JsonSerializer.Deserialize<CleanupPendingRecord>(
                         await ReadUtf8Async(
                                 transactionDirectory,
                                 path,
                                 CancellationToken.None)
                             .ConfigureAwait(false),
                         JsonOptions)
                     ?? throw new InvalidDataException("Cleanup pending record is empty.");
        var known = entries.Select(entry => entry.TargetKey)
            .ToHashSet(StringComparer.Ordinal);
        if (record.TargetKeys.Any(key => !known.Contains(key)))
            throw new InvalidDataException("Cleanup pending record contains an unknown key.");
        return record.TargetKeys.Distinct(StringComparer.Ordinal).ToList();
    }

    private static IReadOnlyList<ExternalMutationJournalEntry> LatestEntries(
        IReadOnlyList<ExternalMutationJournalEntry> entries) =>
        entries
            .GroupBy(entry => entry.Sequence)
            .Select(group => group.Last())
            .ToArray();

    private async Task<IReadOnlyList<ExternalMutationJournalEntry>> ReadJournalAsync(
        string transactionDirectory,
        CancellationToken cancellationToken)
    {
        var path = Path.Combine(transactionDirectory, JournalFileName);
        var journal = await ReadUtf8Async(
                transactionDirectory,
                path,
                cancellationToken)
            .ConfigureAwait(false);
        var entries = journal.Split('\n')
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .Select(line => JsonSerializer.Deserialize<ExternalMutationJournalEntry>(
                                line,
                                JsonOptions)
                            ?? throw new InvalidDataException(
                                "External mutation journal entry is empty."))
            .ToArray();
        foreach (var entry in entries)
        {
            if (!string.Equals(
                    entry.Action,
                    "externalSnapshot",
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    $"Unsupported external journal action '{entry.Action}'.");
            }

            _ = ResolveBackupPath(
                transactionDirectory,
                entry.Backup,
                entry.Sequence);
            if (entry.Sequence <= 0
                || entry.Completed != (entry.Snapshot is not null))
            {
                throw new InvalidDataException(
                    "External mutation journal completion metadata is invalid.");
            }
        }

        return entries;
    }

    private static string ResolveBackupPath(
        string transactionDirectory,
        string relativeBackup,
        int sequence)
    {
        var expected = $"backups/{sequence:D4}";
        if (!string.Equals(relativeBackup, expected, StringComparison.Ordinal))
            throw new InvalidDataException("External snapshot backup name is invalid.");
        return Path.Combine(
            transactionDirectory,
            relativeBackup.Replace('/', Path.DirectorySeparatorChar));
    }

    private Task WritePendingKeysAsync(
        string transactionDirectory,
        IReadOnlyList<string> targetKeys,
        CancellationToken cancellationToken) =>
        WriteDurableJsonAsync(
            transactionDirectory,
            Path.Combine(transactionDirectory, CleanupPendingFileName),
            new CleanupPendingRecord(targetKeys.ToArray()),
            cancellationToken);

    private async Task<TransactionState?> TransitionAsync(
        string transactionDirectory,
        TransactionState? current,
        TransactionState next,
        CancellationToken cancellationToken)
    {
        if (!IsAllowedTransition(current, next))
        {
            throw new InvalidOperationException(
                $"Invalid external mutation state transition {current} -> {next}.");
        }

        var record = new ExternalStateRecord(ToWireName(next));
        await AppendDurableAsync(
                transactionDirectory,
                Path.Combine(transactionDirectory, StateHistoryFileName),
                record,
                cancellationToken)
            .ConfigureAwait(false);
        await WriteDurableJsonAsync(
                transactionDirectory,
                Path.Combine(transactionDirectory, StateFileName),
                record,
                cancellationToken)
            .ConfigureAwait(false);
        return next;
    }

    private static bool IsAllowedTransition(
        TransactionState? current,
        TransactionState next) =>
        (current, next) switch
        {
            (null, TransactionState.Planned) => true,
            (TransactionState.Planned, TransactionState.Staged) => true,
            (TransactionState.Staged, TransactionState.Applying) => true,
            (TransactionState.Applying, TransactionState.Verifying) => true,
            (TransactionState.Verifying, TransactionState.Committed) => true,
            (TransactionState.Planned
                or TransactionState.Staged
                or TransactionState.Applying
                or TransactionState.Verifying,
                TransactionState.RollingBack) => true,
            (TransactionState.RollingBack, TransactionState.RolledBack) => true,
            _ => false
        };

    private async Task<TransactionState> ReadStateAsync(
        string transactionDirectory,
        CancellationToken cancellationToken)
    {
        var history = await ReadUtf8Async(
                transactionDirectory,
                Path.Combine(transactionDirectory, StateHistoryFileName),
                cancellationToken)
            .ConfigureAwait(false);
        var lastRecord = history.Split('\n')
            .LastOrDefault(line => !string.IsNullOrWhiteSpace(line))
                         ?? throw new InvalidDataException(
                             "External transaction state history is empty.");
        var record = JsonSerializer.Deserialize<ExternalStateRecord>(
                         lastRecord,
                         JsonOptions)
                     ?? throw new InvalidDataException(
                         "External transaction state record is empty.");
        return record.State switch
        {
            "planned" => TransactionState.Planned,
            "staged" => TransactionState.Staged,
            "applying" => TransactionState.Applying,
            "verifying" => TransactionState.Verifying,
            "committed" => TransactionState.Committed,
            "rolling_back" => TransactionState.RollingBack,
            "rolled_back" => TransactionState.RolledBack,
            var state => throw new InvalidDataException(
                $"Unknown external mutation state '{state}'.")
        };
    }

    private static string ToWireName(TransactionState state) => state switch
    {
        TransactionState.Planned => "planned",
        TransactionState.Staged => "staged",
        TransactionState.Applying => "applying",
        TransactionState.Verifying => "verifying",
        TransactionState.Committed => "committed",
        TransactionState.RollingBack => "rolling_back",
        TransactionState.RolledBack => "rolled_back",
        _ => throw new ArgumentOutOfRangeException(nameof(state))
    };

    private async Task AppendDurableAsync<T>(
        string rootPath,
        string path,
        T value,
        CancellationToken cancellationToken)
    {
        var content = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        var line = new byte[content.Length + 1];
        content.CopyTo(line, 0);
        line[^1] = (byte)'\n';
        await _pathGuard.AppendDurableAsync(
                rootPath,
                path,
                line,
                cancellationToken)
            .ConfigureAwait(false);
    }

    private Task WriteDurableJsonAsync<T>(
        string rootPath,
        string path,
        T value,
        CancellationToken cancellationToken) =>
        _pathGuard.WriteDurableFileAsync(
            rootPath,
            path,
            JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions),
            cancellationToken);

    private async Task<string> ReadUtf8Async(
        string rootPath,
        string path,
        CancellationToken cancellationToken)
    {
        await using var verified = _pathGuard.OpenVerifiedRead(rootPath, path);
        using var reader = new StreamReader(
            verified.Stream,
            System.Text.Encoding.UTF8,
            detectEncodingFromByteOrderMarks: false,
            leaveOpen: true);
        return await reader.ReadToEndAsync(cancellationToken)
            .ConfigureAwait(false);
    }

    private void EnsureTransactionsRoot()
    {
        var volumeRoot = Path.GetPathRoot(_transactionsRoot)
                         ?? throw new UnauthorizedAccessException(
                             "External transaction root has no filesystem root.");
        _pathGuard.EnsureManagedDirectory(volumeRoot, _transactionsRoot);
        _pathGuard.ValidateExistingDirectory(volumeRoot, _transactionsRoot);
    }

    private void ValidateTransactionDirectories(string transactionDirectory)
    {
        _pathGuard.ValidateExistingDirectory(
            _transactionsRoot,
            transactionDirectory);
        _pathGuard.ValidateExistingDirectory(
            transactionDirectory,
            Path.Combine(transactionDirectory, "backups"));
    }

    private ManagedSnapshotReader CreateSnapshotReader(
        string transactionDirectory,
        ExternalMutationJournalEntry entry)
    {
        var descriptor = entry.Snapshot
                         ?? throw new InvalidDataException(
                             "Completed snapshot has no durable descriptor.");
        var backupPath = ResolveBackupPath(
            transactionDirectory,
            entry.Backup,
            entry.Sequence);
        _pathGuard.ValidateExistingDirectory(
            transactionDirectory,
            backupPath);
        return new ManagedSnapshotReader(backupPath, descriptor, _pathGuard);
    }

    private async Task<IReadOnlyList<Guid>> ReadTransactionIdsAsync(
        CancellationToken cancellationToken)
    {
        var indexPath = Path.Combine(
            _transactionsRoot,
            TransactionsIndexFileName);
        if (!_pathGuard.ManagedFileExists(_transactionsRoot, indexPath))
            return [];
        var index = await ReadUtf8Async(
                _transactionsRoot,
                indexPath,
                cancellationToken)
            .ConfigureAwait(false);
        var ids = new HashSet<Guid>();
        foreach (var line in index.Split('\n')
                     .Where(line => !string.IsNullOrWhiteSpace(line)))
        {
            var record = JsonSerializer.Deserialize<TransactionIndexRecord>(
                             line,
                             JsonOptions)
                         ?? throw new InvalidDataException(
                             "External transaction index record is empty.");
            if (!Guid.TryParseExact(record.TransactionId, "N", out var id))
                throw new InvalidDataException(
                    "External transaction index contains an invalid identifier.");
            ids.Add(id);
        }

        return ids.Order().ToArray();
    }

    private sealed record TransactionIndexRecord(string TransactionId);

    private sealed record ExternalStateRecord(string State);

    private sealed record CleanupPendingRecord(IReadOnlyList<string> TargetKeys);

    private sealed record CleanupCompleteRecord(bool Complete);
}

public sealed class ManagedVerifiedRead : IDisposable, IAsyncDisposable
{
    private readonly IDisposable? _boundHandleOwner;
    private bool _disposed;

    internal ManagedVerifiedRead(Stream stream, IDisposable? boundHandleOwner)
    {
        Stream = stream;
        _boundHandleOwner = boundHandleOwner;
    }

    public Stream Stream { get; }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        Stream.Dispose();
        _boundHandleOwner?.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
            return;
        _disposed = true;
        await Stream.DisposeAsync().ConfigureAwait(false);
        _boundHandleOwner?.Dispose();
    }
}

/// <summary>
/// Validates managed path boundaries and provides handle-verified reads and
/// hashing. On Windows the final file and parent remain bound by handles for
/// the lifetime of <see cref="ManagedVerifiedRead"/>. The non-Windows branch
/// is a compatibility implementation for tests and does not claim equivalent
/// resistance to path replacement races.
/// </summary>
public sealed class ManagedPathGuard
{
    private readonly ITransactionFileSystem _fileSystem;

    public ManagedPathGuard()
        : this(new PhysicalTransactionFileSystem())
    {
    }

    internal ManagedPathGuard(ITransactionFileSystem fileSystem) =>
        _fileSystem = fileSystem
                      ?? throw new ArgumentNullException(nameof(fileSystem));

    public string ValidateManagedPath(
        string rootPath,
        string path,
        bool allowRoot = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        var candidate = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        var rootWithSeparator = Path.EndsInDirectorySeparator(root)
            ? root
            : root + Path.DirectorySeparatorChar;
        if (!(allowRoot && string.Equals(candidate, root, comparison))
            && !candidate.StartsWith(
                rootWithSeparator,
                comparison))
        {
            throw new UnauthorizedAccessException(
                "Managed path is outside its declared root.");
        }

        var volumeRoot = Path.GetPathRoot(candidate)
                         ?? throw new UnauthorizedAccessException(
                             "Managed path has no filesystem root.");
        if (_fileSystem.HasReparsePoint(volumeRoot, candidate))
            throw new UnauthorizedAccessException("Managed path traverses a reparse point.");
        return candidate;
    }

    public ManagedVerifiedRead OpenVerifiedRead(
        string rootPath,
        string path)
    {
        var target = ValidateManagedPath(rootPath, path);
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            if (_fileSystem is not PhysicalTransactionFileSystem)
            {
                throw new InvalidOperationException(
                    "Verified Windows reads require the physical filesystem.");
            }

            var boundFile = WindowsHandleFileSystem.OpenVerifiedRead(
                rootPath,
                target);
            try
            {
                var stream = new FileStream(
                    boundFile.Handle,
                    FileAccess.Read,
                    bufferSize: 81920,
                    isAsync: false);
                return new ManagedVerifiedRead(stream, boundFile);
            }
            catch
            {
                boundFile.Dispose();
                throw;
            }
        }
#endif
        var compatibleStream = new FileStream(
            target,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 81920,
            FileOptions.SequentialScan);
        try
        {
            _ = ValidateManagedPath(rootPath, target);
            return new ManagedVerifiedRead(compatibleStream, null);
        }
        catch
        {
            compatibleStream.Dispose();
            throw;
        }
    }

    public Task<string> ComputeVerifiedSha256Async(
        string rootPath,
        string path,
        CancellationToken cancellationToken = default)
    {
        var target = ValidateManagedPath(rootPath, path);
        return _fileSystem.ComputeSha256Async(
            Path.GetFullPath(rootPath),
            target,
            cancellationToken);
    }

    public void EnsureManagedDirectory(string rootPath, string directoryPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(directoryPath);
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            WindowsHandleFileSystem.EnsureDirectory(rootPath, directoryPath);
            return;
        }
#endif
        _ = ValidateManagedPath(rootPath, directoryPath, allowRoot: true);
        Directory.CreateDirectory(directoryPath);
        _ = ValidateManagedPath(rootPath, directoryPath, allowRoot: true);
    }

    public void ValidateExistingDirectory(string rootPath, string directoryPath)
    {
        _ = ValidateManagedPath(rootPath, directoryPath, allowRoot: true);
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            WindowsHandleFileSystem.ValidateDirectory(rootPath, directoryPath);
            return;
        }
#endif
        if (!Directory.Exists(directoryPath))
            throw new DirectoryNotFoundException(directoryPath);
    }

    public async Task WriteDurableFileAsync(
        string rootPath,
        string path,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken = default)
    {
        _ = ValidateManagedPath(rootPath, path);
        await _fileSystem.ReplaceFileAsync(
                Path.GetFullPath(rootPath),
                Path.GetFullPath(path),
                content,
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task AppendDurableAsync(
        string rootPath,
        string path,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken = default)
    {
        _ = ValidateManagedPath(rootPath, path);
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            await WindowsHandleFileSystem.AppendFileAsync(
                    rootPath,
                    path,
                    content,
                    cancellationToken)
                .ConfigureAwait(false);
            return;
        }
#endif
        var parent = Path.GetDirectoryName(path)
                     ?? throw new UnauthorizedAccessException("Managed file has no parent.");
        EnsureManagedDirectory(rootPath, parent);
        await using var stream = new FileStream(
            path,
            FileMode.OpenOrCreate,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 4096,
            FileOptions.WriteThrough);
        _ = ValidateManagedPath(rootPath, path);
        stream.Seek(0, SeekOrigin.End);
        await stream.WriteAsync(content, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        stream.Flush(flushToDisk: true);
    }

    public bool ManagedFileExists(string rootPath, string path)
    {
        _ = ValidateManagedPath(rootPath, path);
        return _fileSystem.Exists(
            Path.GetFullPath(rootPath),
            Path.GetFullPath(path));
    }

    public Task DeleteManagedFileAsync(
        string rootPath,
        string path,
        CancellationToken cancellationToken = default)
    {
        _ = ValidateManagedPath(rootPath, path);
        return _fileSystem.DeleteIfExistsAsync(
            Path.GetFullPath(rootPath),
            Path.GetFullPath(path),
            cancellationToken);
    }
}

public sealed class PhysicalTransactionFileSystem : ITransactionFileSystem
{
    public bool Exists(string rootPath, string path)
    {
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            try
            {
                using var handle = WindowsHandleFileSystem.OpenExisting(
                    rootPath,
                    path,
                    WindowsHandleFileSystem.FILE_READ_ATTRIBUTES);
                return true;
            }
            catch (FileNotFoundException)
            {
                return false;
            }
            catch (DirectoryNotFoundException)
            {
                return false;
            }
        }
#endif
        return File.Exists(path);
    }

    public bool HasReparsePoint(string rootPath, string targetPath)
    {
        var target = Path.GetFullPath(targetPath);
        var pathRoot = Path.GetPathRoot(target)
                       ?? Path.GetFullPath(rootPath);
        var current = pathRoot;
        if (IsReparsePoint(current))
            return true;
        var relative = target[pathRoot.Length..];
        foreach (var segment in relative.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (IsReparsePoint(current))
                return true;
        }

        return false;
    }

    public async Task<FileBackupMetadata> BackupAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            return await WindowsHandleFileSystem.BackupAsync(
                    targetRootPath,
                    targetPath,
                    backupRootPath,
                    backupPath,
                    cancellationToken)
                .ConfigureAwait(false);
        }
#endif
        EnsureSafePath(targetPath);
        EnsureSafePath(backupPath);
        if (Directory.Exists(targetPath))
            throw new IOException("Managed file target resolves to a directory.");
        if (!File.Exists(targetPath))
            return FileBackupMetadata.Missing;

        var attributes = File.GetAttributes(targetPath);
        var creationTimeUtc = File.GetCreationTimeUtc(targetPath);
        var lastWriteTimeUtc = File.GetLastWriteTimeUtc(targetPath);
        var lastAccessTimeUtc = File.GetLastAccessTimeUtc(targetPath);
        var securityDescriptor = WindowsFileSecurity.TryReadDacl(targetPath);
        Directory.CreateDirectory(Path.GetDirectoryName(backupPath)!);
        await using (var source = new FileStream(
                         targetPath,
                         FileMode.Open,
                         FileAccess.Read,
                         FileShare.Read))
        await using (var destination = new FileStream(
                         backupPath,
                         FileMode.CreateNew,
                         FileAccess.Write,
                         FileShare.None,
                         bufferSize: 81920,
                         FileOptions.WriteThrough))
        {
            EnsureSafePath(targetPath);
            EnsureSafePath(backupPath);
            await source.CopyToAsync(destination, cancellationToken).ConfigureAwait(false);
            await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            destination.Flush(flushToDisk: true);
        }

        return new FileBackupMetadata(
            true,
            (long)attributes,
            creationTimeUtc,
            lastWriteTimeUtc,
            lastAccessTimeUtc,
            securityDescriptor);
    }

    public async Task ReplaceFileAsync(
        string rootPath,
        string targetPath,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            await WindowsHandleFileSystem.ReplaceFileAsync(
                    rootPath,
                    targetPath,
                    content,
                    cancellationToken)
                .ConfigureAwait(false);
            return;
        }
#endif
        EnsureSafePath(targetPath);
        if (Directory.Exists(targetPath))
            throw new IOException("Managed file target resolves to a directory.");
        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        EnsureSafePath(Path.GetDirectoryName(targetPath)!);
        ClearReadOnlyIfPresent(targetPath);
        await using var destination = new FileStream(
            targetPath,
            FileMode.OpenOrCreate,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 81920,
            FileOptions.WriteThrough);
        EnsureSafePath(targetPath);
        destination.SetLength(0);
        await destination.WriteAsync(content, cancellationToken).ConfigureAwait(false);
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
        destination.Flush(flushToDisk: true);
    }

    public async Task<string> ComputeSha256Async(
        string rootPath,
        string path,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            return await WindowsHandleFileSystem.ComputeSha256Async(
                    rootPath,
                    path,
                    cancellationToken)
                .ConfigureAwait(false);
        }
#endif
        EnsureSafePath(path);
        await using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 81920,
            FileOptions.SequentialScan);
        EnsureSafePath(path);
        using var sha256 = SHA256.Create();
        var hash = await sha256.ComputeHashAsync(stream, cancellationToken)
            .ConfigureAwait(false);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public async Task RestoreAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        FileBackupMetadata metadata,
        string expectedSha256,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            await WindowsHandleFileSystem.RestoreAsync(
                    targetRootPath,
                    targetPath,
                    backupRootPath,
                    backupPath,
                    metadata,
                    expectedSha256,
                    cancellationToken)
                .ConfigureAwait(false);
            return;
        }
#endif
        if (!metadata.Existed)
            throw new ArgumentException("Cannot restore a missing-file backup.", nameof(metadata));
        if (!File.Exists(backupPath))
            throw new InvalidDataException("Transaction backup file is missing.");
        if (Directory.Exists(targetPath))
            throw new IOException("Managed file target resolves to a directory.");

        EnsureSafePath(backupPath);
        EnsureSafePath(targetPath);
        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        EnsureSafePath(Path.GetDirectoryName(targetPath)!);
        ClearReadOnlyIfPresent(targetPath);
        await using (var source = new FileStream(
                         backupPath,
                         FileMode.Open,
                         FileAccess.Read,
                         FileShare.Read))
        await using (var destination = new FileStream(
                         targetPath,
                         FileMode.OpenOrCreate,
                         FileAccess.Write,
                         FileShare.None,
                         bufferSize: 81920,
                         FileOptions.WriteThrough))
        {
            EnsureSafePath(backupPath);
            EnsureSafePath(targetPath);
            using var sha256 = SHA256.Create();
            var actualHash = await sha256.ComputeHashAsync(source, cancellationToken)
                .ConfigureAwait(false);
            var actualSha256 = Convert.ToHexString(actualHash).ToLowerInvariant();
            if (!Sha256Matches(expectedSha256, actualSha256))
                throw new InvalidDataException("Transaction backup changed before restore.");
            source.Position = 0;
            destination.SetLength(0);
            await source.CopyToAsync(destination, cancellationToken).ConfigureAwait(false);
            await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            destination.Flush(flushToDisk: true);
        }

        if (metadata.CreationTimeUtc.HasValue)
        {
            EnsureSafePath(targetPath);
            File.SetCreationTimeUtc(targetPath, metadata.CreationTimeUtc.Value);
        }
        if (metadata.LastWriteTimeUtc.HasValue)
        {
            EnsureSafePath(targetPath);
            File.SetLastWriteTimeUtc(targetPath, metadata.LastWriteTimeUtc.Value);
        }
        if (metadata.LastAccessTimeUtc.HasValue)
        {
            EnsureSafePath(targetPath);
            File.SetLastAccessTimeUtc(targetPath, metadata.LastAccessTimeUtc.Value);
        }
        EnsureSafePath(targetPath);
        WindowsFileSecurity.TryRestoreDacl(targetPath, metadata.SecurityDescriptor);
        EnsureSafePath(targetPath);
        File.SetAttributes(targetPath, (FileAttributes)metadata.Attributes);
    }

    public Task DeleteIfExistsAsync(
        string rootPath,
        string targetPath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
#if WINDOWS
        if (OperatingSystem.IsWindows())
        {
            WindowsHandleFileSystem.DeleteIfExists(rootPath, targetPath);
            return Task.CompletedTask;
        }
#endif
        EnsureSafePath(targetPath);
        if (Directory.Exists(targetPath))
            throw new IOException("Managed file target resolves to a directory.");
        if (File.Exists(targetPath))
        {
            ClearReadOnlyIfPresent(targetPath);
            EnsureSafePath(targetPath);
            File.Delete(targetPath);
        }

        return Task.CompletedTask;
    }

    private static bool IsReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch (FileNotFoundException)
        {
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return true;
        }
    }

    private static void ClearReadOnlyIfPresent(string path)
    {
        if (!File.Exists(path))
            return;
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReadOnly) != 0)
            File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly);
    }

    private void EnsureSafePath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath)
                   ?? throw new UnauthorizedAccessException("Path has no filesystem root.");
        if (HasReparsePoint(root, fullPath))
            throw new UnauthorizedAccessException("Path traverses a reparse point.");
    }

    private static bool Sha256Matches(string expected, string actual)
    {
        if (expected.Length != 64 || actual.Length != 64)
            return false;
        return CryptographicOperations.FixedTimeEquals(
            Convert.FromHexString(expected),
            Convert.FromHexString(actual));
    }
}

#if WINDOWS
internal static class WindowsHandleFileSystem
{
    internal const uint FILE_READ_ATTRIBUTES = 0x00000080;

    private const uint FILE_LIST_DIRECTORY = 0x00000001;
    private const uint FILE_WRITE_ATTRIBUTES = 0x00000100;
    private const uint DELETE = 0x00010000;
    private const uint READ_CONTROL = 0x00020000;
    private const uint WRITE_DAC = 0x00040000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_DIRECTORY_FILE = 0x00000001;
    private const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
    private const uint FILE_NON_DIRECTORY_FILE = 0x00000040;
    private const uint FILE_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_OPEN = 1;
    private const uint FILE_CREATE = 2;
    private const uint FILE_OPEN_IF = 3;
    private const uint OBJ_CASE_INSENSITIVE = 0x00000040;
    private const uint OBJ_DONT_REPARSE = 0x00001000;
    private const uint FILE_DISPOSITION_FLAG_DELETE = 0x00000001;
    private const uint FILE_DISPOSITION_FLAG_POSIX_SEMANTICS = 0x00000002;
    private const uint FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE = 0x00000010;
    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;
    private const int ErrorCantAccessFile = 1920;
    private const int ErrorNotAReparsePoint = 4390;
    private const int ErrorReparseAttributeConflict = 4391;
    private const int ErrorInvalidReparseData = 4392;
    private const int ErrorReparseTagInvalid = 4393;
    private const int ErrorReparseTagMismatch = 4394;
    private const int ErrorReparsePointEncountered = 4395;
    private const int ErrorInsufficientBuffer = 122;
    private const int FileBasicInfo = 0;
    private const int FileDispositionInfo = 4;
    private const int FileAttributeTagInfo = 9;
    private const int FileDispositionInfoEx = 21;
    private const uint DaclSecurityInformation = 0x00000004;

    public static async Task<FileBackupMetadata> BackupAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        BoundFile sourceFile;
        try
        {
            sourceFile = OpenRelativeFile(
                targetRootPath,
                targetPath,
                GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
                FILE_OPEN,
                allowCreateParents: false,
                shareAccess: FILE_SHARE_READ);
        }
        catch (FileNotFoundException)
        {
            return FileBackupMetadata.Missing;
        }
        catch (DirectoryNotFoundException)
        {
            return FileBackupMetadata.Missing;
        }

        using (sourceFile)
        {
            var sourceHandle = sourceFile.Handle;
            var basicInfo = ReadBasicInfo(sourceHandle);
            var securityDescriptor = ReadDacl(sourceHandle);
            using var backupFile = OpenRelativeFile(
                backupRootPath,
                backupPath,
                GENERIC_WRITE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                FILE_CREATE,
                allowCreateParents: true,
                shareAccess: 0);
            var backupHandle = backupFile.Handle;
            await using var source = new FileStream(
                sourceHandle,
                FileAccess.Read,
                bufferSize: 81920,
                isAsync: false);
            await using var destination = new FileStream(
                backupHandle,
                FileAccess.Write,
                bufferSize: 81920,
                isAsync: false);
            await source.CopyToAsync(destination, cancellationToken).ConfigureAwait(false);
            await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            destination.Flush(flushToDisk: true);
            return ToBackupMetadata(basicInfo, securityDescriptor);
        }
    }

    public static async Task ReplaceFileAsync(
        string rootPath,
        string targetPath,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var targetFile = OpenRelativeFile(
            rootPath,
            targetPath,
            GENERIC_WRITE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN_IF,
            allowCreateParents: true,
            shareAccess: 0);
        var targetHandle = targetFile.Handle;
        ClearReadOnly(targetHandle);
        await using var destination = new FileStream(
            targetHandle,
            FileAccess.Write,
            bufferSize: 81920,
            isAsync: false);
        destination.SetLength(0);
        await destination.WriteAsync(content, cancellationToken).ConfigureAwait(false);
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
        destination.Flush(flushToDisk: true);
    }

    public static async Task<string> ComputeSha256Async(
        string rootPath,
        string path,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var file = OpenRelativeFile(
            rootPath,
            path,
            GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN,
            allowCreateParents: false,
            shareAccess: FILE_SHARE_READ);
        var handle = file.Handle;
        await using var stream = new FileStream(
            handle,
            FileAccess.Read,
            bufferSize: 81920,
            isAsync: false);
        using var sha256 = SHA256.Create();
        var hash = await sha256.ComputeHashAsync(stream, cancellationToken)
            .ConfigureAwait(false);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public static async Task RestoreAsync(
        string targetRootPath,
        string targetPath,
        string backupRootPath,
        string backupPath,
        FileBackupMetadata metadata,
        string expectedSha256,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!metadata.Existed)
            throw new ArgumentException("Cannot restore a missing-file backup.", nameof(metadata));

        using var backupFile = OpenRelativeFile(
            backupRootPath,
            backupPath,
            GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN,
            allowCreateParents: false,
            shareAccess: FILE_SHARE_READ);
        var backupHandle = backupFile.Handle;
        await using var source = new FileStream(
            backupHandle,
            FileAccess.Read,
            bufferSize: 81920,
            isAsync: false);
        using (var sha256 = SHA256.Create())
        {
            var actualHash = await sha256.ComputeHashAsync(source, cancellationToken)
                .ConfigureAwait(false);
            var actualSha256 = Convert.ToHexString(actualHash).ToLowerInvariant();
            if (!Sha256Matches(expectedSha256, actualSha256))
                throw new InvalidDataException("Transaction backup changed before restore.");
        }

        source.Position = 0;
        using var targetFile = OpenRelativeFile(
            targetRootPath,
            targetPath,
            GENERIC_WRITE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES
            | READ_CONTROL | WRITE_DAC | SYNCHRONIZE,
            FILE_OPEN_IF,
            allowCreateParents: true,
            shareAccess: 0);
        var targetHandle = targetFile.Handle;
        ClearReadOnly(targetHandle);
        await using var destination = new FileStream(
            targetHandle,
            FileAccess.Write,
            bufferSize: 81920,
            isAsync: false);
        destination.SetLength(0);
        await source.CopyToAsync(destination, cancellationToken).ConfigureAwait(false);
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
        destination.Flush(flushToDisk: true);
        RestoreDacl(targetHandle, metadata.SecurityDescriptor);
        RestoreBasicInfo(targetHandle, metadata);
    }

    public static void DeleteIfExists(string rootPath, string targetPath)
    {
        BoundFile? targetFile = null;
        try
        {
            targetFile = OpenRelativeFile(
                rootPath,
                targetPath,
                DELETE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE,
                FILE_OPEN,
                allowCreateParents: false,
                shareAccess: FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
        }
        catch (FileNotFoundException)
        {
            return;
        }
        catch (DirectoryNotFoundException)
        {
            return;
        }

        using (targetFile)
        {
            var targetHandle = targetFile.Handle;
            ClearReadOnly(targetHandle);
            MarkDelete(targetHandle);
        }
    }

    internal static void EnsureDirectory(
        string rootPath,
        string directoryPath)
    {
        using var directory = OpenDirectoryChain(
            Path.GetFullPath(rootPath),
            Path.GetFullPath(directoryPath),
            allowCreate: true);
    }

    internal static void ValidateDirectory(
        string rootPath,
        string directoryPath)
    {
        using var directory = OpenDirectoryChain(
            Path.GetFullPath(rootPath),
            Path.GetFullPath(directoryPath),
            allowCreate: false);
    }

    internal static async Task AppendFileAsync(
        string rootPath,
        string path,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var file = OpenRelativeFile(
            rootPath,
            path,
            GENERIC_WRITE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN_IF,
            allowCreateParents: true,
            shareAccess: 0);
        await using var stream = new FileStream(
            file.Handle,
            FileAccess.Write,
            bufferSize: 4096,
            isAsync: false);
        stream.Seek(0, SeekOrigin.End);
        await stream.WriteAsync(content, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        stream.Flush(flushToDisk: true);
    }

    internal static BoundFile OpenExisting(
        string rootPath,
        string path,
        uint desiredAccess) =>
        OpenRelativeFile(
            rootPath,
            path,
            desiredAccess | SYNCHRONIZE,
            FILE_OPEN,
            allowCreateParents: false,
            shareAccess: FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);

    internal static BoundFile OpenVerifiedRead(
        string rootPath,
        string path) =>
        OpenRelativeFile(
            rootPath,
            path,
            GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN,
            allowCreateParents: false,
            shareAccess: FILE_SHARE_READ);

    private static BoundFile OpenRelativeFile(
        string rootPath,
        string path,
        uint desiredAccess,
        uint createDisposition,
        bool allowCreateParents,
        uint shareAccess)
    {
        var root = Path.GetFullPath(rootPath);
        var target = Path.GetFullPath(path);
        EnsureWithinRoot(root, target, allowEqual: false);
        var parentPath = Path.GetDirectoryName(target)
                         ?? throw new UnauthorizedAccessException("Managed file has no parent.");
        var parentHandle = OpenDirectoryChain(root, parentPath, allowCreateParents);
        var fileName = Path.GetFileName(target);
        try
        {
            var handle = NtCreateRelative(
                parentHandle,
                fileName,
                desiredAccess
                | (createDisposition is FILE_CREATE or FILE_OPEN_IF ? DELETE : 0),
                FILE_ATTRIBUTE_NORMAL,
                shareAccess,
                createDisposition,
                FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT,
                out var created);
            try
            {
                ValidateHandle(root, target, handle, expectDirectory: false);
                return new BoundFile(handle, parentHandle);
            }
            catch (Exception validationError)
            {
                try
                {
                    if (created)
                        DeleteCreated(handle);
                }
                catch (Exception cleanupError)
                {
                    throw new AggregateException(
                        "Handle validation failed and the raced creation could not be removed.",
                        validationError,
                        cleanupError);
                }
                finally
                {
                    handle.Dispose();
                }

                throw;
            }
        }
        catch
        {
            parentHandle.Dispose();
            throw;
        }
    }

    private static SafeFileHandle OpenDirectoryChain(
        string rootPath,
        string directoryPath,
        bool allowCreate)
    {
        EnsureWithinRoot(rootPath, directoryPath, allowEqual: true);
        var rootHandle = OpenRootDirectory(rootPath);
        if (string.Equals(
                Path.TrimEndingDirectorySeparator(rootPath),
                Path.TrimEndingDirectorySeparator(directoryPath),
                StringComparison.OrdinalIgnoreCase))
        {
            return rootHandle;
        }

        var currentPath = Path.TrimEndingDirectorySeparator(rootPath);
        var relative = Path.GetRelativePath(rootPath, directoryPath);
        var currentHandle = rootHandle;
        try
        {
            foreach (var segment in relative.Split(
                         [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                         StringSplitOptions.RemoveEmptyEntries))
            {
                var nextPath = Path.Combine(currentPath, segment);
                var nextHandle = NtCreateRelative(
                    currentHandle,
                    segment,
                    FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES
                    | (allowCreate ? DELETE : 0) | SYNCHRONIZE,
                    FILE_ATTRIBUTE_DIRECTORY,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    allowCreate ? FILE_OPEN_IF : FILE_OPEN,
                    FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT,
                    out var created);
                try
                {
                    ValidateHandle(rootPath, nextPath, nextHandle, expectDirectory: true);
                }
                catch (Exception validationError)
                {
                    try
                    {
                        if (created)
                            DeleteCreated(nextHandle);
                    }
                    catch (Exception cleanupError)
                    {
                        throw new AggregateException(
                            "Directory validation failed and the raced creation could not be removed.",
                            validationError,
                            cleanupError);
                    }
                    finally
                    {
                        nextHandle.Dispose();
                    }

                    throw;
                }

                currentHandle.Dispose();
                currentHandle = nextHandle;
                currentPath = nextPath;
            }

            return currentHandle;
        }
        catch
        {
            currentHandle.Dispose();
            throw;
        }
    }

    private static SafeFileHandle OpenRootDirectory(string rootPath)
    {
        var handle = CreateFileW(
            rootPath,
            FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            ThrowPathError(error, rootPath);
        }

        try
        {
            ValidateHandle(rootPath, rootPath, handle, expectDirectory: true);
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static SafeFileHandle NtCreateRelative(
        SafeFileHandle parentHandle,
        string name,
        uint desiredAccess,
        uint fileAttributes,
        uint shareAccess,
        uint createDisposition,
        uint createOptions,
        out bool created)
    {
        if (string.IsNullOrEmpty(name)
            || name.Contains(Path.DirectorySeparatorChar)
            || name.Contains(Path.AltDirectorySeparatorChar)
            || name is "." or "..")
        {
            throw new UnauthorizedAccessException("Relative file name is invalid.");
        }

        var nameBuffer = Marshal.StringToHGlobalUni(name);
        var unicodeStringPointer = IntPtr.Zero;
        try
        {
            var unicodeString = new UNICODE_STRING
            {
                Length = checked((ushort)(name.Length * sizeof(char))),
                MaximumLength = checked((ushort)((name.Length + 1) * sizeof(char))),
                Buffer = nameBuffer
            };
            unicodeStringPointer = Marshal.AllocHGlobal(
                Marshal.SizeOf<UNICODE_STRING>());
            Marshal.StructureToPtr(unicodeString, unicodeStringPointer, fDeleteOld: false);
            var objectAttributes = new OBJECT_ATTRIBUTES
            {
                Length = Marshal.SizeOf<OBJECT_ATTRIBUTES>(),
                RootDirectory = parentHandle.DangerousGetHandle(),
                ObjectName = unicodeStringPointer,
                Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE
            };
            var status = NtCreateFile(
                out var rawHandle,
                desiredAccess,
                ref objectAttributes,
                out var ioStatus,
                IntPtr.Zero,
                fileAttributes,
                shareAccess,
                createDisposition,
                createOptions | FILE_SYNCHRONOUS_IO_NONALERT,
                IntPtr.Zero,
                0);
            if (status < 0)
            {
                var error = unchecked((int)RtlNtStatusToDosError(status));
                ThrowPathError(error, name);
            }

            created = ioStatus.Information == (UIntPtr)2;
            return new SafeFileHandle(rawHandle, ownsHandle: true);
        }
        finally
        {
            if (unicodeStringPointer != IntPtr.Zero)
                Marshal.FreeHGlobal(unicodeStringPointer);
            Marshal.FreeHGlobal(nameBuffer);
        }
    }

    private static void ValidateHandle(
        string rootPath,
        string expectedPath,
        SafeFileHandle handle,
        bool expectDirectory)
    {
        if (!GetFileInformationByHandleEx(
                handle,
                FileAttributeTagInfo,
                out FILE_ATTRIBUTE_TAG_INFO tagInfo,
                (uint)Marshal.SizeOf<FILE_ATTRIBUTE_TAG_INFO>()))
        {
            ThrowLastWin32("GetFileInformationByHandleEx");
        }

        if ((tagInfo.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            throw new UnauthorizedAccessException("Verified handle is a reparse point.");
        var isDirectory = (tagInfo.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (isDirectory != expectDirectory)
            throw new UnauthorizedAccessException("Verified handle has the wrong file type.");

        var finalPath = GetFinalPath(handle);
        var expected = Path.GetFullPath(expectedPath);
        var root = Path.GetFullPath(rootPath);
        EnsureWithinRoot(root, finalPath, allowEqual: expectDirectory);
        if (!string.Equals(finalPath, expected, StringComparison.OrdinalIgnoreCase))
        {
            throw new UnauthorizedAccessException(
                "Handle final path changed or traversed a reparse point.");
        }
    }

    private static string GetFinalPath(SafeFileHandle handle)
    {
        var capacity = 512;
        while (true)
        {
            var buffer = new System.Text.StringBuilder(capacity);
            var length = GetFinalPathNameByHandleW(
                handle,
                buffer,
                (uint)buffer.Capacity,
                0);
            if (length == 0)
                ThrowLastWin32("GetFinalPathNameByHandle");
            if (length < buffer.Capacity)
                return NormalizeFinalPath(buffer.ToString());
            capacity = checked((int)length + 1);
        }
    }

    private static string NormalizeFinalPath(string path)
    {
        const string uncPrefix = @"\\?\UNC\";
        const string extendedPrefix = @"\\?\";
        if (path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase))
            path = @"\\" + path[uncPrefix.Length..];
        else if (path.StartsWith(extendedPrefix, StringComparison.OrdinalIgnoreCase))
            path = path[extendedPrefix.Length..];
        return Path.GetFullPath(path);
    }

    private static void EnsureWithinRoot(
        string rootPath,
        string path,
        bool allowEqual)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        var candidate = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        if (allowEqual && string.Equals(
                candidate,
                root,
                StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var rootWithSeparator = Path.EndsInDirectorySeparator(root)
            ? root
            : root + Path.DirectorySeparatorChar;
        if (!candidate.StartsWith(
                rootWithSeparator,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new UnauthorizedAccessException("Handle path is outside its managed root.");
        }
    }

    private static FILE_BASIC_INFO ReadBasicInfo(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleEx(
                handle,
                FileBasicInfo,
                out FILE_BASIC_INFO basicInfo,
                (uint)Marshal.SizeOf<FILE_BASIC_INFO>()))
        {
            ThrowLastWin32("GetFileInformationByHandleEx");
        }

        return basicInfo;
    }

    private static void RestoreBasicInfo(
        SafeFileHandle handle,
        FileBackupMetadata metadata)
    {
        var basicInfo = new FILE_BASIC_INFO
        {
            CreationTime = metadata.CreationTimeUtc?.ToFileTimeUtc() ?? 0,
            LastAccessTime = metadata.LastAccessTimeUtc?.ToFileTimeUtc() ?? 0,
            LastWriteTime = metadata.LastWriteTimeUtc?.ToFileTimeUtc() ?? 0,
            ChangeTime = 0,
            FileAttributes = checked((uint)metadata.Attributes)
        };
        if (!SetFileInformationByHandle(
                handle,
                FileBasicInfo,
                ref basicInfo,
                (uint)Marshal.SizeOf<FILE_BASIC_INFO>()))
        {
            ThrowLastWin32("SetFileInformationByHandle");
        }
    }

    private static FileBackupMetadata ToBackupMetadata(
        FILE_BASIC_INFO basicInfo,
        string securityDescriptor) =>
        new(
            true,
            basicInfo.FileAttributes,
            DateTime.FromFileTimeUtc(basicInfo.CreationTime),
            DateTime.FromFileTimeUtc(basicInfo.LastWriteTime),
            DateTime.FromFileTimeUtc(basicInfo.LastAccessTime),
            securityDescriptor);

    private static void ClearReadOnly(SafeFileHandle handle)
    {
        var basicInfo = ReadBasicInfo(handle);
        const uint readOnly = (uint)FileAttributes.ReadOnly;
        if ((basicInfo.FileAttributes & readOnly) == 0)
            return;
        basicInfo.FileAttributes &= ~readOnly;
        if (!SetFileInformationByHandle(
                handle,
                FileBasicInfo,
                ref basicInfo,
                (uint)Marshal.SizeOf<FILE_BASIC_INFO>()))
        {
            ThrowLastWin32("SetFileInformationByHandle");
        }
    }

    private static string ReadDacl(SafeFileHandle handle)
    {
        _ = GetKernelObjectSecurity(
            handle,
            DaclSecurityInformation,
            null,
            0,
            out var required);
        if (required == 0 || Marshal.GetLastWin32Error() != ErrorInsufficientBuffer)
            ThrowLastWin32("GetKernelObjectSecurity");
        var descriptor = new byte[required];
        if (!GetKernelObjectSecurity(
                handle,
                DaclSecurityInformation,
                descriptor,
                required,
                out _))
        {
            ThrowLastWin32("GetKernelObjectSecurity");
        }

        return Convert.ToBase64String(descriptor);
    }

    private static void RestoreDacl(
        SafeFileHandle handle,
        string? encodedDescriptor)
    {
        if (string.IsNullOrEmpty(encodedDescriptor))
            return;
        var descriptor = Convert.FromBase64String(encodedDescriptor);
        if (!SetKernelObjectSecurity(
                handle,
                DaclSecurityInformation,
                descriptor))
        {
            ThrowLastWin32("SetKernelObjectSecurity");
        }
    }

    private static void MarkDelete(SafeFileHandle handle)
    {
        var disposition = new FILE_DISPOSITION_INFO_EX
        {
            Flags = FILE_DISPOSITION_FLAG_DELETE
                    | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS
                    | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE
        };
        if (SetFileInformationByHandle(
                handle,
                FileDispositionInfoEx,
                ref disposition,
                (uint)Marshal.SizeOf<FILE_DISPOSITION_INFO_EX>()))
        {
            return;
        }

        var fallback = new FILE_DISPOSITION_INFO { DeleteFile = true };
        if (!SetFileInformationByHandle(
                handle,
                FileDispositionInfo,
                ref fallback,
                (uint)Marshal.SizeOf<FILE_DISPOSITION_INFO>()))
        {
            ThrowLastWin32("SetFileInformationByHandle");
        }
    }

    private static void DeleteCreated(SafeFileHandle handle)
    {
        ClearReadOnly(handle);
        MarkDelete(handle);
    }

    private static bool Sha256Matches(string expected, string actual)
    {
        if (expected.Length != 64 || actual.Length != 64)
            return false;
        return CryptographicOperations.FixedTimeEquals(
            Convert.FromHexString(expected),
            Convert.FromHexString(actual));
    }

    private static void ThrowPathError(int error, string path)
    {
        if (error == ErrorFileNotFound)
            throw new FileNotFoundException("Managed file was not found.", path);
        if (error == ErrorPathNotFound)
            throw new DirectoryNotFoundException($"Managed path '{path}' was not found.");
        if (error is ErrorCantAccessFile
            or ErrorNotAReparsePoint
            or ErrorReparseAttributeConflict
            or ErrorInvalidReparseData
            or ErrorReparseTagInvalid
            or ErrorReparseTagMismatch
            or ErrorReparsePointEncountered)
        {
            throw new UnauthorizedAccessException(
                $"Managed path '{path}' encountered a reparse point.");
        }
        throw new System.ComponentModel.Win32Exception(error);
    }

    private static void ThrowLastWin32(string operation) =>
        throw new IOException(
            $"{operation} failed.",
            new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));

    internal sealed class BoundFile : IDisposable
    {
        private readonly SafeFileHandle _parentHandle;

        public BoundFile(
            SafeFileHandle handle,
            SafeFileHandle parentHandle)
        {
            Handle = handle;
            _parentHandle = parentHandle;
        }

        public SafeFileHandle Handle { get; }

        public void Dispose()
        {
            Handle.Dispose();
            _parentHandle.Dispose();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_STATUS_BLOCK
    {
        public IntPtr Status;
        public UIntPtr Information;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_ATTRIBUTE_TAG_INFO
    {
        public uint FileAttributes;
        public uint ReparseTag;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_BASIC_INFO
    {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_DISPOSITION_INFO_EX
    {
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_DISPOSITION_INFO
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool DeleteFile;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtCreateFile(
        out IntPtr fileHandle,
        uint desiredAccess,
        ref OBJECT_ATTRIBUTES objectAttributes,
        out IO_STATUS_BLOCK ioStatusBlock,
        IntPtr allocationSize,
        uint fileAttributes,
        uint shareAccess,
        uint createDisposition,
        uint createOptions,
        IntPtr eaBuffer,
        uint eaLength);

    [DllImport("ntdll.dll")]
    private static extern uint RtlNtStatusToDosError(int status);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file,
        System.Text.StringBuilder filePath,
        uint filePathLength,
        uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file,
        int fileInformationClass,
        out FILE_ATTRIBUTE_TAG_INFO fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file,
        int fileInformationClass,
        out FILE_BASIC_INFO fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle file,
        int fileInformationClass,
        ref FILE_BASIC_INFO fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle file,
        int fileInformationClass,
        ref FILE_DISPOSITION_INFO_EX fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle file,
        int fileInformationClass,
        ref FILE_DISPOSITION_INFO fileInformation,
        uint bufferSize);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetKernelObjectSecurity(
        SafeFileHandle handle,
        uint requestedInformation,
        byte[]? securityDescriptor,
        int length,
        out int lengthNeeded);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetKernelObjectSecurity(
        SafeFileHandle handle,
        uint securityInformation,
        byte[] securityDescriptor);
}
#endif

internal static class WindowsFileSecurity
{
    private const uint DaclSecurityInformation = 0x00000004;
    private const int ErrorInsufficientBuffer = 122;

    public static string? TryReadDacl(string path)
    {
#if WINDOWS
        if (!OperatingSystem.IsWindows())
            return null;
        _ = GetFileSecurityW(
            path,
            DaclSecurityInformation,
            null,
            0,
            out var required);
        if (required == 0 || Marshal.GetLastWin32Error() != ErrorInsufficientBuffer)
            throw new IOException("Unable to size the file ACL.", new System.ComponentModel.Win32Exception());
        var descriptor = new byte[required];
        if (!GetFileSecurityW(
                path,
                DaclSecurityInformation,
                descriptor,
                required,
                out _))
        {
            throw new IOException("Unable to read the file ACL.", new System.ComponentModel.Win32Exception());
        }

        return Convert.ToBase64String(descriptor);
#else
        return null;
#endif
    }

    public static void TryRestoreDacl(string path, string? encodedDescriptor)
    {
#if WINDOWS
        if (!OperatingSystem.IsWindows() || string.IsNullOrEmpty(encodedDescriptor))
            return;
        var descriptor = Convert.FromBase64String(encodedDescriptor);
        if (!SetFileSecurityW(path, DaclSecurityInformation, descriptor))
            throw new IOException("Unable to restore the file ACL.", new System.ComponentModel.Win32Exception());
#endif
    }

#if WINDOWS
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileSecurityW(
        string lpFileName,
        uint requestedInformation,
        byte[]? pSecurityDescriptor,
        int nLength,
        out int lpnLengthNeeded);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileSecurityW(
        string lpFileName,
        uint securityInformation,
        byte[] pSecurityDescriptor);
#endif
}
