import Foundation

func scriptRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(
            domain: "ScriptMarketTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

func scriptRequireThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw NSError(
            domain: "ScriptMarketTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    } catch let error as NSError where error.domain == "ScriptMarketTests" && error.code == 2 {
        throw error
    } catch {
        return
    }
}

func scriptJSONObject(at url: URL) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let object = value as? [String: Any] else {
        throw NSError(domain: "ScriptMarketTests", code: 3)
    }
    return object
}

func scriptFileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@main
struct ScriptMarketTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ScriptMarketTests", code: 64)
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codex-script-market-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("user_scripts", isDirectory: true)
        let config = root.appendingPathComponent("user_scripts.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("window.manual = true;\n".utf8).write(to: destination.appendingPathComponent("manual.js"))
        try Data("""
        {
          "enabled": false,
          "custom": {"preserve": true},
          "scripts": {
            "user:manual.js": false,
            "user:market-legacy.js": true
          },
          "market": {
            "user:market-legacy.js": {
              "id": "legacy", "name": "Legacy", "version": "0.1.0",
              "script_url": "https://example.com/legacy.js", "homepage": "", "installed_at": "1"
            }
          }
        }
        """.utf8).write(to: config)

        let result = try ScriptMarketInstaller.install(
            snapshot: fixture,
            destination: destination,
            configURL: config
        )
        try scriptRequire(result.installedCount == 6, "every manifest entry installed")
        let state = try scriptJSONObject(at: config)
        let scripts = state["scripts"] as? [String: Bool] ?? [:]
        try scriptRequire(state["enabled"] as? Bool == true, "scripts globally enabled")
        try scriptRequire((state["custom"] as? [String: Any])?["preserve"] as? Bool == true, "unrelated config preserved")
        try scriptRequire(scripts["user:manual.js"] == false, "manual explicit state preserved")
        try scriptRequire(scripts["user:market-codex-zhcn-translate.js"] == true, "Chinese enabled")
        try scriptRequire(scripts["user:market-codex-context-used-meter.js"] == true, "meter enabled")
        try scriptRequire(scripts["user:market-codex-token-usage.js"] == true, "token usage enabled")
        try scriptRequire(scripts["user:market-codex-daily-token-usage.js"] == false, "daily disabled")
        try scriptRequire(scripts["user:market-codex-live-token-cost.js"] == false, "cost disabled")
        try scriptRequire(scripts["user:market-another-script.js"] == false, "other scripts disabled")
        try scriptRequire(scripts["user:market-legacy.js"] == true, "unmanaged market state preserved")
        try scriptRequire(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("market-another-script.js").path
            ),
            "disabled script still installed"
        )
        let configMode = try scriptFileMode(config)
        let scriptMode = try scriptFileMode(destination.appendingPathComponent("market-another-script.js"))
        try scriptRequire(configMode == 0o600, "script config mode 0600")
        try scriptRequire(scriptMode == 0o600, "market script mode 0600")
        let market = state["market"] as? [String: [String: Any]] ?? [:]
        let meter = market["user:market-codex-context-used-meter.js"] ?? [:]
        try scriptRequire(meter["id"] as? String == "codex-context-used-meter", "market ID stored")
        try scriptRequire(meter["version"] as? String == "101", "market version stored")
        try scriptRequire(!(meter["installed_at"] as? String ?? "").isEmpty, "install timestamp stored")

        let idempotent = try ScriptMarketInstaller.install(
            snapshot: fixture,
            destination: destination,
            configURL: config
        )
        try scriptRequire(idempotent.installedCount == 6, "repeat install complete")
        let repeatState = try scriptJSONObject(at: config)
        try scriptRequire((repeatState["scripts"] as? [String: Bool])?["user:manual.js"] == false, "repeat preserves manual state")

        let corruptSnapshot = root.appendingPathComponent("corrupt-snapshot", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: corruptSnapshot)
        let corruptScript = corruptSnapshot.appendingPathComponent("scripts/codex-token-usage.js")
        try Data("window.corrupt = true;\n".utf8).write(to: corruptScript)
        let corruptDestination = root.appendingPathComponent("corrupt-user-scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDestination, withIntermediateDirectories: true)
        let existing = corruptDestination.appendingPathComponent("market-codex-token-usage.js")
        try Data("old-script\n".utf8).write(to: existing)
        let corruptConfig = root.appendingPathComponent("corrupt-user_scripts.json")
        try Data("{\"enabled\":false,\"custom\":true}\n".utf8).write(to: corruptConfig)
        let oldScript = try Data(contentsOf: existing)
        let oldConfig = try Data(contentsOf: corruptConfig)
        try scriptRequireThrows("corrupt checksum rejected") {
            _ = try ScriptMarketInstaller.install(
                snapshot: corruptSnapshot,
                destination: corruptDestination,
                configURL: corruptConfig
            )
        }
        let scriptAfterCorruptAttempt = try Data(contentsOf: existing)
        let configAfterCorruptAttempt = try Data(contentsOf: corruptConfig)
        try scriptRequire(scriptAfterCorruptAttempt == oldScript, "corrupt install preserved destination")
        try scriptRequire(configAfterCorruptAttempt == oldConfig, "corrupt install preserved config")
        try scriptRequire(
            !FileManager.default.fileExists(
                atPath: corruptDestination.appendingPathComponent("market-another-script.js").path
            ),
            "corrupt install created no new script"
        )

        let unsafeSnapshot = root.appendingPathComponent("unsafe-snapshot", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: unsafeSnapshot)
        let unsafeIndex = unsafeSnapshot.appendingPathComponent("index.json")
        var unsafeManifest = try scriptJSONObject(at: unsafeIndex)
        var unsafeScripts = unsafeManifest["scripts"] as? [[String: Any]] ?? []
        unsafeScripts[0]["id"] = "../escape"
        unsafeManifest["scripts"] = unsafeScripts
        var unsafeData = try JSONSerialization.data(withJSONObject: unsafeManifest, options: [.prettyPrinted])
        unsafeData.append(0x0A)
        try unsafeData.write(to: unsafeIndex)
        let unsafeDestination = root.appendingPathComponent("unsafe-destination", isDirectory: true)
        try scriptRequireThrows("path separators rejected") {
            _ = try ScriptMarketInstaller.install(
                snapshot: unsafeSnapshot,
                destination: unsafeDestination,
                configURL: root.appendingPathComponent("unsafe-config.json")
            )
        }
        try scriptRequire(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.js").path),
            "unsafe ID did not escape destination"
        )

        print("script-market-tests: PASS")
    }
}
