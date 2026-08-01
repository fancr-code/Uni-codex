import CryptoKit
import Foundation

struct InstallExpectation: Codable, Equatable {
    let schemaVersion: Int
    let provider: ProviderKind
    let managedProviderID: String
    let defaultModel: String
    let availableModels: [String]
    let apiKeySHA256: String
    let authenticationMode: AuthenticationMode

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case provider
        case managedProviderID
        case defaultModel
        case availableModels
        case apiKeySHA256
        case authenticationMode
    }

    private init(
        schemaVersion: Int,
        provider: ProviderKind,
        managedProviderID: String,
        defaultModel: String,
        availableModels: [String],
        apiKeySHA256: String,
        authenticationMode: AuthenticationMode
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.managedProviderID = managedProviderID
        self.defaultModel = defaultModel
        self.availableModels = availableModels
        self.apiKeySHA256 = apiKeySHA256
        self.authenticationMode = authenticationMode
    }

    static func make(
        request: InstallRequest,
        managedProviderID: String
    ) throws -> InstallExpectation {
        let apiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = normalizedModels(request.availableModels)
        let defaultModel = request.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard models == request.availableModels,
              defaultModel == request.defaultModel else {
            throw expectationError("install expectation inputs are not normalized")
        }
        let expectation = InstallExpectation(
            schemaVersion: 2,
            provider: request.provider,
            managedProviderID: managedProviderID,
            defaultModel: defaultModel,
            availableModels: models,
            apiKeySHA256: sha256(apiKey),
            authenticationMode: request.authenticationMode
        )
        try expectation.validate()
        return expectation
    }

    static func load(from url: URL) throws -> InstallExpectation {
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any],
              let schemaVersion = object["schemaVersion"] as? Int else {
            throw expectationError("install expectation shape is invalid")
        }
        let versionOneKeys = Set(
            CodingKeys.allCases
                .filter { $0 != .authenticationMode }
                .map(\.rawValue)
        )
        let versionTwoKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard (schemaVersion == 1 && Set(object.keys) == versionOneKeys)
                || (schemaVersion == 2 && Set(object.keys) == versionTwoKeys) else {
            throw expectationError("install expectation shape is invalid")
        }
        let expectation = try JSONDecoder().decode(InstallExpectation.self, from: data)
        try expectation.validate()
        return expectation
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    func validate() throws {
        guard (schemaVersion == 1 || schemaVersion == 2),
              schemaVersion != 1 || authenticationMode == .pureAPI,
              Self.isManagedIdentifier(managedProviderID),
              managedProviderID == Self.providerID(for: provider),
              Self.isSafeText(defaultModel),
              !availableModels.isEmpty,
              availableModels == Self.normalizedModels(availableModels),
              availableModels.contains(defaultModel),
              apiKeySHA256.count == 64,
              apiKeySHA256.allSatisfy({ $0.isHexDigit }),
              apiKeySHA256 == apiKeySHA256.lowercased() else {
            throw Self.expectationError("install expectation is invalid")
        }
    }

    private enum DecodingKeys: String, CodingKey {
        case schemaVersion
        case provider
        case managedProviderID
        case defaultModel
        case availableModels
        case apiKeySHA256
        case authenticationMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        provider = try values.decode(ProviderKind.self, forKey: .provider)
        managedProviderID = try values.decode(String.self, forKey: .managedProviderID)
        defaultModel = try values.decode(String.self, forKey: .defaultModel)
        availableModels = try values.decode([String].self, forKey: .availableModels)
        apiKeySHA256 = try values.decode(String.self, forKey: .apiKeySHA256)
        authenticationMode = try values.decodeIfPresent(
            AuthenticationMode.self,
            forKey: .authenticationMode
        ) ?? .pureAPI
    }

    func matches(apiKey: String) -> Bool {
        Self.sha256(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) == apiKeySHA256
    }

    private static func normalizedModels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeText(normalized), seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func isSafeText(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("|") && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func isManagedIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    private static func expectationError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.InstallExpectation",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

struct ConfigurationVerification: Codable, Equatable {
    let status: String
    let provider: ProviderKind
    let defaultModel: String
    let modelCount: Int
    let authenticationMode: AuthenticationMode
}
