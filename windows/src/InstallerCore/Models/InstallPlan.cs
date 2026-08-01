namespace CodexOneClickInstaller;

public enum PlanAction
{
    Preserve,
    Install,
    Upgrade,
    Repair,
    Skip
}

public sealed record ComponentPlan(
    string Component,
    PlanAction Action,
    string? InstalledVersion,
    string PayloadVersion,
    string ReasonCode);

public interface IInstallerEngine
{
    Task<PreflightResult> PreflightAsync(CancellationToken cancellationToken);

    Task<InstallResult> InstallAsync(
        InstallRequest request,
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationToken);

    Task<RestoreResult> RestoreLatestAsync(
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationToken);
}
