using Xunit;

namespace CodexOneClickInstaller;

public sealed class InstallPlannerTests
{
    [Fact]
    public void Healthy_matching_codex_package_is_preserved()
    {
        var installed = InstalledCodex(signatureValid: true, executablePresent: true);

        var plan = Plan(installed);

        AssertPlan(
            plan,
            "codex-windows-x64",
            PlanAction.Preserve,
            InstallReasonCodes.CodexHealthy,
            installed.Version);
    }

    [Fact]
    public void Package_with_a_different_family_is_not_reused()
    {
        var wrongFamily = InstalledCodex(
            signatureValid: true,
            executablePresent: true) with
        {
            PackageFamilyName = "OpenAI.NotCodex_fixture"
        };

        var plan = Plan(wrongFamily);

        AssertPlan(
            plan,
            "codex-windows-x64",
            PlanAction.Install,
            InstallReasonCodes.CodexNotInstalled,
            installedVersion: null);
    }

    [Fact]
    public void Missing_codex_is_installed()
    {
        var plan = Plan();

        AssertPlan(
            plan,
            "codex-windows-x64",
            PlanAction.Install,
            InstallReasonCodes.CodexNotInstalled,
            installedVersion: null);
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void Codex_with_an_invalid_signature_or_missing_cli_is_repaired(
        bool signatureValid,
        bool executablePresent)
    {
        var damaged = InstalledCodex(signatureValid, executablePresent);

        var plan = Plan(damaged);

        AssertPlan(
            plan,
            "codex-windows-x64",
            PlanAction.Repair,
            InstallReasonCodes.CodexDamaged,
            damaged.Version);
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("26.7")]
    [InlineData("26.7.27.70000")]
    public void Codex_with_a_malformed_package_version_is_repaired(string version)
    {
        var damaged = InstalledCodex(
            signatureValid: true,
            executablePresent: true,
            version: version);

        var plan = Plan(damaged);

        AssertPlan(
            plan,
            "codex-windows-x64",
            PlanAction.Repair,
            InstallReasonCodes.CodexDamaged,
            damaged.Version);
    }

    [Fact]
    public void Matching_codex_plus_plus_version_is_preserved()
    {
        var installed = InstalledCodexPlusPlus("1.2.43+codexkit.1");

        var plan = Plan(installed);

        AssertPlan(
            plan,
            "codex-plus-plus-windows-x64",
            PlanAction.Preserve,
            InstallReasonCodes.CodexPlusPlusCurrent,
            installed.Version);
    }

    [Fact]
    public void Older_codex_plus_plus_version_is_upgraded()
    {
        var installed = InstalledCodexPlusPlus("1.2.42");

        var plan = Plan(installed);

        AssertPlan(
            plan,
            "codex-plus-plus-windows-x64",
            PlanAction.Upgrade,
            InstallReasonCodes.CodexPlusPlusOutdated,
            installed.Version);
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("1.2")]
    [InlineData("1.2.43+other.9")]
    [InlineData("1.2.43+codexkit.x")]
    public void Malformed_codex_plus_plus_version_is_repaired(string version)
    {
        var installed = InstalledCodexPlusPlus(version);

        var plan = Plan(installed);

        AssertPlan(
            plan,
            "codex-plus-plus-windows-x64",
            PlanAction.Repair,
            InstallReasonCodes.CodexPlusPlusDamaged,
            installed.Version);
    }

    [Theory]
    [InlineData(
        "1.2.43+codexkit.2",
        PlanAction.Preserve,
        InstallReasonCodes.CodexPlusPlusNewer)]
    [InlineData(
        "1.2.43+codexkit.0",
        PlanAction.Upgrade,
        InstallReasonCodes.CodexPlusPlusOutdated)]
    public void Codexkit_revision_participates_in_version_ordering(
        string installedVersion,
        PlanAction expectedAction,
        string expectedReason)
    {
        var installed = InstalledCodexPlusPlus(installedVersion);

        var plan = Plan(installed);

        AssertPlan(
            plan,
            "codex-plus-plus-windows-x64",
            expectedAction,
            expectedReason,
            installed.Version);
    }

    [Fact]
    public void Duplicate_codex_records_choose_healthy_exact_version_regardless_of_order()
    {
        var damagedExact = InstalledCodex(
            signatureValid: false,
            executablePresent: true,
            version: "26.7.27.0");
        var healthyNewer = InstalledCodex(
            signatureValid: true,
            executablePresent: true,
            version: "26.8.1.0");
        var healthyExact = InstalledCodex(
            signatureValid: true,
            executablePresent: true,
            version: "26.7.27.0");

        var forward = Plan(damagedExact, healthyNewer, healthyExact);
        var reversed = Plan(healthyExact, healthyNewer, damagedExact);

        Assert.Equal(forward, reversed);
        AssertPlan(
            forward,
            "codex-windows-x64",
            PlanAction.Preserve,
            InstallReasonCodes.CodexHealthy,
            healthyExact.Version);
    }

    [Fact]
    public void Duplicate_codex_records_without_exact_choose_highest_valid_version()
    {
        var older = InstalledCodex(
            signatureValid: true,
            executablePresent: true,
            version: "26.7.20.0");
        var newer = InstalledCodex(
            signatureValid: true,
            executablePresent: true,
            version: "26.8.1.0");

        var forward = Plan(older, newer);
        var reversed = Plan(newer, older);

        Assert.Equal(forward, reversed);
        AssertPlan(
            forward,
            "codex-windows-x64",
            PlanAction.Preserve,
            InstallReasonCodes.CodexHealthy,
            newer.Version);
    }

    [Fact]
    public void Duplicate_codex_plus_plus_records_choose_current_regardless_of_order()
    {
        var damagedCurrent = InstalledCodexPlusPlus(
            "1.2.43+codexkit.1",
            signatureValid: false);
        var healthyOlder = InstalledCodexPlusPlus("1.2.43+codexkit.0");
        var healthyCurrent = InstalledCodexPlusPlus("1.2.43+codexkit.1");

        var forward = Plan(damagedCurrent, healthyOlder, healthyCurrent);
        var reversed = Plan(healthyCurrent, healthyOlder, damagedCurrent);

        Assert.Equal(forward, reversed);
        AssertPlan(
            forward,
            "codex-plus-plus-windows-x64",
            PlanAction.Preserve,
            InstallReasonCodes.CodexPlusPlusCurrent,
            healthyCurrent.Version);
    }

    [Fact]
    public void Duplicate_codex_plus_plus_records_choose_highest_valid_version()
    {
        var older = InstalledCodexPlusPlus("1.2.43+codexkit.0");
        var newer = InstalledCodexPlusPlus("1.2.43+codexkit.2");

        var forward = Plan(older, newer);
        var reversed = Plan(newer, older);

        Assert.Equal(forward, reversed);
        AssertPlan(
            forward,
            "codex-plus-plus-windows-x64",
            PlanAction.Preserve,
            InstallReasonCodes.CodexPlusPlusNewer,
            newer.Version);
    }

    [Fact]
    public void All_damaged_duplicates_choose_a_stable_repair_target()
    {
        var first = InstalledCodexPlusPlus(
            "z-broken",
            signatureValid: false,
            executablePresent: false);
        var second = InstalledCodexPlusPlus(
            "a-broken",
            signatureValid: false,
            executablePresent: false);

        var forward = Plan(first, second);
        var reversed = Plan(second, first);

        Assert.Equal(forward, reversed);
        AssertPlan(
            forward,
            "codex-plus-plus-windows-x64",
            PlanAction.Repair,
            InstallReasonCodes.CodexPlusPlusDamaged,
            "z-broken");
    }

    [Fact]
    public void Planner_returns_one_stable_plan_for_each_installable_application()
    {
        var plans = Plan();

        Assert.Collection(
            plans,
            codex => Assert.Equal("codex-windows-x64", codex.Component),
            codexPlusPlus =>
                Assert.Equal("codex-plus-plus-windows-x64", codexPlusPlus.Component));
    }

    private static IReadOnlyList<ComponentPlan> Plan(
        params InstalledPackage[] installedPackages)
    {
        var preflight = new PreflightResult(
            true,
            null,
            installedPackages,
            []);

        return new InstallPlanner().CreatePlan(preflight, Catalog());
    }

    private static PayloadCatalog Catalog() =>
        new(
            2,
            [
                Entry(
                    "codex-windows-x64",
                    "26.7.27.0",
                    PreflightService.CodexPackageFamilyName),
                Entry(
                    "codex-plus-plus-windows-x64",
                    "1.2.43+codexkit.1",
                    packageFamilyName: null),
                Entry(
                    "codex-plus-plus-source",
                    "1.2.43+codexkit.1",
                    packageFamilyName: null)
            ]);

    private static PayloadEntry Entry(
        string id,
        string version,
        string? packageFamilyName) =>
        new(
            id,
            version,
            id == "codex-plus-plus-source" ? "source" : "x64",
            $"apps/{id}",
            new string('a', 64),
            1,
            new Uri($"https://example.invalid/{id}"),
            id == "codex-windows-x64" ? "msixbundle" : "exe",
            packageFamilyName,
            packageFamilyName is null ? null : "CN=OpenAI",
            packageFamilyName is null ? null : "OpenAI.Codex",
            null,
            id.StartsWith("codex-plus-plus", StringComparison.Ordinal)
                ? "cross-provider-content-v1"
                : null,
            id.StartsWith("codex-plus-plus", StringComparison.Ordinal)
                ? "AGPL-3.0-only"
                : null);

    private static InstalledPackage InstalledCodex(
        bool signatureValid,
        bool executablePresent,
        string version = "26.7.20.0") =>
        new(
            PreflightService.CodexPackageFamilyName,
            version,
            signatureValid,
            executablePresent
                ? @"C:\Program Files\WindowsApps\OpenAI.Codex\codex.exe"
                : null);

    private static InstalledPackage InstalledCodexPlusPlus(
        string version,
        bool signatureValid = true,
        bool executablePresent = true) =>
        new(
            PreflightService.CodexPlusPlusComponentIdentity,
            version,
            signatureValid,
            executablePresent
                ? @"C:\Users\fixture\AppData\Local\Programs\Codex++\Codex++.exe"
                : null);

    private static void AssertPlan(
        IReadOnlyList<ComponentPlan> plans,
        string component,
        PlanAction action,
        string reasonCode,
        string? installedVersion)
    {
        var plan = Assert.Single(plans, candidate => candidate.Component == component);
        Assert.Equal(action, plan.Action);
        Assert.Equal(reasonCode, plan.ReasonCode);
        Assert.Equal(installedVersion, plan.InstalledVersion);
    }
}
