using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class ApplicationInstallerTests : IDisposable
{
    private const string CodexFamily = "OpenAI.Codex_2p2nqsd0c76g0";
    private const string CodexPublisher =
        "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B";
    private const string CodexVersion = "26.7.27.0";
    private const string CodexPlusPlusVersion = "1.2.43+codexkit.1";
    private const string CompatibilityRevision = "cross-provider-content-v1";
    private const string SetupName =
        "CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe";

    private readonly string _temporaryRoot = Path.Combine(
        Path.GetTempPath(),
        "codex-application-installer-tests",
        Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task Healthy_codex_preserve_does_not_call_AddPackageAsync()
    {
        var deployment = new FakeCodexPackageDeployment
        {
            InstalledPackages = [HealthyCodex()]
        };
        var verifier = new FakeAuthenticodeVerifier();
        var installer = new CodexInstaller(_temporaryRoot, deployment, verifier);

        var result = await installer.ApplyAsync(
            Plan("codex-windows-x64", PlanAction.Preserve, CodexVersion),
            Catalog(CodexEntry()));

        Assert.False(result.Changed);
        Assert.Equal(0, deployment.AddPackageCalls);
        Assert.Empty(verifier.VerifiedPaths);
    }

    [Fact]
    public async Task Missing_codex_uses_manifest_main_and_dependency_packages_offline()
    {
        var main = CreatePayload("apps/Codex.msix");
        var dependencyZero = CreatePayload("apps/dependencies/VCLibs.msix");
        var dependencyOne = CreatePayload("apps/dependencies/WinAppRuntime.msix");
        var cli = CreatePayload("installed/codex.exe");
        var deployment = new FakeCodexPackageDeployment
        {
            InstalledPackages = [HealthyCodex(cli)]
        };
        var verifier = new FakeAuthenticodeVerifier();
        var installer = new CodexInstaller(_temporaryRoot, deployment, verifier);
        var catalog = Catalog(
            CodexEntry("apps/Codex.msix"),
            DependencyEntry("codex-dependency-1", "apps/dependencies/WinAppRuntime.msix"),
            DependencyEntry("codex-dependency-0", "apps/dependencies/VCLibs.msix"));

        var result = await installer.ApplyAsync(
            Plan("codex-windows-x64", PlanAction.Install, installedVersion: null),
            catalog);

        Assert.True(result.Changed);
        Assert.Equal(1, deployment.AddPackageCalls);
        Assert.Equal(Path.GetFullPath(main), deployment.MainPackagePath);
        Assert.Equal(
            [Path.GetFullPath(dependencyZero), Path.GetFullPath(dependencyOne)],
            deployment.DependencyPackagePaths);
        Assert.All(
            deployment.AllPackagePaths,
            path => Assert.True(Path.IsPathFullyQualified(path)));
        Assert.Equal(
            deployment.AllPackagePaths.Append(Path.GetFullPath(cli)),
            verifier.VerifiedPaths);
    }

    [Fact]
    public async Task Untrusted_codex_payload_is_rejected_before_deployment()
    {
        var main = CreatePayload("apps/Codex.msix");
        var deployment = new FakeCodexPackageDeployment();
        var verifier = new FakeAuthenticodeVerifier();
        verifier.UntrustedPaths.Add(Path.GetFullPath(main));
        var installer = new CodexInstaller(_temporaryRoot, deployment, verifier);

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-windows-x64", PlanAction.Install, installedVersion: null),
            Catalog(CodexEntry("apps/Codex.msix"))));

        Assert.Equal(0, deployment.AddPackageCalls);
    }

    [Theory]
    [InlineData("family")]
    [InlineData("architecture")]
    [InlineData("publisher")]
    [InlineData("signature-kind")]
    [InlineData("package-status")]
    [InlineData("cli")]
    [InlineData("cli-signature")]
    public async Task Codex_installation_revalidates_fixed_identity_and_cli(string failure)
    {
        var main = CreatePayload("apps/Codex.msix");
        var cli = CreatePayload("installed/codex.exe");
        var installed = HealthyCodex(cli);
        var deployment = new FakeCodexPackageDeployment();
        var verifier = new FakeAuthenticodeVerifier();
        switch (failure)
        {
            case "family":
                installed = installed with { PackageFamilyName = "OpenAI.Decoy_fixture" };
                break;
            case "architecture":
                installed = installed with { Architecture = CodexPackageArchitecture.Arm64 };
                break;
            case "publisher":
                installed = installed with { Publisher = "CN=Decoy" };
                break;
            case "signature-kind":
                installed = installed with { SignatureKind = CodexPackageSignatureKind.Unknown };
                break;
            case "package-status":
                installed = installed with { IsPackageStatusHealthy = false };
                break;
            case "cli":
                installed = installed with { CliPath = null };
                break;
            case "cli-signature":
                verifier.UntrustedPaths.Add(Path.GetFullPath(cli));
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(failure));
        }

        deployment.InstalledPackages = [installed];
        var installer = new CodexInstaller(_temporaryRoot, deployment, verifier);

        var exception = await Assert.ThrowsAsync<InvalidDataException>(
            () => installer.ApplyAsync(
                Plan("codex-windows-x64", PlanAction.Install, installedVersion: null),
                Catalog(CodexEntry("apps/Codex.msix"))));

        Assert.Contains("Codex", exception.Message, StringComparison.Ordinal);
        Assert.Equal(Path.GetFullPath(main), deployment.MainPackagePath);
    }

    [Fact]
    public async Task Codex_verification_failure_restores_the_predeployment_package_graph()
    {
        CreatePayload("apps/Codex.msix");
        var cli = CreatePayload("installed/codex.exe");
        var deployment = new FakeCodexPackageDeployment
        {
            InstalledPackages =
            [
                HealthyCodex(cli) with
                {
                    PackageFamilyName = "OpenAI.Decoy_fixture"
                }
            ],
            Snapshot = new CodexPackageGraphSnapshot(
            [
                new CodexPackageRegistration(
                    "OpenAI.Codex_before",
                    CodexFamily,
                    "/fixture/AppxManifest.xml",
                    IsMainPackage: true)
            ])
        };
        var installer = new CodexInstaller(
            _temporaryRoot,
            deployment,
            new FakeAuthenticodeVerifier());

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-windows-x64", PlanAction.Repair, CodexVersion),
            Catalog(CodexEntry("apps/Codex.msix"))));

        Assert.Equal(1, deployment.CaptureSnapshotCalls);
        Assert.Equal(1, deployment.RestoreSnapshotCalls);
        Assert.Same(deployment.Snapshot, deployment.RestoredSnapshot);
    }

    [Fact]
    public async Task Codex_cancellation_is_primary_and_still_restores_package_graph()
    {
        CreatePayload("apps/Codex.msix");
        var deployment = new FakeCodexPackageDeployment
        {
            CancelDuringAdd = true
        };
        var installer = new CodexInstaller(
            _temporaryRoot,
            deployment,
            new FakeAuthenticodeVerifier());
        using var cancellation = new CancellationTokenSource();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => installer.ApplyAsync(
                Plan("codex-windows-x64", PlanAction.Install, installedVersion: null),
                Catalog(CodexEntry("apps/Codex.msix")),
                cancellation.Token));

        Assert.Equal(1, deployment.RestoreSnapshotCalls);
    }

    [Fact]
    public async Task Codex_payload_leases_remain_open_through_deployment_and_then_close()
    {
        CreatePayload("apps/Codex.msix");
        var cli = CreatePayload("installed/codex.exe");
        var paths = new FakeManagedApplicationPathPolicy();
        var deployment = new FakeCodexPackageDeployment
        {
            InstalledPackages = [HealthyCodex(cli)]
        };
        var installer = new CodexInstaller(
            _temporaryRoot,
            deployment,
            new FakeAuthenticodeVerifier(),
            paths);

        await installer.ApplyAsync(
            Plan("codex-windows-x64", PlanAction.Install, installedVersion: null),
            Catalog(CodexEntry()));

        Assert.True(deployment.PayloadLeasesOpenDuringAdd);
        Assert.Equal(0, paths.ActiveLeaseCount);
    }

    [Fact]
    public async Task Codex_rollback_registers_snapshot_manifests_before_removing_new_package()
    {
        CreatePayload("apps/Codex.msix");
        var cli = CreatePayload("installed/codex.exe");
        const string oldFullName = "OpenAI.Codex_26.7.26.0_x64__2p2nqsd0c76g0";
        var deployment = new FakeCodexPackageDeployment
        {
            InstalledPackages =
            [
                HealthyCodex(cli) with
                {
                    PackageFamilyName = "OpenAI.Decoy_fixture"
                }
            ],
            CurrentPackageFullNames = ["OpenAI.Codex_new"],
            Snapshot = new CodexPackageGraphSnapshot(
            [
                new CodexPackageRegistration(
                    oldFullName,
                    CodexFamily,
                    "/rollback/main/AppxManifest.xml",
                    IsMainPackage: true),
                new CodexPackageRegistration(
                    "Microsoft.Dependency_old",
                    "Microsoft.Dependency_fixture",
                    "/rollback/dependency/AppxManifest.xml",
                    IsMainPackage: false)
            ])
        };
        var installer = new CodexInstaller(
            _temporaryRoot,
            deployment,
            new FakeAuthenticodeVerifier());

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-windows-x64", PlanAction.Repair, CodexVersion),
            Catalog(CodexEntry())));

        Assert.DoesNotContain(oldFullName, deployment.CurrentPackageFullNames);
        Assert.Equal(
            "/rollback/main/AppxManifest.xml",
            deployment.RegisteredMainManifestPath);
        Assert.Equal(
            ["/rollback/dependency/AppxManifest.xml"],
            deployment.RegisteredDependencyManifestPaths);
        Assert.Equal(["register", "remove-new"], deployment.RollbackEvents);
    }

    [Fact]
    public async Task Codex_manifest_restore_failure_retains_snapshot_and_does_not_claim_rollback()
    {
        CreatePayload("apps/Codex.msix");
        var cli = CreatePayload("installed/codex.exe");
        var deployment = new FakeCodexPackageDeployment
        {
            InstalledPackages =
            [
                HealthyCodex(cli) with
                {
                    PackageFamilyName = "OpenAI.Decoy_fixture"
                }
            ],
            Snapshot = new CodexPackageGraphSnapshot(
            [
                new CodexPackageRegistration(
                    "OpenAI.Codex_before",
                    CodexFamily,
                    "/rollback/main/AppxManifest.xml",
                    IsMainPackage: true)
            ]),
            RegisterError = new InvalidDataException("manifest unavailable")
        };
        var installer = new CodexInstaller(
            _temporaryRoot,
            deployment,
            new FakeAuthenticodeVerifier());

        var error = await Assert.ThrowsAsync<AggregateException>(
            () => installer.ApplyAsync(
                Plan("codex-windows-x64", PlanAction.Repair, CodexVersion),
                Catalog(CodexEntry())));

        Assert.Contains(
            error.InnerExceptions,
            item => item.Message.Contains("manifest unavailable", StringComparison.Ordinal));
        Assert.Equal(["register"], deployment.RollbackEvents);
        Assert.Equal(0, deployment.DiscardSnapshotCalls);
        Assert.False(deployment.SnapshotDiscarded);
    }

    [Fact]
    public async Task Codex_unrestorable_snapshot_is_rejected_before_package_change()
    {
        CreatePayload("apps/Codex.msix");
        var deployment = new FakeCodexPackageDeployment
        {
            RestorableError = new InvalidDataException("rollback manifest missing")
        };
        var installer = new CodexInstaller(
            _temporaryRoot,
            deployment,
            new FakeAuthenticodeVerifier());

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-windows-x64", PlanAction.Repair, CodexVersion),
            Catalog(CodexEntry())));

        Assert.Equal(0, deployment.AddPackageCalls);
        Assert.Equal(1, deployment.DiscardSnapshotCalls);
    }

    [Fact]
    public void Windows_codex_adapter_is_strongly_typed_and_uses_real_WinVerifyTrust()
    {
        var source = File.ReadAllText(Path.Combine(
            FindWindowsRoot(),
            "src",
            "InstallerCore",
            "Services",
            "CodexInstaller.cs")).ReplaceLineEndings("\n");

        Assert.Contains("new PackageManager()", source, StringComparison.Ordinal);
        Assert.Contains(".AddPackageAsync(", source, StringComparison.Ordinal);
        Assert.Contains("Windows.Management.Deployment", source, StringComparison.Ordinal);
        Assert.Contains("WinVerifyTrust(", source, StringComparison.Ordinal);
        Assert.Contains("WTD_CACHE_ONLY_URL_RETRIEVAL", source, StringComparison.Ordinal);
        Assert.Contains(
            "AddPackageAsync(\n        VerifiedManagedFileLease mainPackage",
            source,
            StringComparison.Ordinal);
        Assert.Contains("OpenVerifiedRead(", source, StringComparison.Ordinal);
        Assert.Contains("RegisterPackageByManifestAsync(", source, StringComparison.Ordinal);
        Assert.Contains(
            "DeploymentOptions.ForceUpdateFromAnyVersion\n" +
            "                | DeploymentOptions.ForceApplicationShutdown",
            source,
            StringComparison.Ordinal);
        Assert.DoesNotContain("RevalidateAsync(", source, StringComparison.Ordinal);
        Assert.DoesNotContain("System.Reflection", source, StringComparison.Ordinal);
        Assert.DoesNotContain("GetMethod(", source, StringComparison.Ordinal);

        var addStart = source.IndexOf(
            "var operation = new PackageManager().AddPackageAsync(",
            StringComparison.Ordinal);
        var addEnd = source.IndexOf(
            "public async Task RegisterPackageByManifestAsync(",
            addStart,
            StringComparison.Ordinal);
        var addBlock = source[addStart..addEnd];
        var cancellationCheck = addBlock.IndexOf(
            "cancellationToken.ThrowIfCancellationRequested();",
            addBlock.IndexOf("var result = await operation;", StringComparison.Ordinal),
            StringComparison.Ordinal);
        var cancellationHResult = addBlock.IndexOf(
            "ThrowIfCancelled(result.ExtendedErrorCode",
            StringComparison.Ordinal);
        var deploymentFailure = addBlock.IndexOf(
            "if (result.ExtendedErrorCode",
            StringComparison.Ordinal);
        Assert.True(cancellationCheck >= 0);
        Assert.True(cancellationCheck < cancellationHResult);
        Assert.True(cancellationHResult < deploymentFailure);
    }

    [Fact]
    public async Task CodexPlusPlus_preserve_does_not_execute_setup_or_stage_directory()
    {
        var backend = new FakeProcessExecutionBackend();
        var directories = new FakeApplicationTransactionCoordinator();
        var installer = CreateCodexPlusPlusInstaller(
            backend,
            directories,
            new FakeCodexPlusPlusInstallationProbe());

        var result = await installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Preserve, CodexPlusPlusVersion),
            Catalog(CodexPlusPlusEntry()));

        Assert.False(result.Changed);
        Assert.Equal(0, backend.ExecutionCount);
        Assert.Equal(0, directories.StageCount);
    }

    [Fact]
    public async Task CodexPlusPlus_uses_persistent_stable_targets_and_recovers_before_apply()
    {
        CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend();
        var coordinator = new FakeApplicationTransactionCoordinator();
        var installer = new CodexPlusPlusInstaller(
            _temporaryRoot,
            LocalAppData(),
            new ProcessRunner(backend),
            transactionCoordinator: coordinator,
            probe: new FakeCodexPlusPlusInstallationProbe(),
            pathPolicy: new FakeManagedApplicationPathPolicy(),
            setupInspector: new FakeCodexPlusPlusSetupInspector(),
            processSecurityContext: new FakeProcessSecurityContext());

        var result = await installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Upgrade, "1.2.42"),
            Catalog(CodexPlusPlusEntry()));

        Assert.True(result.Changed);
        Assert.Equal(1, coordinator.RecoverCount);
        Assert.Equal(
            CodexPlusPlusManagedTargets.All,
            coordinator.BeginTargetKeys);
        Assert.Equal(1, coordinator.Session.CommitCount);
        Assert.Equal(0, coordinator.Session.RollbackCount);
    }

    [Fact]
    public async Task CodexPlusPlus_commit_cleanup_pending_does_not_delete_new_version()
    {
        CreatePayload($"apps/{SetupName}");
        var coordinator = new FakeApplicationTransactionCoordinator();
        coordinator.Session.CommitResult =
            new ApplicationTransactionCommitResult(CleanupPending: true);
        var installer = new CodexPlusPlusInstaller(
            _temporaryRoot,
            LocalAppData(),
            new ProcessRunner(new FakeProcessExecutionBackend()),
            transactionCoordinator: coordinator,
            probe: new FakeCodexPlusPlusInstallationProbe(),
            pathPolicy: new FakeManagedApplicationPathPolicy(),
            setupInspector: new FakeCodexPlusPlusSetupInspector(),
            processSecurityContext: new FakeProcessSecurityContext());

        var result = await installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Upgrade, "1.2.42"),
            Catalog(CodexPlusPlusEntry()));

        Assert.True(result.Changed);
        Assert.True(result.CleanupPending);
        Assert.True(coordinator.Session.IsCommitted);
        Assert.Equal(0, coordinator.Session.RollbackCount);
    }

    [Fact]
    public async Task Persistent_application_transaction_recovers_real_directory_and_shortcuts()
    {
        var transactionRoot = Path.Combine(_temporaryRoot, "transactions");
        var programRoot = Path.Combine(_temporaryRoot, "program");
        var desktopRoot = Path.Combine(_temporaryRoot, "desktop");
        var shortcut = Path.Combine(desktopRoot, "Codex++.lnk");
        Directory.CreateDirectory(programRoot);
        Directory.CreateDirectory(desktopRoot);
        await File.WriteAllTextAsync(
            Path.Combine(programRoot, "old.exe"),
            "old-program");
        await File.WriteAllTextAsync(shortcut, "old-shortcut");
        var coordinator = PersistentCoordinator();
        _ = await coordinator.BeginAsync(
        [
            CodexPlusPlusManagedTargets.ProgramDirectory,
            CodexPlusPlusManagedTargets.DesktopShortcut
        ],
        CancellationToken.None);
        Directory.Delete(programRoot, recursive: true);
        Directory.CreateDirectory(programRoot);
        await File.WriteAllTextAsync(
            Path.Combine(programRoot, "new.exe"),
            "new-program");
        await File.WriteAllTextAsync(shortcut, "new-shortcut");

        await PersistentCoordinator().RecoverIncompleteAsync(
            CancellationToken.None);

        Assert.Equal(
            "old-program",
            await File.ReadAllTextAsync(Path.Combine(programRoot, "old.exe")));
        Assert.False(File.Exists(Path.Combine(programRoot, "new.exe")));
        Assert.Equal("old-shortcut", await File.ReadAllTextAsync(shortcut));

        PersistentApplicationTransactionCoordinator PersistentCoordinator()
        {
            var catalog = new ExternalMutationCatalog(
            [
                new(
                    CodexPlusPlusManagedTargets.ProgramDirectory,
                    new DirectoryExternalMutationProvider(programRoot)),
                new(
                    CodexPlusPlusManagedTargets.DesktopShortcut,
                    new ShortcutSetExternalMutationProvider(
                    [
                        (desktopRoot, shortcut)
                    ]))
            ]);
            return new PersistentApplicationTransactionCoordinator(
                new ExternalMutationCoordinator(transactionRoot, catalog));
        }
    }

    [Theory]
    [InlineData(true, true, true, "user")]
    [InlineData(false, false, true, "user")]
    [InlineData(false, true, false, "user")]
    [InlineData(false, true, true, "admin")]
    [InlineData(false, true, true, "userAsAdmin")]
    public async Task CodexPlusPlus_S_requires_non_elevated_current_user_and_user_manifest(
        bool elevated,
        bool currentUser,
        bool perUser,
        string requestExecutionLevel)
    {
        CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend();
        var setupInspector = new FakeCodexPlusPlusSetupInspector
        {
            Provenance = ReviewedSetupProvenance() with
            {
                PerUser = perUser,
                ExecutionLevel = requestExecutionLevel
            }
        };
        var installer = new CodexPlusPlusInstaller(
            _temporaryRoot,
            LocalAppData(),
            new ProcessRunner(backend),
            transactionCoordinator: new FakeApplicationTransactionCoordinator(),
            probe: new FakeCodexPlusPlusInstallationProbe(),
            pathPolicy: new FakeManagedApplicationPathPolicy(),
            setupInspector,
            processSecurityContext: new FakeProcessSecurityContext
            {
                IsElevated = elevated,
                IsCurrentUser = currentUser
            });

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Install, installedVersion: null),
            Catalog(CodexPlusPlusEntry())));

        Assert.Equal(0, backend.ExecutionCount);
    }

    [Theory]
    [InlineData("schema")]
    [InlineData("setup-name")]
    [InlineData("upstream")]
    [InlineData("patch")]
    [InlineData("registry")]
    [InlineData("shortcut-scope")]
    [InlineData("requires-elevation")]
    [InlineData("raw-launch")]
    [InlineData("fixture")]
    [InlineData("executable")]
    public async Task CodexPlusPlus_rejects_nonreviewed_setup_provenance(
        string failure)
    {
        CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend();
        var reviewed = ReviewedSetupProvenance();
        var invalid = failure switch
        {
            "schema" => reviewed with { Schema = "decoy" },
            "setup-name" => reviewed with { SetupFileName = "decoy.exe" },
            "upstream" => reviewed with { UpstreamTag = "v9.9.9" },
            "patch" => reviewed with { PatchSha256 = new string('0', 64) },
            "registry" => reviewed with { RegistryHive = "HKLM" },
            "shortcut-scope" => reviewed with { ShortcutScope = "allUsers" },
            "requires-elevation" => reviewed with { RequiresElevation = true },
            "raw-launch" => reviewed with
            {
                RawCreateProcessCompatible = false
            },
            "fixture" => reviewed with { FixtureOnly = true },
            "executable" => reviewed with
            {
                Executables =
                [
                    reviewed.Executables[0] with
                    {
                        MetadataMagic = "decoy:"
                    },
                    reviewed.Executables[1]
                ]
            },
            _ => throw new ArgumentOutOfRangeException(nameof(failure))
        };
        var installer = new CodexPlusPlusInstaller(
            _temporaryRoot,
            LocalAppData(),
            new ProcessRunner(backend),
            transactionCoordinator: new FakeApplicationTransactionCoordinator(),
            probe: new FakeCodexPlusPlusInstallationProbe(),
            pathPolicy: new FakeManagedApplicationPathPolicy(),
            setupInspector: new FakeCodexPlusPlusSetupInspector
            {
                Provenance = invalid
            },
            processSecurityContext: new FakeProcessSecurityContext());

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Install, installedVersion: null),
            Catalog(CodexPlusPlusEntry())));

        Assert.Equal(0, backend.ExecutionCount);
    }

    [Fact]
    public async Task CodexPlusPlus_executes_only_reviewed_setup_with_S_and_no_api_key()
    {
        const string secret = "sk-must-never-reach-the-setup";
        var setup = CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend();
        var directories = new FakeApplicationTransactionCoordinator();
        var probe = new FakeCodexPlusPlusInstallationProbe();
        var installer = CreateCodexPlusPlusInstaller(backend, directories, probe);

        var result = await installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Install, installedVersion: null),
            Catalog(CodexPlusPlusEntry()));

        Assert.True(result.Changed);
        Assert.Equal(Path.GetFullPath(setup), backend.Request!.FileName);
        Assert.Equal(["/S"], backend.Request.Arguments);
        Assert.Null(backend.Request.StandardInput);
        Assert.DoesNotContain(
            backend.Request.Arguments,
            argument => argument.Contains(secret, StringComparison.Ordinal));
        Assert.DoesNotContain(
            backend.Request.Arguments,
            argument => argument.StartsWith("/D=", StringComparison.OrdinalIgnoreCase));
        Assert.Equal(
            Path.Combine(LocalAppData(), "Programs", "Codex++"),
            probe.RequestedInstallRoot);
    }

    [Fact]
    public async Task CodexPlusPlus_setup_lease_remains_open_through_process_completion()
    {
        CreatePayload($"apps/{SetupName}");
        var paths = new FakeManagedApplicationPathPolicy();
        var backend = new FakeProcessExecutionBackend
        {
            LeaseOpenProbe = () => paths.ActiveLeaseCount > 0
        };
        var installer = new CodexPlusPlusInstaller(
            _temporaryRoot,
            LocalAppData(),
            new ProcessRunner(backend),
            new FakeApplicationTransactionCoordinator(),
            new FakeCodexPlusPlusInstallationProbe(),
            paths,
            new FakeCodexPlusPlusSetupInspector(),
            new FakeProcessSecurityContext());

        await installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Install, installedVersion: null),
            Catalog(CodexPlusPlusEntry()));

        Assert.True(backend.LeaseOpenDuringExecution);
        Assert.Equal(0, paths.ActiveLeaseCount);
    }

    [Fact]
    public async Task CodexPlusPlus_tampered_setup_is_rejected_before_staging_or_execution()
    {
        CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend();
        var directories = new FakeApplicationTransactionCoordinator();
        var installer = CreateCodexPlusPlusInstaller(
            backend,
            directories,
            new FakeCodexPlusPlusInstallationProbe());
        var tamperedEntry = CodexPlusPlusEntry() with
        {
            Sha256 = new string('0', 64)
        };

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Install, installedVersion: null),
            Catalog(tamperedEntry)));

        Assert.Equal(0, backend.ExecutionCount);
        Assert.Equal(0, directories.StageCount);
    }

    [Fact]
    public async Task CodexPlusPlus_old_version_is_upgraded_and_backup_is_committed()
    {
        CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend();
        var directories = new FakeApplicationTransactionCoordinator
        {
            ExistingDirectory = true
        };
        var installer = CreateCodexPlusPlusInstaller(
            backend,
            directories,
            new FakeCodexPlusPlusInstallationProbe());

        await installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Upgrade, "1.2.42"),
            Catalog(CodexPlusPlusEntry()));

        Assert.Equal(1, directories.StageCount);
        Assert.Equal(1, directories.CommitCount);
        Assert.Equal(0, directories.RestoreCount);
    }

    [Fact]
    public async Task CodexPlusPlus_setup_failure_restores_old_program_directory()
    {
        CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend { ExitCode = 23 };
        var directories = new FakeApplicationTransactionCoordinator
        {
            ExistingDirectory = true
        };
        var installer = CreateCodexPlusPlusInstaller(
            backend,
            directories,
            new FakeCodexPlusPlusInstallationProbe());

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Upgrade, "1.2.42"),
            Catalog(CodexPlusPlusEntry())));

        Assert.Equal(0, directories.CommitCount);
        Assert.Equal(1, directories.RestoreCount);
        Assert.True(directories.OldDirectoryRestored);
    }

    [Theory]
    [InlineData("launcher")]
    [InlineData("manager")]
    [InlineData("version")]
    [InlineData("revision")]
    [InlineData("fixture")]
    [InlineData("uninstall")]
    [InlineData("launcher-pe")]
    [InlineData("manager-pe")]
    [InlineData("file-version")]
    [InlineData("hash")]
    [InlineData("product-hive")]
    [InlineData("uninstall-hive")]
    [InlineData("product-install-dir")]
    [InlineData("uninstall-version")]
    [InlineData("install-location")]
    [InlineData("uninstall-string")]
    [InlineData("uninstaller")]
    [InlineData("shortcuts")]
    public async Task CodexPlusPlus_revalidates_both_binaries_metadata_and_uninstall(
        string failure)
    {
        CreatePayload($"apps/{SetupName}");
        var directories = new FakeApplicationTransactionCoordinator
        {
            ExistingDirectory = true
        };
        var probe = new FakeCodexPlusPlusInstallationProbe();
        probe.State = failure switch
        {
            "launcher" => probe.State with { LauncherPresent = false },
            "manager" => probe.State with { ManagerPresent = false },
            "version" => probe.State with
            {
                DisplayVersion = "1.2.42",
                LauncherMetadata = Metadata("launcher") with
                {
                    PayloadVersion = "1.2.42"
                }
            },
            "revision" => probe.State with
            {
                ManagerMetadata = Metadata("manager") with
                {
                    CompatibilityRevision = "decoy"
                }
            },
            "fixture" => probe.State with
            {
                LauncherMetadata = Metadata("launcher") with { FixtureOnly = true }
            },
            "uninstall" => probe.State with { HasUninstallEntry = false },
            "launcher-pe" => probe.State with { LauncherIsPeX64 = false },
            "manager-pe" => probe.State with { ManagerIsPeX64 = false },
            "file-version" => probe.State with
            {
                LauncherFileVersion = "1.2.42"
            },
            "hash" => probe.State with
            {
                ManagerSha256 = new string('0', 64)
            },
            "product-hive" => probe.State with
            {
                ProductRegistrationIsCurrentUser = false
            },
            "uninstall-hive" => probe.State with
            {
                UninstallRegistrationIsCurrentUser = false
            },
            "product-install-dir" => probe.State with
            {
                ProductInstallDirectory = "/decoy"
            },
            "uninstall-version" => probe.State with
            {
                UninstallDisplayVersion = "1.2.42"
            },
            "install-location" => probe.State with
            {
                UninstallInstallLocation = "/decoy"
            },
            "uninstall-string" => probe.State with
            {
                UninstallString = "/decoy/uninstall.exe"
            },
            "uninstaller" => probe.State with { UninstallerPresent = false },
            "shortcuts" => probe.State with
            {
                CurrentUserShortcutsPresent = false
            },
            _ => throw new ArgumentOutOfRangeException(nameof(failure))
        };
        var installer = CreateCodexPlusPlusInstaller(
            new FakeProcessExecutionBackend(),
            directories,
            probe);

        await Assert.ThrowsAsync<InvalidDataException>(() => installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Upgrade, "1.2.42"),
            Catalog(CodexPlusPlusEntry())));

        Assert.Equal(1, directories.RestoreCount);
        Assert.True(directories.OldDirectoryRestored);
    }

    [Fact]
    public async Task Hung_setup_cancellation_kills_descendants_before_restoring_old_directory()
    {
        CreatePayload($"apps/{SetupName}");
        var backend = new FakeProcessExecutionBackend { HangWithChild = true };
        var directories = new FakeApplicationTransactionCoordinator
        {
            ExistingDirectory = true
        };
        var installer = CreateCodexPlusPlusInstaller(
            backend,
            directories,
            new FakeCodexPlusPlusInstallationProbe());
        using var cancellation = new CancellationTokenSource();

        var running = installer.ApplyAsync(
            Plan("codex-plus-plus-windows-x64", PlanAction.Upgrade, "1.2.42"),
            Catalog(CodexPlusPlusEntry()),
            cancellation.Token);
        await backend.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        await backend.CancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.False(backend.RootProcessAlive);
        Assert.False(backend.ChildProcessAlive);
        Assert.False(running.IsCompleted);
        Assert.Equal(0, directories.RestoreCount);

        backend.AllowExit.TrySetResult();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running);
        Assert.Equal(1, directories.RestoreCount);
        Assert.True(directories.OldDirectoryRestored);
    }

    [Fact]
    public void Task3_executable_metadata_reader_rejects_truncated_contract()
    {
        var path = CreateMinimalX64Pe("fake-installers/truncated.exe");
        File.AppendAllText(path, "\nCODEXKIT-EXECUTABLE-METADATA-V1:{\"schemaVersion\":1}");

        var exception = Assert.Throws<InvalidDataException>(
            () => CodexKitExecutableMetadataReader.Read(path));

        Assert.Contains("truncated", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Task3_executable_metadata_reader_accepts_reviewed_downstream_contract()
    {
        var path = CreateMinimalX64Pe("fake-installers/reviewed.exe");
        File.AppendAllText(
            path,
            """

            CODEXKIT-EXECUTABLE-METADATA-V1:{"schemaVersion":1,"payloadVersion":"1.2.43+codexkit.1","compatibilityRevision":"cross-provider-content-v1","architecture":"x64","component":"launcher","fixtureOnly":false}

            """);

        var metadata = CodexKitExecutableMetadataReader.Read(path);

        Assert.Equal(Metadata("launcher"), metadata);
    }

    [Fact]
    public void Task3_executable_metadata_reader_rejects_plain_text_marker()
    {
        var path = CreatePayload("fake-installers/plain-text.exe");
        File.AppendAllText(
            path,
            "\nCODEXKIT-EXECUTABLE-METADATA-V1:{}\n");

        Assert.Throws<InvalidDataException>(
            () => CodexKitExecutableMetadataReader.Read(path));
    }

    [Fact]
    public void Setup_provenance_reader_accepts_exact_per_user_contract()
    {
        var path = CreateMinimalX64Pe("fake-installers/setup-provenance.exe");
        File.AppendAllText(
            path,
            """

            CODEXKIT-SETUP-PROVENANCE-V1:{"schema":"CODEXKIT-SETUP-PROVENANCE-V1","schemaVersion":1,"setupFileName":"CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe","upstreamTag":"v1.2.43","patchSha256":"5a411571c2c950a3ce5f8b1ed3a72a0f42bb4c4de2f9ea3ba5de8d767e14f739","payloadVersion":"1.2.43+codexkit.1","compatibilityRevision":"cross-provider-content-v1","architecture":"x64","perUser":true,"executionLevel":"user","installDir":"$LOCALAPPDATA\\Programs\\Codex++","registryHive":"HKCU","shortcutScope":"currentUser","requiresElevation":false,"rawCreateProcessCompatible":true,"fixtureOnly":false,"executables":[{"name":"codex-plus-plus.exe","component":"launcher","sha256":"1111111111111111111111111111111111111111111111111111111111111111","payloadVersion":"1.2.43+codexkit.1","compatibilityRevision":"cross-provider-content-v1","architecture":"x64","metadataMagic":"CODEXKIT-EXECUTABLE-METADATA-V1:"},{"name":"codex-plus-plus-manager.exe","component":"manager","sha256":"2222222222222222222222222222222222222222222222222222222222222222","payloadVersion":"1.2.43+codexkit.1","compatibilityRevision":"cross-provider-content-v1","architecture":"x64","metadataMagic":"CODEXKIT-EXECUTABLE-METADATA-V1:"}]}

            """);

        var provenance = CodexPlusPlusSetupProvenanceReader.Read(path);

        var expected = ReviewedSetupProvenance();
        Assert.Equal(expected.Schema, provenance.Schema);
        Assert.Equal(expected.SchemaVersion, provenance.SchemaVersion);
        Assert.Equal(expected.SetupFileName, provenance.SetupFileName);
        Assert.Equal(expected.UpstreamTag, provenance.UpstreamTag);
        Assert.Equal(expected.PatchSha256, provenance.PatchSha256);
        Assert.Equal(expected.PayloadVersion, provenance.PayloadVersion);
        Assert.Equal(
            expected.CompatibilityRevision,
            provenance.CompatibilityRevision);
        Assert.Equal(expected.Architecture, provenance.Architecture);
        Assert.Equal(expected.PerUser, provenance.PerUser);
        Assert.Equal(expected.ExecutionLevel, provenance.ExecutionLevel);
        Assert.Equal(expected.InstallDir, provenance.InstallDir);
        Assert.Equal(expected.RegistryHive, provenance.RegistryHive);
        Assert.Equal(expected.ShortcutScope, provenance.ShortcutScope);
        Assert.Equal(expected.RequiresElevation, provenance.RequiresElevation);
        Assert.Equal(
            expected.RawCreateProcessCompatible,
            provenance.RawCreateProcessCompatible);
        Assert.Equal(expected.FixtureOnly, provenance.FixtureOnly);
        Assert.Equal(expected.Executables, provenance.Executables);
    }

    [Fact]
    public async Task Managed_application_path_policy_rejects_symlink_ancestors()
    {
        var realRoot = Path.Combine(_temporaryRoot, "real");
        var linkRoot = Path.Combine(_temporaryRoot, "link");
        Directory.CreateDirectory(realRoot);
        Directory.CreateSymbolicLink(linkRoot, realRoot);
        var path = Path.Combine(realRoot, "payload.exe");
        await File.WriteAllTextAsync(path, "fixture");
        var policy = new PhysicalManagedApplicationPathPolicy();

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            policy.VerifyFileAsync(
                "fixture",
                linkRoot,
                Path.Combine(linkRoot, "payload.exe"),
                expectedSha256: null,
                CancellationToken.None));
    }

    [Fact]
    public async Task Managed_application_path_policy_lease_denies_replacement_until_disposed()
    {
#if WINDOWS
        if (!OperatingSystem.IsWindows())
            return;
        var root = Path.Combine(_temporaryRoot, "verified");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "payload.exe");
        var replacement = Path.Combine(root, "replacement.exe");
        await File.WriteAllTextAsync(path, "reviewed");
        await File.WriteAllTextAsync(replacement, "changed");
        var policy = new PhysicalManagedApplicationPathPolicy();
        await using (var lease = await policy.VerifyFileAsync(
                         "fixture",
                         root,
                         path,
                         expectedSha256: null,
                         CancellationToken.None))
        {
            var replacementError = Record.Exception(
                () => File.Move(replacement, path, overwrite: true));
            Assert.NotNull(replacementError);
            Assert.True(
                replacementError is IOException or UnauthorizedAccessException,
                $"Unexpected Windows sharing error: {replacementError.GetType().FullName}");
        }
        File.Move(replacement, path, overwrite: true);
        Assert.Equal("changed", await File.ReadAllTextAsync(path));
#else
        await Task.CompletedTask;
#endif
    }

#if WINDOWS
    [Fact]
    public async Task Windows_real_success_fixture_exits_zero()
    {
        if (!OperatingSystem.IsWindows())
            return;
        var fixture = Path.Combine(
            FindWindowsRoot(),
            "tests",
            "fixtures",
            "fake-installers",
            "succeed.cmd");
        var command = Environment.GetEnvironmentVariable("ComSpec")
                      ?? Path.Combine(
                          Environment.GetFolderPath(Environment.SpecialFolder.System),
                          "cmd.exe");
        var result = await new ProcessRunner().RunAsync(
            new ProcessRunRequest(
                command,
                ["/d", "/s", "/c", fixture],
                environment: null,
                apiKey: null),
            _ => { });

        Assert.False(result.WasCancelled);
        Assert.Equal(0, result.ExitCode);
    }

    [Fact]
    public async Task Windows_real_hang_fixture_cancellation_reaps_child()
    {
        if (!OperatingSystem.IsWindows())
            return;
        var fixture = Path.Combine(
            FindWindowsRoot(),
            "tests",
            "fixtures",
            "fake-installers",
            "hang-with-child.cmd");
        var command = Environment.GetEnvironmentVariable("ComSpec")
                      ?? Path.Combine(
                          Environment.GetFolderPath(Environment.SpecialFolder.System),
                          "cmd.exe");
        var childPid = new TaskCompletionSource<int>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using var cancellation = new CancellationTokenSource();
        var running = new ProcessRunner().RunAsync(
            new ProcessRunRequest(
                command,
                ["/d", "/s", "/c", fixture],
                environment: null,
                apiKey: null),
            line =>
            {
                const string prefix = "CHILD_PID=";
                if (line.Text.StartsWith(prefix, StringComparison.Ordinal)
                    && int.TryParse(line.Text[prefix.Length..], out var pid))
                {
                    childPid.TrySetResult(pid);
                }
            },
            cancellation.Token);

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
            // GetProcessById throws once the Job Object has fully reaped the child.
        }
    }
#endif

    public void Dispose()
    {
        TestDirectoryCleanup.DeleteWithoutFollowingReparsePoints(_temporaryRoot);
    }

    private CodexPlusPlusInstaller CreateCodexPlusPlusInstaller(
        IProcessExecutionBackend backend,
        IApplicationTransactionCoordinator directories,
        ICodexPlusPlusInstallationProbe probe) =>
        new(
            _temporaryRoot,
            LocalAppData(),
            new ProcessRunner(backend),
            directories,
            probe,
            new FakeManagedApplicationPathPolicy(),
            new FakeCodexPlusPlusSetupInspector(),
            new FakeProcessSecurityContext());

    private string LocalAppData() => Path.Combine(_temporaryRoot, "local-app-data");

    private string CreatePayload(string relativePath)
    {
        var path = Path.Combine(
            _temporaryRoot,
            relativePath.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "fixture");
        return path;
    }

    private string CreateMinimalX64Pe(string relativePath)
    {
        var path = Path.Combine(
            _temporaryRoot,
            relativePath.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var bytes = new byte[256];
        bytes[0] = (byte)'M';
        bytes[1] = (byte)'Z';
        BitConverter.GetBytes(0x80).CopyTo(bytes, 0x3c);
        bytes[0x80] = (byte)'P';
        bytes[0x81] = (byte)'E';
        BitConverter.GetBytes((ushort)0x8664).CopyTo(bytes, 0x84);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private static PayloadCatalog Catalog(params PayloadEntry[] entries) =>
        new(2, Array.AsReadOnly(entries));

    private static PayloadEntry CodexEntry(
        string relativePath = "apps/Codex.msix") =>
        Entry(
            "codex-windows-x64",
            CodexVersion,
            relativePath,
            "msix",
            packageFamilyName: CodexFamily,
            publisher: CodexPublisher,
            packageName: "OpenAI.Codex");

    private static PayloadEntry DependencyEntry(string id, string relativePath) =>
        Entry(
            id,
            "14.0.0.0",
            relativePath,
            "msix",
            packageFamilyName: "Microsoft.Dependency_fixture",
            publisher: "CN=Microsoft Corporation",
            packageName: "Microsoft.Dependency");

    private static PayloadEntry CodexPlusPlusEntry() =>
        Entry(
            "codex-plus-plus-windows-x64",
            CodexPlusPlusVersion,
            $"apps/{SetupName}",
            "exe",
            compatibilityRevision: CompatibilityRevision);

    private static PayloadEntry Entry(
        string id,
        string version,
        string relativePath,
        string format,
        string? packageFamilyName = null,
        string? publisher = null,
        string? packageName = null,
        string? compatibilityRevision = null) =>
        new(
            id,
            version,
            "x64",
            relativePath,
            Convert.ToHexString(
                    SHA256.HashData(Encoding.UTF8.GetBytes("fixture")))
                .ToLowerInvariant(),
            7,
            new Uri($"https://example.invalid/{id}"),
            format,
            packageFamilyName,
            publisher,
            packageName,
            MinimumVersion: null,
            CompatibilityRevision: compatibilityRevision,
            LicenseId: null);

    private static ComponentPlan Plan(
        string component,
        PlanAction action,
        string? installedVersion) =>
        new(
            component,
            action,
            installedVersion,
            component == "codex-windows-x64"
                ? CodexVersion
                : CodexPlusPlusVersion,
            "fixture");

    private static CodexPackageInstallation HealthyCodex(
        string? cliPath = "/fixture/codex.exe") =>
        new(
            CodexFamily,
            CodexVersion,
            CodexPackageArchitecture.X64,
            CodexPublisher,
            CodexPackageSignatureKind.Store,
            IsPackageStatusHealthy: true,
            cliPath,
            cliPath is null ? null : Path.GetDirectoryName(cliPath));

    private static CodexKitExecutableMetadata Metadata(string component) =>
        new(
            1,
            CodexPlusPlusVersion,
            CompatibilityRevision,
            "x64",
            component,
            FixtureOnly: false);

    private static CodexPlusPlusSetupProvenance ReviewedSetupProvenance() =>
        new(
            Schema: "CODEXKIT-SETUP-PROVENANCE-V1",
            SchemaVersion: 1,
            SetupFileName: SetupName,
            UpstreamTag: "v1.2.43",
            PatchSha256:
            "5a411571c2c950a3ce5f8b1ed3a72a0f42bb4c4de2f9ea3ba5de8d767e14f739",
            PayloadVersion: CodexPlusPlusVersion,
            CompatibilityRevision,
            Architecture: "x64",
            PerUser: true,
            ExecutionLevel: "user",
            InstallDir: @"$LOCALAPPDATA\Programs\Codex++",
            RegistryHive: "HKCU",
            ShortcutScope: "currentUser",
            RequiresElevation: false,
            RawCreateProcessCompatible: true,
            FixtureOnly: false,
            Executables:
            [
                new(
                    "codex-plus-plus.exe",
                    "launcher",
                    new string('1', 64),
                    CodexPlusPlusVersion,
                    CompatibilityRevision,
                    "x64",
                    CodexKitExecutableMetadataReader.Magic),
                new(
                    "codex-plus-plus-manager.exe",
                    "manager",
                    new string('2', 64),
                    CodexPlusPlusVersion,
                    CompatibilityRevision,
                    "x64",
                    CodexKitExecutableMetadataReader.Magic)
            ]);

    private static string FindWindowsRoot() => Path.GetFullPath(
        Path.Combine(AppContext.BaseDirectory, "../../../../.."));

    private sealed class FakeAuthenticodeVerifier : IAuthenticodeVerifier
    {
        public List<string> VerifiedPaths { get; } = [];

        public HashSet<string> UntrustedPaths { get; } =
            new(StringComparer.OrdinalIgnoreCase);

        public bool IsTrusted(string path)
        {
            var fullPath = Path.GetFullPath(path);
            VerifiedPaths.Add(fullPath);
            return !UntrustedPaths.Contains(fullPath);
        }
    }

    private sealed class FakeCodexPackageDeployment : ICodexPackageDeployment
    {
        public int AddPackageCalls { get; private set; }

        public string? MainPackagePath { get; private set; }

        public IReadOnlyList<string> DependencyPackagePaths { get; private set; } = [];

        public IReadOnlyList<string> AllPackagePaths =>
            MainPackagePath is null
                ? DependencyPackagePaths
                : [MainPackagePath, .. DependencyPackagePaths];

        public IReadOnlyList<CodexPackageInstallation> InstalledPackages { get; set; } = [];

        public CodexPackageGraphSnapshot Snapshot { get; set; } =
            new([]);

        public int CaptureSnapshotCalls { get; private set; }

        public int RestoreSnapshotCalls { get; private set; }

        public CodexPackageGraphSnapshot? RestoredSnapshot { get; private set; }

        public bool CancelDuringAdd { get; init; }

        public bool PayloadLeasesOpenDuringAdd { get; private set; }

        public Exception? RestorableError { get; init; }

        public Exception? RegisterError { get; init; }

        public IReadOnlyList<string> CurrentPackageFullNames { get; init; } = [];

        public string? RegisteredMainManifestPath { get; private set; }

        public IReadOnlyList<string> RegisteredDependencyManifestPaths
        {
            get;
            private set;
        } = [];

        public List<string> RollbackEvents { get; } = [];

        public int DiscardSnapshotCalls { get; private set; }

        public bool SnapshotDiscarded { get; private set; }

        public Task<CodexPackageGraphSnapshot> CaptureSnapshotAsync(
            string packageFamilyName,
            CancellationToken cancellationToken)
        {
            CaptureSnapshotCalls++;
            return Task.FromResult(Snapshot);
        }

        public Task ValidateSnapshotRestorableAsync(
            CodexPackageGraphSnapshot snapshot,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (RestorableError is not null)
                throw RestorableError;
            return Task.CompletedTask;
        }

        public Task AddPackageAsync(
            VerifiedManagedFileLease mainPackage,
            IReadOnlyList<VerifiedManagedFileLease> dependencyPackages,
            CancellationToken cancellationToken)
        {
            AddPackageCalls++;
            PayloadLeasesOpenDuringAdd =
                !mainPackage.IsDisposed
                && dependencyPackages.All(package => !package.IsDisposed);
            MainPackagePath = mainPackage.FullPath;
            DependencyPackagePaths = dependencyPackages
                .Select(package => package.FullPath)
                .ToArray();
            if (CancelDuringAdd)
                throw new OperationCanceledException(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public Task RegisterPackageByManifestAsync(
            string mainManifestPath,
            IReadOnlyList<string> dependencyManifestPaths,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            RollbackEvents.Add("register");
            RegisteredMainManifestPath = mainManifestPath;
            RegisteredDependencyManifestPaths =
                dependencyManifestPaths.ToArray();
            if (RegisterError is not null)
                throw RegisterError;
            return Task.CompletedTask;
        }

        public async Task RestoreSnapshotAsync(
            CodexPackageGraphSnapshot snapshot,
            CancellationToken cancellationToken)
        {
            RestoreSnapshotCalls++;
            RestoredSnapshot = snapshot;
            var dependencies = snapshot.Registrations
                .Where(item => !item.IsMainPackage)
                .Select(item => item.ManifestPath)
                .ToArray();
            foreach (var main in snapshot.Registrations.Where(
                         item => item.IsMainPackage))
            {
                await RegisterPackageByManifestAsync(
                    main.ManifestPath,
                    dependencies,
                    cancellationToken);
            }
            RollbackEvents.Add("remove-new");
        }

        public Task<bool> DiscardSnapshotAsync(
            CodexPackageGraphSnapshot snapshot,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DiscardSnapshotCalls++;
            SnapshotDiscarded = true;
            return Task.FromResult(true);
        }

        public IReadOnlyList<CodexPackageInstallation> FindPackages(
            string packageFamilyName) =>
            InstalledPackages;
    }

    private sealed class FakeApplicationTransactionCoordinator
        : IApplicationTransactionCoordinator
    {
        public bool ExistingDirectory { get; init; }

        public int RecoverCount { get; private set; }

        public IReadOnlyList<string> BeginTargetKeys { get; private set; } = [];

        public FakeApplicationTransactionSession Session { get; } = new();

        public int StageCount => Session.BeginCount;

        public int CommitCount => Session.CommitCount;

        public int RestoreCount => Session.RollbackCount;

        public bool OldDirectoryRestored =>
            ExistingDirectory && Session.RollbackCount > 0;

        public Task RecoverIncompleteAsync(CancellationToken cancellationToken)
        {
            RecoverCount++;
            return Task.CompletedTask;
        }

        public Task<IApplicationTransactionSession> BeginAsync(
            IReadOnlyList<string> targetKeys,
            CancellationToken cancellationToken)
        {
            BeginTargetKeys = targetKeys.ToArray();
            Session.BeginCount++;
            return Task.FromResult<IApplicationTransactionSession>(Session);
        }
    }

    private sealed class FakeApplicationTransactionSession
        : IApplicationTransactionSession
    {
        public int BeginCount { get; set; }

        public bool IsCommitted { get; private set; }

        public int CommitCount { get; private set; }

        public int RollbackCount { get; private set; }

        public ApplicationTransactionCommitResult CommitResult { get; set; } =
            new(CleanupPending: false);

        public Task<ApplicationTransactionCommitResult> CommitAsync(
            CancellationToken cancellationToken)
        {
            CommitCount++;
            IsCommitted = true;
            return Task.FromResult(CommitResult);
        }

        public Task RollBackAsync(CancellationToken cancellationToken)
        {
            RollbackCount++;
            return Task.CompletedTask;
        }
    }

    private sealed class FakeManagedApplicationPathPolicy
        : IManagedApplicationPathPolicy
    {
        public int ActiveLeaseCount { get; private set; }

        public async Task<VerifiedManagedFileLease> VerifyPayloadAsync(
            string targetKey,
            string payloadRoot,
            PayloadEntry entry,
            CancellationToken cancellationToken)
        {
            var path = Path.GetFullPath(Path.Combine(
                payloadRoot,
                entry.RelativePath.Replace('/', Path.DirectorySeparatorChar)));
            await using var stream = File.OpenRead(path);
            var sha256 = Convert.ToHexString(
                    await SHA256.HashDataAsync(stream, cancellationToken))
                .ToLowerInvariant();
            if (new FileInfo(path).Length != entry.Size
                || !string.Equals(
                    sha256,
                    entry.Sha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Fixture payload mismatch.");
            }

            return CreateLease(new VerifiedManagedFile(
                    targetKey,
                    payloadRoot,
                    path,
                    new FileInfo(path).Length,
                    sha256));
        }

        public async Task<VerifiedManagedFileLease> VerifyFileAsync(
            string targetKey,
            string rootPath,
            string path,
            string? expectedSha256,
            CancellationToken cancellationToken)
        {
            await using var stream = File.OpenRead(path);
            var sha256 = Convert.ToHexString(
                    await SHA256.HashDataAsync(stream, cancellationToken))
                .ToLowerInvariant();
            if (expectedSha256 is not null
                && !string.Equals(
                    expectedSha256,
                    sha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Fixture hash mismatch.");
            }

            return CreateLease(new VerifiedManagedFile(
                    targetKey,
                    rootPath,
                    Path.GetFullPath(path),
                    new FileInfo(path).Length,
                    sha256));
        }

        public void ValidatePath(string targetKey, string rootPath, string path)
        {
        }

        private VerifiedManagedFileLease CreateLease(VerifiedManagedFile file)
        {
            ActiveLeaseCount++;
            return new VerifiedManagedFileLease(
                file,
                new FakeLeaseOwner(() => ActiveLeaseCount--));
        }

        private sealed class FakeLeaseOwner(Action onDispose) : IAsyncDisposable
        {
            private bool _disposed;

            public ValueTask DisposeAsync()
            {
                if (!_disposed)
                {
                    _disposed = true;
                    onDispose();
                }
                return ValueTask.CompletedTask;
            }
        }
    }

    private sealed class FakeCodexPlusPlusSetupInspector
        : ICodexPlusPlusSetupInspector
    {
        public CodexPlusPlusSetupProvenance Provenance { get; set; } =
            ReviewedSetupProvenance();

        public CodexPlusPlusSetupProvenance Inspect(
            VerifiedManagedFile setup) =>
            Provenance;
    }

    private sealed class FakeProcessSecurityContext : IProcessSecurityContext
    {
        public bool IsElevated { get; init; }

        public bool IsCurrentUser { get; init; } = true;
    }

    private sealed class FakeProcessExecutionBackend : IProcessExecutionBackend
    {
        public int ExitCode { get; init; }

        public bool HangWithChild { get; init; }

        public int ExecutionCount { get; private set; }

        public ProcessExecutionRequest? Request { get; private set; }

        public bool RootProcessAlive { get; private set; }

        public bool ChildProcessAlive { get; private set; }

        public Func<bool>? LeaseOpenProbe { get; init; }

        public bool LeaseOpenDuringExecution { get; private set; }

        public TaskCompletionSource Started { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource CancellationObserved { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource AllowExit { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<ProcessExecutionResult> ExecuteAsync(
            ProcessExecutionRequest request,
            Func<string, Task> onStandardOutput,
            Func<string, Task> onStandardError,
            CancellationToken cancellationToken)
        {
            ExecutionCount++;
            Request = request;
            LeaseOpenDuringExecution = LeaseOpenProbe?.Invoke() ?? false;
            RootProcessAlive = true;
            ChildProcessAlive = HangWithChild;
            Started.TrySetResult();
            if (HangWithChild)
            {
                try
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    RootProcessAlive = false;
                    ChildProcessAlive = false;
                    CancellationObserved.TrySetResult();
                }

                await AllowExit.Task;
                return new ProcessExecutionResult(137, WasCancelled: true);
            }

            RootProcessAlive = false;
            return new ProcessExecutionResult(ExitCode, WasCancelled: false);
        }
    }

    private sealed class FakeCodexPlusPlusInstallationProbe
        : ICodexPlusPlusInstallationProbe
    {
        public string? RequestedInstallRoot { get; private set; }

        public CodexPlusPlusInstallationState State { get; set; } =
            new(
                InstallRoot: string.Empty,
                LauncherPresent: true,
                ManagerPresent: true,
                DisplayVersion: CodexPlusPlusVersion,
                HasUninstallEntry: true,
                LauncherMetadata: Metadata("launcher"),
                ManagerMetadata: Metadata("manager"),
                LauncherIsPeX64: true,
                ManagerIsPeX64: true,
                LauncherFileVersion: CodexPlusPlusVersion,
                ManagerFileVersion: CodexPlusPlusVersion,
                LauncherSha256: new string('1', 64),
                ManagerSha256: new string('2', 64),
                ProductRegistrationIsCurrentUser: true,
                UninstallRegistrationIsCurrentUser: true,
                ProductInstallDirectory: "<requested>",
                UninstallDisplayVersion: CodexPlusPlusVersion,
                UninstallInstallLocation: "<requested>",
                UninstallString: "<requested-uninstall>",
                UninstallerPresent: true,
                CurrentUserShortcutsPresent: true);

        public Task<CodexPlusPlusInstallationState> InspectAsync(
            string installRoot,
            CodexPlusPlusSetupProvenance provenance,
            CancellationToken cancellationToken)
        {
            RequestedInstallRoot = installRoot;
            return Task.FromResult(State with
            {
                InstallRoot = installRoot,
                UninstallInstallLocation =
                    State.UninstallInstallLocation == "<requested>"
                        ? installRoot
                        : State.UninstallInstallLocation,
                ProductInstallDirectory =
                    State.ProductInstallDirectory == "<requested>"
                        ? installRoot
                        : State.ProductInstallDirectory,
                UninstallString =
                    State.UninstallString == "<requested-uninstall>"
                        ? $"\"{Path.Combine(installRoot, "uninstall.exe")}\""
                        : State.UninstallString
            });
        }
    }
}
