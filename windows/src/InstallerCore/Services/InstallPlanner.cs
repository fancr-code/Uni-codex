namespace CodexOneClickInstaller;

public static class InstallReasonCodes
{
    public const string CodexHealthy = "codex_healthy";
    public const string CodexNotInstalled = "codex_not_installed";
    public const string CodexDamaged = "codex_damaged";
    public const string CodexPlusPlusCurrent = "codex_plus_plus_current";
    public const string CodexPlusPlusNotInstalled = "codex_plus_plus_not_installed";
    public const string CodexPlusPlusOutdated = "codex_plus_plus_outdated";
    public const string CodexPlusPlusDamaged = "codex_plus_plus_damaged";
    public const string CodexPlusPlusNewer = "codex_plus_plus_newer";
}

public sealed class InstallPlanner
{
    private const string CodexPayloadId = "codex-windows-x64";
    private const string CodexPlusPlusPayloadId = "codex-plus-plus-windows-x64";

    public IReadOnlyList<ComponentPlan> CreatePlan(
        PreflightResult preflight,
        PayloadCatalog catalog)
    {
        ArgumentNullException.ThrowIfNull(preflight);
        ArgumentNullException.ThrowIfNull(catalog);

        var codexPayload = RequiredEntry(catalog, CodexPayloadId);
        var codexPlusPlusPayload = RequiredEntry(catalog, CodexPlusPlusPayloadId);
        if (string.IsNullOrWhiteSpace(codexPayload.PackageFamilyName))
        {
            throw new ArgumentException(
                "The validated Codex payload must declare a package family.",
                nameof(catalog));
        }

        return Array.AsReadOnly(
        [
            PlanCodex(
                preflight.InstalledPackages,
                codexPayload),
            PlanCodexPlusPlus(
                preflight.InstalledPackages,
                codexPlusPlusPayload)
        ]);
    }

    private static ComponentPlan PlanCodex(
        IReadOnlyList<InstalledPackage> installedPackages,
        PayloadEntry payload)
    {
        var matches = installedPackages
            .Where(package => string.Equals(
                package.PackageFamilyName,
                payload.PackageFamilyName,
                StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (matches.Length == 0)
        {
            return Plan(
                payload,
                PlanAction.Install,
                installedVersion: null,
                InstallReasonCodes.CodexNotInstalled);
        }

        var healthyExact = matches
            .Where(package =>
                IsHealthy(package)
                && string.Equals(
                    package.Version,
                    payload.Version,
                    StringComparison.Ordinal))
            .OrderByDescending(StablePackageKey, StringComparer.Ordinal)
            .FirstOrDefault();
        if (healthyExact is not null)
        {
            return Plan(
                payload,
                PlanAction.Preserve,
                healthyExact.Version,
                InstallReasonCodes.CodexHealthy);
        }

        var healthy = matches
            .Select(package => new
            {
                Package = package,
                Parsed = TryParseWindowsPackageVersion(package.Version, out var parsed)
                    ? parsed
                    : (WindowsPackageVersion?)null
            })
            .Where(candidate =>
                IsHealthy(candidate.Package)
                && candidate.Parsed.HasValue)
            .OrderByDescending(candidate => candidate.Parsed!.Value)
            .ThenByDescending(
                candidate => StablePackageKey(candidate.Package),
                StringComparer.Ordinal)
            .Select(candidate => candidate.Package)
            .FirstOrDefault();
        if (healthy is not null)
        {
            return Plan(
                payload,
                PlanAction.Preserve,
                healthy.Version,
                InstallReasonCodes.CodexHealthy);
        }

        var damaged = SelectStableRepairTarget(matches);
        return Plan(
            payload,
            PlanAction.Repair,
            damaged.Version,
            InstallReasonCodes.CodexDamaged);
    }

    private static ComponentPlan PlanCodexPlusPlus(
        IReadOnlyList<InstalledPackage> installedPackages,
        PayloadEntry payload)
    {
        var matches = installedPackages
            .Where(package => string.Equals(
                package.PackageFamilyName,
                PreflightService.CodexPlusPlusComponentIdentity,
                StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (matches.Length == 0)
        {
            return Plan(
                payload,
                PlanAction.Install,
                installedVersion: null,
                InstallReasonCodes.CodexPlusPlusNotInstalled);
        }

        if (!TryParseCodexPlusPlusVersion(payload.Version, out var payloadVersion))
        {
            throw new ArgumentException(
                "The validated Codex++ payload version is malformed.",
                nameof(payload));
        }

        var current = matches
            .Where(package =>
                IsHealthy(package)
                && string.Equals(
                    package.Version,
                    payload.Version,
                    StringComparison.Ordinal))
            .OrderByDescending(StablePackageKey, StringComparer.Ordinal)
            .FirstOrDefault();
        if (current is not null)
        {
            return Plan(
                payload,
                PlanAction.Preserve,
                current.Version,
                InstallReasonCodes.CodexPlusPlusCurrent);
        }

        var candidate = matches
            .Select(package => new
            {
                Package = package,
                Parsed = TryParseCodexPlusPlusVersion(package.Version, out var parsed)
                    ? parsed
                    : (CodexPlusPlusVersion?)null
            })
            .Where(item => IsHealthy(item.Package) && item.Parsed.HasValue)
            .OrderByDescending(item => item.Parsed!.Value)
            .ThenByDescending(
                item => StablePackageKey(item.Package),
                StringComparer.Ordinal)
            .FirstOrDefault();
        if (candidate is null)
        {
            var damaged = SelectStableRepairTarget(matches);
            return Plan(
                payload,
                PlanAction.Repair,
                damaged.Version,
                InstallReasonCodes.CodexPlusPlusDamaged);
        }

        if (candidate.Parsed!.Value.CompareTo(payloadVersion) > 0)
        {
            return Plan(
                payload,
                PlanAction.Preserve,
                candidate.Package.Version,
                InstallReasonCodes.CodexPlusPlusNewer);
        }

        return Plan(
            payload,
            PlanAction.Upgrade,
            candidate.Package.Version,
            InstallReasonCodes.CodexPlusPlusOutdated);
    }

    private static ComponentPlan Plan(
        PayloadEntry payload,
        PlanAction action,
        string? installedVersion,
        string reasonCode) =>
        new(
            payload.Id,
            action,
            installedVersion,
            payload.Version,
            reasonCode);

    private static PayloadEntry RequiredEntry(PayloadCatalog catalog, string id)
    {
        var entries = catalog.Entries
            .Where(entry => string.Equals(entry.Id, id, StringComparison.Ordinal))
            .ToArray();
        return entries.Length == 1
            ? entries[0]
            : throw new ArgumentException(
                $"Validated payload catalog must contain exactly one {id} entry.",
                nameof(catalog));
    }

    private static bool IsHealthy(InstalledPackage package) =>
        package.IsSignatureValid
        && !string.IsNullOrWhiteSpace(package.ExecutablePath);

    private static InstalledPackage SelectStableRepairTarget(
        IEnumerable<InstalledPackage> packages) =>
        packages
            .OrderByDescending(package => package.Version, StringComparer.Ordinal)
            .ThenByDescending(StablePackageKey, StringComparer.Ordinal)
            .First();

    private static string StablePackageKey(InstalledPackage package) =>
        $"{package.PackageFamilyName}\0{package.ExecutablePath}\0" +
        (package.IsSignatureValid ? "1" : "0");

    private static bool TryParseWindowsPackageVersion(
        string value,
        out WindowsPackageVersion version)
    {
        version = default;
        var parts = value.Split('.');
        if (parts.Length != 4
            || !parts.All(IsCanonicalNumber)
            || !ushort.TryParse(parts[0], out var major)
            || !ushort.TryParse(parts[1], out var minor)
            || !ushort.TryParse(parts[2], out var build)
            || !ushort.TryParse(parts[3], out var revision))
        {
            return false;
        }

        version = new WindowsPackageVersion(major, minor, build, revision);
        return true;
    }

    private static bool TryParseCodexPlusPlusVersion(
        string value,
        out CodexPlusPlusVersion version)
    {
        version = default;
        var sections = value.Split('+');
        if (sections.Length is < 1 or > 2)
            return false;

        var core = sections[0].Split('.');
        if (core.Length != 3
            || !core.All(IsCanonicalNumber)
            || !ulong.TryParse(core[0], out var major)
            || !ulong.TryParse(core[1], out var minor)
            || !ulong.TryParse(core[2], out var patch))
        {
            return false;
        }

        ulong? codexKitRevision = null;
        if (sections.Length == 2)
        {
            const string prefix = "codexkit.";
            var metadata = sections[1];
            if (!metadata.StartsWith(prefix, StringComparison.Ordinal))
                return false;
            var revision = metadata[prefix.Length..];
            if (!IsCanonicalNumber(revision)
                || !ulong.TryParse(revision, out var parsedRevision))
            {
                return false;
            }
            codexKitRevision = parsedRevision;
        }

        version = new CodexPlusPlusVersion(
            major,
            minor,
            patch,
            codexKitRevision);
        return true;
    }

    private static bool IsCanonicalNumber(string value) =>
        value.Length > 0
        && (value.Length == 1 || value[0] != '0')
        && value.All(character => character is >= '0' and <= '9');

    private readonly record struct WindowsPackageVersion(
        ushort Major,
        ushort Minor,
        ushort Build,
        ushort Revision) : IComparable<WindowsPackageVersion>
    {
        public int CompareTo(WindowsPackageVersion other)
        {
            var result = Major.CompareTo(other.Major);
            if (result != 0) return result;
            result = Minor.CompareTo(other.Minor);
            if (result != 0) return result;
            result = Build.CompareTo(other.Build);
            return result != 0 ? result : Revision.CompareTo(other.Revision);
        }
    }

    private readonly record struct CodexPlusPlusVersion(
        ulong Major,
        ulong Minor,
        ulong Patch,
        ulong? CodexKitRevision) : IComparable<CodexPlusPlusVersion>
    {
        public int CompareTo(CodexPlusPlusVersion other)
        {
            var result = Major.CompareTo(other.Major);
            if (result != 0) return result;
            result = Minor.CompareTo(other.Minor);
            if (result != 0) return result;
            result = Patch.CompareTo(other.Patch);
            if (result != 0) return result;
            if (CodexKitRevision.HasValue != other.CodexKitRevision.HasValue)
                return CodexKitRevision.HasValue ? 1 : -1;
            return CodexKitRevision.GetValueOrDefault()
                .CompareTo(other.CodexKitRevision.GetValueOrDefault());
        }
    }
}
