import CryptoKit
import Foundation

struct ScriptMarketInstallResult: Codable, Equatable {
    let installedCount: Int
    let installedFiles: [String]
}

enum ScriptMarketInstaller {
    private struct Manifest: Decodable {
        let version: Int
        let scripts: [Script]
    }

    private struct Script: Decodable {
        let id: String
        let name: String
        let version: String
        let homepage: String?
        let scriptURL: String
        let sha256: String

        private enum CodingKeys: String, CodingKey {
            case id, name, version, homepage, sha256
            case scriptURL = "script_url"
        }
    }

    private struct ValidatedScript {
        let metadata: Script
        let data: Data
        let filename: String
    }

    private struct OriginalFile {
        let data: Data?
        let permissions: Int
    }

    private static let enabledByDefault = Set([
        "codex-zhcn-translate",
        "codex-context-used-meter",
        "codex-token-usage"
    ])

    static func install(
        snapshot: URL,
        destination: URL,
        configURL: URL
    ) throws -> ScriptMarketInstallResult {
        let fileManager = FileManager.default
        let managedRoot = configURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try ManagedPathPolicy.requireDirectory(root: managedRoot, target: managedRoot)
        try ManagedPathPolicy.requireSafeAncestors(root: managedRoot, target: destination)
        try ManagedPathPolicy.requireSafeAncestors(root: managedRoot, target: configURL)
        try ManagedPathPolicy.requireDirectory(root: snapshot, target: snapshot)
        let indexURL = snapshot.appendingPathComponent("index.json")
        try ManagedPathPolicy.requireRegularFile(root: snapshot, target: indexURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: indexURL))
        guard manifest.version >= 1, !manifest.scripts.isEmpty else {
            throw installError("script market manifest is empty or unsupported")
        }

        var seenIDs = Set<String>()
        var validated: [ValidatedScript] = []
        for script in manifest.scripts {
            guard isSafeScriptID(script.id),
                  seenIDs.insert(script.id).inserted,
                  !script.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !script.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !script.scriptURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  script.sha256.count == 64,
                  script.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw installError("script market entry is invalid")
            }
            let source = snapshot
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent("\(script.id).js")
            try ManagedPathPolicy.requireRegularFile(root: snapshot, target: source)
            let data = try Data(contentsOf: source)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == script.sha256.lowercased() else {
                throw installError("script market payload hash mismatch")
            }
            validated.append(
                ValidatedScript(
                    metadata: script,
                    data: data,
                    filename: "market-\(script.id).js"
                )
            )
        }

        var config = try readConfig(configURL, root: managedRoot)
        var scriptStates = try objectField(config, key: "scripts")
        var marketState = try objectField(config, key: "market")
        let installedAt = String(Int(Date().timeIntervalSince1970))
        for entry in validated {
            let script = entry.metadata
            let key = "user:\(entry.filename)"
            scriptStates[key] = enabledByDefault.contains(script.id)
            marketState[key] = [
                "id": script.id,
                "name": script.name,
                "version": script.version,
                "script_url": script.scriptURL,
                "homepage": script.homepage ?? "",
                "installed_at": installedAt
            ]
        }
        config["enabled"] = true
        config["scripts"] = scriptStates
        config["market"] = marketState
        let configData = try encodedJSONObject(config)

        let destinationExisted = try ManagedPathPolicy.requireDirectoryIfPresent(
            root: managedRoot,
            target: destination
        )
        try ManagedPathPolicy.ensurePrivateDirectory(root: managedRoot, directory: destination)

        var targets: [(URL, Data, Int)] = validated.map {
            (destination.appendingPathComponent($0.filename), $0.data, 0o600)
        }
        targets.append((configURL, configData, 0o600))
        var originals: [String: OriginalFile] = [:]
        do {
            for (target, _, _) in targets {
                if try ManagedPathPolicy.requireRegularFileIfPresent(root: managedRoot, target: target) {
                    try ManagedPathPolicy.requireRegularFile(root: managedRoot, target: target)
                    let attributes = try fileManager.attributesOfItem(atPath: target.path)
                    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
                    originals[target.path] = OriginalFile(
                        data: try Data(contentsOf: target),
                        permissions: permissions
                    )
                } else {
                    originals[target.path] = OriginalFile(data: nil, permissions: 0o600)
                }
            }
            for (target, data, permissions) in targets {
                try atomicWrite(data, root: managedRoot, to: target, permissions: permissions)
            }
        } catch {
            for (target, _, _) in targets.reversed() {
                guard let original = originals[target.path] else { continue }
                if let data = original.data {
                    try? atomicWrite(data, root: managedRoot, to: target, permissions: original.permissions)
                } else if (try? ManagedPathPolicy.requireRegularFileIfPresent(root: managedRoot, target: target)) == true {
                    try? fileManager.removeItem(at: target)
                }
            }
            if !destinationExisted,
               (try? ManagedPathPolicy.requireDirectory(root: managedRoot, target: destination)) != nil,
               (try? fileManager.contentsOfDirectory(atPath: destination.path).isEmpty) == true {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }

        return ScriptMarketInstallResult(
            installedCount: validated.count,
            installedFiles: validated.map(\.filename)
        )
    }

    private static func readConfig(_ url: URL, root: URL) throws -> [String: Any] {
        guard try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url) else { return [:] }
        try ManagedPathPolicy.requireRegularFile(root: root, target: url)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? [String: Any] else {
            throw installError("user script configuration root must be an object")
        }
        return object
    }

    private static func objectField(_ object: [String: Any], key: String) throws -> [String: Any] {
        guard let value = object[key] else { return [:] }
        guard let typed = value as? [String: Any] else {
            throw installError("user script configuration field \(key) must be an object")
        }
        return typed
    }

    private static func encodedJSONObject(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw installError("user script configuration contains an invalid value")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    private static func isSafeScriptID(_ id: String) -> Bool {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func atomicWrite(_ data: Data, root: URL, to url: URL, permissions: Int) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try ManagedPathPolicy.ensurePrivateDirectory(root: root, directory: parent)
        _ = try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url)
        let temporary = parent.appendingPathComponent(".codex-one-click-script-\(UUID().uuidString).tmp")
        guard try !ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: temporary) else {
            throw installError("temporary script market file already exists")
        }
        guard fileManager.createFile(atPath: temporary.path, contents: data) else {
            throw installError("failed to stage script market file")
        }
        defer {
            if (try? ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: temporary)) == true {
                try? fileManager.removeItem(at: temporary)
            }
        }
        try ManagedPathPolicy.requireRegularFile(root: root, target: temporary)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if try ManagedPathPolicy.requireRegularFileIfPresent(root: root, target: url) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        try ManagedPathPolicy.requireRegularFile(root: root, target: url)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func installError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.ScriptMarket",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
