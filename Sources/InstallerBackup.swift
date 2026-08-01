import Foundation

struct BackupEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case directory
    }

    let key: String
    let kind: Kind
    let existed: Bool
    let backupRelativePath: String?

    private enum CodingKeys: String, CodingKey {
        case key
        case kind
        case existed
        case backupRelativePath
    }

    init(key: String, kind: Kind, existed: Bool, backupRelativePath: String?) {
        self.key = key
        self.kind = kind
        self.existed = existed
        self.backupRelativePath = backupRelativePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        kind = try container.decode(Kind.self, forKey: .kind)
        existed = try container.decode(Bool.self, forKey: .existed)
        backupRelativePath = try container.decodeIfPresent(String.self, forKey: .backupRelativePath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(kind, forKey: .kind)
        try container.encode(existed, forKey: .existed)
        if let backupRelativePath {
            try container.encode(backupRelativePath, forKey: .backupRelativePath)
        } else {
            try container.encodeNil(forKey: .backupRelativePath)
        }
    }
}

struct BackupInventory: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: String
    let entries: [BackupEntry]
}

enum InstallerBackup {
    private struct CompleteBackupExpectation {
        let kind: BackupEntry.Kind
        let relativePath: String
    }

    private struct ConfigurationTarget {
        let key: String
        let target: URL
        let backupRelativePath: String
    }

    private struct ConfigurationRestoreEntry {
        let target: URL
        let source: URL?
    }

    static func makeIdentifier(date: Date = Date(), uuid: UUID = UUID()) -> String {
        let microseconds = Int64(date.timeIntervalSince1970 * 1_000_000)
        return String(format: "%020lld-%@", microseconds, uuid.uuidString.lowercased())
    }

    static func buildCompleteInventory(createdAt: String, entriesData: Data) throws -> Data {
        guard !createdAt.isEmpty,
              !createdAt.contains("\n"),
              !createdAt.contains("\r"),
              entriesData.count <= 1_048_576,
              let input = String(data: entriesData, encoding: .utf8) else {
            throw backupError("complete backup inventory input is invalid")
        }
        var lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty, lines.allSatisfy({ !$0.isEmpty }) else {
            throw backupError("complete backup inventory input is empty")
        }
        let entries = try lines.map { try decodeEntry(Data($0.utf8)) }
        let inventory = BackupInventory(schemaVersion: 2, createdAt: createdAt, entries: entries)
        _ = try validateCompleteInventory(inventory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(inventory)
        data.append(0x0A)
        return data
    }

    static func validateCompleteInventory(at inventoryURL: URL) throws -> [BackupEntry] {
        try validateCompleteInventory(decodeInventory(Data(contentsOf: inventoryURL)))
    }

    static func snapshotConfiguration(root: URL, backup: URL) throws {
        let paths = InstallerPaths(home: root)
        try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.home)
        try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.backupRoot)
        try requireBackupContained(backup, paths: paths, mustExist: false)

        let targets = configurationTargets(paths: paths)
        var existence: [String: Bool] = [:]
        for target in targets {
            existence[target.key] = try ManagedPathPolicy.requireRegularFileIfPresent(
                root: paths.home,
                target: target.target
            )
        }

        try ManagedPathPolicy.ensurePrivateDirectory(root: paths.backupRoot, directory: backup)
        let files = backup.appendingPathComponent("files", isDirectory: true)
        try ManagedPathPolicy.ensurePrivateDirectory(root: backup, directory: files)

        var entries: [BackupEntry] = []
        for target in targets {
            let existed = existence[target.key] == true
            if existed {
                let copy = try backupSource(backup: backup, relativePath: target.backupRelativePath)
                guard try !ManagedPathPolicy.requireRegularFileIfPresent(root: backup, target: copy) else {
                    throw backupError("backup target already exists")
                }
                try ManagedPathPolicy.requireRegularFile(root: paths.home, target: target.target)
                try FileManager.default.copyItem(at: target.target, to: copy)
                try ManagedPathPolicy.requireRegularFile(root: backup, target: copy)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                let handle = try FileHandle(forWritingTo: copy)
                try handle.synchronize()
                try handle.close()
            }
            entries.append(
                BackupEntry(
                    key: target.key,
                    kind: .file,
                    existed: existed,
                    backupRelativePath: existed ? target.backupRelativePath : nil
                )
            )
        }

        let inventory = BackupInventory(
            schemaVersion: 2,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            entries: entries
        )
        let data = try JSONEncoder().encode(inventory)
        try atomicWrite(
            data,
            root: backup,
            to: backup.appendingPathComponent("inventory.json"),
            permissions: 0o600
        )
    }

    static func restoreConfiguration(root: URL, backup: URL) throws {
        let entries = try validatedConfigurationRestoreEntries(root: root, backup: backup)
        for entry in entries {
            if let source = entry.source {
                let data = try Data(contentsOf: source)
                try atomicWrite(data, root: root, to: entry.target, permissions: 0o600)
            } else if try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: entry.target) {
                try ManagedPathPolicy.requireRegularFile(root: root, target: entry.target)
                try FileManager.default.removeItem(at: entry.target)
            }
        }
    }

    static func validateConfiguration(root: URL, backup: URL) throws {
        _ = try validatedConfigurationRestoreEntries(root: root, backup: backup)
    }

    private static func validatedConfigurationRestoreEntries(
        root: URL,
        backup: URL
    ) throws -> [ConfigurationRestoreEntry] {
        let paths = InstallerPaths(home: root)
        try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.home)
        try ManagedPathPolicy.requireDirectory(root: paths.home, target: paths.backupRoot)
        try requireBackupContained(backup, paths: paths, mustExist: true)

        let inventoryURL = backup.appendingPathComponent("inventory.json")
        try ManagedPathPolicy.requireRegularFile(root: backup, target: inventoryURL)
        let inventory = try decodeInventory(Data(contentsOf: inventoryURL))
        guard inventory.schemaVersion == 2 else {
            throw backupError("unsupported backup inventory")
        }

        let targets = configurationTargets(paths: paths)
        let targetsByKey = Dictionary(uniqueKeysWithValues: targets.map { ($0.key, $0) })
        guard inventory.entries.count == targets.count,
              Set(inventory.entries.map(\.key)).count == inventory.entries.count,
              Set(inventory.entries.map(\.key)) == Set(targetsByKey.keys) else {
            throw backupError("backup inventory keys are invalid")
        }

        var sources: [String: URL] = [:]
        for entry in inventory.entries {
            guard let target = targetsByKey[entry.key], entry.kind == .file else {
                throw backupError("backup inventory kind is invalid")
            }
            _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: paths.home, target: target.target)
            if entry.existed {
                guard let relative = entry.backupRelativePath,
                      relative == target.backupRelativePath else {
                    throw backupError("backup relative path is invalid")
                }
                let source = try backupSource(backup: backup, relativePath: relative)
                try ManagedPathPolicy.requireRegularFile(root: backup, target: source)
                sources[entry.key] = source
            } else if entry.backupRelativePath != nil {
                throw backupError("absent backup entry contains a source path")
            }
        }

        return try inventory.entries.map { entry in
            guard let target = targetsByKey[entry.key] else {
                throw backupError("backup inventory key is invalid")
            }
            if entry.existed {
                guard let source = sources[entry.key] else {
                    throw backupError("backup source is missing")
                }
                return ConfigurationRestoreEntry(target: target.target, source: source)
            }
            return ConfigurationRestoreEntry(target: target.target, source: nil)
        }
    }

    static func decodeInventory(_ data: Data) throws -> BackupInventory {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "createdAt", "entries"]),
              let rawEntries = object["entries"] as? [[String: Any]],
              rawEntries.allSatisfy({
                  Set($0.keys) == Set(["key", "kind", "existed", "backupRelativePath"])
              }) else {
            throw backupError("backup inventory shape is invalid")
        }
        return try JSONDecoder().decode(BackupInventory.self, from: data)
    }

    private static func decodeEntry(_ data: Data) throws -> BackupEntry {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any],
              Set(object.keys) == Set(["key", "kind", "existed", "backupRelativePath"]) else {
            throw backupError("complete backup entry shape is invalid")
        }
        return try JSONDecoder().decode(BackupEntry.self, from: data)
    }

    private static func validateCompleteInventory(
        _ inventory: BackupInventory
    ) throws -> [BackupEntry] {
        let expected = completeBackupExpectations
        let keys = inventory.entries.map(\.key)
        guard inventory.schemaVersion == 2,
              !inventory.createdAt.isEmpty,
              !inventory.createdAt.contains("\n"),
              !inventory.createdAt.contains("\r"),
              inventory.entries.count >= expected.count,
              Set(keys).count == keys.count,
              Set(expected.keys).isSubset(of: Set(keys)) else {
            throw backupError("complete backup inventory header or keys are invalid")
        }

        for entry in inventory.entries {
            if let expectation = expected[entry.key] {
                guard entry.kind == expectation.kind,
                      entry.backupRelativePath == (entry.existed ? expectation.relativePath : nil) else {
                    throw backupError("complete backup entry does not match its managed key")
                }
                continue
            }

            let prefix = "script.file."
            guard entry.key.hasPrefix(prefix) else {
                throw backupError("complete backup inventory contains an unknown key")
            }
            let name = String(entry.key.dropFirst(prefix.count))
            guard isValidMarketScriptName(name),
                  entry.kind == .file,
                  entry.backupRelativePath == (
                    entry.existed ? "scripts/user_scripts/\(name)" : nil
                  ) else {
                throw backupError("complete backup market script entry is invalid")
            }
        }
        return inventory.entries
    }

    private static var completeBackupExpectations: [String: CompleteBackupExpectation] {
        [
            "app.chatgpt": .init(kind: .directory, relativePath: "applications/ChatGPT.app"),
            "app.codex-plus-plus": .init(kind: .directory, relativePath: "applications/Codex++.app"),
            "app.codex-plus-plus-manager": .init(kind: .directory, relativePath: "applications/Codex++ manager.app"),
            "marketplace.openai-bundled": .init(kind: .directory, relativePath: "managed/marketplace-openai-bundled"),
            "marketplace.openai-primary-runtime": .init(kind: .directory, relativePath: "managed/marketplace-openai-primary-runtime"),
            "marketplace.openai-curated": .init(kind: .directory, relativePath: "managed/marketplace-openai-curated"),
            "plugin.openai-bundled.browser": .init(kind: .directory, relativePath: "managed/plugin-openai-bundled-browser"),
            "plugin.openai-bundled.chrome": .init(kind: .directory, relativePath: "managed/plugin-openai-bundled-chrome"),
            "plugin.openai-bundled.computer-use": .init(kind: .directory, relativePath: "managed/plugin-openai-bundled-computer-use"),
            "plugin.openai-bundled.latex": .init(kind: .directory, relativePath: "managed/plugin-openai-bundled-latex"),
            "plugin.openai-primary-runtime.pdf": .init(kind: .directory, relativePath: "managed/plugin-openai-primary-runtime-pdf"),
            "plugin.openai-primary-runtime.documents": .init(kind: .directory, relativePath: "managed/plugin-openai-primary-runtime-documents"),
            "plugin.openai-primary-runtime.spreadsheets": .init(kind: .directory, relativePath: "managed/plugin-openai-primary-runtime-spreadsheets"),
            "plugin.openai-primary-runtime.presentations": .init(kind: .directory, relativePath: "managed/plugin-openai-primary-runtime-presentations"),
            "plugin.openai-curated.github": .init(kind: .directory, relativePath: "managed/plugin-openai-curated-github"),
            "script.config": .init(kind: .file, relativePath: "scripts/user_scripts.json"),
            "script.file.market-codex-zhcn-translate.js": .init(kind: .file, relativePath: "scripts/user_scripts/market-codex-zhcn-translate.js"),
            "script.file.market-codex-context-used-meter.js": .init(kind: .file, relativePath: "scripts/user_scripts/market-codex-context-used-meter.js"),
            "script.file.market-another-script.js": .init(kind: .file, relativePath: "scripts/user_scripts/market-another-script.js")
        ]
    }

    private static func isValidMarketScriptName(_ name: String) -> Bool {
        guard name.hasPrefix("market-"), name.hasSuffix(".js") else { return false }
        let start = name.index(name.startIndex, offsetBy: "market-".count)
        let end = name.index(name.endIndex, offsetBy: -".js".count)
        let identifier = name[start..<end]
        guard let first = identifier.unicodeScalars.first, isASCIIAlphaNumeric(first) else {
            return false
        }
        return identifier.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\\"),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\0") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func configurationTargets(paths: InstallerPaths) -> [ConfigurationTarget] {
        [
            ConfigurationTarget(
                key: "config.codex",
                target: paths.codexConfig,
                backupRelativePath: "files/codex-config.toml"
            ),
            ConfigurationTarget(
                key: "config.codex-auth",
                target: paths.codexAuth,
                backupRelativePath: "files/codex-auth.json"
            ),
            ConfigurationTarget(
                key: "config.codex-plus-settings",
                target: paths.codexPlusSettings,
                backupRelativePath: "files/codex-plus-settings.json"
            ),
            ConfigurationTarget(
                key: "config.install-expectation",
                target: paths.installExpectation,
                backupRelativePath: "files/install-expectation.json"
            )
        ]
    }

    private static func requireBackupContained(
        _ backup: URL,
        paths: InstallerPaths,
        mustExist: Bool
    ) throws {
        let rootPath = try ManagedPathPolicy.lexicalPath(paths.backupRoot)
        let backupPath = try ManagedPathPolicy.lexicalPath(backup)
        guard backupPath.hasPrefix(rootPath + "/") else {
            throw backupError("backup path escapes the backup root")
        }
        if mustExist {
            try ManagedPathPolicy.requireDirectory(root: paths.backupRoot, target: backup)
        } else {
            guard try !ManagedPathPolicy.requireDirectoryIfPresent(root: paths.backupRoot, target: backup) else {
                throw backupError("backup directory already exists")
            }
        }
    }

    private static func backupSource(backup: URL, relativePath: String) throws -> URL {
        guard isSafeRelativePath(relativePath) else {
            throw backupError("backup relative path is unsafe")
        }
        return backup.appendingPathComponent(relativePath)
    }

    private static func atomicWrite(_ data: Data, root: URL, to url: URL, permissions: Int) throws {
        let parent = url.deletingLastPathComponent()
        try ManagedPathPolicy.ensurePrivateDirectory(root: root, directory: parent)
        _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url)
        let temporary = parent.appendingPathComponent(".codex-one-click-\(UUID().uuidString).tmp")
        guard try !ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: temporary),
              FileManager.default.createFile(atPath: temporary.path, contents: data) else {
            throw backupError("failed to create backup inventory")
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
    }

    private static func backupError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.Backup",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
