using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexOneClickInstaller;

public sealed record StartupOptions(
    string PayloadRoot,
    string? CiSmokeReport,
    string? DreamSkinSetupPath = null);

public static class StartupContract
{
    public const int SuccessExitCode = 0;
    public const int CancelledExitCode = 2;
    public const int FailureExitCode = 3;

    public static string ResolvePayloadRoot(
        IReadOnlyList<string> arguments,
        string baseDirectory)
        => Parse(arguments, baseDirectory).PayloadRoot;

    public static StartupOptions Parse(
        IReadOnlyList<string> arguments,
        string baseDirectory)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentException.ThrowIfNullOrWhiteSpace(baseDirectory);

        string? payloadCandidate = null;
        string? reportCandidate = null;
        string? dreamSkinCandidate = null;
        for (var index = 0; index < arguments.Count; index += 2)
        {
            if (index + 1 >= arguments.Count
                || string.IsNullOrWhiteSpace(arguments[index + 1]))
            {
                throw new ArgumentException(
                    "Startup arguments must be name/value pairs.",
                    nameof(arguments));
            }
            switch (arguments[index])
            {
                case "--payload-root" when payloadCandidate is null:
                    payloadCandidate = arguments[index + 1];
                    break;
                case "--ci-smoke-report" when reportCandidate is null:
                    reportCandidate = arguments[index + 1];
                    break;
                case "--dream-skin-setup" when dreamSkinCandidate is null:
                    dreamSkinCandidate = arguments[index + 1];
                    break;
                default:
                    throw new ArgumentException(
                        "Unknown or duplicate startup argument.",
                        nameof(arguments));
            }
        }

        payloadCandidate ??= Path.Combine(baseDirectory, "offline-payloads");
        if (!Path.IsPathFullyQualified(payloadCandidate))
            throw new ArgumentException("Payload root must be an absolute path.");
        var payloadRoot = Path.GetFullPath(payloadCandidate);
        if (!Directory.Exists(payloadRoot))
            throw new DirectoryNotFoundException("Payload root is missing.");
        AssertNoReparsePoints(payloadRoot);

        string? report = null;
        if (reportCandidate is not null)
        {
            if (!Path.IsPathFullyQualified(reportCandidate))
                throw new ArgumentException("CI smoke report must be an absolute path.");
            report = Path.GetFullPath(reportCandidate);
            var parent = Path.GetDirectoryName(report)
                         ?? throw new ArgumentException("CI smoke report has no parent.");
            if (!Directory.Exists(parent))
                throw new DirectoryNotFoundException("CI smoke report parent is missing.");
            AssertNoReparsePoints(parent);
            if (File.Exists(report)
                && (File.GetAttributes(report) & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException("CI smoke report is a symbolic link or reparse point.");
            }
        }
        string? dreamSkinSetup = null;
        if (dreamSkinCandidate is not null)
        {
            if (!Path.IsPathFullyQualified(dreamSkinCandidate))
                throw new ArgumentException("Dream Skin setup path must be absolute.");
            dreamSkinSetup = Path.GetFullPath(dreamSkinCandidate);
            if (!File.Exists(dreamSkinSetup))
                throw new FileNotFoundException("Dream Skin setup is missing.", dreamSkinSetup);
            var setupParent = Path.GetDirectoryName(dreamSkinSetup)
                              ?? throw new ArgumentException("Dream Skin setup has no parent.");
            AssertNoReparsePoints(setupParent);
            if ((File.GetAttributes(dreamSkinSetup) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Dream Skin setup is a symbolic link or reparse point.");
        }
        return new StartupOptions(payloadRoot, report, dreamSkinSetup);
    }

    public static void WriteCiSmokeEvidence(StartupOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.CiSmokeReport is null)
            throw new ArgumentException("CI smoke report was not requested.");
        var manifestPath = Path.Combine(options.PayloadRoot, "payload-manifest.json");
        var catalogPath = Path.Combine(options.PayloadRoot, "model-catalog.json");
        using var manifest = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        using var catalog = JsonDocument.Parse(File.ReadAllBytes(catalogPath));
        if (!manifest.RootElement.TryGetProperty("files", out var files)
            || files.ValueKind != JsonValueKind.Array
            || files.GetArrayLength() == 0)
        {
            throw new InvalidDataException("Payload manifest has no files.");
        }
        if (!catalog.RootElement.TryGetProperty("providers", out var providers)
            || providers.ValueKind != JsonValueKind.Array
            || providers.GetArrayLength() == 0)
        {
            throw new InvalidDataException("Model catalog has no providers.");
        }
        var manifestSha256 = Convert.ToHexString(
            SHA256.HashData(File.ReadAllBytes(manifestPath))).ToLowerInvariant();
        var evidence = new
        {
            schemaVersion = 1,
            status = "pass",
            payloadManifest = "validated",
            modelCatalog = "validated",
            payloadCount = files.GetArrayLength(),
            providerCount = providers.GetArrayLength(),
            payloadManifestSha256 = manifestSha256,
            containsSecrets = false
        };
        var temporary = options.CiSmokeReport + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(
                temporary,
                JsonSerializer.Serialize(evidence) + "\n",
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            File.Move(temporary, options.CiSmokeReport, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }

    private static void AssertNoReparsePoints(string path)
    {
        var current = new DirectoryInfo(path);
        while (current is not null)
        {
            if ((current.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException(
                    "Payload root contains a symbolic link or reparse point.");
            }
            current = current.Parent;
        }
    }
}

public sealed class InstallerExitCodeCoordinator
{
    public int ExitCode { get; private set; } = StartupContract.CancelledExitCode;

    public void RecordSuccess() => ExitCode = StartupContract.SuccessExitCode;
    public void RecordCancellation() => ExitCode = StartupContract.CancelledExitCode;
    public void RecordFailure() => ExitCode = StartupContract.FailureExitCode;
}
