import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(
            domain: "InstallerDomainTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

func requireThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw NSError(
            domain: "InstallerDomainTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    } catch let error as NSError where error.domain == "InstallerDomainTests" && error.code == 2 {
        throw error
    } catch {
        return
    }
}

@main
struct InstallerDomainTests {
    static func main() throws {
        try require(
            HardwareArchitecture.detect(
                environment: ["REAL_ARCH_OVERRIDE": "arm64"],
                testMode: true
            ) == .arm64,
            "arm64 test override"
        )
        try require(
            HardwareArchitecture.detect(
                environment: ["REAL_ARCH_OVERRIDE": "x86_64"],
                testMode: true
            ) == .x86_64,
            "x86_64 test override"
        )

        try require(
            ProviderKind.deepSeek.defaultBaseURL.absoluteString == "https://api.deepseek.com",
            "DeepSeek base URL"
        )
        try require(
            ProviderKind.deepSeek.applyURL.absoluteString == "https://platform.deepseek.com/api_keys",
            "DeepSeek API application URL"
        )
        try require(
            ProviderKind.kimiOpen.defaultBaseURL.absoluteString == "https://api.moonshot.cn/v1",
            "Kimi Open base URL"
        )
        try require(
            ProviderKind.kimiOpen.applyURL.absoluteString == "https://platform.moonshot.cn/console/api-keys",
            "Kimi Open API application URL"
        )
        try require(
            ProviderKind.kimiCode.defaultBaseURL.absoluteString == "https://api.kimi.com/coding/v1",
            "Kimi Code base URL"
        )
        try require(
            ProviderKind.kimiCode.applyURL.absoluteString == "https://www.kimi.com/code/console",
            "Kimi Code application URL"
        )
        let newProviderContracts: [(ProviderKind, String, String, String, String)] = [
            (
                .zhipu,
                "zhipu",
                "https://open.bigmodel.cn/api/paas/v4",
                "https://open.bigmodel.cn/api/paas/v4/models",
                "https://bigmodel.cn/usercenter/apikeys"
            ),
            (
                .qwen,
                "qwen",
                "https://dashscope.aliyuncs.com/compatible-mode/v1",
                "https://dashscope.aliyuncs.com/compatible-mode/v1/models",
                "https://bailian.console.aliyun.com/cn-beijing?tab=model"
            ),
            (
                .xiaomiMiMo,
                "xiaomi-mimo",
                "https://api.xiaomimimo.com/v1",
                "https://api.xiaomimimo.com/v1/models",
                "https://platform.xiaomimimo.com/"
            )
        ]
        for (provider, raw, base, models, apply) in newProviderContracts {
            try require(provider.rawValue == raw, "\(raw) raw value")
            try require(provider.defaultBaseURL.absoluteString == base, "\(raw) base URL")
            try require(provider.modelsURL.absoluteString == models, "\(raw) models URL")
            try require(provider.applyURL.absoluteString == apply, "\(raw) application URL")
            let json = try JSONEncoder().encode(provider)
            try require(String(decoding: json, as: UTF8.self) == "\"\(raw)\"", "\(raw) JSON")
        }

        let request = InstallRequest(
            provider: .kimiCode,
            apiKey: "secret-value",
            defaultModel: "k3",
            availableModels: ["k3"]
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(InstallRequest.self, from: requestData)
        try require(decodedRequest == request, "request round trip")

        let files = [
            PayloadFile(
                id: "chatgpt-codex",
                version: "1.0",
                architecture: "universal",
                relativePath: "apps/ChatGPT",
                sha256: String(repeating: "a", count: 64),
                sourceURL: "https://example.invalid/ChatGPT.dmg",
                format: .directory,
                bundleIdentifier: "com.openai.codex",
                teamIdentifier: "2DC432GLL2",
                compatibilityRevision: nil,
                licenseID: nil
            ),
            PayloadFile(
                id: "codex-plus-plus-arm64",
                version: "1.0",
                architecture: "arm64",
                relativePath: "apps/CodexPlusPlus-arm64",
                sha256: String(repeating: "b", count: 64),
                sourceURL: "https://example.invalid/CodexPlusPlus-arm64.dmg",
                format: .directory,
                bundleIdentifier: nil,
                teamIdentifier: nil,
                compatibilityRevision: "cross-provider-content-v1",
                licenseID: "AGPL-3.0-only"
            ),
            PayloadFile(
                id: "codex-plus-plus-x86_64",
                version: "1.0",
                architecture: "x86_64",
                relativePath: "apps/CodexPlusPlus-x86_64",
                sha256: String(repeating: "c", count: 64),
                sourceURL: "https://example.invalid/CodexPlusPlus-x64.dmg",
                format: .directory,
                bundleIdentifier: nil,
                teamIdentifier: nil,
                compatibilityRevision: "cross-provider-content-v1",
                licenseID: "AGPL-3.0-only"
            ),
            PayloadFile(
                id: "plugin-marketplaces",
                version: "2026-07-21",
                architecture: "any",
                relativePath: "plugins",
                sha256: String(repeating: "d", count: 64),
                sourceURL: "https://example.invalid/plugins",
                format: .directory,
                bundleIdentifier: nil,
                teamIdentifier: nil,
                compatibilityRevision: nil,
                licenseID: nil
            ),
            PayloadFile(
                id: "script-market",
                version: "2026-07-21",
                architecture: "any",
                relativePath: "scripts",
                sha256: String(repeating: "e", count: 64),
                sourceURL: "https://example.invalid/scripts",
                format: .directory,
                bundleIdentifier: nil,
                teamIdentifier: nil,
                compatibilityRevision: nil,
                licenseID: nil
            ),
            PayloadFile(
                id: "codex-plus-plus-source",
                version: "1.0",
                architecture: "source",
                relativePath: "sources/CodexPlusPlus.tar.gz",
                sha256: String(repeating: "f", count: 64),
                sourceURL: "https://example.invalid/source.tar.gz",
                format: .archive,
                bundleIdentifier: nil,
                teamIdentifier: nil,
                compatibilityRevision: "cross-provider-content-v1",
                licenseID: "AGPL-3.0-only"
            )
        ]

        let manifest = PayloadManifest(
            schemaVersion: 1,
            generatedAt: "2026-07-21T00:00:00Z",
            files: files
        )
        try manifest.validateRequiredPayloads(testMode: true)
        try requireThrows("directory app payload rejected outside test mode") {
            try manifest.validateRequiredPayloads()
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let manifestURL = temporaryDirectory.appendingPathComponent("payload-manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let decodedManifest = try PayloadManifest.load(from: manifestURL)
        try require(decodedManifest == manifest, "manifest round trip")

        let incomplete = PayloadManifest(
            schemaVersion: 1,
            generatedAt: manifest.generatedAt,
            files: Array(files.dropLast())
        )
        try requireThrows("source archive required") {
            try incomplete.validateRequiredPayloads(testMode: true)
        }

        print("installer-domain-tests: PASS")
    }
}
