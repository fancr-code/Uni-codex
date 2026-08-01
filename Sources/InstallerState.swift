import Foundation

enum InstallerPhase: Equatable {
    case preflight
    case ready
    case refreshingModels
    case installing(Double, String)
    case completed
    case failed(String)
    case restoring
}

enum BackendOperation: Equatable {
    case preflight
    case install
    case restore
    case authorization
}

struct PreflightResult: Codable, Equatable {
    let macOSVersion: String
    let architecture: HardwareArchitecture
    let translated: Bool
    let availableDiskBytes: UInt64
    let mode: String
    let installedApplications: [String: String]
    let runningApplications: [String]
    let latestBackup: String?
}

struct InstallerEvent: Codable, Equatable {
    let kind: String
    let progress: Double?
    let message: String
    let code: String?
}

struct InstallerBackendFailure: LocalizedError, Equatable {
    let code: String
    let safeMessage: String

    var errorDescription: String? { safeMessage }
}

protocol InstallerBackend: AnyObject {
    func preflight() async throws -> PreflightResult
    func install(
        request: InstallRequest,
        onEvent: @escaping (InstallerEvent) -> Void
    ) async throws
    func restoreLatest(onEvent: @escaping (InstallerEvent) -> Void) async throws
    func cancel()
}

@MainActor
final class InstallerState {
    private(set) var selectedProvider: ProviderKind = .deepSeek
    private(set) var phase: InstallerPhase = .preflight
    private(set) var isPreflightReady = false
    private(set) var latestBackup: String?
    private(set) var preflight: PreflightResult?
    private(set) var redactedLogLines: [String] = []
    private(set) var reportURL: URL?
    private var modelsByProvider: [ProviderKind: [ModelDefinition]]
    private var modelSources: [ProviderKind: ModelSource]
    let offlineModelsByProvider: [ProviderKind: [ModelDefinition]]

    init(catalog: ProviderCatalogStore) {
        let values = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map {
            ($0, catalog.models(for: $0))
        })
        modelsByProvider = values
        modelSources = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .offlineSnapshot) })
        offlineModelsByProvider = values
    }

    func models(for provider: ProviderKind? = nil) -> [ModelDefinition] {
        modelsByProvider[provider ?? selectedProvider] ?? []
    }

    func selectProvider(_ provider: ProviderKind) {
        selectedProvider = provider
    }

    func replaceModels(_ models: [ModelDefinition], for provider: ProviderKind) {
        modelsByProvider[provider] = models
        modelSources[provider] = .upstreamRefresh
    }

    func restoreOfflineModels(for provider: ProviderKind) {
        modelsByProvider[provider] = offlineModelsByProvider[provider] ?? []
        modelSources[provider] = .offlineSnapshot
    }

    func modelSource(for provider: ProviderKind? = nil) -> ModelSource {
        modelSources[provider ?? selectedProvider] ?? .offlineSnapshot
    }

    func applyPreflight(_ result: PreflightResult) {
        preflight = result
        latestBackup = result.latestBackup
        isPreflightReady = result.runningApplications.isEmpty
        if result.runningApplications.isEmpty {
            phase = .ready
        } else {
            phase = .failed("请先正常退出：\(result.runningApplications.joined(separator: "、"))")
        }
    }

    func beginPreflight() {
        isPreflightReady = false
        preflight = nil
        phase = .preflight
    }

    func markPreflightFailed(_ message: String) {
        isPreflightReady = false
        phase = .failed(message)
    }

    func setPhase(_ phase: InstallerPhase) {
        self.phase = phase
    }

    func receive(_ event: InstallerEvent) {
        appendLog(event.message)
        switch event.kind {
        case "install_completed":
            phase = .completed
            if let marker = event.message.range(of: "report: ") {
                let path = String(event.message[marker.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("/") {
                    reportURL = URL(fileURLWithPath: path)
                }
            }
        case "install_failed", "error":
            phase = .failed(event.message)
        case "cancelled":
            phase = .installing(event.progress ?? 0, "正在回滚…")
        case "rollback", "rollback_completed":
            phase = .installing(event.progress ?? 0, event.message)
        case "restore_completed":
            phase = .ready
        default:
            if let progress = event.progress {
                phase = .installing(progress, event.message)
            }
        }
    }

    func appendLog(_ line: String) {
        let redacted = Self.redact(line)
        guard !redacted.isEmpty, redactedLogLines.last != redacted else { return }
        redactedLogLines.append(redacted)
        if redactedLogLines.count > 300 {
            redactedLogLines.removeFirst(redactedLogLines.count - 300)
        }
    }

    private static func redact(_ input: String) -> String {
        var output = input
        let patterns = [
            #"(?i)(Bearer\s+)[A-Za-z0-9._-]+"#,
            #"(?i)(\"?(?:apiKey|OPENAI_API_KEY)\"?\s*[:=]\s*\"?)[^\",\s]+"#,
            #"sk-[A-Za-z0-9._-]{8,}"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: pattern.hasPrefix("(?i)(") ? "$1[REDACTED]" : "[REDACTED]"
            )
        }
        return output
    }
}

final class BackendRunner: InstallerBackend, @unchecked Sendable {
    private let coreURL: URL
    private let environment: [String: String]
    private let processLock = NSLock()
    private var currentProcess: Process?

    init(
        coreURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.coreURL = coreURL
        self.environment = environment
    }

    func preflight() async throws -> PreflightResult {
        guard FileManager.default.isReadableFile(atPath: coreURL.path) else {
            throw InstallerBackendFailure(
                code: "missing_backend_resource",
                safeMessage: "installer backend resource is missing"
            )
        }
        let output = try await run(arguments: ["preflight"], standardInput: nil, onEvent: nil)
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("::event::") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let json = lines.last?.data(using: .utf8) else {
            throw backendError("preflight returned no data")
        }
        return try JSONDecoder().decode(PreflightResult.self, from: json)
    }

    func install(
        request: InstallRequest,
        onEvent: @escaping (InstallerEvent) -> Void
    ) async throws {
        let input = try JSONEncoder().encode(request)
        _ = try await run(
            arguments: ["install", "--request-stdin"],
            standardInput: input,
            onEvent: onEvent
        )
    }

    func restoreLatest(onEvent: @escaping (InstallerEvent) -> Void) async throws {
        _ = try await run(arguments: ["restore-latest"], standardInput: nil, onEvent: onEvent)
    }

    func cancel() {
        processLock.lock()
        let process = currentProcess
        processLock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func run(
        arguments: [String],
        standardInput: Data?,
        onEvent: ((InstallerEvent) -> Void)?
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()
                let inputPipe = standardInput == nil ? nil : Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [self.coreURL.path] + arguments
                process.environment = self.environment
                process.standardOutput = outputPipe
                process.standardError = outputPipe
                if let inputPipe {
                    process.standardInput = inputPipe
                } else {
                    process.standardInput = FileHandle.nullDevice
                }

                self.processLock.lock()
                if self.currentProcess != nil {
                    self.processLock.unlock()
                    continuation.resume(throwing: self.backendError("another backend operation is running"))
                    return
                }
                self.currentProcess = process
                self.processLock.unlock()

                defer {
                    self.processLock.lock()
                    if self.currentProcess === process {
                        self.currentProcess = nil
                    }
                    self.processLock.unlock()
                }

                do {
                    try process.run()
                    if let standardInput, let inputPipe {
                        inputPipe.fileHandleForWriting.write(standardInput)
                        try inputPipe.fileHandleForWriting.close()
                    }

                    var allOutput = Data()
                    var pending = Data()
                    var lastFailureEvent: InstallerEvent?
                    while true {
                        let chunk = outputPipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        allOutput.append(chunk)
                        pending.append(chunk)
                        Self.consumeCompleteLines(
                            from: &pending,
                            onEvent: onEvent,
                            lastFailure: &lastFailureEvent
                        )
                    }
                    if !pending.isEmpty {
                        Self.consumeLine(
                            pending,
                            onEvent: onEvent,
                            lastFailure: &lastFailureEvent
                        )
                    }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        continuation.resume(
                            throwing: InstallerBackendFailure(
                                code: lastFailureEvent?.code ?? "backend_exit_\(process.terminationStatus)",
                                safeMessage: lastFailureEvent?.message ?? "installer backend failed"
                            )
                        )
                        return
                    }
                    continuation.resume(returning: allOutput)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func consumeCompleteLines(
        from pending: inout Data,
        onEvent: ((InstallerEvent) -> Void)?,
        lastFailure: inout InstallerEvent?
    ) {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            consumeLine(Data(line), onEvent: onEvent, lastFailure: &lastFailure)
            pending.removeSubrange(...newline)
        }
    }

    private static func decodeEvent(_ data: Data) -> InstallerEvent? {
        guard let line = String(data: data, encoding: .utf8),
              line.hasPrefix("::event::") else { return nil }
        let payload = Data(line.dropFirst("::event::".count).utf8)
        return try? JSONDecoder().decode(InstallerEvent.self, from: payload)
    }

    private static func consumeLine(
        _ data: Data,
        onEvent: ((InstallerEvent) -> Void)?,
        lastFailure: inout InstallerEvent?
    ) {
        guard let event = decodeEvent(data) else { return }
        if event.kind == "error" || event.kind.hasSuffix("_failed") {
            lastFailure = event
        }
        onEvent?(event)
    }

    private func backendError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.Backend",
            code: 70,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
