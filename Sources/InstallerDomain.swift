import Foundation

enum HardwareArchitecture: String, Codable {
    case arm64
    case x86_64

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        testMode: Bool = false
    ) -> Self {
        if testMode, let override = environment["REAL_ARCH_OVERRIDE"], let architecture = Self(rawValue: override) {
            return architecture
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "hw.optional.arm64"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && value == "1" ? .arm64 : .x86_64
        } catch {
            return .x86_64
        }
    }
}

enum ProviderKind: String, Codable, CaseIterable {
    case deepSeek = "deepseek"
    case kimiOpen = "kimi-open"
    case kimiCode = "kimi-code"
    case zhipu
    case qwen
    case xiaomiMiMo = "xiaomi-mimo"

    var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .kimiOpen: "Kimi 开放平台"
        case .kimiCode: "Kimi Code 会员"
        case .zhipu: "智谱 GLM"
        case .qwen: "阿里千问"
        case .xiaomiMiMo: "小米 MiMo"
        }
    }

    var defaultBaseURL: URL {
        switch self {
        case .deepSeek: URL(string: "https://api.deepseek.com")!
        case .kimiOpen: URL(string: "https://api.moonshot.cn/v1")!
        case .kimiCode: URL(string: "https://api.kimi.com/coding/v1")!
        case .zhipu: URL(string: "https://open.bigmodel.cn/api/paas/v4")!
        case .qwen: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        case .xiaomiMiMo: URL(string: "https://api.xiaomimimo.com/v1")!
        }
    }

    var modelsURL: URL {
        switch self {
        case .deepSeek: URL(string: "https://api.deepseek.com/models")!
        case .kimiOpen: URL(string: "https://api.moonshot.cn/v1/models")!
        case .kimiCode: URL(string: "https://api.kimi.com/coding/v1/models")!
        case .zhipu: URL(string: "https://open.bigmodel.cn/api/paas/v4/models")!
        case .qwen: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/models")!
        case .xiaomiMiMo: URL(string: "https://api.xiaomimimo.com/v1/models")!
        }
    }

    var applyURL: URL {
        switch self {
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .kimiOpen: URL(string: "https://platform.moonshot.cn/console/api-keys")!
        case .kimiCode: URL(string: "https://www.kimi.com/code/console")!
        case .zhipu: URL(string: "https://bigmodel.cn/usercenter/apikeys")!
        case .qwen: URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=model")!
        case .xiaomiMiMo: URL(string: "https://platform.xiaomimimo.com/")!
        }
    }
}

enum ModelSource: String, Codable {
    case offlineSnapshot
    case upstreamRefresh
}

enum AuthenticationMode: String, Codable {
    case openAIAccountWithAPI
    case pureAPI

    var displayName: String {
        switch self {
        case .openAIAccountWithAPI:
            "OpenAI 账号 + API（推荐）"
        case .pureAPI:
            "纯 API 模式"
        }
    }
}

struct ModelDefinition: Codable, Equatable {
    let id: String
    let displayName: String
    let contextWindow: Int?
}

struct ProviderDefinition: Codable, Equatable {
    let kind: ProviderKind
    let protocolName: String
    let models: [ModelDefinition]
}

struct InstallRequest: Codable, Equatable {
    let provider: ProviderKind
    let apiKey: String
    let defaultModel: String
    let availableModels: [String]
    let modelSource: ModelSource
    let authenticationMode: AuthenticationMode

    init(
        provider: ProviderKind,
        apiKey: String,
        defaultModel: String,
        availableModels: [String],
        modelSource: ModelSource = .offlineSnapshot,
        authenticationMode: AuthenticationMode = .pureAPI
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.availableModels = availableModels
        self.modelSource = modelSource
        self.authenticationMode = authenticationMode
    }

    private enum CodingKeys: String, CodingKey {
        case provider, apiKey, defaultModel, availableModels, modelSource, authenticationMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(ProviderKind.self, forKey: .provider)
        apiKey = try values.decode(String.self, forKey: .apiKey)
        defaultModel = try values.decode(String.self, forKey: .defaultModel)
        availableModels = try values.decode([String].self, forKey: .availableModels)
        modelSource = try values.decodeIfPresent(ModelSource.self, forKey: .modelSource) ?? .offlineSnapshot
        authenticationMode = try values.decodeIfPresent(
            AuthenticationMode.self,
            forKey: .authenticationMode
        ) ?? .pureAPI
    }
}

enum PayloadFormat: String, Codable {
    case dmg
    case directory
    case archive
    case file
}

enum AppPayloadComponent: String, Codable {
    case chatgpt
    case codexPlusPlus = "codex-plus-plus"
}

struct PayloadFile: Codable, Equatable {
    let id: String
    let version: String
    let architecture: String
    let relativePath: String
    let sha256: String
    let sourceURL: String
    let format: PayloadFormat
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let compatibilityRevision: String?
    let licenseID: String?
}

struct PayloadManifest: Codable, Equatable {
    static let requiredCodexPlusCompatibilityRevision = "cross-provider-content-v1"

    let schemaVersion: Int
    let generatedAt: String
    let files: [PayloadFile]

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func resolveAppPayload(
        component: AppPayloadComponent,
        architecture: HardwareArchitecture
    ) throws -> PayloadFile {
        let candidates: [PayloadFile]
        switch component {
        case .chatgpt:
            candidates = files.filter {
                $0.id == "chatgpt-codex" || $0.id.hasPrefix("chatgpt-codex-")
            }
        case .codexPlusPlus:
            candidates = files.filter {
                $0.id.hasPrefix("codex-plus-plus-") && $0.id != "codex-plus-plus-source"
            }
        }

        let exact = candidates.filter { $0.architecture == architecture.rawValue }
        if exact.count == 1 {
            return exact[0]
        }
        if component == .chatgpt {
            let universal = candidates.filter { $0.architecture == "universal" }
            if universal.count == 1 {
                return universal[0]
            }
        }
        throw validationError("unable to resolve a unique \(component.rawValue) payload for \(architecture.rawValue)")
    }

    func validateRequiredPayloads(testMode: Bool = false) throws {
        guard schemaVersion == 1 else {
            throw validationError("unsupported schema version")
        }
        guard !generatedAt.isEmpty else {
            throw validationError("missing generation time")
        }

        var seenIDs = Set<String>()
        for file in files {
            guard !file.id.isEmpty, seenIDs.insert(file.id).inserted else {
                throw validationError("payload IDs must be unique and non-empty")
            }
            guard !file.version.isEmpty else {
                throw validationError("payload \(file.id) has no version")
            }
            guard file.sha256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
                throw validationError("payload \(file.id) has an invalid SHA-256")
            }
            guard !file.relativePath.hasPrefix("/"), !file.relativePath.split(separator: "/").contains("..") else {
                throw validationError("payload \(file.id) has an unsafe relative path")
            }
            guard let sourceURL = URL(string: file.sourceURL), sourceURL.scheme == "https" else {
                throw validationError("payload \(file.id) has an invalid source URL")
            }
        }

        let chatGPT = files.filter { $0.id == "chatgpt-codex" || $0.id.hasPrefix("chatgpt-codex-") }
        let chatGPTArchitectures = Set(chatGPT.map(\.architecture))
        guard chatGPTArchitectures.contains("universal")
                || chatGPTArchitectures.isSuperset(of: ["arm64", "x86_64"]) else {
            throw validationError("ChatGPT/Codex must cover arm64 and x86_64")
        }

        let codexPlusArchitectures = Set(
            files.filter { $0.id.hasPrefix("codex-plus-plus-") && $0.id != "codex-plus-plus-source" }
                .map(\.architecture)
        )
        guard codexPlusArchitectures.isSuperset(of: ["arm64", "x86_64"]) else {
            throw validationError("Codex++ must cover arm64 and x86_64")
        }

        for requiredID in ["plugin-marketplaces", "script-market", "codex-plus-plus-source"] {
            guard files.contains(where: { $0.id == requiredID }) else {
                throw validationError("missing required payload \(requiredID)")
            }
        }

        if !testMode {
            guard chatGPT.allSatisfy({ $0.format == .dmg }) else {
                throw validationError("production ChatGPT/Codex payloads must be DMGs")
            }
            let codexPlusApps = files.filter {
                $0.id.hasPrefix("codex-plus-plus-") && $0.id != "codex-plus-plus-source"
            }
            guard codexPlusApps.allSatisfy({ $0.format == .dmg }) else {
                throw validationError("production Codex++ payloads must be DMGs")
            }
            let codexPlusPayloads = files.filter {
                $0.id == "codex-plus-plus-source"
                    || $0.id == "codex-plus-plus-arm64"
                    || $0.id == "codex-plus-plus-x86_64"
            }
            guard codexPlusPayloads.count == 3,
                  codexPlusPayloads.allSatisfy({
                      $0.compatibilityRevision == Self.requiredCodexPlusCompatibilityRevision
                  }) else {
                throw validationError(
                    "production Codex++ payloads must carry compatibility revision "
                        + Self.requiredCodexPlusCompatibilityRevision
                )
            }
            guard Set(codexPlusPayloads.map(\.version)).count == 1 else {
                throw validationError("production Codex++ payload versions must match")
            }
        }
    }

    private func validationError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.PayloadManifest",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
