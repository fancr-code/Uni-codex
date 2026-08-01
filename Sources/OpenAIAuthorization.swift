import Foundation
import Security

enum OpenAIAuthorizationMethod: Equatable {
    case browser
    case deviceCode
}

enum OpenAIAuthorizationUnavailableReason: Error, Equatable {
    case codexNotInstalled
    case untrustedCodex
    case unsupportedCodex
}

enum OpenAIAuthorizationState: Equatable {
    case unavailable(OpenAIAuthorizationUnavailableReason)
    case ready
    case launching
    case waitingForBrowser
    case deviceCode(URL, String)
    case verifying
    case authorized
    case cancelled
    case timedOut
    case failed(String)
}

@MainActor
protocol OpenAIAuthorizationClient: AnyObject {
    var state: OpenAIAuthorizationState { get }
    func refreshStatus() async -> OpenAIAuthorizationState
    func authorize(
        using method: OpenAIAuthorizationMethod,
        onState: @escaping (OpenAIAuthorizationState) -> Void
    ) async -> OpenAIAuthorizationState
    func cancel()
}

protocol OfficialCodexCLILocating: AnyObject {
    func locate() -> Result<URL, OpenAIAuthorizationUnavailableReason>
}

enum OfficialCodexCLIInspectionResult {
    case trusted
    case invalidBundleIdentifier
    case invalidSignature
    case wrongTeamIdentifier
    case unsafeExecutable
    case unsupportedHardware
}

protocol OfficialCodexCLIInspecting: AnyObject {
    func inspect(applicationURL: URL, cliURL: URL) -> OfficialCodexCLIInspectionResult
}

final class OfficialCodexCLILocator: OfficialCodexCLILocating {
    static let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    static let cliURL = applicationURL.appendingPathComponent("Contents/Resources/codex")

    private let applicationURL: URL
    private let cliURL: URL
    private let inspector: any OfficialCodexCLIInspecting
    private let fileManager: FileManager

    init(
        applicationURL: URL = OfficialCodexCLILocator.applicationURL,
        cliURL: URL = OfficialCodexCLILocator.cliURL,
        inspector: any OfficialCodexCLIInspecting = SystemOfficialCodexCLIInspector(),
        fileManager: FileManager = .default
    ) {
        self.applicationURL = applicationURL
        self.cliURL = cliURL
        self.inspector = inspector
        self.fileManager = fileManager
    }

    func locate() -> Result<URL, OpenAIAuthorizationUnavailableReason> {
        guard fileManager.fileExists(atPath: applicationURL.path),
              fileManager.fileExists(atPath: cliURL.path) else {
            return .failure(.codexNotInstalled)
        }

        switch inspector.inspect(applicationURL: applicationURL, cliURL: cliURL) {
        case .trusted:
            return .success(cliURL)
        case .invalidBundleIdentifier,
             .invalidSignature,
             .wrongTeamIdentifier,
             .unsafeExecutable,
             .unsupportedHardware:
            return .failure(.untrustedCodex)
        }
    }
}

final class SystemOfficialCodexCLIInspector: OfficialCodexCLIInspecting {
    private static let expectedBundleIdentifier = "com.openai.codex"
    private static let expectedTeamIdentifier = "2DC432GLL2"

    func inspect(applicationURL: URL, cliURL: URL) -> OfficialCodexCLIInspectionResult {
        guard Bundle(url: applicationURL)?.bundleIdentifier == Self.expectedBundleIdentifier else {
            return .invalidBundleIdentifier
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(cliURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess else {
            return .invalidSignature
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &signingInformation) == errSecSuccess,
              let signingInformation = signingInformation as? [String: Any],
              signingInformation[kSecCodeInfoTeamIdentifier as String] as? String == Self.expectedTeamIdentifier else {
            return .wrongTeamIdentifier
        }

        guard isSafeBundleExecutable(cliURL, inside: applicationURL) else {
            return .unsafeExecutable
        }
        guard canExecuteOnCurrentHardware(cliURL) else {
            return .unsupportedHardware
        }
        return .trusted
    }

    private func isSafeBundleExecutable(_ cliURL: URL, inside applicationURL: URL) -> Bool {
        let appPath = applicationURL.standardizedFileURL.path + "/"
        guard cliURL.standardizedFileURL.path.hasPrefix(appPath),
              let values = try? cliURL.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
                  .isExecutableKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isExecutable == true else {
            return false
        }
        return true
    }

    private func canExecuteOnCurrentHardware(_ cliURL: URL) -> Bool {
        let architectures = runTool("/usr/bin/lipo", arguments: ["-archs", cliURL.path])
        guard architectures.status == 0 else { return false }

        let supportedArchitectures = Set(
            architectures.output.split(whereSeparator: \.isWhitespace).map(String.init)
        )
        let hostIsAppleSilicon = runTool("/usr/sbin/sysctl", arguments: ["-n", "hw.optional.arm64"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let preferredArchitecture = hostIsAppleSilicon ? "arm64" : "x86_64"
        guard supportedArchitectures.contains(preferredArchitecture) else { return false }
        return runTool("/usr/bin/arch", arguments: ["-\(preferredArchitecture)", "/usr/bin/true"]).status == 0
    }

    private func runTool(_ executablePath: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        } catch {
            return (1, "")
        }
    }
}

struct CodexCLIProcessResult: Equatable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

enum CodexCLIProcessOutput: Equatable {
    case deviceCode(URL, String)
}

struct CodexCLIProcessOperation: Hashable {
    private let id = UUID()
}

enum CodexCLIOutputParser {
    static func deviceCode(from output: String) -> CodexCLIProcessOutput? {
        let urlPattern = #"https://[^\s]+"#
        let codePattern = #"(?i)(?:code|验证码)\s*[:]?\s*([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+)"#
        guard let urlMatch = output.range(of: urlPattern, options: .regularExpression),
              let url = URL(string: String(output[urlMatch])),
              let expression = try? NSRegularExpression(pattern: codePattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return .deviceCode(url, String(output[range]))
    }
}

protocol CodexCLIProcessRunning: AnyObject {
    func run(
        operation: CodexCLIProcessOperation,
        executableURL: URL,
        arguments: [String],
        onOutput: @escaping @MainActor (CodexCLIProcessOutput) -> Void
    ) async -> CodexCLIProcessResult
    func cancel(_ operation: CodexCLIProcessOperation)
}

final class ProcessCodexCLIProcessRunner: CodexCLIProcessRunning, @unchecked Sendable {
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var currentProcess: Process?
    private var activeOperation: CodexCLIProcessOperation?
    private var cancelledOperations = Set<CodexCLIProcessOperation>()

    init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    func run(
        operation: CodexCLIProcessOperation,
        executableURL: URL,
        arguments: [String],
        onOutput: @escaping @MainActor (CodexCLIProcessOutput) -> Void
    ) async -> CodexCLIProcessResult {
        return await withCheckedContinuation { continuation in
            let completion = ProcessCompletion(continuation: continuation)
            lock.lock()
            activeOperation = operation
            currentProcess = nil
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let process = Process()
                let output = Pipe()
                let error = Pipe()
                let collector = ProcessOutputCollector()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = error

                guard !isCancelled(operation) else {
                    complete(
                        operation,
                        completion: completion,
                        result: CodexCLIProcessResult(
                            terminationStatus: 1,
                            standardOutput: "",
                            standardError: "",
                            timedOut: false
                        )
                    )
                    return
                }

                do {
                    try process.run()
                } catch {
                    complete(
                        operation,
                        completion: completion,
                        result: CodexCLIProcessResult(
                            terminationStatus: 1,
                            standardOutput: "",
                            standardError: "",
                            timedOut: false
                        )
                    )
                    return
                }

                lock.lock()
                let cancelled = cancelledOperations.contains(operation) || activeOperation != operation
                if !cancelled {
                    currentProcess = process
                }
                lock.unlock()
                if cancelled {
                    process.terminate()
                }

                let outputRead = readPipe(output.fileHandleForReading) { data in
                    if let event = collector.append(data) {
                        Task { @MainActor in onOutput(event) }
                    }
                }
                let errorCollector = ProcessDataCollector()
                let errorRead = readPipe(error.fileHandleForReading) { data in
                    errorCollector.append(data)
                }

                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    process.waitUntilExit()
                    outputRead.wait()
                    errorRead.wait()
                    self.complete(
                        operation,
                        completion: completion,
                        result: CodexCLIProcessResult(
                            terminationStatus: process.terminationStatus,
                            standardOutput: collector.contents,
                            standardError: errorCollector.contents,
                            timedOut: false
                        )
                    )
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [self] in
                    if process.isRunning {
                        process.terminate()
                        self.complete(
                            operation,
                            completion: completion,
                            result: CodexCLIProcessResult(
                                terminationStatus: 1,
                                standardOutput: "",
                                standardError: "",
                                timedOut: true
                            )
                        )
                    }
                }
            }
        }
    }

    func cancel(_ operation: CodexCLIProcessOperation) {
        lock.lock()
        cancelledOperations.insert(operation)
        let process: Process?
        if activeOperation == operation {
            process = currentProcess
            currentProcess = nil
        } else {
            process = nil
        }
        lock.unlock()
        process?.terminate()
    }

    private func isCancelled(_ operation: CodexCLIProcessOperation) -> Bool {
        lock.lock()
        let cancelled = cancelledOperations.contains(operation) || activeOperation != operation
        lock.unlock()
        return cancelled
    }

    private func complete(
        _ operation: CodexCLIProcessOperation,
        completion: ProcessCompletion,
        result: CodexCLIProcessResult
    ) {
        lock.lock()
        if activeOperation == operation {
            activeOperation = nil
            currentProcess = nil
        }
        cancelledOperations.remove(operation)
        lock.unlock()
        completion.finish(result)
    }

    private func readPipe(
        _ handle: FileHandle,
        consume: @escaping @Sendable (Data) -> Void
    ) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                consume(data)
            }
        }
        return group
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var scanBuffer = ""
    private var lastEvent: CodexCLIProcessOutput?

    func append(_ chunk: Data) -> CodexCLIProcessOutput? {
        guard !chunk.isEmpty else { return nil }
        lock.lock()
        data.append(chunk)
        scanBuffer += String(decoding: chunk, as: UTF8.self)
        if scanBuffer.count > 8_192 {
            scanBuffer = String(scanBuffer.suffix(8_192))
        }
        let event = CodexCLIOutputParser.deviceCode(from: scanBuffer)
        let newEvent = event == lastEvent ? nil : event
        lastEvent = event
        lock.unlock()
        return newEvent
    }

    var contents: String {
        lock.lock()
        let contents = String(decoding: data, as: UTF8.self)
        lock.unlock()
        return contents
    }
}

private final class ProcessDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var contents: String {
        lock.lock()
        let contents = String(decoding: data, as: UTF8.self)
        lock.unlock()
        return contents
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CodexCLIProcessResult, Never>?

    init(continuation: CheckedContinuation<CodexCLIProcessResult, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: CodexCLIProcessResult) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

@MainActor
final class OfficialCodexAuthorizationClient: OpenAIAuthorizationClient {
    private let locator: any OfficialCodexCLILocating
    private let runner: any CodexCLIProcessRunning
    private var cancellationGeneration = 0
    private var activeAuthorizationGeneration: Int?
    private var activeProcessOperation: CodexCLIProcessOperation?

    private(set) var state: OpenAIAuthorizationState

    init(
        locator: any OfficialCodexCLILocating = OfficialCodexCLILocator(),
        runner: any CodexCLIProcessRunning = ProcessCodexCLIProcessRunner()
    ) {
        self.locator = locator
        self.runner = runner
        switch locator.locate() {
        case .success:
            state = .ready
        case .failure(let reason):
            state = .unavailable(reason)
        }
    }

    func refreshStatus() async -> OpenAIAuthorizationState {
        guard let cliURL = resolveCLI() else { return state }
        let generation = cancellationGeneration
        transition(.verifying, onState: nil)
        let result = await runProcess(
            executableURL: cliURL,
            arguments: ["login", "status"],
            onOutput: { _ in }
        )
        guard generation == cancellationGeneration else { return .cancelled }
        if result.timedOut {
            transition(.timedOut, onState: nil)
        } else if result.terminationStatus == 0, confirmsLoggedIn(result.standardOutput) {
            transition(.authorized, onState: nil)
        } else {
            transition(.failed("Codex login status could not be confirmed"), onState: nil)
        }
        return state
    }

    func authorize(
        using method: OpenAIAuthorizationMethod,
        onState: @escaping (OpenAIAuthorizationState) -> Void = { _ in }
    ) async -> OpenAIAuthorizationState {
        guard let cliURL = resolveCLI() else { return state }
        let generation = cancellationGeneration
        activeAuthorizationGeneration = generation
        transition(.launching, onState: onState)
        let arguments = method == .browser ? ["login"] : ["login", "--device-auth"]
        if method == .browser {
            transition(.waitingForBrowser, onState: onState)
        }

        let login = await runProcess(
            executableURL: cliURL,
            arguments: arguments,
            onOutput: { [weak self] output in
                self?.receive(output, method: method, generation: generation, onState: onState)
            }
        )
        guard generation == cancellationGeneration else { return .cancelled }
        activeAuthorizationGeneration = nil
        if login.timedOut {
            transition(.timedOut, onState: onState)
            return state
        }

        transition(.verifying, onState: onState)
        let status = await runProcess(
            executableURL: cliURL,
            arguments: ["login", "status"],
            onOutput: { _ in }
        )
        guard generation == cancellationGeneration else { return .cancelled }
        if status.timedOut {
            transition(.timedOut, onState: onState)
        } else if status.terminationStatus == 0, confirmsLoggedIn(status.standardOutput) {
            transition(.authorized, onState: onState)
        } else if login.terminationStatus != 0 {
            transition(.failed("Codex login failed"), onState: onState)
        } else {
            transition(.failed("Codex login status could not be confirmed"), onState: onState)
        }
        return state
    }

    func cancel() {
        cancellationGeneration += 1
        activeAuthorizationGeneration = nil
        if let operation = activeProcessOperation {
            activeProcessOperation = nil
            runner.cancel(operation)
        }
        transition(.cancelled, onState: nil)
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        onOutput: @escaping @MainActor (CodexCLIProcessOutput) -> Void
    ) async -> CodexCLIProcessResult {
        let operation = CodexCLIProcessOperation()
        activeProcessOperation = operation
        let result = await runner.run(
            operation: operation,
            executableURL: executableURL,
            arguments: arguments,
            onOutput: onOutput
        )
        if activeProcessOperation == operation {
            activeProcessOperation = nil
        }
        return result
    }

    private func resolveCLI() -> URL? {
        switch locator.locate() {
        case .success(let url):
            return url
        case .failure(let reason):
            transition(.unavailable(reason), onState: nil)
            return nil
        }
    }

    private func transition(
        _ nextState: OpenAIAuthorizationState,
        onState: ((OpenAIAuthorizationState) -> Void)?
    ) {
        state = nextState
        onState?(nextState)
    }

    private func confirmsLoggedIn(_ output: String) -> Bool {
        output.lowercased()
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { line in
                line == "you are logged in"
                    || line.hasPrefix("you are logged in ")
                    || line.hasPrefix("logged in as ")
                    || line.hasPrefix("logged in using ")
                    || line == "authentication status: authenticated"
                    || line == "status: authenticated"
            }
    }

    private func receive(
        _ output: CodexCLIProcessOutput,
        method: OpenAIAuthorizationMethod,
        generation: Int,
        onState: @escaping (OpenAIAuthorizationState) -> Void
    ) {
        guard method == .deviceCode,
              generation == cancellationGeneration,
              activeAuthorizationGeneration == generation else {
            return
        }
        switch output {
        case .deviceCode(let url, let code):
            transition(.deviceCode(url, code), onState: onState)
        }
    }
}
