using System.Text.Json.Nodes;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class PayloadCatalogTests : IDisposable
{
    private static readonly string Fixtures = Path.GetFullPath(
        Path.Combine(AppContext.BaseDirectory, "../../../../fixtures"));
    private readonly string _temporaryRoot = Path.Combine(
        Fixtures, $".codex-windows-payload-tests-{Guid.NewGuid():N}");

    public PayloadCatalogTests() => Directory.CreateDirectory(_temporaryRoot);

    [Fact]
    public async Task Valid_schema_2_catalog_and_payload_tree_pass()
    {
        var root = CopyValidFixture();

        var catalog = await new PayloadCatalogService().ValidateAsync(root, fixtureMode: true);

        Assert.Equal(2, catalog.SchemaVersion);
        Assert.Equal(6, catalog.Entries.Count);
    }

    [Fact]
    public async Task Checked_in_invalid_manifest_is_rejected()
    {
        var root = CopyValidFixture();
        File.Copy(Path.Combine(Fixtures, "payload-manifest.invalid.json"),
            Path.Combine(root, "payload-manifest.json"), overwrite: true);

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new PayloadCatalogService().ValidateAsync(root, fixtureMode: true));
    }

    [Fact]
    public async Task Schema_other_than_2_is_rejected()
    {
        var root = CopyValidFixture();
        MutateManifest(root, manifest => manifest["schemaVersion"] = 1);

        await AssertInvalidAsync(root, "schemaVersion");
    }

    [Theory]
    [InlineData("codex-windows-x64")]
    [InlineData("codex-plus-plus-windows-x64")]
    [InlineData("codex-plus-plus-source")]
    [InlineData("model-catalog")]
    [InlineData("plugin-marketplaces")]
    [InlineData("script-market")]
    public async Task Missing_required_component_is_rejected(string id)
    {
        var root = CopyValidFixture();
        MutateManifest(root, manifest =>
        {
            var files = manifest["files"]!.AsArray();
            files.Remove(files.Single(item => (string?)item!["id"] == id));
        });

        await AssertInvalidAsync(root, id);
    }

    [Theory]
    [InlineData("ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789")]
    [InlineData("abcdef")]
    [InlineData("gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg")]
    public async Task Sha256_must_be_64_lowercase_hex_characters(string sha256)
    {
        var root = CopyValidFixture();
        MutateEntry(root, "model-catalog", entry => entry["sha256"] = sha256);

        await AssertInvalidAsync(root, "sha256");
    }

    [Theory]
    [InlineData("/tmp/Codex.msix")]
    [InlineData("C:\\payloads\\Codex.msix")]
    [InlineData("\\\\server\\share\\Codex.msix")]
    [InlineData("../Codex.msix")]
    [InlineData("apps/../Codex.msix")]
    [InlineData("apps/./Codex.msix")]
    public async Task Unsafe_relative_path_is_rejected(string relativePath)
    {
        var root = CopyValidFixture();
        MutateEntry(root, "codex-windows-x64", entry => entry["relativePath"] = relativePath);

        await AssertInvalidAsync(root, "relativePath");
    }

    [Fact]
    public async Task Windows_backslashes_are_normalized_for_lookup()
    {
        var root = CopyValidFixture();
        MutateEntry(root, "codex-windows-x64",
            entry => entry["relativePath"] = "apps\\Codex.msix");

        var catalog = await new PayloadCatalogService().ValidateAsync(root, fixtureMode: true);

        Assert.Equal("apps/Codex.msix",
            catalog.Entries.Single(entry => entry.Id == "codex-windows-x64").RelativePath);
    }

    [Fact]
    public async Task Paths_that_collide_under_Windows_case_rules_are_rejected()
    {
        var root = CopyValidFixture();
        MutateEntry(root, "model-catalog", entry => entry["relativePath"] = "APPS/CODEX.MSIX");

        await AssertInvalidAsync(root, "Windows");
    }

    [Fact]
    public async Task Fixture_payload_requires_explicit_fixture_mode()
    {
        var root = CopyValidFixture();

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new PayloadCatalogService().ValidateAsync(root));
    }

    [Theory]
    [InlineData("codex-windows-x64", "apps/not-codex.msix", "msix")]
    [InlineData("codex-windows-x64", "apps/Codex.msix", "exe")]
    [InlineData("codex-plus-plus-windows-x64", "apps/setup.exe", "exe")]
    [InlineData("codex-plus-plus-windows-x64", "apps/CodexPlusPlus-setup.exe", "archive")]
    [InlineData("codex-plus-plus-source", "sources/source.tar.gz", "archive")]
    [InlineData("codex-plus-plus-source", "sources/CodexPlusPlus-v1.2.43.tar.gz", "exe")]
    [InlineData("model-catalog", "metadata/models.json", "json")]
    [InlineData("model-catalog", "model-catalog.json", "file")]
    [InlineData("plugin-marketplaces", "metadata/plugins", "directory")]
    [InlineData("plugin-marketplaces", "plugins", "json")]
    [InlineData("script-market", "scripts", "directory")]
    [InlineData("script-market", "script-market", "json")]
    public async Task Required_component_path_and_format_are_canonical(
        string id, string relativePath, string format)
    {
        var root = CopyValidFixture();
        MutateEntry(root, id, entry =>
        {
            entry["relativePath"] = relativePath;
            entry["format"] = format;
        });

        await AssertInvalidAsync(root, "canonical");
    }

    [Theory]
    [InlineData("http://example.invalid/payload")]
    [InlineData("../payload")]
    [InlineData("payload")]
    public async Task Source_url_must_be_absolute_https(string sourceUrl)
    {
        var root = CopyValidFixture();
        MutateEntry(root, "model-catalog", entry => entry["sourceURL"] = sourceUrl);

        await AssertInvalidAsync(root, "HTTPS");
    }

    [Fact]
    public async Task Symbolic_link_or_reparse_point_payload_is_rejected()
    {
        var root = CopyValidFixture();
        var codex = Path.Combine(root, "apps", "Codex.msix");
        var target = Path.Combine(root, "apps", "Codex.real.msix");
        File.Move(codex, target);
        File.CreateSymbolicLink(codex, target);

        await AssertInvalidAsync(root, "reparse");
    }

    [Fact]
    public async Task Symbolic_link_or_reparse_point_parent_directory_is_rejected()
    {
        var root = CopyValidFixture();
        var apps = Path.Combine(root, "apps");
        var realApps = Path.Combine(root, "real-apps");
        Directory.Move(apps, realApps);
        Directory.CreateSymbolicLink(apps, realApps);

        await AssertInvalidAsync(root, "reparse");
    }

    [Fact]
    public async Task Symbolic_link_or_junction_above_payload_root_is_rejected()
    {
        var realParent = Path.Combine(_temporaryRoot, "real-parent");
        Directory.CreateDirectory(realParent);
        var root = Path.Combine(realParent, "payload");
        CopyDirectory(Path.Combine(Fixtures, "payload-root"), root);
        var aliasParent = Path.Combine(_temporaryRoot, "alias-parent");
        Directory.CreateSymbolicLink(aliasParent, realParent);
        var aliasRoot = Path.Combine(aliasParent, "payload");

        await AssertInvalidAsync(aliasRoot, "reparse");
    }

    [Theory]
    [InlineData("arm64", "OpenAI.Codex_2p2nqsd0c76g0")]
    [InlineData("x64", "OpenAI.NotCodex_2p2nqsd0c76g0")]
    public async Task Codex_identity_must_be_x64_and_expected_package_family(
        string architecture, string packageFamilyName)
    {
        var root = CopyValidFixture();
        MutateEntry(root, "codex-windows-x64", entry =>
        {
            entry["architecture"] = architecture;
            entry["packageFamilyName"] = packageFamilyName;
        });

        await AssertInvalidAsync(root, "Codex");
    }

    [Fact]
    public async Task Codex_publisher_must_be_recorded_from_official_package()
    {
        var root = CopyValidFixture();
        MutateEntry(root, "codex-windows-x64", entry => entry["publisher"] = "");

        await AssertInvalidAsync(root, "publisher");
    }

    [Fact]
    public async Task CodexPlusPlus_requires_cross_provider_compatibility_revision()
    {
        var root = CopyValidFixture();
        MutateEntry(root, "codex-plus-plus-windows-x64",
            entry => entry["compatibilityRevision"] = "other");

        await AssertInvalidAsync(root, "compatibilityRevision");
    }

    [Fact]
    public async Task Plugin_catalog_must_contain_exactly_three_markets_and_nine_plugins()
    {
        var root = CopyValidFixture();
        var catalogPath = Path.Combine(root, "plugins", "plugin-catalog.json");
        var catalog = JsonNode.Parse(File.ReadAllText(catalogPath))!.AsObject();
        catalog["plugins"]!.AsArray().RemoveAt(0);
        File.WriteAllText(catalogPath, catalog.ToJsonString());

        await AssertInvalidAsync(root, "plugin");
    }

    [Fact]
    public async Task Primary_runtime_plugin_cannot_be_relabelled_as_redistributable()
    {
        var root = CopyValidFixture();
        var catalogPath = Path.Combine(root, "plugins", "plugin-catalog.json");
        var catalog = JsonNode.Parse(File.ReadAllText(catalogPath))!.AsObject();
        var plugin = catalog["plugins"]!.AsArray()
            .Single(item => (string?)item!["id"] == "documents")!.AsObject();
        plugin["delivery"] = "offline";
        File.WriteAllText(catalogPath, catalog.ToJsonString());

        await AssertInvalidAsync(root, "delivery");
    }

    [Fact]
    public async Task Plugin_directory_identity_must_match_catalog()
    {
        var root = CopyValidFixture();
        var identityPath = Path.Combine(root, "plugins", "marketplaces",
            "openai-bundled", "plugins", "browser", ".codex-plugin", "plugin.json");
        File.WriteAllText(identityPath, """{"name":"not-browser","version":"1.0.0"}""");

        await AssertInvalidAsync(root, "plugin identity");
    }

    [Theory]
    [InlineData("requiredComponents")]
    [InlineData("codex")]
    [InlineData("codexPlusPlus")]
    [InlineData("plugins")]
    [InlineData("monitoringScripts")]
    [InlineData("scriptMarket")]
    public async Task Executable_payload_lock_rules_are_enforced(string property)
    {
        var root = CopyValidFixture();
        var lockPath = Path.Combine(root, "payload-lock.json");
        var payloadLock = JsonNode.Parse(File.ReadAllText(lockPath))!.AsObject();
        payloadLock.Remove(property);
        File.WriteAllText(lockPath, payloadLock.ToJsonString());

        await AssertInvalidAsync(root, "payload lock");
    }

    [Fact]
    public async Task Joint_manifest_and_lock_decoy_path_is_rejected_by_compiled_policy()
    {
        var root = CopyValidFixture();
        MutateEntry(root, "model-catalog", entry =>
            entry["relativePath"] = "metadata/decoy-models.json");
        Directory.CreateDirectory(Path.Combine(root, "metadata"));
        File.Copy(Path.Combine(root, "model-catalog.json"),
            Path.Combine(root, "metadata", "decoy-models.json"));
        MutateLock(root, payloadLock =>
            payloadLock["components"]!["model-catalog"]!["relativePath"] =
                "metadata/decoy-models.json");

        await AssertInvalidAsync(root, "compiled policy");
    }

    [Fact]
    public async Task Joint_manifest_and_lock_revision_mutation_is_rejected_by_compiled_policy()
    {
        var root = CopyValidFixture();
        foreach (var id in new[]
                 {
                     "codex-plus-plus-windows-x64",
                     "codex-plus-plus-source"
                 })
            MutateEntry(root, id, entry => entry["compatibilityRevision"] = "decoy");
        MutateLock(root, payloadLock =>
            payloadLock["codexPlusPlus"]!["compatibilityRevision"] = "decoy");

        await AssertInvalidAsync(root, "compiled policy");
    }

    [Fact]
    public async Task Joint_lock_and_catalog_plugin_identity_mutation_is_rejected()
    {
        var root = CopyValidFixture();
        MutateLock(root, payloadLock =>
            payloadLock["plugins"]![0]!["id"] = "decoy-browser");
        var catalogPath = Path.Combine(root, "plugins", "plugin-catalog.json");
        var catalog = JsonNode.Parse(File.ReadAllText(catalogPath))!.AsObject();
        catalog["plugins"]![0]!["id"] = "decoy-browser";
        File.WriteAllText(catalogPath, catalog.ToJsonString());

        await AssertInvalidAsync(root, "compiled policy");
    }

    [Fact]
    public async Task Injected_volume_root_reparse_point_is_rejected()
    {
        var root = CopyValidFixture();
        var volumeRoot = Path.GetPathRoot(Path.GetFullPath(root))!;
        var service = new PayloadCatalogService(path =>
            string.Equals(path, volumeRoot, StringComparison.Ordinal)
                ? FileAttributes.Directory | FileAttributes.ReparsePoint
                : File.GetAttributes(path));

        var exception = await Assert.ThrowsAsync<InvalidDataException>(
            () => service.ValidateAsync(root, fixtureMode: true));

        Assert.Contains("reparse", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("codex-context-used-meter", "wrong", null)]
    [InlineData("codex-token-usage", "wrong", null)]
    [InlineData("codex-daily-token-usage", "wrong", null)]
    [InlineData("codex-live-token-cost", "wrong", null)]
    [InlineData("codex-context-used-meter", null, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("codex-token-usage", null, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("codex-daily-token-usage", null, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("codex-live-token-cost", null, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    public async Task Monitoring_script_version_or_hash_mismatch_is_rejected(
        string id, string? version, string? sha256)
    {
        var root = CopyValidFixture();
        var indexPath = Path.Combine(root, "script-market", "index.json");
        var index = JsonNode.Parse(File.ReadAllText(indexPath))!.AsObject();
        var script = index["scripts"]!.AsArray()
            .Single(item => (string?)item!["id"] == id)!.AsObject();
        if (version is not null) script["version"] = version;
        if (sha256 is not null) script["sha256"] = sha256;
        File.WriteAllText(indexPath, index.ToJsonString());

        await AssertInvalidAsync(root, id);
    }

    [Fact]
    public async Task Directory_hash_uses_UTF8_sorted_path_nul_sha256_nul_size_newline_records()
    {
        var plugins = Path.Combine(Fixtures, "payload-root", "plugins");

        var result = await PayloadCatalogService.CalculateDirectoryHashAsync(plugins);

        Assert.Equal("50df9475ad644647734e8c2d27cea9c2a06de6a1ee005388211c727a42f2fc26",
            result.Sha256);
        Assert.Equal(1298, result.Size);
    }

    [Fact]
    public async Task Directory_hash_sorts_by_UTF8_bytes_instead_of_UTF16_code_units()
    {
        var directory = Path.Combine(_temporaryRoot, "utf8-order");
        Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(Path.Combine(directory, "\uE000.txt"), "A");
        await File.WriteAllTextAsync(Path.Combine(directory, "\U00010000.txt"), "B");

        var result = await PayloadCatalogService.CalculateDirectoryHashAsync(directory);

        Assert.Equal("7f3f3792e08ca62acbd7d807cbd19434b638117d6ff0a83bba50888933dabea5",
            result.Sha256);
        Assert.Equal(2, result.Size);
    }

    [Fact]
    public async Task Declared_size_must_match_streamed_payload_size()
    {
        var root = CopyValidFixture();
        MutateEntry(root, "codex-windows-x64", entry => entry["size"] = 15);

        await AssertInvalidAsync(root, "size");
    }

    private string CopyValidFixture()
    {
        var root = Path.Combine(_temporaryRoot, Guid.NewGuid().ToString("N"));
        CopyDirectory(Path.Combine(Fixtures, "payload-root"), root);
        File.Copy(Path.Combine(Fixtures, "payload-manifest.valid.json"),
            Path.Combine(root, "payload-manifest.json"), overwrite: true);
        return root;
    }

    private static void MutateEntry(string root, string id, Action<JsonObject> mutate) =>
        MutateManifest(root, manifest =>
        {
            var entry = manifest["files"]!.AsArray()
                .Single(item => (string?)item!["id"] == id)!.AsObject();
            mutate(entry);
        });

    private static void MutateManifest(string root, Action<JsonObject> mutate)
    {
        var path = Path.Combine(root, "payload-manifest.json");
        var manifest = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        mutate(manifest);
        File.WriteAllText(path, manifest.ToJsonString());
    }

    private static void MutateLock(string root, Action<JsonObject> mutate)
    {
        var path = Path.Combine(root, "payload-lock.json");
        var payloadLock = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        mutate(payloadLock);
        File.WriteAllText(path, payloadLock.ToJsonString());
    }

    private static async Task AssertInvalidAsync(string root, string expectedFragment)
    {
        var exception = await Assert.ThrowsAsync<InvalidDataException>(
            () => new PayloadCatalogService().ValidateAsync(root, fixtureMode: true));
        Assert.Contains(expectedFragment, exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var directory in Directory.EnumerateDirectories(source, "*",
                     SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(destination,
                Path.GetRelativePath(source, directory)));
        }
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target);
        }
    }

    public void Dispose() => Directory.Delete(_temporaryRoot, recursive: true);
}
