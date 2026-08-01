import Foundation

func configurationRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(
            domain: "ConfigurationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

func configurationRequireThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw NSError(
            domain: "ConfigurationTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    } catch let error as NSError where error.domain == "ConfigurationTests" && error.code == 2 {
        throw error
    } catch {
        return
    }
}

func writeText(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
}

func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func jsonObject(at url: URL) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let object = value as? [String: Any] else {
        throw NSError(domain: "ConfigurationTests", code: 3)
    }
    return object
}

@main
struct ConfigurationTests {
    static func main() throws {
        let legacyRequest = try JSONDecoder().decode(
            InstallRequest.self,
            from: Data(#"{"provider":"deepseek","apiKey":"sk-test-key-12345","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-pro"]}"#.utf8)
        )
        try configurationRequire(legacyRequest.modelSource == .offlineSnapshot, "legacy request defaults to offline snapshot")

        let originalTOML = """
        # user's leading comment
        model = "user-model"
        custom_setting = "keep-me" # preserve inline comment

        [plugins."user-plugin@private"]
        enabled = true
        """

        var document = try TomlDocument.parse(originalTOML)
        document.set(table: [], key: "model", value: .string("deepseek-v4-flash"))
        document.set(table: [], key: "model_provider", value: .string("codex-one-click-deepseek"))
        document.set(
            table: ["model_providers", "codex-one-click-deepseek"],
            key: "base_url",
            value: .string("http://127.0.0.1:57321/v1")
        )
        document.set(
            table: ["model_providers", "codex-one-click-deepseek"],
            key: "requires_openai_auth",
            value: .boolean(true)
        )
        let rendered = document.render()
        try configurationRequire(rendered.contains("custom_setting = \"keep-me\" # preserve inline comment"), "unknown root key preserved")
        try configurationRequire(rendered.contains("[plugins.\"user-plugin@private\"]"), "unknown table preserved")
        try configurationRequire(rendered.contains("model = \"deepseek-v4-flash\""), "root key updated")
        try configurationRequire(rendered.contains("[model_providers.\"codex-one-click-deepseek\"]"), "quoted managed table")
        let reparsed = try TomlDocument.parse(rendered)
        try configurationRequire(reparsed.render() == rendered, "TOML round trip stable")

        document.remove(table: [], key: "model_provider")
        try configurationRequire(!document.render().contains("model_provider ="), "root key removed")
        var escaping = try TomlDocument.parse("")
        escaping.set(table: [], key: "quoted", value: .string("a \\\"quote\\\" and \\\\ slash"))
        try configurationRequire(escaping.render().contains(#"quoted = "a \\\"quote\\\" and \\\\ slash""#), "TOML string escaping")

        try configurationRequireThrows("duplicate tables rejected") {
            _ = try TomlDocument.parse("[managed]\na = 1\n[managed]\nb = 2\n")
        }

        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codex-configuration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        for (provider, model, expectedID, expectedBase) in [
            (
                ProviderKind.zhipu,
                "glm-5.2",
                "codex-one-click-zhipu",
                "https://open.bigmodel.cn/api/paas/v4"
            ),
            (
                ProviderKind.qwen,
                "qwen3.7-max",
                "codex-one-click-qwen",
                "https://dashscope.aliyuncs.com/compatible-mode/v1"
            ),
            (
                ProviderKind.xiaomiMiMo,
                "mimo-v2.5-pro",
                "codex-one-click-xiaomi-mimo",
                "https://api.xiaomimimo.com/v1"
            )
        ] {
            let providerHome = temporaryDirectory.appendingPathComponent(provider.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: providerHome, withIntermediateDirectories: true)
            let providerPaths = InstallerPaths(home: providerHome)
            let providerRequest = InstallRequest(
                provider: provider,
                apiKey: "sk-provider-contract-test",
                defaultModel: model,
                availableModels: [model]
            )
            let result = try InstallerConfiguration.apply(
                request: providerRequest,
                paths: providerPaths,
                catalog: [ModelDefinition(id: model, displayName: model, contextWindow: 1_000_000)]
            )
            let settings = try jsonObject(at: providerPaths.codexPlusSettings)
            let profile = (settings["relayProfiles"] as? [[String: Any]])?.first
            try configurationRequire(result.managedProviderID == expectedID, "\(provider.rawValue) provider ID")
            try configurationRequire(profile?["upstreamBaseUrl"] as? String == expectedBase, "\(provider.rawValue) upstream")
        }

        let paths = InstallerPaths(home: temporaryDirectory)
        let originalAuth = """
        {"auth_mode":"chatgpt","tokens":{"access_token":"official-session"},"userFlag":true}
        """
        let originalSettings = """
        {
          "userFlag": "keep-settings",
          "relayProfiles": [
            {
              "id": "user-provider",
              "name": "User Provider",
              "relayMode": "official",
              "authContents": ""
            }
          ],
          "activeRelayId": "user-provider"
        }
        """
        try writeText(originalTOML, to: paths.codexConfig)
        try writeText(originalAuth, to: paths.codexAuth)
        try writeText(originalSettings, to: paths.codexPlusSettings)

        let request = InstallRequest(
            provider: .deepSeek,
            apiKey: "sk-test-key-12345",
            defaultModel: "deepseek-v4-pro",
            availableModels: ["deepseek-v4-flash", "deepseek-v4-pro"]
        )
        let catalog = [
            ModelDefinition(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", contextWindow: 1_000_000),
            ModelDefinition(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", contextWindow: 1_000_000)
        ]

        let first = try InstallerConfiguration.apply(request: request, paths: paths, catalog: catalog)
        let firstConfig = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        let firstAuth = try jsonObject(at: paths.codexAuth)
        let firstSettings = try jsonObject(at: paths.codexPlusSettings)
        let expectationData = try Data(contentsOf: paths.installExpectation)
        let expectationText = String(decoding: expectationData, as: UTF8.self)
        let expectation = try InstallExpectation.load(from: paths.installExpectation)
        let expectationMode = try fileMode(paths.installExpectation)

        try configurationRequire(first.managedProviderID == "codex-one-click-deepseek", "stable managed provider ID")
        try configurationRequire(expectationMode == 0o600, "expectation mode 0600")
        try configurationRequire(!expectationText.contains(request.apiKey), "expectation excludes API key")
        try configurationRequire(expectation.apiKeySHA256.count == 64, "expectation stores SHA-256")
        try configurationRequire(expectation.defaultModel == request.defaultModel, "expectation stores default model")
        try configurationRequire(
            expectation.availableModels == request.availableModels,
            "expectation stores available models"
        )
        try configurationRequire(firstConfig.contains("custom_setting = \"keep-me\" # preserve inline comment"), "apply preserves user TOML")
        try configurationRequire(firstConfig.contains("model = \"deepseek-v4-pro\""), "default model applied")
        try configurationRequire(firstConfig.contains("base_url = \"http://127.0.0.1:57321/v1\""), "Codex++ Responses proxy applied")
        try configurationRequire(!firstConfig.contains(request.apiKey), "Key absent from config TOML")
        try configurationRequire(firstAuth["OPENAI_API_KEY"] as? String == request.apiKey, "auth API key applied")
        try configurationRequire((firstAuth["tokens"] as? [String: Any])?["access_token"] as? String == "official-session", "official session preserved")

        try configurationRequire(firstSettings["userFlag"] as? String == "keep-settings", "unknown settings key preserved")
        try configurationRequire(firstSettings["activeRelayId"] as? String == first.managedProviderID, "managed profile active")
        try configurationRequire(firstSettings["relayProfilesEnabled"] as? Bool == true, "relay profiles enabled")
        try configurationRequire(firstSettings["enhancementsEnabled"] as? Bool == true, "enhancements enabled")
        try configurationRequire(firstSettings["codexAppPluginMarketplaceUnlock"] as? Bool == true, "plugin market unlocked")
        try configurationRequire(firstSettings["codexAppPluginAutoExpand"] as? Bool == true, "plugin auto expand enabled")
        try configurationRequire(firstSettings["codexAppModelWhitelistUnlock"] as? Bool == true, "model whitelist unlocked")
        try configurationRequire(firstSettings["codexAppForceChineseLocale"] as? Bool == true, "Chinese locale enabled")
        try configurationRequire(firstSettings["codexAppNativeMenuLocalization"] as? Bool == true, "native menu localization enabled")
        try configurationRequire(firstSettings["codexAppPath"] as? String == "/Applications/ChatGPT.app", "official app path")

        guard let profiles = firstSettings["relayProfiles"] as? [[String: Any]] else {
            throw NSError(domain: "ConfigurationTests", code: 4)
        }
        try configurationRequire(profiles.count == 2, "user and managed profiles retained")
        try configurationRequire(profiles.contains { $0["id"] as? String == "user-provider" }, "user profile preserved")
        guard let managed = profiles.first(where: { $0["id"] as? String == first.managedProviderID }) else {
            throw NSError(domain: "ConfigurationTests", code: 5)
        }
        try configurationRequire(managed["relayMode"] as? String == "pureApi", "pure API mode")
        try configurationRequire(managed["protocol"] as? String == "chatCompletions", "Chat Completions upstream protocol")
        try configurationRequire(managed["upstreamBaseUrl"] as? String == "https://api.deepseek.com", "DeepSeek upstream URL")
        try configurationRequire(managed["testModel"] as? String == request.defaultModel, "default test model")
        try configurationRequire(managed["modelList"] as? String == request.availableModels.joined(separator: "\n"), "all models stored")
        try configurationRequire((managed["authContents"] as? String)?.contains(request.apiKey) == true, "profile auth contains Key")
        try configurationRequire((managed["configContents"] as? String)?.contains(request.apiKey) == false, "profile config excludes Key")

        let providerDefinition = ProviderDefinition(
            kind: .deepSeek,
            protocolName: "chatCompletions",
            models: catalog
        )
        let verification = try InstallerConfiguration.verify(
            expectation: expectation,
            paths: paths,
            catalog: providerDefinition
        )
        try configurationRequire(verification.provider == .deepSeek, "verification provider")
        try configurationRequire(verification.defaultModel == request.defaultModel, "verification default model")
        try configurationRequire(verification.modelCount == request.availableModels.count, "verification model count")

        let validConfig = try Data(contentsOf: paths.codexConfig)
        let validAuth = try Data(contentsOf: paths.codexAuth)
        let validSettings = try Data(contentsOf: paths.codexPlusSettings)
        try writeText("model = \"wrong-model\"\n", to: paths.codexConfig)
        try configurationRequireThrows("wrong model is rejected") {
            _ = try InstallerConfiguration.verify(
                expectation: expectation,
                paths: paths,
                catalog: providerDefinition
            )
        }
        try validConfig.write(to: paths.codexConfig)

        try writeText("{\"OPENAI_API_KEY\":\"sk-wrong-key-12345\"}\n", to: paths.codexAuth)
        try configurationRequireThrows("wrong API key is rejected") {
            _ = try InstallerConfiguration.verify(
                expectation: expectation,
                paths: paths,
                catalog: providerDefinition
            )
        }
        try validAuth.write(to: paths.codexAuth)

        var corruptedSettings = try jsonObject(at: paths.codexPlusSettings)
        corruptedSettings["activeRelayId"] = "wrong-relay"
        try JSONSerialization.data(withJSONObject: corruptedSettings).write(to: paths.codexPlusSettings)
        try configurationRequireThrows("wrong relay is rejected") {
            _ = try InstallerConfiguration.verify(
                expectation: expectation,
                paths: paths,
                catalog: providerDefinition
            )
        }
        try validSettings.write(to: paths.codexPlusSettings)

        corruptedSettings = try jsonObject(at: paths.codexPlusSettings)
        corruptedSettings["codexAppNativeMenuLocalization"] = false
        try JSONSerialization.data(withJSONObject: corruptedSettings).write(to: paths.codexPlusSettings)
        try configurationRequireThrows("disabled enhancement is rejected") {
            _ = try InstallerConfiguration.verify(
                expectation: expectation,
                paths: paths,
                catalog: providerDefinition
            )
        }
        try validSettings.write(to: paths.codexPlusSettings)

        try configurationRequireThrows("every selected model must be resolved") {
            _ = try InstallerConfiguration.apply(
                request: InstallRequest(
                    provider: .deepSeek,
                    apiKey: "sk-test-key-12345",
                    defaultModel: "deepseek-v4-pro",
                    availableModels: ["deepseek-v4-pro", "unresolved-model"]
                ),
                paths: paths,
                catalog: catalog
            )
        }

        let authMode = try fileMode(paths.codexAuth)
        let settingsMode = try fileMode(paths.codexPlusSettings)
        try configurationRequire(authMode == 0o600, "auth mode 0600")
        try configurationRequire(settingsMode == 0o600, "settings mode 0600")
        let firstBackupURL = URL(fileURLWithPath: first.backupDirectory, isDirectory: true)
        let backupMode = try fileMode(firstBackupURL)
        try configurationRequire(backupMode == 0o700, "backup directory mode 0700")
        try configurationRequire(FileManager.default.fileExists(atPath: firstBackupURL.appendingPathComponent("inventory.json").path), "backup inventory exists")

        let second = try InstallerConfiguration.apply(request: request, paths: paths, catalog: catalog)
        let secondConfig = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        let secondSettings = try jsonObject(at: paths.codexPlusSettings)
        let secondProfiles = secondSettings["relayProfiles"] as? [[String: Any]] ?? []
        try configurationRequire(second.managedProviderID == first.managedProviderID, "provider ID idempotent")
        try configurationRequire(secondConfig == firstConfig, "TOML idempotent")
        try configurationRequire(secondProfiles.filter { $0["id"] as? String == first.managedProviderID }.count == 1, "managed profile not duplicated")

        let marketplaces = [
            MarketplaceRegistration(
                id: "openai-bundled",
                source: paths.home.appendingPathComponent(".codex/offline-marketplaces/openai-bundled", isDirectory: true)
            ),
            MarketplaceRegistration(
                id: "openai-primary-runtime",
                source: paths.home.appendingPathComponent(".codex/offline-marketplaces/openai-primary-runtime", isDirectory: true)
            ),
            MarketplaceRegistration(
                id: "openai-curated",
                source: paths.home.appendingPathComponent(".codex/offline-marketplaces/openai-curated", isDirectory: true)
            )
        ]
        let managedPlugins = [
            ManagedPluginRegistration(marketplace: "openai-bundled", id: "browser"),
            ManagedPluginRegistration(marketplace: "openai-primary-runtime", id: "pdf"),
            ManagedPluginRegistration(marketplace: "openai-curated", id: "github")
        ]
        try InstallerConfiguration.registerMarketplaces(marketplaces, configURL: paths.codexConfig)
        try InstallerConfiguration.enableManagedPlugins(managedPlugins, configURL: paths.codexConfig)
        let pluginConfig = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        try configurationRequire(pluginConfig.contains("[marketplaces.\"openai-bundled\"]"), "bundled marketplace registered")
        try configurationRequire(pluginConfig.contains("source_type = \"local\""), "marketplace local source type")
        try configurationRequire(pluginConfig.contains(marketplaces[0].source.path), "absolute marketplace source")
        try configurationRequire(pluginConfig.contains("[plugins.\"browser@openai-bundled\"]"), "managed browser enabled")
        try configurationRequire(pluginConfig.contains("[plugins.\"pdf@openai-primary-runtime\"]"), "managed PDF enabled")
        try configurationRequire(pluginConfig.contains("[plugins.\"github@openai-curated\"]"), "managed GitHub enabled")
        try configurationRequire(pluginConfig.contains("[plugins.\"user-plugin@private\"]"), "private plugin preserved")
        let reparsedPluginConfig = try TomlDocument.parse(pluginConfig)
        try configurationRequire(reparsedPluginConfig.render() == pluginConfig, "plugin TOML round trip stable")

        try writeText("broken = true\n", to: paths.codexConfig)
        try InstallerConfiguration.restore(from: firstBackupURL, paths: paths)
        let restoredConfig = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        let restoredAuth = try String(contentsOf: paths.codexAuth, encoding: .utf8)
        let restoredSettings = try String(contentsOf: paths.codexPlusSettings, encoding: .utf8)
        try configurationRequire(restoredConfig == originalTOML, "restore original TOML")
        try configurationRequire(restoredAuth == originalAuth, "restore original auth")
        try configurationRequire(restoredSettings == originalSettings, "restore original settings")
        try configurationRequire(
            !FileManager.default.fileExists(atPath: paths.installExpectation.path),
            "restore removes installer-created expectation"
        )

        let policyRoot = temporaryDirectory.appendingPathComponent("managed-path-policy", isDirectory: true)
        let policyEscape = temporaryDirectory.appendingPathComponent("managed-path-escape", isDirectory: true)
        try FileManager.default.createDirectory(at: policyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: policyEscape, withIntermediateDirectories: true)
        let linkedAncestor = policyRoot.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedAncestor, withDestinationURL: policyEscape)
        try configurationRequireThrows("managed path policy rejects a symlink ancestor") {
            try ManagedPathPolicy.requireSafeAncestors(
                root: policyRoot,
                target: linkedAncestor.appendingPathComponent("child/config.json")
            )
        }
        try configurationRequireThrows("managed path policy does not create through a symlink ancestor") {
            try ManagedPathPolicy.ensurePrivateDirectory(
                root: policyRoot,
                directory: linkedAncestor.appendingPathComponent("child", isDirectory: true)
            )
        }
        let escapedContents = try FileManager.default.contentsOfDirectory(atPath: policyEscape.path)
        try configurationRequire(escapedContents.isEmpty, "managed path policy left the external directory unchanged")

        let rootEscape = temporaryDirectory.appendingPathComponent("root-ancestor-escape", isDirectory: true)
        let rootAlias = temporaryDirectory.appendingPathComponent("root-ancestor-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootEscape.appendingPathComponent("home", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: rootEscape)
        try configurationRequireThrows("managed path policy rejects a symlink above the trusted root") {
            try ManagedPathPolicy.requireSafeAncestors(
                root: rootAlias.appendingPathComponent("home", isDirectory: true),
                target: rootAlias.appendingPathComponent("home/child/config.json")
            )
        }

        print("configuration-tests: PASS")
    }
}
