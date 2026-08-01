import Darwin
import CryptoKit
import Foundation

@main
enum InstallerSupportCLI {
    private struct PluginFileManifest: Decodable {
        struct Entry: Decodable {
            let path: String
            let sha256: String
        }

        let schemaVersion: Int
        let files: [Entry]
    }

    private struct FixtureModelTransport: HTTPTransport {
        let responseFile: URL

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let data = try Data(contentsOf: responseFile)
            let fixtureObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let fixtureObject, fixtureObject["provider"] != nil {
                guard let providerID = fixtureObject["provider"] as? String,
                      let expectedProvider = ProviderKind(rawValue: providerID) else {
                    throw CLIError.invalidData("invalid fixture provider metadata")
                }
                guard request.url == expectedProvider.modelsURL else {
                    throw CLIError.invalidData("fixture response is scoped to another provider")
                }
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, response)
        }
    }

    private struct ResolvedModelSelection {
        let models: [ModelDefinition]
        let source: ModelSource
    }

    private enum CLIError: Error {
        case usage(String)
        case invalidData(String)
    }

    static func main() async {
        do {
            try await run(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
        } catch CLIError.usage(let message) {
            writeError(message)
            exit(64)
        } catch CLIError.invalidData(let message) {
            writeError(message)
            exit(65)
        } catch {
            writeError("invalid data")
            exit(65)
        }
    }

    private static func run(arguments: [String], environment: [String: String]) async throws {
        guard arguments.count >= 2 else {
            throw CLIError.usage("usage: installer-support <command>")
        }

        switch arguments[1] {
        case "backup-identifier":
            guard arguments.count == 2 else {
                throw CLIError.usage("usage: installer-support backup-identifier")
            }
            try writeJSON(["identifier": InstallerBackup.makeIdentifier()])

        case "build-complete-inventory":
            guard arguments.count == 4, arguments[2] == "--created-at" else {
                throw CLIError.usage(
                    "usage: installer-support build-complete-inventory --created-at <timestamp>"
                )
            }
            do {
                let entries = FileHandle.standardInput.readDataToEndOfFile()
                let inventory = try InstallerBackup.buildCompleteInventory(
                    createdAt: arguments[3],
                    entriesData: entries
                )
                FileHandle.standardOutput.write(inventory)
            } catch {
                throw CLIError.invalidData("invalid complete backup inventory")
            }

        case "validate-complete-inventory":
            guard arguments.count == 4, arguments[2] == "--inventory" else {
                throw CLIError.usage(
                    "usage: installer-support validate-complete-inventory --inventory <path>"
                )
            }
            do {
                let entries = try InstallerBackup.validateCompleteInventory(
                    at: URL(fileURLWithPath: arguments[3])
                )
                writeBackupEntriesTSV(entries)
            } catch {
                throw CLIError.invalidData("invalid complete backup inventory")
            }

        case "hardware-architecture":
            guard arguments.count == 2 else {
                throw CLIError.usage("usage: installer-support hardware-architecture")
            }
            let architecture = HardwareArchitecture.detect(
                environment: environment,
                testMode: environment["TEST_MODE"] == "1"
            )
            try writeJSON(["architecture": architecture.rawValue])

        case "chatgpt-auth-status":
            guard arguments.count == 4, arguments[2] == "--root" else {
                throw CLIError.usage(
                    "usage: installer-support chatgpt-auth-status --root <home>"
                )
            }
            do {
                let home = URL(fileURLWithPath: arguments[3], isDirectory: true)
                try ManagedPathPolicy.requireDirectory(root: home, target: home)
                let authenticated = try chatGPTAuthenticationStatus(home: home)
                try writeJSON([
                    "authenticated": authenticated,
                    "authenticationMode": authenticated ? "chatgpt" : "none",
                    "status": "checked"
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid ChatGPT authentication state")
            }

        case "manifest-validate":
            guard arguments.count == 3 else {
                throw CLIError.usage("usage: installer-support manifest-validate <manifest-path>")
            }
            do {
                let manifest = try PayloadManifest.load(from: URL(fileURLWithPath: arguments[2]))
                try manifest.validateRequiredPayloads(testMode: environment["TEST_MODE"] == "1")
                try writeJSON([
                    "payloadCount": manifest.files.count,
                    "schemaVersion": manifest.schemaVersion,
                    "status": "valid"
                ])
            } catch {
                throw CLIError.invalidData("invalid payload manifest")
            }

        case "payload-resolve":
            guard arguments.count == 8,
                  arguments[2] == "--manifest",
                  arguments[4] == "--component",
                  arguments[6] == "--architecture",
                  let component = AppPayloadComponent(rawValue: arguments[5]),
                  let architecture = HardwareArchitecture(rawValue: arguments[7]) else {
                throw CLIError.usage(
                    "usage: installer-support payload-resolve --manifest <path> --component <chatgpt|codex-plus-plus> --architecture <arm64|x86_64>"
                )
            }
            do {
                let manifest = try PayloadManifest.load(from: URL(fileURLWithPath: arguments[3]))
                try manifest.validateRequiredPayloads(testMode: environment["TEST_MODE"] == "1")
                let payload = try manifest.resolveAppPayload(
                    component: component,
                    architecture: architecture
                )
                var output: [String: Any] = [
                    "architecture": payload.architecture,
                    "format": payload.format.rawValue,
                    "id": payload.id,
                    "relativePath": payload.relativePath,
                    "sha256": payload.sha256,
                    "version": payload.version
                ]
                if let bundleIdentifier = payload.bundleIdentifier {
                    output["bundleIdentifier"] = bundleIdentifier
                }
                if let teamIdentifier = payload.teamIdentifier {
                    output["teamIdentifier"] = teamIdentifier
                }
                if let compatibilityRevision = payload.compatibilityRevision {
                    output["compatibilityRevision"] = compatibilityRevision
                }
                try writeJSON(output)
            } catch {
                throw CLIError.invalidData("invalid application payload")
            }

        case "apply-config":
            guard (arguments.count == 6 || arguments.count == 8),
                  arguments[2] == "--root",
                  arguments[4] == "--catalog",
                  arguments.count == 6 || arguments[6] == "--backup" else {
                throw CLIError.usage(
                    "usage: installer-support apply-config --root <home> --catalog <model-catalog.json> [--backup <path>]"
                )
            }
            do {
                let home = URL(fileURLWithPath: arguments[3], isDirectory: true)
                try ManagedPathPolicy.requireDirectory(root: home, target: home)
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard !input.isEmpty, input.count <= 1_048_576 else {
                    throw CLIError.invalidData("invalid install request")
                }
                let request = try JSONDecoder().decode(InstallRequest.self, from: input)
                guard request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else {
                    throw CLIError.invalidData("invalid install request")
                }
                let catalog = try ProviderCatalogStore.load(
                    from: URL(fileURLWithPath: arguments[5])
                )
                guard let provider = catalog.providers.first(where: { $0.kind == request.provider }) else {
                    throw CLIError.invalidData("invalid model catalog")
                }
                let normalizedRequest = InstallRequest(
                    provider: request.provider,
                    apiKey: request.apiKey,
                    defaultModel: request.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines),
                    availableModels: normalizedModelIDs(request.availableModels),
                    modelSource: request.modelSource,
                    authenticationMode: request.authenticationMode
                )
                guard !normalizedRequest.availableModels.isEmpty,
                      normalizedRequest.availableModels.contains(normalizedRequest.defaultModel) else {
                    throw CLIError.invalidData("invalid install request")
                }
                let frozenIDs = Set(provider.models.map(\.id))
                let requestedIDs = Set(normalizedRequest.availableModels)
                let needsLiveResolution = !requestedIDs.isSubset(of: frozenIDs)
                let resolved: ResolvedModelSelection
                if needsLiveResolution {
                    guard normalizedRequest.modelSource == .upstreamRefresh else {
                        throw CLIError.invalidData("selected model is absent from the offline catalog")
                    }
                    let client = ProviderCatalogClient(transport: modelTransport(environment: environment))
                    let upstream = try await client.fetchModels(
                        provider: normalizedRequest.provider,
                        apiKey: normalizedRequest.apiKey
                    )
                    let upstreamIDs = Set(upstream.map(\.id))
                    guard upstreamIDs.contains(normalizedRequest.defaultModel) else {
                        throw CLIError.invalidData("selected model is absent from the current upstream catalog")
                    }
                    resolved = ResolvedModelSelection(models: upstream, source: .upstreamRefresh)
                } else {
                    resolved = ResolvedModelSelection(models: provider.models, source: .offlineSnapshot)
                }
                let resolvedRequest = InstallRequest(
                    provider: normalizedRequest.provider,
                    apiKey: normalizedRequest.apiKey,
                    defaultModel: normalizedRequest.defaultModel,
                    availableModels: resolved.models.map(\.id),
                    modelSource: resolved.source,
                    authenticationMode: normalizedRequest.authenticationMode
                )
                let result = try InstallerConfiguration.apply(
                    request: resolvedRequest,
                    paths: InstallerPaths(home: home),
                    catalog: resolved.models,
                    backup: arguments.count == 8
                        ? URL(fileURLWithPath: arguments[7], isDirectory: true)
                        : nil
                )
                try writeJSON([
                    "backupDirectory": result.backupDirectory,
                    "managedProviderID": result.managedProviderID,
                    "modelCount": resolved.models.count,
                    "modelSource": resolved.source.rawValue,
                    "authenticationMode": resolvedRequest.authenticationMode.rawValue
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid configuration data")
            }

        case "validate-install-request":
            guard arguments.count == 4, arguments[2] == "--catalog" else {
                throw CLIError.usage(
                    "usage: installer-support validate-install-request --catalog <model-catalog.json>"
                )
            }
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard !input.isEmpty, input.count <= 1_048_576 else {
                    throw CLIError.invalidData("invalid install request")
                }
                let request = try JSONDecoder().decode(InstallRequest.self, from: input)
                let apiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let defaultModel = request.defaultModel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let availableModels = normalizedModelIDs(request.availableModels)
                guard apiKey.count >= 8,
                      !availableModels.isEmpty,
                      availableModels.contains(defaultModel) else {
                    throw CLIError.invalidData("invalid install request")
                }
                let catalog = try ProviderCatalogStore.load(
                    from: URL(fileURLWithPath: arguments[3])
                )
                guard let provider = catalog.providers.first(where: {
                    $0.kind == request.provider
                }) else {
                    throw CLIError.invalidData("invalid model catalog")
                }
                let frozenIDs = Set(provider.models.map(\.id))
                let requestedIDs = Set(availableModels)
                let source: ModelSource
                let modelCount: Int
                if requestedIDs.isSubset(of: frozenIDs) {
                    source = .offlineSnapshot
                    modelCount = provider.models.count
                } else {
                    guard request.modelSource == .upstreamRefresh else {
                        throw CLIError.invalidData(
                            "selected model is absent from the offline catalog"
                        )
                    }
                    let client = ProviderCatalogClient(
                        transport: modelTransport(environment: environment)
                    )
                    let upstream = try await client.fetchModels(
                        provider: request.provider,
                        apiKey: apiKey
                    )
                    guard upstream.contains(where: { $0.id == defaultModel }) else {
                        throw CLIError.invalidData(
                            "selected model is absent from the current upstream catalog"
                        )
                    }
                    source = .upstreamRefresh
                    modelCount = upstream.count
                }
                try writeJSON([
                    "modelCount": modelCount,
                    "modelSource": source.rawValue,
                    "provider": request.provider.rawValue,
                    "authenticationMode": request.authenticationMode.rawValue,
                    "status": "valid"
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid install request")
            }

        case "verify-config":
            guard arguments.count == 8,
                  arguments[2] == "--root",
                  arguments[4] == "--catalog",
                  arguments[6] == "--expectation" else {
                throw CLIError.usage(
                    "usage: installer-support verify-config --root <home> --catalog <model-catalog.json> --expectation <path>"
                )
            }
            do {
                let paths = InstallerPaths(
                    home: URL(fileURLWithPath: arguments[3], isDirectory: true)
                )
                try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.home)
                let expectationURL = URL(fileURLWithPath: arguments[7])
                guard try ManagedPathPolicy.lexicalPath(expectationURL)
                    == ManagedPathPolicy.lexicalPath(paths.installExpectation) else {
                    throw CLIError.invalidData("invalid install expectation path")
                }
                try ManagedPathPolicy.requireRegularFile(
                    root: paths.home,
                    target: paths.installExpectation
                )
                let expectation = try InstallExpectation.load(from: paths.installExpectation)
                let catalog = try ProviderCatalogStore.load(
                    from: URL(fileURLWithPath: arguments[5])
                )
                guard let provider = catalog.providers.first(where: {
                    $0.kind == expectation.provider
                }) else {
                    throw CLIError.invalidData("invalid model catalog")
                }
                let verification = try InstallerConfiguration.verify(
                    expectation: expectation,
                    paths: paths,
                    catalog: provider
                )
                try writeJSON([
                    "defaultModel": verification.defaultModel,
                    "modelCount": verification.modelCount,
                    "provider": verification.provider.rawValue,
                    "authenticationMode": verification.authenticationMode.rawValue,
                    "status": verification.status
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid installed configuration")
            }

        case "refresh-models":
            guard arguments.count == 7,
                  arguments[2] == "--provider",
                  arguments[4] == "--catalog",
                  arguments[6] == "--key-stdin",
                  let provider = ProviderKind(rawValue: arguments[3]) else {
                throw CLIError.usage(
                    "usage: installer-support refresh-models --provider <id> --catalog <path> --key-stdin"
                )
            }
            do {
                let keyData = FileHandle.standardInput.readDataToEndOfFile()
                guard keyData.count <= 65_536,
                      let key = String(data: keyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      key.count >= 8 else {
                    throw CLIError.invalidData("invalid API Key input")
                }

                let client = ProviderCatalogClient(transport: modelTransport(environment: environment))
                let models = try await client.fetchModels(provider: provider, apiKey: key)
                let catalogURL = URL(fileURLWithPath: arguments[5])
                var catalog = try ProviderCatalogStore.load(from: catalogURL)
                try catalog.replaceModels(
                    for: provider,
                    with: models,
                    generatedAt: ISO8601DateFormatter().string(from: Date())
                )
                try catalog.writeAtomically(to: catalogURL)
                try writeJSON(["count": models.count, "provider": provider.rawValue])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid upstream model response")
            }

        case "model-catalog-validate":
            guard arguments.count == 6,
                  arguments[2] == "--catalog",
                  arguments[4] == "--max-age-days",
                  let maximumAgeDays = Int(arguments[5]),
                  maximumAgeDays > 0 else {
                throw CLIError.usage(
                    "usage: installer-support model-catalog-validate --catalog <path> --max-age-days <days>"
                )
            }
            do {
                let catalog = try ProviderCatalogStore.load(
                    from: URL(fileURLWithPath: arguments[3])
                )
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let generatedAt = formatter.date(from: catalog.generatedAt)
                    ?? ISO8601DateFormatter().date(from: catalog.generatedAt)
                guard let generatedAt else {
                    throw CLIError.invalidData("model catalog timestamp is invalid")
                }
                let age = Date().timeIntervalSince(generatedAt)
                guard age >= -86_400, age <= Double(maximumAgeDays) * 86_400 else {
                    throw CLIError.invalidData("model catalog is stale")
                }
                try writeJSON([
                    "generatedAt": catalog.generatedAt,
                    "maximumAgeDays": maximumAgeDays,
                    "status": "valid"
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid model catalog")
            }

        case "plugin-package-validate":
            guard arguments.count == 6,
                  arguments[2] == "--root",
                  arguments[4] == "--catalog" else {
                throw CLIError.usage(
                    "usage: installer-support plugin-package-validate --root <plugins-root> --catalog <plugin-catalog.json>"
                )
            }
            do {
                let count = try validatePluginPackage(
                    root: URL(fileURLWithPath: arguments[3], isDirectory: true),
                    catalogURL: URL(fileURLWithPath: arguments[5])
                )
                try writeJSON(["fileCount": count, "status": "valid"])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid plugin package")
            }

        case "configure-plugins":
            guard arguments.count == 6,
                  arguments[2] == "--root",
                  arguments[4] == "--catalog" else {
                throw CLIError.usage(
                    "usage: installer-support configure-plugins --root <home> --catalog <plugin-catalog.json>"
                )
            }
            do {
                let paths = InstallerPaths(home: URL(fileURLWithPath: arguments[3], isDirectory: true))
                try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.home)
                try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.offlineMarketplaces)
                try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.pluginCache)
                _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: paths.home, target: paths.codexConfig)
                let catalog = try ManagedPluginCatalog.load(from: URL(fileURLWithPath: arguments[5]))
                let marketplaces = Array(Set(catalog.plugins.map(\.marketplace))).sorted().map {
                    MarketplaceRegistration(
                        id: $0,
                        source: paths.offlineMarketplaces.appendingPathComponent($0, isDirectory: true)
                    )
                }
                for registration in marketplaces {
                    try ManagedPathPolicy.requireDirectory(root: paths.home, target: registration.source)
                }
                try InstallerConfiguration.registerMarketplaces(marketplaces, configURL: paths.codexConfig)
                try InstallerConfiguration.enableManagedPlugins(catalog.plugins, configURL: paths.codexConfig)
                try writeJSON([
                    "marketplaceCount": marketplaces.count,
                    "pluginCount": catalog.plugins.count,
                    "status": "configured"
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid plugin configuration")
            }

        case "verify-plugin-config":
            guard arguments.count == 6,
                  arguments[2] == "--root",
                  arguments[4] == "--catalog" else {
                throw CLIError.usage(
                    "usage: installer-support verify-plugin-config --root <home> --catalog <plugin-catalog.json>"
                )
            }
            do {
                let paths = InstallerPaths(
                    home: URL(fileURLWithPath: arguments[3], isDirectory: true)
                )
                try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.home)
                let catalog = try ManagedPluginCatalog.load(
                    from: URL(fileURLWithPath: arguments[5])
                )
                let verification = try InstallerConfiguration.verifyManagedPlugins(
                    catalog.plugins,
                    paths: paths
                )
                try writeJSON([
                    "marketplaceCount": verification.marketplaceCount,
                    "pluginCount": verification.pluginCount,
                    "status": verification.status
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid installed plugin configuration")
            }

        case "install-scripts":
            guard arguments.count == 8,
                  arguments[2] == "--snapshot",
                  arguments[4] == "--destination",
                  arguments[6] == "--config" else {
                throw CLIError.usage(
                    "usage: installer-support install-scripts --snapshot <dir> --destination <dir> --config <path>"
                )
            }
            do {
                let result = try ScriptMarketInstaller.install(
                    snapshot: URL(fileURLWithPath: arguments[3], isDirectory: true),
                    destination: URL(fileURLWithPath: arguments[5], isDirectory: true),
                    configURL: URL(fileURLWithPath: arguments[7])
                )
                try writeJSON([
                    "installedCount": result.installedCount,
                    "installedFiles": result.installedFiles
                ])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid script market package")
            }

        case "snapshot-config":
            guard arguments.count == 6,
                  arguments[2] == "--root",
                  arguments[4] == "--backup" else {
                throw CLIError.usage(
                    "usage: installer-support snapshot-config --root <home> --backup <path>"
                )
            }
            do {
                let home = URL(fileURLWithPath: arguments[3], isDirectory: true)
                let backup = URL(fileURLWithPath: arguments[5], isDirectory: true)
                try InstallerBackup.snapshotConfiguration(root: home, backup: backup)
                try writeJSON(["status": "snapshotted"])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid backup data")
            }

        case "validate-config-backup":
            guard arguments.count == 6,
                  arguments[2] == "--root",
                  arguments[4] == "--backup" else {
                throw CLIError.usage(
                    "usage: installer-support validate-config-backup --root <home> --backup <path>"
                )
            }
            do {
                try InstallerBackup.validateConfiguration(
                    root: URL(fileURLWithPath: arguments[3], isDirectory: true),
                    backup: URL(fileURLWithPath: arguments[5], isDirectory: true)
                )
                try writeJSON(["status": "valid"])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid backup data")
            }

        case "restore-config":
            guard arguments.count == 6,
                  arguments[2] == "--root",
                  arguments[4] == "--backup" else {
                throw CLIError.usage(
                    "usage: installer-support restore-config --root <home> --backup <path>"
                )
            }
            do {
                let paths = InstallerPaths(
                    home: URL(fileURLWithPath: arguments[3], isDirectory: true)
                )
                let backup = URL(fileURLWithPath: arguments[5], isDirectory: true)
                let root = try ManagedPathPolicy.lexicalPath(paths.backupRoot) + "/"
                guard try ManagedPathPolicy.lexicalPath(backup).hasPrefix(root) else {
                    throw CLIError.invalidData("invalid backup path")
                }
                try InstallerConfiguration.restore(from: backup, paths: paths)
                try writeJSON(["status": "restored"])
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.invalidData("invalid backup data")
            }

        default:
            throw CLIError.usage("unknown command")
        }
    }

    private static func modelTransport(environment: [String: String]) -> any HTTPTransport {
        if environment["TEST_MODE"] == "1", let fixture = environment["MODELS_RESPONSE_FILE"] {
            return FixtureModelTransport(responseFile: URL(fileURLWithPath: fixture))
        }
        return URLSessionTransport()
    }

    private static func normalizedModelIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private static func writeJSON(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func writeBackupEntriesTSV(_ entries: [BackupEntry]) {
        let lines = entries.map { entry in
            [
                entry.key,
                entry.kind.rawValue,
                entry.existed ? "true" : "false",
                entry.backupRelativePath ?? ""
            ].joined(separator: "\t")
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func validatePluginPackage(root: URL, catalogURL: URL) throws -> Int {
        let fileManager = FileManager.default
        let packageRoot = try canonicalExistingURL(root)
        let catalog = try ManagedPluginCatalog.load(from: catalogURL)
        let manifestURL = packageRoot.appendingPathComponent("file-manifest.json")
        let manifest = try JSONDecoder().decode(PluginFileManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, !manifest.files.isEmpty else {
            throw CLIError.invalidData("invalid plugin file manifest")
        }

        var manifestPaths = Set<String>()
        for entry in manifest.files {
            guard isSafePluginRelativePath(entry.path),
                  entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit }),
                  manifestPaths.insert(entry.path).inserted else {
                throw CLIError.invalidData("invalid plugin file manifest entry")
            }
        }

        var actualPaths = Set<String>()
        for subtree in ["marketplaces", "cache"] {
            let subtreeURL = packageRoot.appendingPathComponent(subtree, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: subtreeURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                throw CLIError.invalidData("missing plugin package subtree")
            }
            while let item = enumerator.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true,
                      values.isRegularFile == true || values.isDirectory == true else {
                    throw CLIError.invalidData(
                        "unsupported plugin package file: \(item.lastPathComponent)"
                    )
                }
                if values.isRegularFile == true {
                    let prefix = packageRoot.path + "/"
                    guard item.path.hasPrefix(prefix) else {
                        throw CLIError.invalidData("unsafe plugin package file")
                    }
                    actualPaths.insert(String(item.path.dropFirst(prefix.count)))
                }
            }
        }
        guard actualPaths == manifestPaths else {
            throw CLIError.invalidData("plugin file manifest does not match package")
        }

        for entry in manifest.files {
            let data = try Data(contentsOf: packageRoot.appendingPathComponent(entry.path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == entry.sha256.lowercased() else {
                throw CLIError.invalidData("plugin payload hash mismatch")
            }
        }

        let requiredMarketplaces = Set(catalog.plugins.map(\.marketplace))
        let marketplaceRoot = packageRoot.appendingPathComponent("marketplaces", isDirectory: true)
        let packagedMarketplaces = try childDirectoryNames(at: marketplaceRoot)
        guard packagedMarketplaces == requiredMarketplaces else {
            throw CLIError.invalidData("plugin marketplace set mismatch")
        }
        for marketplace in requiredMarketplaces {
            let metadata = marketplaceRoot
                .appendingPathComponent(marketplace, isDirectory: true)
                .appendingPathComponent(".agents/plugins/marketplace.json")
            guard fileManager.fileExists(atPath: metadata.path) else {
                throw CLIError.invalidData("missing marketplace metadata")
            }
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata))
        }

        let cacheRoot = packageRoot.appendingPathComponent("cache", isDirectory: true)
        guard try childDirectoryNames(at: cacheRoot) == requiredMarketplaces else {
            throw CLIError.invalidData("plugin cache marketplace set mismatch")
        }
        for marketplace in requiredMarketplaces {
            let expectedPlugins = Set(catalog.plugins.filter { $0.marketplace == marketplace }.map(\.id))
            let marketplaceCache = cacheRoot.appendingPathComponent(marketplace, isDirectory: true)
            guard try childDirectoryNames(at: marketplaceCache) == expectedPlugins else {
                throw CLIError.invalidData("plugin cache set mismatch")
            }
        }

        for plugin in catalog.plugins {
            let pluginRoot = cacheRoot
                .appendingPathComponent(plugin.marketplace, isDirectory: true)
                .appendingPathComponent(plugin.id, isDirectory: true)
            let versions = try childDirectoryNames(at: pluginRoot)
            guard versions.count == 1, let version = versions.first, !version.isEmpty else {
                throw CLIError.invalidData("plugin version directory is invalid")
            }
            let pluginJSON = pluginRoot
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent(".codex-plugin/plugin.json")
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: pluginJSON)) as? [String: Any],
                  object["name"] as? String == plugin.id,
                  object["version"] as? String == version else {
                throw CLIError.invalidData("plugin identity does not match its package path")
            }
        }
        return manifest.files.count
    }

    private static func childDirectoryNames(at root: URL) throws -> Set<String> {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var result = Set<String>()
        for child in children {
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CLIError.invalidData("plugin package contains an invalid directory entry")
            }
            result.insert(child.lastPathComponent)
        }
        return result
    }

    private static func chatGPTAuthenticationStatus(home: URL) throws -> Bool {
        let authURL = InstallerPaths(home: home).codexAuth
        guard try ManagedPathPolicy.requireRegularFileIfPresent(
            root: home,
            target: authURL
        ) else {
            return false
        }
        try ManagedPathPolicy.requireRegularFile(root: home, target: authURL)
        guard let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: authURL)
        ) as? [String: Any],
              (object["auth_mode"] as? String)?.lowercased() == "chatgpt",
              let tokens = object["tokens"] as? [String: Any] else {
            return false
        }
        return ["access_token", "id_token", "refresh_token"].contains { key in
            guard let value = tokens[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func canonicalExistingURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw CLIError.invalidData("plugin package root is missing")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func isSafePluginRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return components.first == "marketplaces" || components.first == "cache"
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
