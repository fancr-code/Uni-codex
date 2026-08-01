using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class TransactionTests : IDisposable
{
    private readonly string _temporaryRoot = Path.Combine(
        Path.GetTempPath(),
        "codex-transaction-tests",
        Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task Journal_entry_is_durable_before_each_managed_target_is_changed()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(target, "before", Metadata(1));
        var observedPreChangeEntry = false;
        fileSystem.BeforeReplace = (_, replaceNumber) =>
        {
            var journal = Directory.GetFiles(
                transactions,
                "journal.jsonl",
                SearchOption.AllDirectories).Single();
            var line = File.ReadLines(journal)
                .Select(text => JsonDocument.Parse(text))
                .Select(document => document.RootElement)
                .Single(element =>
                    element.TryGetProperty("sequence", out var sequence)
                    && sequence.GetInt32() == replaceNumber
                    && element.GetProperty("action").GetString() == "replaceFile");
            observedPreChangeEntry =
                !line.GetProperty("completed").GetBoolean()
                && line.GetProperty("targetKey").GetString() == "codex.config";
        };
        var service = Service(
            transactions,
            fileSystem,
            Target("codex.config", targetRoot, target));

        var result = await service.ExecuteAsync(
            [TransactionChange.ReplaceFile("codex.config", Bytes("after"))]);

        Assert.Equal(TransactionState.Committed, result.State);
        Assert.True(observedPreChangeEntry);
        var journalText = File.ReadAllText(Path.Combine(
            transactions,
            result.TransactionId.ToString("N"),
            "journal.jsonl"));
        Assert.DoesNotContain(target, journalText, StringComparison.Ordinal);
        Assert.Contains("\"targetKey\":\"codex.config\"", journalText, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Third_change_failure_restores_content_metadata_and_deletes_new_files()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var first = Path.Combine(targetRoot, "one.txt");
        var second = Path.Combine(targetRoot, "two.txt");
        var third = Path.Combine(targetRoot, "three.txt");
        var unrelated = Path.Combine(targetRoot, "unrelated.txt");
        var firstMetadata = Metadata(10);
        var thirdMetadata = Metadata(30);
        var fileSystem = new FakeTransactionFileSystem { FailReplaceNumber = 3 };
        fileSystem.Seed(first, "one-before", firstMetadata);
        fileSystem.Seed(third, "three-before", thirdMetadata);
        fileSystem.Seed(unrelated, "leave-me-alone", Metadata(99));
        var service = Service(
            Path.Combine(_temporaryRoot, "transactions"),
            fileSystem,
            Target("one", targetRoot, first),
            Target("two", targetRoot, second),
            Target("three", targetRoot, third));

        await Assert.ThrowsAsync<IOException>(() => service.ExecuteAsync(
        [
            TransactionChange.ReplaceFile("one", Bytes("one-after")),
            TransactionChange.ReplaceFile("two", Bytes("two-after")),
            TransactionChange.ReplaceFile("three", Bytes("three-after"))
        ]));

        Assert.Equal("one-before", fileSystem.Read(first));
        Assert.Equal(firstMetadata, fileSystem.Metadata(first));
        Assert.False(fileSystem.Exists(targetRoot, second));
        Assert.Equal("three-before", fileSystem.Read(third));
        Assert.Equal(thirdMetadata, fileSystem.Metadata(third));
        Assert.Equal("leave-me-alone", fileSystem.Read(unrelated));
        Assert.Equal(
            TransactionState.RolledBack,
            ReadState(Directory.GetDirectories(
                Path.Combine(_temporaryRoot, "transactions")).Single()));
    }

    [Theory]
    [InlineData("applying")]
    [InlineData("verifying")]
    public async Task Startup_recovers_interrupted_applying_and_verifying_transactions(
        string interruptedState)
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var transactionId = Guid.NewGuid();
        var transactionDirectory = Path.Combine(
            transactions,
            transactionId.ToString("N"));
        var backup = Path.Combine(transactionDirectory, "backups", "0001");
        Directory.CreateDirectory(Path.GetDirectoryName(backup)!);
        var metadata = Metadata(7);
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(target, "partially-applied", Metadata(70));
        fileSystem.SeedBackup(backup, "before-crash");
        File.WriteAllText(
            Path.Combine(transactionDirectory, "state.json"),
            $$"""{"state":"{{interruptedState}}"}""");
        var journalEntry = new
        {
            sequence = 1,
            action = "replaceFile",
            targetKey = "codex.config",
            backup = "backups/0001",
            beforeSha256 = Convert.ToHexString(
                SHA256.HashData(Bytes("before-crash"))).ToLowerInvariant(),
            completed = false,
            backupMetadata = metadata
        };
        File.WriteAllText(
            Path.Combine(transactionDirectory, "journal.jsonl"),
            JsonSerializer.Serialize(journalEntry, JsonOptions) + Environment.NewLine);
        var service = Service(
            transactions,
            fileSystem,
            Target("codex.config", targetRoot, target));

        var recovered = await service.RecoverIncompleteAsync();

        Assert.Equal([transactionId], recovered);
        Assert.Equal("before-crash", fileSystem.Read(target));
        Assert.Equal(metadata, fileSystem.Metadata(target));
        Assert.Equal(TransactionState.RolledBack, ReadState(transactionDirectory));
    }

    [Fact]
    public async Task Recovery_ignores_only_a_truncated_final_journal_record()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var transactionId = Guid.NewGuid();
        var metadata = Metadata(8);
        var fileSystem = new FakeTransactionFileSystem();
        var transactionDirectory = CreateRecoveryFixture(
            transactions,
            transactionId,
            "applying",
            JournalEntry(1, "codex.config", "backups/0001", "before-crash", metadata));
        var backup = Path.Combine(transactionDirectory, "backups", "0001");
        fileSystem.Seed(target, "partially-applied", Metadata(80));
        fileSystem.SeedBackup(backup, "before-crash");
        File.AppendAllText(
            Path.Combine(transactionDirectory, "journal.jsonl"),
            "{\"sequence\":1,\"action\":\"replaceFile\",\"targetKey\":\"codex.config\"");
        var service = Service(
            transactions,
            fileSystem,
            Target("codex.config", targetRoot, target));

        var recovered = await service.RecoverIncompleteAsync();

        Assert.Equal([transactionId], recovered);
        Assert.Equal("before-crash", fileSystem.Read(target));
        Assert.Equal(metadata, fileSystem.Metadata(target));
    }

    [Fact]
    public async Task Recovery_rejects_a_corrupt_middle_journal_record()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var first = Path.Combine(targetRoot, "one.txt");
        var second = Path.Combine(targetRoot, "two.txt");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var transactionId = Guid.NewGuid();
        var transactionDirectory = CreateRecoveryFixture(
            transactions,
            transactionId,
            "applying",
            JournalEntry(1, "one", "backups/0001", "one-before", Metadata(1)));
        File.AppendAllText(
            Path.Combine(transactionDirectory, "journal.jsonl"),
            "{broken-middle}" + Environment.NewLine
            + JsonSerializer.Serialize(
                JournalEntry(2, "two", "backups/0002", "two-before", Metadata(2)),
                JsonOptions)
            + Environment.NewLine);
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(first, "one-after", Metadata(11));
        fileSystem.Seed(second, "two-after", Metadata(22));
        fileSystem.SeedBackup(
            Path.Combine(transactionDirectory, "backups", "0001"),
            "one-before");
        fileSystem.SeedBackup(
            Path.Combine(transactionDirectory, "backups", "0002"),
            "two-before");
        var service = Service(
            transactions,
            fileSystem,
            Target("one", targetRoot, first),
            Target("two", targetRoot, second));

        await Assert.ThrowsAsync<InvalidDataException>(
            () => service.RecoverIncompleteAsync());

        Assert.Equal("one-after", fileSystem.Read(first));
        Assert.Equal("two-after", fileSystem.Read(second));
        Assert.Equal(TransactionState.Applying, ReadState(transactionDirectory));
    }

    [Fact]
    public async Task Recovery_requires_the_exact_backup_name_for_the_sequence()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var transactionDirectory = CreateRecoveryFixture(
            transactions,
            Guid.NewGuid(),
            "applying",
            JournalEntry(1, "codex.config", "backups/0002", "before", Metadata(1)));
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(target, "after", Metadata(2));
        fileSystem.SeedBackup(
            Path.Combine(transactionDirectory, "backups", "0002"),
            "before");
        var service = Service(
            transactions,
            fileSystem,
            Target("codex.config", targetRoot, target));

        await Assert.ThrowsAsync<InvalidDataException>(
            () => service.RecoverIncompleteAsync());

        Assert.Equal("after", fileSystem.Read(target));
    }

    [Fact]
    public async Task Recovery_rejects_a_backup_whose_hash_no_longer_matches()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var transactionDirectory = CreateRecoveryFixture(
            transactions,
            Guid.NewGuid(),
            "verifying",
            JournalEntry(1, "codex.config", "backups/0001", "original", Metadata(4)));
        var backup = Path.Combine(transactionDirectory, "backups", "0001");
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(target, "applied", Metadata(40));
        fileSystem.SeedBackup(backup, "tampered");
        var service = Service(
            transactions,
            fileSystem,
            Target("codex.config", targetRoot, target));

        await Assert.ThrowsAsync<InvalidDataException>(
            () => service.RecoverIncompleteAsync());

        Assert.Equal("applied", fileSystem.Read(target));
    }

    [Fact]
    public async Task Recovery_rejects_a_reparse_point_in_the_backup_chain()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var transactionDirectory = CreateRecoveryFixture(
            transactions,
            Guid.NewGuid(),
            "applying",
            JournalEntry(1, "codex.config", "backups/0001", "before", Metadata(4)));
        var backupRoot = Path.Combine(transactionDirectory, "backups");
        var backup = Path.Combine(backupRoot, "0001");
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(target, "after", Metadata(40));
        fileSystem.SeedBackup(backup, "before");
        fileSystem.ReparsePoints.Add(backupRoot);
        var service = Service(
            transactions,
            fileSystem,
            Target("codex.config", targetRoot, target));

        await Assert.ThrowsAsync<UnauthorizedAccessException>(
            () => service.RecoverIncompleteAsync());

        Assert.Equal("after", fileSystem.Read(target));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Reparse_points_in_managed_or_transaction_root_ancestors_are_rejected(
        bool linkIsTransactionAncestor)
    {
        var realRoot = Path.Combine(_temporaryRoot, "real");
        var linkedRoot = Path.Combine(_temporaryRoot, "linked");
        Directory.CreateDirectory(Path.Combine(realRoot, "managed"));
        Directory.CreateDirectory(Path.Combine(realRoot, "transactions"));
        Directory.CreateSymbolicLink(linkedRoot, realRoot);
        var managedRoot = linkIsTransactionAncestor
            ? Path.Combine(realRoot, "managed")
            : Path.Combine(linkedRoot, "managed");
        var transactions = linkIsTransactionAncestor
            ? Path.Combine(linkedRoot, "transactions")
            : Path.Combine(realRoot, "transactions");
        var target = Path.Combine(managedRoot, "config.toml");
        var service = new TransactionService(
            transactions,
            new ManagedTargetCatalog(
                [Target("codex.config", managedRoot, target)]));

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => service.ExecuteAsync(
            [TransactionChange.ReplaceFile("codex.config", Bytes("bad"))]));
    }

    [Fact]
    public async Task A_chain_swapped_to_a_reparse_point_at_the_open_boundary_is_rejected()
    {
        var managedRoot = Path.Combine(_temporaryRoot, "managed");
        var linkedParent = Path.Combine(managedRoot, "linked");
        var target = Path.Combine(linkedParent, "config.toml");
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(target, "before", Metadata(6));
        fileSystem.BeforeReplace = (_, _) =>
            fileSystem.ReparsePoints.Add(linkedParent);
        fileSystem.RejectUnsafePathAtOpenBoundary = true;
        var service = Service(
            Path.Combine(_temporaryRoot, "transactions"),
            fileSystem,
            Target("codex.config", managedRoot, target));

        var error = await Assert.ThrowsAsync<AggregateException>(() => service.ExecuteAsync(
            [TransactionChange.ReplaceFile("codex.config", Bytes("outside"))]));

        Assert.All(
            error.Flatten().InnerExceptions,
            inner => Assert.IsType<UnauthorizedAccessException>(inner));
        Assert.Equal("before", fileSystem.Read(target));
    }

    [Fact]
    public void Windows_physical_filesystem_binds_mutations_to_verified_handles()
    {
        var source = File.ReadAllText(Path.Combine(
            FindWindowsRoot(),
            "src",
            "InstallerCore",
            "Services",
            "TransactionService.cs"));

        Assert.Contains("NtCreateFile(", source, StringComparison.Ordinal);
        Assert.Contains("GetFinalPathNameByHandleW(", source, StringComparison.Ordinal);
        Assert.Contains("GetFileInformationByHandleEx(", source, StringComparison.Ordinal);
        Assert.Contains("SetFileInformationByHandle(", source, StringComparison.Ordinal);
        Assert.Contains("GetKernelObjectSecurity(", source, StringComparison.Ordinal);
        Assert.Contains("SetKernelObjectSecurity(", source, StringComparison.Ordinal);
        Assert.Contains("FILE_OPEN_REPARSE_POINT", source, StringComparison.Ordinal);
        Assert.Contains(
            "createOptions | FILE_SYNCHRONOUS_IO_NONALERT",
            source,
            StringComparison.Ordinal);
        Assert.Contains("Path.EndsInDirectorySeparator(root)", source, StringComparison.Ordinal);
        Assert.Contains("FileDispositionInfoEx", source, StringComparison.Ordinal);
        Assert.Contains("#if WINDOWS", source, StringComparison.Ordinal);
    }

    [Fact]
    public void Windows_physical_filesystem_accepts_a_drive_root_as_managed_root()
    {
        if (!OperatingSystem.IsWindows())
            return;

        var root = Path.GetPathRoot(_temporaryRoot)!;
        new ManagedPathGuard().EnsureManagedDirectory(root, _temporaryRoot);
    }

    [Fact]
    public async Task Windows_physical_filesystem_never_writes_through_a_junction()
    {
        if (!OperatingSystem.IsWindows())
            return;

        var managedRoot = Path.Combine(_temporaryRoot, "managed");
        var outsideRoot = Path.Combine(_temporaryRoot, "outside");
        var junction = Path.Combine(managedRoot, "swapped");
        var target = Path.Combine(junction, "config.toml");
        Directory.CreateDirectory(managedRoot);
        Directory.CreateDirectory(outsideRoot);
        var start = new System.Diagnostics.ProcessStartInfo("cmd.exe")
        {
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };
        start.ArgumentList.Add("/d");
        start.ArgumentList.Add("/c");
        start.ArgumentList.Add("mklink");
        start.ArgumentList.Add("/J");
        start.ArgumentList.Add(junction);
        start.ArgumentList.Add(outsideRoot);
        using var process = System.Diagnostics.Process.Start(start)
                            ?? throw new InvalidOperationException("Unable to start mklink.");
        await process.WaitForExitAsync();
        Assert.True(
            process.ExitCode == 0,
            await process.StandardError.ReadToEndAsync());
        var fileSystem = new PhysicalTransactionFileSystem();

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            fileSystem.ReplaceFileAsync(
                managedRoot,
                target,
                Bytes("must-not-escape"),
                CancellationToken.None));

        Assert.False(File.Exists(Path.Combine(outsideRoot, "config.toml")));
    }

    [Fact]
    public async Task Unknown_target_key_is_rejected_without_writing_a_journal()
    {
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var service = Service(
            transactions,
            new FakeTransactionFileSystem(),
            Target(
                "known",
                Path.Combine(_temporaryRoot, "managed"),
                Path.Combine(_temporaryRoot, "managed", "known.txt")));

        await Assert.ThrowsAsync<KeyNotFoundException>(() => service.ExecuteAsync(
            [TransactionChange.ReplaceFile("user-path", Bytes("bad"))]));

        Assert.Empty(Directory.Exists(transactions)
            ? Directory.GetDirectories(transactions)
            : []);
    }

    [Fact]
    public async Task Path_outside_the_declared_root_is_rejected()
    {
        var managedRoot = Path.Combine(_temporaryRoot, "managed");
        var outside = Path.Combine(_temporaryRoot, "outside.txt");
        var service = Service(
            Path.Combine(_temporaryRoot, "transactions"),
            new FakeTransactionFileSystem(),
            Target("escape", managedRoot, outside));

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => service.ExecuteAsync(
            [TransactionChange.ReplaceFile("escape", Bytes("bad"))]));
    }

    [Fact]
    public async Task Reparse_points_are_rejected_before_staging()
    {
        var managedRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(managedRoot, "linked", "config.toml");
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.ReparsePoints.Add(Path.Combine(managedRoot, "linked"));
        var service = Service(
            Path.Combine(_temporaryRoot, "transactions"),
            fileSystem,
            Target("linked", managedRoot, target));

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => service.ExecuteAsync(
            [TransactionChange.ReplaceFile("linked", Bytes("bad"))]));
    }

    [Fact]
    public async Task WindowsApps_requires_explicit_catalog_authorization()
    {
        var managedRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(managedRoot, "WindowsApps", "Codex", "config.toml");
        var service = Service(
            Path.Combine(_temporaryRoot, "transactions"),
            new FakeTransactionFileSystem(),
            Target("windows-app", managedRoot, target, allowWindowsApps: false));

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => service.ExecuteAsync(
            [TransactionChange.ReplaceFile("windows-app", Bytes("bad"))]));
    }

    [Fact]
    public async Task Transaction_uses_only_the_fixed_state_transitions()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var transactions = Path.Combine(_temporaryRoot, "transactions");
        var service = Service(
            transactions,
            new FakeTransactionFileSystem(),
            Target("codex.config", targetRoot, target));

        var result = await service.ExecuteAsync(
            [TransactionChange.ReplaceFile("codex.config", Bytes("after"))]);

        var states = File.ReadLines(Path.Combine(
                transactions,
                result.TransactionId.ToString("N"),
                "state-history.jsonl"))
            .Select(line => JsonDocument.Parse(line).RootElement
                .GetProperty("state").GetString()!)
            .ToArray();
        Assert.Equal(
            ["planned", "staged", "applying", "verifying", "committed"],
            states);
    }

    [Fact]
    public async Task Cancellation_waits_for_work_to_exit_before_rollback_starts()
    {
        var targetRoot = Path.Combine(_temporaryRoot, "managed");
        var target = Path.Combine(targetRoot, "config.toml");
        var fileSystem = new FakeTransactionFileSystem();
        fileSystem.Seed(target, "before", Metadata(5));
        var service = Service(
            Path.Combine(_temporaryRoot, "transactions"),
            fileSystem,
            Target("codex.config", targetRoot, target));
        var workStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var allowWorkToExit = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using var cancellation = new CancellationTokenSource();

        var transaction = service.ExecuteAsync(
            [TransactionChange.ReplaceFile("codex.config", Bytes("applied"))],
            async token =>
            {
                workStarted.TrySetResult();
                try
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, token);
                }
                catch (OperationCanceledException)
                {
                    await allowWorkToExit.Task;
                }
            },
            cancellation.Token);
        await workStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        await Task.Delay(25);

        Assert.False(transaction.IsCompleted);
        Assert.Equal("applied", fileSystem.Read(target));

        allowWorkToExit.TrySetResult();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => transaction);
        Assert.Equal("before", fileSystem.Read(target));
    }

    [Fact]
    public async Task External_mutation_session_restores_directory_registry_and_file_targets()
    {
        var transactionRoot = Path.Combine(_temporaryRoot, "external");
        var directory = ExternalProvider(
            ExternalMutationTargetKind.Directory,
            "directory-before");
        var registry = ExternalProvider(
            ExternalMutationTargetKind.RegistryKey,
            "registry-before",
            ExternalMutationProviderScope.CurrentUser);
        var file = ExternalProvider(
            ExternalMutationTargetKind.File,
            "file-before");
        var coordinator = ExternalCoordinator(
            transactionRoot,
            ("codex.program", directory),
            ("codex.registry", registry),
            ("codex.shortcut", file));
        var session = await coordinator.BeginExternalMutationAsync(
            ["codex.program", "codex.registry", "codex.shortcut"]);
        await session.MarkApplyingAsync();
        directory.Value = "directory-after";
        registry.Value = "registry-after";
        file.Value = "file-after";

        await session.RollBackAsync();

        Assert.Equal("directory-before", directory.Value);
        Assert.Equal("registry-before", registry.Value);
        Assert.Equal("file-before", file.Value);
        Assert.Equal(TransactionState.RolledBack, session.State);
    }

    [Fact]
    public async Task External_snapshot_failure_on_third_target_cleans_only_this_session()
    {
        var first = ExternalProvider(ExternalMutationTargetKind.Directory, "first");
        var second = ExternalProvider(ExternalMutationTargetKind.File, "second");
        var third = ExternalProvider(ExternalMutationTargetKind.File, "third");
        third.FailCapture = true;
        var coordinator = ExternalCoordinator(
            Path.Combine(_temporaryRoot, "external"),
            ("first", first),
            ("second", second),
            ("third", third));

        await Assert.ThrowsAsync<IOException>(() =>
            coordinator.BeginExternalMutationAsync(["first", "second", "third"]));

        Assert.Equal(1, first.CleanupCalls);
        Assert.Equal(1, second.CleanupCalls);
        Assert.Equal(1, third.CleanupCalls);
        Assert.Equal(0, first.RestoreCalls);
        Assert.Equal(0, second.RestoreCalls);
        Assert.Equal("first", first.Value);
        Assert.Equal("second", second.Value);
    }

    [Fact]
    public async Task External_third_mutation_failure_rolls_back_prior_targets()
    {
        var first = ExternalProvider(ExternalMutationTargetKind.Directory, "first-before");
        var second = ExternalProvider(ExternalMutationTargetKind.File, "second-before");
        var third = ExternalProvider(ExternalMutationTargetKind.File, "third-before");
        third.FailMutation = true;
        var coordinator = ExternalCoordinator(
            Path.Combine(_temporaryRoot, "external"),
            ("first", first),
            ("second", second),
            ("third", third));
        var session = await coordinator.BeginExternalMutationAsync(
            ["first", "second", "third"]);
        await session.MarkApplyingAsync();
        first.Apply("first-after");
        second.Apply("second-after");

        Assert.Throws<IOException>(() => third.Apply("third-after"));
        await session.RollBackAsync();

        Assert.Equal("first-before", first.Value);
        Assert.Equal("second-before", second.Value);
        Assert.Equal("third-before", third.Value);
        Assert.Equal(1, first.RestoreCalls);
        Assert.Equal(1, second.RestoreCalls);
        Assert.Equal(1, third.RestoreCalls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task External_startup_recovers_staged_and_applying_sessions(
        bool markApplying)
    {
        var transactionRoot = Path.Combine(_temporaryRoot, "external");
        var provider = ExternalProvider(
            ExternalMutationTargetKind.Directory,
            "before-crash");
        var coordinator = ExternalCoordinator(
            transactionRoot,
            ("codex.program", provider));
        var session = await coordinator.BeginExternalMutationAsync(["codex.program"]);
        if (markApplying)
            await session.MarkApplyingAsync();
        provider.Value = "after-crash";
        var restartedProvider = provider.Fork();
        var restarted = ExternalCoordinator(
            transactionRoot,
            ("codex.program", restartedProvider));

        var recovered = await restarted.RecoverIncompleteAsync();

        Assert.Equal([session.TransactionId], recovered);
        Assert.Equal("before-crash", provider.Value);
        Assert.Equal(1, restartedProvider.RestoreCalls);
    }

    [Fact]
    public async Task External_recovery_rejects_a_snapshot_changed_on_disk()
    {
        var transactionRoot = Path.Combine(_temporaryRoot, "external");
        var provider = ExternalProvider(
            ExternalMutationTargetKind.File,
            "before-crash");
        var coordinator = ExternalCoordinator(
            transactionRoot,
            ("codex.config", provider));
        var session = await coordinator.BeginExternalMutationAsync(["codex.config"]);
        provider.Value = "after-crash";
        await File.WriteAllBytesAsync(
            Path.Combine(
                transactionRoot,
                session.TransactionId.ToString("N"),
                "backups",
                "0001",
                "snapshot.bin"),
            Bytes("tampered"));
        var restartedProvider = provider.Fork();
        var restarted = ExternalCoordinator(
            transactionRoot,
            ("codex.config", restartedProvider));

        await Assert.ThrowsAsync<InvalidDataException>(
            () => restarted.RecoverIncompleteAsync());

        Assert.Equal("after-crash", provider.Value);
        Assert.Equal(0, restartedProvider.RestoreCalls);
    }

    [Fact]
    public async Task Windows_external_transaction_root_junction_is_rejected()
    {
        if (!OperatingSystem.IsWindows())
            return;

        var outside = Path.Combine(_temporaryRoot, "external-outside");
        var junction = Path.Combine(_temporaryRoot, "external-junction");
        Directory.CreateDirectory(outside);
        await CreateJunctionAsync(junction, outside);
        var provider = ExternalProvider(
            ExternalMutationTargetKind.File,
            "before");
        var coordinator = ExternalCoordinator(
            junction,
            ("codex.config", provider));

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            coordinator.BeginExternalMutationAsync(["codex.config"]));

        Assert.False(File.Exists(Path.Combine(
            outside,
            "transactions.index.jsonl")));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Windows_external_recovery_rejects_guid_and_backups_junctions(
        bool replaceTransactionDirectory)
    {
        if (!OperatingSystem.IsWindows())
            return;

        var transactionRoot = Path.Combine(_temporaryRoot, "external");
        var provider = ExternalProvider(
            ExternalMutationTargetKind.File,
            "before-crash");
        var coordinator = ExternalCoordinator(
            transactionRoot,
            ("codex.config", provider));
        var session = await coordinator.BeginExternalMutationAsync(["codex.config"]);
        provider.Value = "after-crash";
        var transactionDirectory = Path.Combine(
            transactionRoot,
            session.TransactionId.ToString("N"));
        if (replaceTransactionDirectory)
        {
            var realDirectory = Path.Combine(
                _temporaryRoot,
                "external-transaction-real");
            Directory.Move(transactionDirectory, realDirectory);
            await CreateJunctionAsync(transactionDirectory, realDirectory);
        }
        else
        {
            var backups = Path.Combine(transactionDirectory, "backups");
            var realBackups = Path.Combine(transactionDirectory, "backups-real");
            Directory.Move(backups, realBackups);
            await CreateJunctionAsync(backups, realBackups);
        }

        var restartedProvider = provider.Fork();
        var restarted = ExternalCoordinator(
            transactionRoot,
            ("codex.config", restartedProvider));

        await Assert.ThrowsAsync<UnauthorizedAccessException>(
            () => restarted.RecoverIncompleteAsync());

        Assert.Equal("after-crash", provider.Value);
        Assert.Equal(0, restartedProvider.RestoreCalls);
    }

    [Fact]
    public async Task Durable_commit_never_rolls_back_when_cleanup_is_pending()
    {
        var transactionRoot = Path.Combine(_temporaryRoot, "external");
        var provider = ExternalProvider(
            ExternalMutationTargetKind.File,
            "before");
        provider.FailCleanupCount = 1;
        var coordinator = ExternalCoordinator(
            transactionRoot,
            ("codex.config", provider));
        var session = await coordinator.BeginExternalMutationAsync(["codex.config"]);
        await session.MarkApplyingAsync();
        provider.Value = "committed-value";

        var commit = await session.CommitAsync();

        Assert.Equal(TransactionState.Committed, session.State);
        Assert.True(commit.CleanupPending);
        Assert.Equal(["codex.config"], commit.PendingTargetKeys);
        Assert.Equal("committed-value", provider.Value);
        Assert.Equal(0, provider.RestoreCalls);
        var statePath = Path.Combine(
            transactionRoot,
            session.TransactionId.ToString("N"),
            "state.json");
        Assert.Contains("\"state\":\"committed\"", File.ReadAllText(statePath));
        var pendingPath = Path.Combine(
            transactionRoot,
            session.TransactionId.ToString("N"),
            "cleanup-pending.json");
        Assert.Contains(
            "codex.config",
            File.ReadAllText(pendingPath),
            StringComparison.Ordinal);

        var restartedProvider = provider.Fork();
        var restarted = ExternalCoordinator(
            transactionRoot,
            ("codex.config", restartedProvider));
        var pending = await restarted.RetryPendingCleanupAsync();

        Assert.Empty(pending);
        Assert.Equal("committed-value", provider.Value);
        Assert.Equal(0, provider.RestoreCalls);
        Assert.Equal(1, provider.CleanupCalls);
        Assert.Equal(1, restartedProvider.CleanupCalls);
        Assert.False(File.Exists(pendingPath));
    }

    [Fact]
    public async Task External_journal_contains_only_catalog_keys_and_fixed_backup_names()
    {
        var transactionRoot = Path.Combine(_temporaryRoot, "external");
        var provider = ExternalProvider(ExternalMutationTargetKind.File, "before");
        provider.SensitiveTargetPath = @"C:\Users\alice\secret\config.toml";
        var coordinator = ExternalCoordinator(
            transactionRoot,
            ("codex.config", provider));

        var session = await coordinator.BeginExternalMutationAsync(["codex.config"]);

        var journal = File.ReadAllText(Path.Combine(
            transactionRoot,
            session.TransactionId.ToString("N"),
            "journal.jsonl"));
        Assert.Contains("\"targetKey\":\"codex.config\"", journal);
        Assert.Contains("\"backup\":\"backups/0001\"", journal);
        Assert.Contains("\"schema\":\"fixture.external.v1\"", journal);
        Assert.Contains("\"length\":", journal);
        Assert.Contains("\"sha256\":", journal);
        Assert.DoesNotContain(provider.SensitiveTargetPath, journal, StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(
            transactionRoot,
            session.TransactionId.ToString("N"),
            "backups",
            "0001",
            "snapshot.bin")));
    }

    [Fact]
    public void External_registry_targets_are_hkcu_only()
    {
        var machineRegistry = ExternalProvider(
            ExternalMutationTargetKind.RegistryKey,
            "machine",
            ExternalMutationProviderScope.LocalMachine);

        Assert.Throws<ArgumentException>(() => ExternalCoordinator(
            Path.Combine(_temporaryRoot, "external"),
            ("machine.registry", machineRegistry)));
    }

    [Fact]
    public void External_target_kind_must_be_a_defined_whitelisted_value()
    {
        var undefined = ExternalProvider(
            (ExternalMutationTargetKind)999,
            "undefined");

        Assert.Throws<ArgumentException>(() => ExternalCoordinator(
            Path.Combine(_temporaryRoot, "external"),
            ("undefined", undefined)));
    }

    [Fact]
    public async Task Committed_cleanup_cancellation_is_recorded_not_thrown()
    {
        var provider = ExternalProvider(ExternalMutationTargetKind.File, "before");
        provider.CancelCleanupCount = 1;
        var coordinator = ExternalCoordinator(
            Path.Combine(_temporaryRoot, "external"),
            ("codex.config", provider));
        var session = await coordinator.BeginExternalMutationAsync(["codex.config"]);
        await session.MarkApplyingAsync();
        provider.Value = "committed";

        var result = await session.CommitAsync();

        Assert.True(result.CleanupPending);
        Assert.Equal(TransactionState.Committed, session.State);
        Assert.Equal("committed", provider.Value);
        Assert.Equal(0, provider.RestoreCalls);
    }

    [Fact]
    public void External_storage_uses_verified_handle_io_and_a_durable_index()
    {
        var source = File.ReadAllText(Path.Combine(
            FindWindowsRoot(),
            "src",
            "InstallerCore",
            "Services",
            "TransactionService.cs"));
        var externalStart = source.IndexOf(
            "public sealed class ExternalMutationCoordinator",
            StringComparison.Ordinal);
        var externalEnd = source.IndexOf(
            "public sealed class ManagedVerifiedRead",
            externalStart,
            StringComparison.Ordinal);
        var externalSource = source[externalStart..externalEnd];

        Assert.Contains("ManagedSnapshotWriter", externalSource, StringComparison.Ordinal);
        Assert.Contains("OpenVerifiedRead", externalSource, StringComparison.Ordinal);
        Assert.Contains("EnsureManagedDirectory", externalSource, StringComparison.Ordinal);
        Assert.Contains("transactions.index.jsonl", externalSource, StringComparison.Ordinal);
        Assert.DoesNotContain("Directory.EnumerateDirectories", externalSource, StringComparison.Ordinal);
        Assert.DoesNotContain("File.ReadAllText", externalSource, StringComparison.Ordinal);
        Assert.DoesNotContain("File.ReadLines", externalSource, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Managed_path_guard_opens_verified_reads_and_hashes()
    {
        var physicalTemporaryRoot =
            !OperatingSystem.IsWindows()
            && _temporaryRoot.StartsWith("/var/", StringComparison.Ordinal)
                ? "/private" + _temporaryRoot
                : _temporaryRoot;
        var root = Path.Combine(physicalTemporaryRoot, "guard");
        var path = Path.Combine(root, "payload.bin");
        Directory.CreateDirectory(root);
        await File.WriteAllBytesAsync(path, Bytes("verified"));
        var guard = new ManagedPathGuard();

        await using var verified = guard.OpenVerifiedRead(root, path);
        using var reader = new StreamReader(
            verified.Stream,
            Encoding.UTF8,
            detectEncodingFromByteOrderMarks: false,
            leaveOpen: true);
        var content = await reader.ReadToEndAsync();
        var hash = await guard.ComputeVerifiedSha256Async(root, path);

        Assert.Equal("verified", content);
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(Bytes("verified"))).ToLowerInvariant(),
            hash);
    }

    public void Dispose()
    {
        TestDirectoryCleanup.DeleteWithoutFollowingReparsePoints(_temporaryRoot);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private static TransactionService Service(
        string transactionsRoot,
        ITransactionFileSystem fileSystem,
        params ManagedTargetDefinition[] targets) =>
        new(transactionsRoot, new ManagedTargetCatalog(targets), fileSystem);

    private static ExternalMutationCoordinator ExternalCoordinator(
        string transactionRoot,
        params (string Key, FakeExternalMutationProvider Provider)[] targets) =>
        new(
            transactionRoot,
            new ExternalMutationCatalog(targets.Select(target =>
                new ExternalMutationTargetDefinition(target.Key, target.Provider))));

    private static FakeExternalMutationProvider ExternalProvider(
        ExternalMutationTargetKind kind,
        string value,
        ExternalMutationProviderScope scope = ExternalMutationProviderScope.None) =>
        new(kind, value, scope);

    private static string FindWindowsRoot() => Path.GetFullPath(
        Path.Combine(AppContext.BaseDirectory, "../../../../.."));

    private static async Task CreateJunctionAsync(
        string junction,
        string target)
    {
        var start = new System.Diagnostics.ProcessStartInfo("cmd.exe")
        {
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };
        start.ArgumentList.Add("/d");
        start.ArgumentList.Add("/c");
        start.ArgumentList.Add("mklink");
        start.ArgumentList.Add("/J");
        start.ArgumentList.Add(junction);
        start.ArgumentList.Add(target);
        using var process = System.Diagnostics.Process.Start(start)
                            ?? throw new InvalidOperationException(
                                "Unable to start mklink.");
        await process.WaitForExitAsync();
        Assert.True(
            process.ExitCode == 0,
            await process.StandardError.ReadToEndAsync());
    }

    private static ManagedTargetDefinition Target(
        string key,
        string root,
        string path,
        bool allowWindowsApps = false) =>
        new(key, root, path, allowWindowsApps);

    private static byte[] Bytes(string value) => Encoding.UTF8.GetBytes(value);

    private static object JournalEntry(
        int sequence,
        string targetKey,
        string backup,
        string beforeContent,
        FileBackupMetadata metadata) =>
        new
        {
            sequence,
            action = "replaceFile",
            targetKey,
            backup,
            beforeSha256 = Convert.ToHexString(
                SHA256.HashData(Bytes(beforeContent))).ToLowerInvariant(),
            completed = false,
            backupMetadata = metadata
        };

    private static string CreateRecoveryFixture(
        string transactions,
        Guid transactionId,
        string state,
        object journalEntry)
    {
        var transactionDirectory = Path.Combine(
            transactions,
            transactionId.ToString("N"));
        Directory.CreateDirectory(Path.Combine(transactionDirectory, "backups"));
        File.WriteAllText(
            Path.Combine(transactionDirectory, "state.json"),
            $$"""{"state":"{{state}}"}""");
        File.WriteAllText(
            Path.Combine(transactionDirectory, "journal.jsonl"),
            JsonSerializer.Serialize(journalEntry, JsonOptions) + Environment.NewLine);
        return transactionDirectory;
    }

    private static FileBackupMetadata Metadata(long marker) =>
        new(
            Existed: true,
            Attributes: marker,
            CreationTimeUtc: DateTime.UnixEpoch.AddSeconds(marker),
            LastWriteTimeUtc: DateTime.UnixEpoch.AddSeconds(marker + 1),
            LastAccessTimeUtc: DateTime.UnixEpoch.AddSeconds(marker + 2),
            SecurityDescriptor: Convert.ToBase64String(BitConverter.GetBytes(marker)));

    private static TransactionState ReadState(string transactionDirectory)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(
            Path.Combine(transactionDirectory, "state.json")));
        return document.RootElement.GetProperty("state").GetString() switch
        {
            "planned" => TransactionState.Planned,
            "staged" => TransactionState.Staged,
            "applying" => TransactionState.Applying,
            "verifying" => TransactionState.Verifying,
            "committed" => TransactionState.Committed,
            "rolling_back" => TransactionState.RollingBack,
            "rolled_back" => TransactionState.RolledBack,
            var state => throw new InvalidDataException($"Unknown state '{state}'.")
        };
    }

    private sealed record FakeFile(byte[] Content, FileBackupMetadata Metadata);

    private sealed class FakeTransactionFileSystem : ITransactionFileSystem
    {
        private readonly Dictionary<string, FakeFile> _files =
            new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, byte[]> _backups =
            new(StringComparer.OrdinalIgnoreCase);
        private int _replaceCount;

        public int? FailReplaceNumber { get; init; }

        public Action<string, int>? BeforeReplace { get; set; }

        public bool RejectUnsafePathAtOpenBoundary { get; set; }

        public HashSet<string> ReparsePoints { get; } =
            new(StringComparer.OrdinalIgnoreCase);

        public bool Exists(string rootPath, string path) =>
            _files.ContainsKey(path) || _backups.ContainsKey(path);

        public bool HasReparsePoint(string rootPath, string targetPath) =>
            ReparsePoints.Any(candidate =>
                string.Equals(candidate, rootPath, StringComparison.OrdinalIgnoreCase)
                || rootPath.StartsWith(
                    candidate + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase)
                || targetPath.StartsWith(
                    candidate + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase));

        public Task<FileBackupMetadata> BackupAsync(
            string targetRootPath,
            string targetPath,
            string backupRootPath,
            string backupPath,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!_files.TryGetValue(targetPath, out var file))
                return Task.FromResult(FileBackupMetadata.Missing);
            _backups[backupPath] = file.Content.ToArray();
            return Task.FromResult(file.Metadata);
        }

        public Task ReplaceFileAsync(
            string rootPath,
            string targetPath,
            ReadOnlyMemory<byte> content,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _replaceCount++;
            BeforeReplace?.Invoke(targetPath, _replaceCount);
            if (RejectUnsafePathAtOpenBoundary
                && HasReparsePoint(Path.GetPathRoot(targetPath)!, targetPath))
            {
                throw new UnauthorizedAccessException(
                    "Path changed to a reparse point at the open boundary.");
            }
            if (_replaceCount == FailReplaceNumber)
                throw new IOException("Injected third-action failure.");
            _files[targetPath] = new FakeFile(
                content.ToArray(),
                TransactionTests.Metadata(1000 + _replaceCount));
            return Task.CompletedTask;
        }

        public Task RestoreAsync(
            string targetRootPath,
            string targetPath,
            string backupRootPath,
            string backupPath,
            FileBackupMetadata metadata,
            string expectedSha256,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!string.Equals(
                    expectedSha256,
                    BackupSha256(backupPath),
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException("Backup hash changed before restore.");
            }
            _files[targetPath] = new FakeFile(_backups[backupPath].ToArray(), metadata);
            return Task.CompletedTask;
        }

        public Task<string> ComputeSha256Async(
            string rootPath,
            string path,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(BackupSha256(path));
        }

        public Task DeleteIfExistsAsync(
            string rootPath,
            string targetPath,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _files.Remove(targetPath);
            return Task.CompletedTask;
        }

        public void Seed(string path, string content, FileBackupMetadata metadata) =>
            _files[path] = new FakeFile(Bytes(content), metadata);

        public void SeedBackup(string path, string content) =>
            _backups[path] = Bytes(content);

        public string Read(string path) => Encoding.UTF8.GetString(_files[path].Content);

        public FileBackupMetadata Metadata(string path) => _files[path].Metadata;

        public string BackupSha256(string path) =>
            Convert.ToHexString(SHA256.HashData(_backups[path])).ToLowerInvariant();
    }

    private sealed class FakeExternalTarget
    {
        public FakeExternalTarget(string value) => Value = value;

        public string Value { get; set; }
    }

    private sealed class FakeExternalMutationProvider : IExternalMutationProvider
    {
        private readonly FakeExternalTarget _target;

        public FakeExternalMutationProvider(
            ExternalMutationTargetKind kind,
            string value,
            ExternalMutationProviderScope scope)
            : this(kind, new FakeExternalTarget(value), scope)
        {
        }

        private FakeExternalMutationProvider(
            ExternalMutationTargetKind kind,
            FakeExternalTarget target,
            ExternalMutationProviderScope scope)
        {
            Kind = kind;
            Scope = scope;
            _target = target;
        }

        public ExternalMutationTargetKind Kind { get; }

        public ExternalMutationProviderScope Scope { get; }

        public string Value
        {
            get => _target.Value;
            set => _target.Value = value;
        }

        public string SensitiveTargetPath { get; set; } = string.Empty;

        public bool FailCapture { get; set; }

        public bool FailMutation { get; set; }

        public int FailCleanupCount { get; set; }

        public int CancelCleanupCount { get; set; }

        public int RestoreCalls { get; private set; }

        public int CleanupCalls { get; private set; }

        public FakeExternalMutationProvider Fork() =>
            new(Kind, _target, Scope)
            {
                SensitiveTargetPath = SensitiveTargetPath
            };

        public void Apply(string value)
        {
            if (FailMutation)
                throw new IOException("Injected external mutation failure.");
            Value = value;
        }

        public Task<ManagedSnapshotDescriptor> CaptureSnapshotAsync(
            ManagedSnapshotWriter writer,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (FailCapture)
                throw new IOException("Injected external snapshot failure.");
            return writer.WriteAsync(
                "fixture.external.v1",
                Bytes(Value),
                cancellationToken);
        }

        public async Task ValidateSnapshotAsync(
            ManagedSnapshotReader snapshot,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _ = await snapshot.ReadAllBytesAsync(cancellationToken);
        }

        public async Task RestoreSnapshotAsync(
            ManagedSnapshotReader snapshot,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            RestoreCalls++;
            Value = Encoding.UTF8.GetString(
                await snapshot.ReadAllBytesAsync(cancellationToken));
        }

        public Task CleanupSnapshotAsync(
            ManagedSnapshotReader? snapshot,
            CancellationToken cancellationToken)
        {
            CleanupCalls++;
            if (CancelCleanupCount > 0)
            {
                CancelCleanupCount--;
                throw new OperationCanceledException(cancellationToken);
            }
            if (FailCleanupCount > 0)
            {
                FailCleanupCount--;
                throw new IOException("Injected cleanup failure.");
            }

            return Task.CompletedTask;
        }
    }
}
