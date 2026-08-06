using System.Runtime.InteropServices;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class PreflightTests
{
    private const string InstallPath = @"C:\Users\fixture\AppData\Local\Codex";
    private static readonly string WindowsRoot = Path.GetFullPath(
        Path.Combine(AppContext.BaseDirectory, "../../../../.."));

    [Theory]
    [InlineData(17762, false, PreflightFailureCodes.UnsupportedWindowsBuild)]
    [InlineData(17763, true, null)]
    public void Windows_build_17763_is_the_minimum(
        int build,
        bool expectedSupported,
        string? expectedFailureCode)
    {
        var environment = SupportedEnvironment();
        environment.OSVersionValue = new Version(10, 0, build);

        var result = new PreflightService(environment)
            .Evaluate(InstallPath, payloadExtractionPeakBytes: 1);

        Assert.Equal(expectedSupported, result.IsSupported);
        Assert.Equal(expectedFailureCode, result.FailureCode);
    }

    [Theory]
    [InlineData(Architecture.X64, true, null)]
    [InlineData(Architecture.X86, false, PreflightFailureCodes.UnsupportedArchitecture)]
    [InlineData(Architecture.Arm64, false, PreflightFailureCodes.UnsupportedArchitecture)]
    public void Only_x64_operating_systems_are_supported(
        Architecture architecture,
        bool expectedSupported,
        string? expectedFailureCode)
    {
        var environment = SupportedEnvironment();
        environment.OSArchitectureValue = architecture;

        var result = new PreflightService(environment)
            .Evaluate(InstallPath, payloadExtractionPeakBytes: 1);

        Assert.Equal(expectedSupported, result.IsSupported);
        Assert.Equal(expectedFailureCode, result.FailureCode);
    }

    [Fact]
    public void Disk_requires_payload_extraction_peak_plus_two_gibibytes()
    {
        const long peakBytes = 750_000_000;
        var requiredBytes = peakBytes + PreflightService.DiskSafetyMarginBytes;
        var insufficient = SupportedEnvironment();
        insufficient.AvailableBytes = requiredBytes - 1;
        var exact = SupportedEnvironment();
        exact.AvailableBytes = requiredBytes;

        var rejected = new PreflightService(insufficient).Evaluate(InstallPath, peakBytes);
        var accepted = new PreflightService(exact).Evaluate(InstallPath, peakBytes);

        Assert.False(rejected.IsSupported);
        Assert.Equal(PreflightFailureCodes.InsufficientDiskSpace, rejected.FailureCode);
        Assert.True(accepted.IsSupported);
        Assert.Null(accepted.FailureCode);
        Assert.Equal(InstallPath, insufficient.LastDiskPath);
    }

    [Fact]
    public void Running_codex_components_block_apply_and_are_listed()
    {
        var environment = SupportedEnvironment();
        environment.RunningComponents =
        [
            new RunningComponent("Codex", 101),
            new RunningComponent("Codex++", 202)
        ];

        var result = new PreflightService(environment)
            .Evaluate(InstallPath, payloadExtractionPeakBytes: 1);

        Assert.False(result.IsSupported);
        Assert.Equal(PreflightFailureCodes.ComponentsRunning, result.FailureCode);
        Assert.Equal(["Codex", "Codex++"],
            result.RunningComponents.Select(component => component.Name));
    }

    [Theory]
    [InlineData("ChatGPT", "Codex")]
    [InlineData("chatgpt", "Codex")]
    [InlineData("codex", "Codex")]
    [InlineData("codex-plus-plus", "Codex++")]
    [InlineData("codex-plus-plus-manager", "Codex++")]
    public void Production_process_names_map_to_blocking_components(
        string processName,
        string expectedComponent)
    {
        Assert.True(WindowsEnvironment.TryGetBlockingComponentName(
            processName,
            out var component));
        Assert.Equal(expectedComponent, component);
    }

    [Fact]
    public void Production_package_query_uses_typed_winrt_projection()
    {
        var source = File.ReadAllText(Path.Combine(
            WindowsRoot,
            "src",
            "InstallerCore",
            "Services",
            "PreflightService.cs"));
        var project = File.ReadAllText(Path.Combine(
            WindowsRoot,
            "src",
            "InstallerCore",
            "CodexOneClick.Core.csproj"));

        Assert.DoesNotContain("ContentType=WindowsRuntime", source, StringComparison.Ordinal);
        Assert.DoesNotContain("Type.GetType(", source, StringComparison.Ordinal);
        Assert.Contains("new PackageManager()", source, StringComparison.Ordinal);
        Assert.Contains(
            "net8.0-windows10.0.17763.0",
            project,
            StringComparison.Ordinal);
    }

    [Fact]
    public void Installed_component_queries_are_injected_and_preserved_in_the_snapshot()
    {
        var environment = SupportedEnvironment();
        environment.Packages[PreflightService.CodexPackageFamilyName] =
        [
            new InstalledPackage(
                PreflightService.CodexPackageFamilyName,
                "26.7.27.0",
                true,
                @"C:\Program Files\WindowsApps\OpenAI.Codex\codex.exe")
        ];
        environment.Packages[PreflightService.CodexPlusPlusComponentIdentity] =
        [
            new InstalledPackage(
                PreflightService.CodexPlusPlusComponentIdentity,
                "1.2.44+codexkit.1",
                true,
                @"C:\Users\fixture\AppData\Local\Programs\Codex++\Codex++.exe")
        ];

        var result = new PreflightService(environment)
            .Evaluate(InstallPath, payloadExtractionPeakBytes: 1);

        Assert.True(result.IsSupported);
        Assert.Equal(2, result.InstalledPackages.Count);
        Assert.Equal(
            [
                PreflightService.CodexPackageFamilyName,
                PreflightService.CodexPlusPlusComponentIdentity
            ],
            environment.PackageQueries);
    }

    private static FakeWindowsEnvironment SupportedEnvironment() =>
        new()
        {
            OSVersionValue = new Version(10, 0, 17763),
            OSArchitectureValue = Architecture.X64,
            AvailableBytes = long.MaxValue
        };

    private sealed class FakeWindowsEnvironment : IWindowsEnvironment
    {
        public Version OSVersionValue { get; set; } = new(10, 0, 17763);

        public Architecture OSArchitectureValue { get; set; } = Architecture.X64;

        public long AvailableBytes { get; set; } = long.MaxValue;

        public string? LastDiskPath { get; private set; }

        public Dictionary<string, IReadOnlyList<InstalledPackage>> Packages { get; } =
            new(StringComparer.Ordinal);

        public List<string> PackageQueries { get; } = [];

        public IReadOnlyList<RunningComponent> RunningComponents { get; set; } = [];

        public Version OSVersion => OSVersionValue;

        public Architecture OSArchitecture => OSArchitectureValue;

        public long GetAvailableBytes(string path)
        {
            LastDiskPath = path;
            return AvailableBytes;
        }

        public IReadOnlyList<InstalledPackage> FindPackages(string packageFamilyName)
        {
            PackageQueries.Add(packageFamilyName);
            return Packages.TryGetValue(packageFamilyName, out var packages)
                ? packages
                : [];
        }

        public IReadOnlyList<RunningComponent> FindRunningComponents() =>
            RunningComponents;
    }
}
