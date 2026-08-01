using Xunit;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexOneClickInstaller;

public sealed class StartupContractTests : IDisposable
{
    private readonly string root = Path.Combine(
        OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(),
        "codex-startup-contract",
        Guid.NewGuid().ToString("N"));

    public StartupContractTests()
    {
        CreatePayload(Path.Combine(root, "offline-payloads"));
        CreatePayload(Path.Combine(root, "explicit"));
        Directory.CreateDirectory(Path.Combine(root, "reports"));
    }

    [Fact]
    public void Payload_and_absolute_ci_report_are_parsed_in_either_order()
    {
        var payload = Path.Combine(root, "explicit");
        var report = Path.Combine(root, "reports", "smoke.json");

        var first = StartupContract.Parse(
            ["--payload-root", payload, "--ci-smoke-report", report], root);
        var second = StartupContract.Parse(
            ["--ci-smoke-report", report, "--payload-root", payload], root);

        Assert.Equal(payload, first.PayloadRoot);
        Assert.Equal(report, first.CiSmokeReport);
        Assert.Equal(first, second);
    }

    [Fact]
    public void No_arguments_uses_only_the_app_relative_payload()
    {
        Assert.Equal(
            Path.Combine(root, "offline-payloads"),
            StartupContract.ResolvePayloadRoot([], root));
    }

    [Fact]
    public void One_absolute_payload_override_is_accepted()
    {
        var expected = Path.Combine(root, "explicit");
        Assert.Equal(
            expected,
            StartupContract.ResolvePayloadRoot(["--payload-root", expected], root));
    }

    [Theory]
    [InlineData("--unknown")]
    [InlineData("--payload-root")]
    [InlineData("--payload-root|relative")]
    [InlineData("--payload-root|/tmp|--payload-root|/tmp")]
    [InlineData("--ci-smoke-report|relative")]
    [InlineData("--ci-smoke-report|/tmp/a|--ci-smoke-report|/tmp/b")]
    public void Missing_relative_duplicate_and_unknown_arguments_are_rejected(string encoded)
    {
        var arguments = encoded.Split('|');
        Assert.ThrowsAny<ArgumentException>(
            () => StartupContract.ResolvePayloadRoot(arguments, root));
    }

    [Fact]
    public void Ci_smoke_evidence_validates_payload_and_has_no_bom_or_secrets()
    {
        var payload = Path.Combine(root, "explicit");
        var report = Path.Combine(root, "reports", "smoke.json");
        var options = StartupContract.Parse(
            ["--payload-root", payload, "--ci-smoke-report", report], root);

        StartupContract.WriteCiSmokeEvidence(options);

        var bytes = File.ReadAllBytes(report);
        Assert.False(bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble));
        using var evidence = JsonDocument.Parse(bytes);
        Assert.Equal("pass", evidence.RootElement.GetProperty("status").GetString());
        Assert.Equal(
            "validated",
            evidence.RootElement.GetProperty("payloadManifest").GetString());
        Assert.Equal(
            "validated",
            evidence.RootElement.GetProperty("modelCatalog").GetString());
        Assert.False(evidence.RootElement.GetProperty("containsSecrets").GetBoolean());
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(
                Path.Combine(payload, "payload-manifest.json")))).ToLowerInvariant(),
            evidence.RootElement.GetProperty("payloadManifestSha256").GetString());
    }

    [Fact]
    public void Exit_codes_are_exact_and_later_install_outcome_wins()
    {
        var coordinator = new InstallerExitCodeCoordinator();
        Assert.Equal(2, coordinator.ExitCode);
        coordinator.RecordFailure();
        Assert.Equal(3, coordinator.ExitCode);
        coordinator.RecordSuccess();
        Assert.Equal(0, coordinator.ExitCode);
    }

    [Fact]
    public void Symbolic_link_payload_root_is_rejected_on_non_windows_hosts()
    {
        if (OperatingSystem.IsWindows())
            return;
        var link = Path.Combine(root, "payload-link");
        Directory.CreateSymbolicLink(link, Path.Combine(root, "explicit"));

        Assert.Throws<IOException>(
            () => StartupContract.ResolvePayloadRoot(["--payload-root", link], root));
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
            Directory.Delete(root, recursive: true);
    }

    private static void CreatePayload(string path)
    {
        Directory.CreateDirectory(path);
        File.WriteAllText(
            Path.Combine(path, "payload-manifest.json"),
            """{"schemaVersion":2,"files":[{"id":"fixture"}]}""",
            new UTF8Encoding(false));
        File.WriteAllText(
            Path.Combine(path, "model-catalog.json"),
            """{"schemaVersion":1,"providers":[{"kind":"deepseek"}]}""",
            new UTF8Encoding(false));
    }
}
