import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(
            domain: "OpenAIAuthorizationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

struct Invocation: Equatable {
    let arguments: [String]
}

final class FakeLocator: OfficialCodexCLILocating {
    var result: Result<URL, OpenAIAuthorizationUnavailableReason>

    init(_ result: Result<URL, OpenAIAuthorizationUnavailableReason>) {
        self.result = result
    }

    func locate() -> Result<URL, OpenAIAuthorizationUnavailableReason> {
        result
    }
}

final class FakeInspector: OfficialCodexCLIInspecting {
    var result: OfficialCodexCLIInspectionResult

    init(_ result: OfficialCodexCLIInspectionResult) {
        self.result = result
    }

    func inspect(applicationURL: URL, cliURL: URL) -> OfficialCodexCLIInspectionResult {
        result
    }
}

final class FakeRunner: CodexCLIProcessRunning {
    var invocations: [Invocation] = []
    var results: [CodexCLIProcessResult]
    var onRun: (() -> Void)?
    private(set) var cancelled = false

    init(results: [CodexCLIProcessResult]) {
        self.results = results
    }

    func run(
        operation: CodexCLIProcessOperation,
        executableURL: URL,
        arguments: [String],
        onOutput: @escaping @MainActor (CodexCLIProcessOutput) -> Void
    ) async -> CodexCLIProcessResult {
        invocations.append(Invocation(arguments: arguments))
        onRun?()
        let next = results.removeFirst()
        if let output = CodexCLIOutputParser.deviceCode(from: next.standardOutput) {
            await onOutput(output)
        }
        return next
    }

    func cancel(_ operation: CodexCLIProcessOperation) {
        cancelled = true
    }
}

final class SuspendingRunner: CodexCLIProcessRunning {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CodexCLIProcessResult, Never>?
    private var didStart = false
    private(set) var cancelled = false

    var started: Bool {
        lock.lock()
        let started = didStart
        lock.unlock()
        return started
    }

    func run(
        operation: CodexCLIProcessOperation,
        executableURL: URL,
        arguments: [String],
        onOutput: @escaping @MainActor (CodexCLIProcessOutput) -> Void
    ) async -> CodexCLIProcessResult {
        await withCheckedContinuation {
            lock.lock()
            continuation = $0
            didStart = true
            lock.unlock()
        }
    }

    func cancel(_ operation: CodexCLIProcessOperation) {
        cancelled = true
    }

    func finish(_ result: CodexCLIProcessResult) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

final class StreamingDeviceRunner: CodexCLIProcessRunning {
    private let lock = NSLock()
    private var loginContinuation: CheckedContinuation<CodexCLIProcessResult, Never>?
    private var didStart = false
    private(set) var cancelled = false

    var started: Bool {
        lock.lock()
        let started = didStart
        lock.unlock()
        return started
    }

    func run(
        operation: CodexCLIProcessOperation,
        executableURL: URL,
        arguments: [String],
        onOutput: @escaping @MainActor (CodexCLIProcessOutput) -> Void
    ) async -> CodexCLIProcessResult {
        if arguments == ["login", "--device-auth"] {
            await onOutput(.deviceCode(URL(string: "https://auth.openai.com/codex/device")!, "ABCD-EFGH"))
            return await withCheckedContinuation {
                lock.lock()
                loginContinuation = $0
                didStart = true
                lock.unlock()
            }
        }
        return result(output: "You are logged in")
    }

    func cancel(_ operation: CodexCLIProcessOperation) {
        cancelled = true
    }

    func finishLogin() {
        lock.lock()
        let continuation = loginContinuation
        loginContinuation = nil
        lock.unlock()
        continuation?.resume(returning: result(output: "waiting for device authorization"))
    }
}

final class LateDeviceOutputRunner: CodexCLIProcessRunning {
    private var loginOutput: (@MainActor (CodexCLIProcessOutput) -> Void)?

    func run(
        operation: CodexCLIProcessOperation,
        executableURL: URL,
        arguments: [String],
        onOutput: @escaping @MainActor (CodexCLIProcessOutput) -> Void
    ) async -> CodexCLIProcessResult {
        if arguments == ["login", "--device-auth"] {
            loginOutput = onOutput
            return result(output: "device login complete")
        }
        await loginOutput?(
            .deviceCode(URL(string: "https://auth.openai.com/codex/device")!, "LATE-CODE")
        )
        return result(output: "Logged in using ChatGPT")
    }

    func cancel(_ operation: CodexCLIProcessOperation) {}
}

func result(
    _ status: Int32 = 0,
    output: String = "",
    error: String = "",
    timedOut: Bool = false
) -> CodexCLIProcessResult {
    CodexCLIProcessResult(
        terminationStatus: status,
        standardOutput: output,
        standardError: error,
        timedOut: timedOut
    )
}

@main
struct OpenAIAuthorizationTests {
    @MainActor
    static func main() async throws {
        let helperArguments = Array(CommandLine.arguments.dropFirst())
        if helperArguments == ["login"] {
            if let markerPath = ProcessInfo.processInfo.environment["OPENAI_AUTH_TEST_LOGIN_MARKER"] {
                try Data().write(to: URL(fileURLWithPath: markerPath))
            }
            return
        }
        if helperArguments == ["login", "status"] {
            FileHandle.standardOutput.write(Data("Logged in using ChatGPT\n".utf8))
            return
        }

        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applicationURL = fixtureRoot.appendingPathComponent("ChatGPT.app")
        let codexURL = applicationURL.appendingPathComponent("Contents/Resources/codex")
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: codexURL)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let missing = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.failure(.codexNotInstalled)),
            runner: FakeRunner(results: [])
        )
        try require(
            missing.state == .unavailable(.codexNotInstalled),
            "missing Codex is unavailable"
        )

        let invalidSignature = OfficialCodexCLILocator(
            applicationURL: applicationURL,
            cliURL: codexURL,
            inspector: FakeInspector(.invalidSignature)
        )
        try require(
            invalidSignature.locate() == .failure(.untrustedCodex),
            "invalid signature is untrusted"
        )

        let wrongTeam = OfficialCodexCLILocator(
            applicationURL: applicationURL,
            cliURL: codexURL,
            inspector: FakeInspector(.wrongTeamIdentifier)
        )
        try require(
            wrongTeam.locate() == .failure(.untrustedCodex),
            "wrong Team ID is untrusted"
        )

        let runner = FakeRunner(results: [
            result(output: "Opened browser for sign in"),
            result(output: "Logged in using ChatGPT")
        ])
        let coordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: runner
        )
        let browserState = await coordinator.authorize(using: .browser)
        try require(browserState == .authorized, "browser login is followed by status verification")
        try require(
            runner.invocations == [
                Invocation(arguments: ["login"]),
                Invocation(arguments: ["login", "status"])
            ],
            "only official stable login commands are used"
        )

        for output in ["Not logged in", "Not logged in using ChatGPT"] {
            let negativeStatus = OfficialCodexAuthorizationClient(
                locator: FakeLocator(.success(codexURL)),
                runner: FakeRunner(results: [
                    result(output: "Opened browser for sign in"),
                    result(output: output)
                ])
            )
            let negativeStatusState = await negativeStatus.authorize(using: .browser)
            try require(
                negativeStatusState == .failed("Codex login status could not be confirmed"),
                "negative login status cannot authorize"
            )
        }

        let nonzeroLogin = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: FakeRunner(results: [
                result(1, output: "sk-test-secret"),
                result(1, error: "device code WXYZ-1234")
            ])
        )
        let nonzeroState = await nonzeroLogin.authorize(using: .browser)
        try require(nonzeroState == .failed("Codex login failed"), "non-zero login fails safely")
        try require(
            !String(describing: nonzeroState).contains("sk-test-secret")
                && !String(describing: nonzeroState).contains("WXYZ-1234"),
            "failure state redacts secret output and device codes"
        )

        var observedStates: [OpenAIAuthorizationState] = []
        let deviceRunner = FakeRunner(results: [
            result(output: "Visit https://auth.openai.com/codex/device and enter code ABCD-EFGH"),
            result(output: "You are logged in")
        ])
        let deviceCoordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: deviceRunner
        )
        let deviceState = await deviceCoordinator.authorize(
            using: .deviceCode,
            onState: { observedStates.append($0) }
        )
        try require(deviceState == .authorized, "device login verifies the final status")
        try require(
            observedStates.contains(.deviceCode(URL(string: "https://auth.openai.com/codex/device")!, "ABCD-EFGH")),
            "device output is represented only by the device code state"
        )
        try require(deviceCoordinator.state == .authorized, "device code is cleared after authorization")
        try require(
            deviceRunner.invocations == [
                Invocation(arguments: ["login", "--device-auth"]),
                Invocation(arguments: ["login", "status"])
            ],
            "device authorization uses the official stable command"
        )

        var streamingStates: [OpenAIAuthorizationState] = []
        let streamingRunner = StreamingDeviceRunner()
        let streamingCoordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: streamingRunner
        )
        let streamingAuthorization = Task { @MainActor in
            await streamingCoordinator.authorize(using: .deviceCode, onState: { streamingStates.append($0) })
        }
        while !streamingRunner.started {
            await Task.yield()
        }
        try require(
            streamingCoordinator.state == .deviceCode(
                URL(string: "https://auth.openai.com/codex/device")!,
                "ABCD-EFGH"
            ),
            "device code reaches the UI while device authentication is still running"
        )
        try require(
            streamingStates.contains(.deviceCode(URL(string: "https://auth.openai.com/codex/device")!, "ABCD-EFGH")),
            "streamed process output is sanitized to the device-code state"
        )
        streamingRunner.finishLogin()
        let streamingState = await streamingAuthorization.value
        try require(streamingState == .authorized, "streamed device login clears code after verification")

        var lateOutputStates: [OpenAIAuthorizationState] = []
        let lateOutputCoordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: LateDeviceOutputRunner()
        )
        let lateOutputState = await lateOutputCoordinator.authorize(
            using: .deviceCode,
            onState: { lateOutputStates.append($0) }
        )
        try require(lateOutputState == .authorized, "late process output does not change authorization")
        try require(
            !lateOutputStates.contains(
                .deviceCode(URL(string: "https://auth.openai.com/codex/device")!, "LATE-CODE")
            ),
            "device code is cleared when login moves to verification"
        )

        let timedOut = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: FakeRunner(results: [result(timedOut: true)])
        )
        let timeoutState = await timedOut.refreshStatus()
        try require(timeoutState == .timedOut, "status timeout is finite")

        let refreshRaceRunner = SuspendingRunner()
        let refreshRaceCoordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: refreshRaceRunner
        )
        let refresh = Task { @MainActor in await refreshRaceCoordinator.refreshStatus() }
        while !refreshRaceRunner.started {
            await Task.yield()
        }
        refreshRaceCoordinator.cancel()
        refreshRaceRunner.finish(result(output: "You are logged in"))
        let refreshRaceState = await refresh.value
        try require(refreshRaceState == .cancelled, "cancel wins against a late refresh status callback")
        try require(refreshRaceCoordinator.state == .cancelled, "cancelled refresh state is retained")

        let raceRunner = SuspendingRunner()
        let raceCoordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(codexURL)),
            runner: raceRunner
        )
        let authorization = Task { @MainActor in
            await raceCoordinator.authorize(using: .browser)
        }
        while !raceRunner.started {
            await Task.yield()
        }
        raceCoordinator.cancel()
        raceRunner.finish(result(output: "Opened browser"))
        let raceState = await authorization.value
        try require(raceState == .cancelled, "cancel wins against a late success callback")
        try require(raceCoordinator.state == .cancelled, "cancelled state is retained")
        try require(raceRunner.cancelled, "cancel forwards to the active process boundary")

        let helperURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let idleStatusCoordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(helperURL)),
            runner: ProcessCodexCLIProcessRunner(timeout: 5)
        )
        idleStatusCoordinator.cancel()
        let idleStatusState = await idleStatusCoordinator.refreshStatus()
        try require(
            idleStatusState == .authorized,
            "idle cancellation does not poison a later status refresh"
        )

        let loginMarker = fixtureRoot.appendingPathComponent("idle-cancel-login-marker")
        setenv("OPENAI_AUTH_TEST_LOGIN_MARKER", loginMarker.path, 1)
        defer { unsetenv("OPENAI_AUTH_TEST_LOGIN_MARKER") }
        let idleAuthorizationCoordinator = OfficialCodexAuthorizationClient(
            locator: FakeLocator(.success(helperURL)),
            runner: ProcessCodexCLIProcessRunner(timeout: 5)
        )
        idleAuthorizationCoordinator.cancel()
        let idleAuthorizationState = await idleAuthorizationCoordinator.authorize(using: .browser)
        try require(
            idleAuthorizationState == .authorized,
            "idle cancellation does not poison a later authorization"
        )
        try require(
            FileManager.default.fileExists(atPath: loginMarker.path),
            "fresh authorization still launches login after idle cancellation"
        )

        let processRunner = ProcessCodexCLIProcessRunner(timeout: 5)
        let processStart = Date()
        let queuedOperation = CodexCLIProcessOperation()
        processRunner.cancel(queuedOperation)
        let processTask = Task {
            await processRunner.run(
                operation: queuedOperation,
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                onOutput: { _ in }
            )
        }
        _ = await processTask.value
        try require(
            Date().timeIntervalSince(processStart) < 1,
            "cancellation terminates a process queued to start"
        )

        print("openai-authorization-tests: PASS")
    }
}
