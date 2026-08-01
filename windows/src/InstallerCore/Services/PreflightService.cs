using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32;
#if WINDOWS
using Windows.ApplicationModel;
using Windows.Management.Deployment;
#endif

namespace CodexOneClickInstaller;

public interface IWindowsEnvironment
{
    Version OSVersion { get; }

    Architecture OSArchitecture { get; }

    long GetAvailableBytes(string path);

    IReadOnlyList<InstalledPackage> FindPackages(string packageFamilyName);

    IReadOnlyList<RunningComponent> FindRunningComponents();
}

public static class PreflightFailureCodes
{
    public const string UnsupportedWindowsBuild = "unsupported_windows_build";
    public const string UnsupportedArchitecture = "unsupported_architecture";
    public const string InsufficientDiskSpace = "insufficient_disk_space";
    public const string ComponentsRunning = "components_running";
}

public sealed class PreflightService
{
    public const int MinimumWindowsBuild = 17763;
    public const long DiskSafetyMarginBytes = 2L * 1024 * 1024 * 1024;
    public const string CodexPackageFamilyName = "OpenAI.Codex_2p2nqsd0c76g0";
    public const string CodexPlusPlusComponentIdentity = "Codex++";

    private readonly IWindowsEnvironment _environment;

    public PreflightService(IWindowsEnvironment environment) =>
        _environment = environment ?? throw new ArgumentNullException(nameof(environment));

    public PreflightResult Evaluate(
        string installPath,
        long payloadExtractionPeakBytes)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(installPath);
        if (payloadExtractionPeakBytes < 0
            || payloadExtractionPeakBytes > long.MaxValue - DiskSafetyMarginBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(payloadExtractionPeakBytes),
                "Payload extraction peak must leave room for the 2 GiB safety margin.");
        }

        if (_environment.OSVersion.Build < MinimumWindowsBuild)
            return Failed(PreflightFailureCodes.UnsupportedWindowsBuild);

        if (_environment.OSArchitecture != Architecture.X64)
            return Failed(PreflightFailureCodes.UnsupportedArchitecture);

        var requiredBytes = payloadExtractionPeakBytes + DiskSafetyMarginBytes;
        if (_environment.GetAvailableBytes(installPath) < requiredBytes)
            return Failed(PreflightFailureCodes.InsufficientDiskSpace);

        var installedPackages = _environment.FindPackages(CodexPackageFamilyName)
            .Concat(_environment.FindPackages(CodexPlusPlusComponentIdentity))
            .ToArray();
        var runningComponents = _environment.FindRunningComponents().ToArray();
        if (runningComponents.Length > 0)
        {
            return new PreflightResult(
                false,
                PreflightFailureCodes.ComponentsRunning,
                Array.AsReadOnly(installedPackages),
                Array.AsReadOnly(runningComponents));
        }

        return new PreflightResult(
            true,
            null,
            Array.AsReadOnly(installedPackages),
            Array.AsReadOnly(runningComponents));
    }

    private static PreflightResult Failed(string failureCode) =>
        new(false, failureCode, Array.Empty<InstalledPackage>(),
            Array.Empty<RunningComponent>());
}

public sealed class WindowsEnvironment : IWindowsEnvironment
{
    private static readonly string[] CodexExecutableNames =
        ["codex.exe", "Codex.exe"];
    private static readonly string[] CodexPlusPlusExecutableNames =
        ["codex-plus-plus.exe", "Codex++.exe"];
    private static readonly HashSet<string> BlockingProcessNames =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "ChatGPT",
            "codex",
            "codex-plus-plus",
            "codex-plus-plus-manager",
            "Codex++"
        };

    public Version OSVersion => Environment.OSVersion.Version;

    public Architecture OSArchitecture => RuntimeInformation.OSArchitecture;

    public long GetAvailableBytes(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(root))
            throw new ArgumentException("Install path does not have a volume root.", nameof(path));
        return new DriveInfo(root).AvailableFreeSpace;
    }

    public IReadOnlyList<InstalledPackage> FindPackages(string packageFamilyName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageFamilyName);
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException(
                "Installed package queries require Windows.");

        if (string.Equals(
                packageFamilyName,
                PreflightService.CodexPlusPlusComponentIdentity,
                StringComparison.Ordinal))
        {
            var installed = FindCodexPlusPlus();
            return installed is null ? [] : [installed];
        }

#if WINDOWS
        return FindAppPackages(packageFamilyName);
#else
        throw new PlatformNotSupportedException(
            "App package queries require the Windows-targeted core asset.");
#endif
    }

    public IReadOnlyList<RunningComponent> FindRunningComponents()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException(
                "Running component queries require Windows.");

        var running = new List<RunningComponent>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (TryGetBlockingComponentName(
                            process.ProcessName,
                            out var componentName))
                    {
                        running.Add(new RunningComponent(
                            componentName,
                            process.Id));
                    }
                }
                catch (InvalidOperationException)
                {
                    // The process exited while its metadata was being read.
                }
            }
        }

        return running
            .OrderBy(component => component.Name, StringComparer.Ordinal)
            .ThenBy(component => component.ProcessId)
            .ToArray();
    }

#if WINDOWS
    private static IReadOnlyList<InstalledPackage> FindAppPackages(
        string packageFamilyName)
    {
        var packageManager = new PackageManager();
        var results = new List<InstalledPackage>();
        foreach (var package in packageManager.FindPackagesForUser(
                     string.Empty,
                     packageFamilyName))
        {
            var familyName = package.Id.FamilyName;
            if (!string.Equals(
                    familyName,
                    packageFamilyName,
                    StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var version = package.Id.Version;
            var executable = FindExecutable(
                package.InstalledLocation.Path,
                CodexExecutableNames);
            results.Add(new InstalledPackage(
                familyName,
                $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}",
                IsPackageSignatureValid(package),
                executable));
        }

        return results;
    }

    private static bool IsPackageSignatureValid(Package package) =>
        package.SignatureKind is PackageSignatureKind.Store
            or PackageSignatureKind.Developer
        && package.Status.VerifyIsOK();
#endif

    [SupportedOSPlatform("windows")]
    private static InstalledPackage? FindCodexPlusPlus()
    {
        var installRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs",
            "Codex++");
        var executable = FindExecutable(installRoot, CodexPlusPlusExecutableNames);
        using var productKey = Registry.CurrentUser.OpenSubKey(@"Software\Codex++");
        using var uninstallKey = Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++");
        var version = productKey?.GetValue("DisplayVersion")?.ToString()
                      ?? uninstallKey?.GetValue("DisplayVersion")?.ToString();
        if (string.IsNullOrWhiteSpace(version) && executable is not null)
        {
            version = FileVersionInfo.GetVersionInfo(executable).ProductVersion
                      ?? FileVersionInfo.GetVersionInfo(executable).FileVersion;
        }

        if (string.IsNullOrWhiteSpace(version) && executable is null)
            return null;

        return new InstalledPackage(
            PreflightService.CodexPlusPlusComponentIdentity,
            version ?? "unknown",
            executable is not null,
            executable);
    }

    private static string? FindExecutable(
        string? directory,
        IReadOnlyList<string> executableNames)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
            return null;

        foreach (var name in executableNames)
        {
            var directPath = Path.Combine(directory, name);
            if (File.Exists(directPath))
                return directPath;
        }

        try
        {
            var expected = executableNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
            return Directory.EnumerateFiles(
                    directory,
                    "*.exe",
                    SearchOption.AllDirectories)
                .FirstOrDefault(path => expected.Contains(Path.GetFileName(path)));
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    public static bool TryGetBlockingComponentName(
        string processName,
        out string componentName)
    {
        if (string.IsNullOrWhiteSpace(processName)
            || !BlockingProcessNames.Contains(processName))
        {
            componentName = string.Empty;
            return false;
        }

        componentName = processName.StartsWith(
                            "codex-plus-plus",
                            StringComparison.OrdinalIgnoreCase)
                        || string.Equals(
                            processName,
                            "Codex++",
                            StringComparison.OrdinalIgnoreCase)
            ? "Codex++"
            : "Codex";
        return true;
    }
}
