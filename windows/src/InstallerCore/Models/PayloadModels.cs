namespace CodexOneClickInstaller;

public sealed record ModelDefinition(string Id, string DisplayName, int? ContextWindow);

public sealed record ProviderDefinition(
    ProviderKind Kind,
    string Protocol,
    IReadOnlyList<ModelDefinition> Models);

public sealed record ProviderCatalog(
    int SchemaVersion,
    DateTimeOffset GeneratedAt,
    IReadOnlyList<ProviderDefinition> Providers);

public sealed record PayloadEntry(
    string Id,
    string Version,
    string Architecture,
    string RelativePath,
    string Sha256,
    long Size,
    Uri SourceUrl,
    string Format,
    string? PackageFamilyName,
    string? Publisher,
    string? PackageName,
    string? MinimumVersion,
    string? CompatibilityRevision,
    string? LicenseId);

public sealed record PayloadCatalog(int SchemaVersion, IReadOnlyList<PayloadEntry> Entries);

public sealed record InstalledPackage(
    string PackageFamilyName,
    string Version,
    bool IsSignatureValid,
    string? ExecutablePath);

public sealed record RunningComponent(string Name, int ProcessId);
