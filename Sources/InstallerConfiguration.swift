import Foundation

private func isManagedIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    return value.unicodeScalars.allSatisfy(allowed.contains)
}

struct InstallerPaths {
    let home: URL

    var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    var codexAuth: URL { home.appendingPathComponent(".codex/auth.json") }
    var codexPlusSettings: URL { home.appendingPathComponent(".codex-session-delete/settings.json") }
    var scriptConfig: URL { home.appendingPathComponent(".config/Codex++/user_scripts.json") }
    var offlineMarketplaces: URL { home.appendingPathComponent(".codex/offline-marketplaces", isDirectory: true) }
    var pluginCache: URL { home.appendingPathComponent(".codex/plugins/cache", isDirectory: true) }
    var installerDataRoot: URL {
        home.appendingPathComponent("Library/Application Support/Codex One Click Installer", isDirectory: true)
    }
    var installExpectation: URL { installerDataRoot.appendingPathComponent("install-expectation.json") }
    var backupRoot: URL {
        installerDataRoot.appendingPathComponent("backups", isDirectory: true)
    }
}

struct MarketplaceRegistration: Equatable {
    let id: String
    let source: URL
}

struct ManagedPluginRegistration: Codable, Equatable {
    let marketplace: String
    let id: String
}

struct ManagedPluginCatalog: Codable, Equatable {
    let schemaVersion: Int
    let plugins: [ManagedPluginRegistration]

    static func load(from url: URL) throws -> ManagedPluginCatalog {
        let catalog = try JSONDecoder().decode(ManagedPluginCatalog.self, from: Data(contentsOf: url))
        let required = [
            ManagedPluginRegistration(marketplace: "openai-bundled", id: "browser"),
            ManagedPluginRegistration(marketplace: "openai-bundled", id: "chrome"),
            ManagedPluginRegistration(marketplace: "openai-bundled", id: "computer-use"),
            ManagedPluginRegistration(marketplace: "openai-bundled", id: "latex"),
            ManagedPluginRegistration(marketplace: "openai-primary-runtime", id: "pdf"),
            ManagedPluginRegistration(marketplace: "openai-primary-runtime", id: "documents"),
            ManagedPluginRegistration(marketplace: "openai-primary-runtime", id: "spreadsheets"),
            ManagedPluginRegistration(marketplace: "openai-primary-runtime", id: "presentations"),
            ManagedPluginRegistration(marketplace: "openai-curated", id: "github")
        ]
        guard catalog.schemaVersion == 1, catalog.plugins == required else {
            throw NSError(
                domain: "CodexOneClickInstaller.Configuration",
                code: 65,
                userInfo: [NSLocalizedDescriptionKey: "invalid plugin catalog"]
            )
        }
        guard catalog.plugins.allSatisfy({
            isManagedIdentifier($0.marketplace) && isManagedIdentifier($0.id)
        }), Set(catalog.plugins.map { "\($0.id)@\($0.marketplace)" }).count == catalog.plugins.count else {
            throw NSError(
                domain: "CodexOneClickInstaller.Configuration",
                code: 65,
                userInfo: [NSLocalizedDescriptionKey: "invalid plugin catalog entries"]
            )
        }
        return catalog
    }
}

struct ConfigurationResult: Codable, Equatable {
    let managedProviderID: String
    let backupDirectory: String
}

struct PluginConfigurationVerification: Codable, Equatable {
    let status: String
    let marketplaceCount: Int
    let pluginCount: Int
}

enum InstallerConfiguration {
    private static let responsesProxyBaseURL = "http://127.0.0.1:57321/v1"

    static func apply(
        request: InstallRequest,
        paths: InstallerPaths,
        catalog: [ModelDefinition],
        backup suppliedBackup: URL? = nil
    ) throws -> ConfigurationResult {
        try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.home)
        _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: paths.home, target: paths.codexConfig)
        _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: paths.home, target: paths.codexAuth)
        _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: paths.home, target: paths.codexPlusSettings)
        _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: paths.home, target: paths.installExpectation)
        _ = try ManagedPathPolicy.requireDirectoryIfPresent(root: paths.home, target: paths.backupRoot)
        let apiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = orderedUnique(request.availableModels)
        guard apiKey.count >= 8 else {
            throw configurationError("API Key must contain at least 8 characters")
        }
        guard !models.isEmpty, models.contains(request.defaultModel) else {
            throw configurationError("default model is not available")
        }
        let catalogIDs = Set(catalog.map(\.id))
        guard Set(models).isSubset(of: catalogIDs), catalogIDs.contains(request.defaultModel) else {
            throw configurationError("resolved model list is inconsistent with the provider catalog")
        }

        let managedProviderID = providerID(for: request.provider)
        let expectation = try InstallExpectation.make(
            request: InstallRequest(
                provider: request.provider,
                apiKey: apiKey,
                defaultModel: request.defaultModel,
                availableModels: models,
                modelSource: request.modelSource,
                authenticationMode: request.authenticationMode
            ),
            managedProviderID: managedProviderID
        )
        let backupDirectory: URL
        if let suppliedBackup {
            try InstallerBackup.validateConfiguration(root: paths.home, backup: suppliedBackup)
            backupDirectory = suppliedBackup
        } else {
            backupDirectory = try createBackup(paths: paths)
        }

        do {
            let existingConfig = try readTextIfPresent(root: paths.home, url: paths.codexConfig)
            var document = try TomlDocument.parse(existingConfig)
            document.set(table: [], key: "model", value: .string(request.defaultModel))
            document.set(table: [], key: "model_provider", value: .string(managedProviderID))
            let providerTable = ["model_providers", managedProviderID]
            document.set(table: providerTable, key: "name", value: .string(request.provider.displayName))
            document.set(table: providerTable, key: "wire_api", value: .string("responses"))
            document.set(table: providerTable, key: "requires_openai_auth", value: .boolean(true))
            document.set(table: providerTable, key: "base_url", value: .string(responsesProxyBaseURL))
            switch request.authenticationMode {
            case .openAIAccountWithAPI:
                document.set(
                    table: providerTable,
                    key: "experimental_bearer_token",
                    value: .string(apiKey)
                )
            case .pureAPI:
                document.remove(table: providerTable, key: "experimental_bearer_token")
            }
            let configText = document.render()

            var auth = try readJSONObjectIfPresent(root: paths.home, url: paths.codexAuth)
            switch request.authenticationMode {
            case .openAIAccountWithAPI:
                auth.removeValue(forKey: "OPENAI_API_KEY")
            case .pureAPI:
                auth["OPENAI_API_KEY"] = apiKey
            }
            let authData = try encodedJSONObject(auth)
            let authText = String(decoding: authData, as: UTF8.self)

            var settings = try readJSONObjectIfPresent(root: paths.home, url: paths.codexPlusSettings)
            var profiles: [[String: Any]]
            if let existingProfiles = settings["relayProfiles"] {
                guard let typedProfiles = existingProfiles as? [[String: Any]] else {
                    throw configurationError("relayProfiles must be an array of objects")
                }
                profiles = typedProfiles
            } else {
                profiles = []
            }

            let existingIndex = profiles.firstIndex { $0["id"] as? String == managedProviderID }
            var managedProfile = existingIndex.map { profiles[$0] } ?? [:]
            managedProfile["id"] = managedProviderID
            managedProfile["name"] = request.provider.displayName
            managedProfile["protocol"] = "chatCompletions"
            managedProfile["relayMode"] = request.authenticationMode == .openAIAccountWithAPI
                ? "official"
                : "pureApi"
            managedProfile["officialMixApiKey"] =
                request.authenticationMode == .openAIAccountWithAPI
            managedProfile["upstreamBaseUrl"] = request.provider.defaultBaseURL.absoluteString
            managedProfile["testModel"] = request.defaultModel
            managedProfile["configContents"] = configText
            managedProfile["authContents"] = request.authenticationMode == .openAIAccountWithAPI
                ? ""
                : authText
            managedProfile["useCommonConfig"] = true
            managedProfile["contextSelection"] = managedProfile["contextSelection"] ?? [
                "mcpServers": [], "skills": [], "plugins": []
            ]
            managedProfile["contextSelectionInitialized"] = managedProfile["contextSelectionInitialized"] ?? false
            managedProfile["modelInsertMode"] = "patch"
            managedProfile["modelList"] = models.joined(separator: "\n")
            managedProfile["modelWindows"] = try modelWindowsJSON(models: models, catalog: catalog)

            if let existingIndex {
                profiles[existingIndex] = managedProfile
            } else {
                profiles.append(managedProfile)
            }

            settings["relayProfiles"] = profiles
            settings["relayProfilesEnabled"] = true
            settings["activeRelayId"] = managedProviderID
            settings["relayTestModel"] = request.defaultModel
            settings["launchMode"] = "patch"
            settings["codexAppPath"] = "/Applications/ChatGPT.app"
            settings["enhancementsEnabled"] = true
            settings["codexAppPluginMarketplaceUnlock"] = true
            settings["codexAppPluginAutoExpand"] = true
            settings["codexAppModelWhitelistUnlock"] = true
            settings["codexAppForceChineseLocale"] = true
            settings["codexAppNativeMenuLocalization"] = true
            let settingsData = try encodedJSONObject(settings)

            try atomicWrite(Data(configText.utf8), root: paths.home, to: paths.codexConfig, permissions: 0o600)
            try atomicWrite(authData, root: paths.home, to: paths.codexAuth, permissions: 0o600)
            try atomicWrite(settingsData, root: paths.home, to: paths.codexPlusSettings, permissions: 0o600)
            try atomicWrite(
                expectation.encoded(),
                root: paths.home,
                to: paths.installExpectation,
                permissions: 0o600
            )
        } catch let applyError {
            do {
                try restore(from: backupDirectory, paths: paths)
            } catch let restoreError {
                throw configurationError(
                    "configuration apply failed and rollback failed: \(restoreError.localizedDescription)"
                )
            }
            throw applyError
        }

        return ConfigurationResult(
            managedProviderID: managedProviderID,
            backupDirectory: backupDirectory.path
        )
    }

    static func restore(from backup: URL, paths: InstallerPaths) throws {
        try InstallerBackup.restoreConfiguration(root: paths.home, backup: backup)
    }

    static func verify(
        expectation: InstallExpectation,
        paths: InstallerPaths,
        catalog: ProviderDefinition
    ) throws -> ConfigurationVerification {
        try expectation.validate()
        guard catalog.kind == expectation.provider,
              catalog.protocolName == "chatCompletions",
              !catalog.models.isEmpty else {
            throw verificationError("catalog_provider_mismatch")
        }

        try ManagedPathPolicy.requireRegularFile(root: paths.home, target: paths.codexConfig)
        try ManagedPathPolicy.requireRegularFile(root: paths.home, target: paths.codexAuth)
        try ManagedPathPolicy.requireRegularFile(root: paths.home, target: paths.codexPlusSettings)
        try ManagedPathPolicy.requireRegularFile(root: paths.home, target: paths.installExpectation)

        let configText = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        let config = try TomlDocument.parse(configText)
        try verifyManagedTOML(config, expectation: expectation)

        let auth = try readJSONObjectIfPresent(root: paths.home, url: paths.codexAuth)
        switch expectation.authenticationMode {
        case .openAIAccountWithAPI:
            guard auth["OPENAI_API_KEY"] == nil else {
                throw verificationError("official_auth_contains_api_key")
            }
        case .pureAPI:
            guard let apiKey = auth["OPENAI_API_KEY"] as? String,
                  expectation.matches(apiKey: apiKey) else {
                throw verificationError("api_key_mismatch")
            }
        }

        let settings = try readJSONObjectIfPresent(root: paths.home, url: paths.codexPlusSettings)
        guard settings["relayProfilesEnabled"] as? Bool == true,
              settings["activeRelayId"] as? String == expectation.managedProviderID,
              settings["relayTestModel"] as? String == expectation.defaultModel else {
            throw verificationError("active_relay_mismatch")
        }

        for key in [
            "enhancementsEnabled",
            "codexAppPluginMarketplaceUnlock",
            "codexAppPluginAutoExpand",
            "codexAppModelWhitelistUnlock",
            "codexAppForceChineseLocale",
            "codexAppNativeMenuLocalization"
        ] where settings[key] as? Bool != true {
            throw verificationError("enhancement_disabled")
        }

        guard let profiles = settings["relayProfiles"] as? [[String: Any]] else {
            throw verificationError("relay_profiles_invalid")
        }
        let managedProfiles = profiles.filter { $0["id"] as? String == expectation.managedProviderID }
        guard managedProfiles.count == 1 else {
            throw verificationError("managed_relay_missing_or_duplicate")
        }
        let profile = managedProfiles[0]
        let expectedRelayMode = expectation.authenticationMode == .openAIAccountWithAPI
            ? "official"
            : "pureApi"
        let expectedOfficialMix = expectation.authenticationMode == .openAIAccountWithAPI
        guard profile["name"] as? String == expectation.provider.displayName,
              profile["protocol"] as? String == "chatCompletions",
              profile["relayMode"] as? String == expectedRelayMode,
              profile["officialMixApiKey"] as? Bool == expectedOfficialMix,
              profile["upstreamBaseUrl"] as? String == expectation.provider.defaultBaseURL.absoluteString,
              profile["testModel"] as? String == expectation.defaultModel,
              profile["useCommonConfig"] as? Bool == true,
              profile["modelInsertMode"] as? String == "patch",
              profile["modelList"] as? String == expectation.availableModels.joined(separator: "\n") else {
            throw verificationError("managed_relay_mismatch")
        }

        guard let profileConfigText = profile["configContents"] as? String else {
            throw verificationError("relay_config_contents_missing")
        }
        let profileConfig = try TomlDocument.parse(profileConfigText)
        try verifyManagedTOML(profileConfig, expectation: expectation)

        guard let profileAuthText = profile["authContents"] as? String else {
            throw verificationError("relay_auth_contents_missing")
        }
        switch expectation.authenticationMode {
        case .openAIAccountWithAPI:
            guard profileAuthText.isEmpty else {
                throw verificationError("official_relay_auth_must_follow_live_login")
            }
        case .pureAPI:
            guard let profileAuthData = profileAuthText.data(using: .utf8),
                  let profileAuth = try JSONSerialization.jsonObject(
                    with: profileAuthData
                  ) as? [String: Any],
                  let profileAPIKey = profileAuth["OPENAI_API_KEY"] as? String,
                  expectation.matches(apiKey: profileAPIKey),
                  try encodedJSONObject(profileAuth) == encodedJSONObject(auth) else {
                throw verificationError("relay_auth_contents_mismatch")
            }
        }

        return ConfigurationVerification(
            status: "pass",
            provider: expectation.provider,
            defaultModel: expectation.defaultModel,
            modelCount: expectation.availableModels.count,
            authenticationMode: expectation.authenticationMode
        )
    }

    static func registerMarketplaces(
        _ registrations: [MarketplaceRegistration],
        configURL: URL
    ) throws {
        guard Set(registrations.map(\.id)).count == registrations.count else {
            throw configurationError("duplicate marketplace registration")
        }
        let root = configURL.deletingLastPathComponent().deletingLastPathComponent()
        var document = try TomlDocument.parse(try readTextIfPresent(root: root, url: configURL))
        for registration in registrations {
            let source = URL(fileURLWithPath: registration.source.path)
            guard isManagedIdentifier(registration.id),
                  source.path.hasPrefix("/"),
                  !source.path.contains("\n") else {
                throw configurationError("invalid marketplace registration")
            }
            _ = try ManagedPathPolicy.requireDirectoryIfPresent(root: root, target: source)
            let table = ["marketplaces", registration.id]
            document.set(table: table, key: "source_type", value: .string("local"))
            document.set(table: table, key: "source", value: .string(source.path))
        }
        let rendered = document.render()
        _ = try TomlDocument.parse(rendered)
        try atomicWrite(Data(rendered.utf8), root: root, to: configURL, permissions: 0o600)
    }

    static func enableManagedPlugins(
        _ plugins: [ManagedPluginRegistration],
        configURL: URL
    ) throws {
        guard Set(plugins.map { "\($0.id)@\($0.marketplace)" }).count == plugins.count else {
            throw configurationError("duplicate managed plugin registration")
        }
        let root = configURL.deletingLastPathComponent().deletingLastPathComponent()
        var document = try TomlDocument.parse(try readTextIfPresent(root: root, url: configURL))
        for plugin in plugins {
            guard isManagedIdentifier(plugin.marketplace),
                  isManagedIdentifier(plugin.id) else {
                throw configurationError("invalid managed plugin registration")
            }
            document.set(
                table: ["plugins", "\(plugin.id)@\(plugin.marketplace)"],
                key: "enabled",
                value: .boolean(true)
            )
        }
        let rendered = document.render()
        _ = try TomlDocument.parse(rendered)
        try atomicWrite(Data(rendered.utf8), root: root, to: configURL, permissions: 0o600)
    }

    static func verifyManagedPlugins(
        _ plugins: [ManagedPluginRegistration],
        paths: InstallerPaths
    ) throws -> PluginConfigurationVerification {
        guard !plugins.isEmpty,
              Set(plugins.map { "\($0.id)@\($0.marketplace)" }).count == plugins.count else {
            throw verificationError("managed_plugin_catalog_invalid")
        }
        try ManagedPathPolicy.requireRegularFile(root: paths.home, target: paths.codexConfig)
        let document = try TomlDocument.parse(
            String(contentsOf: paths.codexConfig, encoding: .utf8)
        )
        let marketplaces = Set(plugins.map(\.marketplace))
        for marketplace in marketplaces {
            let table = ["marketplaces", marketplace]
            let source = paths.offlineMarketplaces
                .appendingPathComponent(marketplace, isDirectory: true)
                .path
            guard try document.value(table: table, key: "source_type") == .string("local"),
                  try document.value(table: table, key: "source") == .string(source) else {
                throw verificationError("managed_marketplace_configuration_mismatch")
            }
        }
        for plugin in plugins {
            let table = ["plugins", "\(plugin.id)@\(plugin.marketplace)"]
            guard try document.value(table: table, key: "enabled") == .boolean(true) else {
                throw verificationError("managed_plugin_disabled")
            }
        }
        return PluginConfigurationVerification(
            status: "pass",
            marketplaceCount: marketplaces.count,
            pluginCount: plugins.count
        )
    }

    private static func providerID(for provider: ProviderKind) -> String {
        switch provider {
        case .deepSeek: "codex-one-click-deepseek"
        case .kimiOpen: "codex-one-click-kimi-open"
        case .kimiCode: "codex-one-click-kimi-code"
        case .zhipu: "codex-one-click-zhipu"
        case .qwen: "codex-one-click-qwen"
        case .xiaomiMiMo: "codex-one-click-xiaomi-mimo"
        }
    }

    private static func verifyManagedTOML(
        _ document: TomlDocument,
        expectation: InstallExpectation
    ) throws {
        let providerTable = ["model_providers", expectation.managedProviderID]
        guard try document.value(table: [], key: "model") == .string(expectation.defaultModel),
              try document.value(table: [], key: "model_provider") == .string(expectation.managedProviderID),
              try document.value(table: providerTable, key: "name") == .string(expectation.provider.displayName),
              try document.value(table: providerTable, key: "wire_api") == .string("responses"),
              try document.value(table: providerTable, key: "requires_openai_auth") == .boolean(true),
              try document.value(table: providerTable, key: "base_url") == .string(responsesProxyBaseURL) else {
            throw verificationError("managed_toml_mismatch")
        }
        let bearerToken = try document.value(
            table: providerTable,
            key: "experimental_bearer_token"
        )
        switch expectation.authenticationMode {
        case .openAIAccountWithAPI:
            guard case let .string(value)? = bearerToken,
                  expectation.matches(apiKey: value) else {
                throw verificationError("mixed_api_bearer_token_mismatch")
            }
        case .pureAPI:
            guard bearerToken == nil else {
                throw verificationError("pure_api_bearer_token_present")
            }
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func createBackup(paths: InstallerPaths) throws -> URL {
        try ManagedPathPolicy.ensurePrivateDirectory(root: paths.home, directory: paths.backupRoot)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let name = "\(formatter.string(from: Date()))-\(UUID().uuidString.lowercased())"
        let backup = paths.backupRoot.appendingPathComponent(name, isDirectory: true)
        try InstallerBackup.snapshotConfiguration(root: paths.home, backup: backup)
        return backup
    }

    private static func readTextIfPresent(root: URL, url: URL) throws -> String {
        guard try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url) else { return "" }
        try ManagedPathPolicy.requireRegularFile(root: root, target: url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func readJSONObjectIfPresent(root: URL, url: URL) throws -> [String: Any] {
        guard try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url) else { return [:] }
        try ManagedPathPolicy.requireRegularFile(root: root, target: url)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? [String: Any] else {
            throw configurationError("JSON root must be an object")
        }
        return object
    }

    private static func encodedJSONObject(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw configurationError("configuration contains an invalid JSON value")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    private static func modelWindowsJSON(models: [String], catalog: [ModelDefinition]) throws -> String {
        var windows: [String: String] = [:]
        for model in models {
            if let contextWindow = catalog.first(where: { $0.id == model })?.contextWindow {
                windows[model] = String(contextWindow)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func atomicWrite(_ data: Data, root: URL, to url: URL, permissions: Int) throws {
        let parent = url.deletingLastPathComponent()
        try ManagedPathPolicy.ensurePrivateDirectory(root: root, directory: parent)
        _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url)
        let temporary = parent.appendingPathComponent(".codex-one-click-\(UUID().uuidString).tmp")
        guard try !ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: temporary) else {
            throw configurationError("temporary configuration file already exists")
        }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data) else {
            throw configurationError("failed to create temporary configuration file")
        }
        defer {
            if (try? ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: temporary)) == true {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        try ManagedPathPolicy.requireRegularFile(root: root, target: temporary)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()

        if try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try ManagedPathPolicy.requireRegularFile(root: root, target: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func configurationError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.Configuration",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func verificationError(_ reason: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.ConfigurationVerification",
            code: 67,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }
}
