import Cocoa

private enum UITestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func uiRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw UITestFailure.failed(message) }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping () -> Bool
) throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    throw UITestFailure.failed("timed out waiting for UI state")
}

@MainActor
private func waitUntilAsync(
    timeout: TimeInterval = 2,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw UITestFailure.failed("timed out waiting for async UI state")
}

private func effectivelyHidden(_ view: NSView) -> Bool {
    var candidate: NSView? = view
    while let current = candidate {
        if current.isHidden { return true }
        candidate = current.superview
    }
    return false
}

private final class FakeBackend: InstallerBackend {
    var request: InstallRequest?
    var preflightError: Error?
    var preflightResult = PreflightResult(
        macOSVersion: "14.6",
        architecture: .arm64,
        translated: false,
        availableDiskBytes: 10_000_000_000,
        mode: "fresh",
        installedApplications: [:],
        runningApplications: [],
        latestBackup: "/tmp/backup"
    )
    var cancelled = false
    var restored = false

    func preflight() async throws -> PreflightResult {
        if let preflightError { throw preflightError }
        return preflightResult
    }

    func install(
        request: InstallRequest,
        onEvent: @escaping (InstallerEvent) -> Void
    ) async throws {
        self.request = request
        onEvent(InstallerEvent(kind: "installing", progress: 0.25, message: "Bearer sk-ui-secret-value", code: nil))
        onEvent(InstallerEvent(kind: "installing", progress: 0.5, message: "正在安装", code: nil))
        onEvent(InstallerEvent(kind: "install_completed", progress: 1, message: "installation completed; report: /tmp/report.md", code: nil))
    }

    func restoreLatest(onEvent: @escaping (InstallerEvent) -> Void) async throws {
        restored = true
        onEvent(InstallerEvent(kind: "restore_completed", progress: 1, message: "已恢复", code: nil))
    }

    func cancel() { cancelled = true }
}

private final class FakeTransport: HTTPTransport {
    var shouldFail = false
    var modelIDs = ["upstream-a", "upstream-b"]
    var delayNanoseconds: UInt64 = 0
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if shouldFail { throw UITestFailure.failed("offline") }
        let data = try JSONSerialization.data(
            withJSONObject: ["data": modelIDs.map { ["id": $0] }]
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

@MainActor
private final class FakeAuthorizationClient: OpenAIAuthorizationClient {
    private(set) var state: OpenAIAuthorizationState
    private(set) var methods: [OpenAIAuthorizationMethod] = []
    private(set) var cancelCount = 0
    private(set) var refreshCount = 0
    var refreshedState: OpenAIAuthorizationState?
    private var continuation: CheckedContinuation<OpenAIAuthorizationState, Never>?
    private var onState: ((OpenAIAuthorizationState) -> Void)?

    init(state: OpenAIAuthorizationState = .ready) {
        self.state = state
    }

    func refreshStatus() async -> OpenAIAuthorizationState {
        refreshCount += 1
        if let refreshedState { state = refreshedState }
        return state
    }

    func authorize(
        using method: OpenAIAuthorizationMethod,
        onState: @escaping (OpenAIAuthorizationState) -> Void
    ) async -> OpenAIAuthorizationState {
        methods.append(method)
        self.onState = onState
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        finish(.cancelled)
    }

    func waitUntilStarted() async throws {
        try await waitUntilAsync { !self.methods.isEmpty }
    }

    func finish(_ nextState: OpenAIAuthorizationState) {
        state = nextState
        onState?(nextState)
        onState = nil
        continuation?.resume(returning: nextState)
        continuation = nil
    }

    func emit(_ nextState: OpenAIAuthorizationState) {
        state = nextState
        onState?(nextState)
    }
}

private final class ControlledBackend: InstallerBackend {
    var preflightResult = PreflightResult(
        macOSVersion: "14.6",
        architecture: .arm64,
        translated: false,
        availableDiskBytes: 10_000_000_000,
        mode: "fresh",
        installedApplications: [:],
        runningApplications: [],
        latestBackup: nil
    )
    private var installContinuation: CheckedContinuation<Void, Never>?

    func preflight() async throws -> PreflightResult {
        preflightResult
    }

    func install(
        request: InstallRequest,
        onEvent: @escaping (InstallerEvent) -> Void
    ) async throws {
        onEvent(
            InstallerEvent(
                kind: "install_completed",
                progress: 1,
                message: "installation completed; report: /tmp/report.md",
                code: nil
            )
        )
        await withCheckedContinuation { continuation in
            installContinuation = continuation
        }
    }

    func finishInstall() {
        installContinuation?.resume()
        installContinuation = nil
    }

    func restoreLatest(onEvent: @escaping (InstallerEvent) -> Void) async throws {}
    func cancel() {}
}

@main
struct AppKitUITests {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try testStructureAndLayouts()
        try await testInteractionsAndFallback()
        try await testDirectOpenAIAuthorizationFlow()
        try await testPostInstallAuthorizationRefresh()
        try await testRetryAndOperationOwnership()
        try await testBackendFailureDetails()
        try await testBackendUsesStandardInputOnly()
        try await testBackendCancellationWaitsForRollback()
        print("appkit-ui-tests: PASS")
    }

    @MainActor
    private static func testRetryAndOperationOwnership() async throws {
        let runningBackend = FakeBackend()
        runningBackend.preflightResult = PreflightResult(
            macOSVersion: "14.6",
            architecture: .arm64,
            translated: false,
            availableDiskBytes: 10_000_000_000,
            mode: "fresh",
            installedApplications: [:],
            runningApplications: ["ChatGPT"],
            latestBackup: nil
        )
        let retryController = InstallerViewController(
            backend: runningBackend,
            transport: FakeTransport(),
            openURL: { _ in }
        )
        retryController.loadView()
        try await waitUntilAsync { !retryController.retryPreflightButton.isHidden }
        try uiRequire(!retryController.installButton.isEnabled, "running app blocks install")
        runningBackend.preflightResult = PreflightResult(
            macOSVersion: "14.6",
            architecture: .arm64,
            translated: false,
            availableDiskBytes: 10_000_000_000,
            mode: "fresh",
            installedApplications: [:],
            runningApplications: [],
            latestBackup: nil
        )
        retryController.retryPreflight(nil)
        try await waitUntilAsync { retryController.retryPreflightButton.isHidden }
        retryController.apiKeyField.stringValue = "sk-retry-valid-key"
        retryController.controlTextDidChange(
            Notification(
                name: NSControl.textDidChangeNotification,
                object: retryController.apiKeyField
            )
        )
        try uiRequire(retryController.installButton.isEnabled, "retry enables install")

        let transientBackend = FakeBackend()
        transientBackend.preflightError = InstallerBackendFailure(
            code: "unknown",
            safeMessage: "temporary"
        )
        let transientController = InstallerViewController(
            backend: transientBackend,
            transport: FakeTransport(),
            openURL: { _ in }
        )
        transientController.loadView()
        try await waitUntilAsync { !transientController.retryPreflightButton.isHidden }
        transientBackend.preflightError = nil
        transientController.retryPreflight(nil)
        try await waitUntilAsync {
            transientController.preflightStatusLabel.stringValue.contains("macOS 14.6")
        }

        let controlledBackend = ControlledBackend()
        let controlledController = InstallerViewController(
            backend: controlledBackend,
            transport: FakeTransport(),
            openURL: { _ in }
        )
        controlledController.loadView()
        try await waitUntilAsync {
            controlledController.preflightStatusLabel.stringValue.contains("macOS 14.6")
        }
        controlledController.apiKeyField.stringValue = "sk-controlled-valid-key"
        controlledController.controlTextDidChange(
            Notification(
                name: NSControl.textDidChangeNotification,
                object: controlledController.apiKeyField
            )
        )
        controlledController.beginInstallation(nil)
        try await waitUntilAsync {
            controlledController.phaseLabel.stringValue.hasPrefix("安装完成")
        }
        try uiRequire(
            controlledController.hasActiveBackendOperation,
            "backend ownership survives early completed event"
        )
        try uiRequire(
            !controlledController.requestClose(),
            "close denied until backend await returns"
        )
        controlledBackend.finishInstall()
        try await waitUntilAsync { !controlledController.hasActiveBackendOperation }
        try uiRequire(controlledController.requestClose(), "close allowed after backend returns")
    }

    @MainActor
    private static func testStructureAndLayouts() throws {
        let backend = FakeBackend()
        let transport = FakeTransport()
        var openedURLs: [URL] = []
        let controller = InstallerViewController(
            backend: backend,
            transport: transport,
            openURL: { openedURLs.append($0) }
        )
        controller.loadView()
        let window = makeInstallerWindow(controller: controller)
        let frameBeforeDisplay = window.frame
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        let frameAfterDisplay = window.frame
        try waitUntil { controller.preflightStatusLabel.stringValue.contains("macOS 14.6") }
        try uiRequire(!controller.refreshModelsButton.isEnabled, "empty Key blocks refresh")
        try uiRequire(!controller.installButton.isEnabled, "empty Key blocks install")
        controller.apiKeyField.stringValue = "sk-valid-preview-key"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.apiKeyField)
        )
        try uiRequire(controller.refreshModelsButton.isEnabled, "valid Key enables refresh")
        try uiRequire(controller.installButton.isEnabled, "valid Key enables install")
        try uiRequire(
            frameBeforeDisplay.width >= 800,
            "window is constructed at minimum width; window=\(frameBeforeDisplay)"
        )
        try uiRequire(
            frameAfterDisplay.width >= 800,
            "display preserves window width; window=\(frameAfterDisplay) content=\(controller.view.frame) " +
            "min=\(window.minSize) contentMin=\(window.contentMinSize) fitting=\(controller.view.fittingSize)"
        )
        try uiRequire(
            window.frame.width >= 800,
            "preflight preserves window width; window=\(window.frame) content=\(controller.view.frame)"
        )
        try uiRequire(window.frame.height >= 640, "initial window height honors minimum; window=\(window.frame)")
        try uiRequire(
            controller.view.frame.width >= 752,
            "content view fills initial window width; content=\(controller.view.frame)"
        )

        try uiRequire(
            controller.providerPopup.itemArray.map(\.title)
                == ["DeepSeek", "Kimi", "智谱 GLM", "阿里千问", "小米 MiMo"],
            "provider choices"
        )
        try uiRequire(
            controller.authenticationModePopup.itemArray.map(\.title) == [
                "纯 API 模式",
                "OpenAI 账号 + API（推荐）"
            ],
            "authentication mode choices"
        )
        try uiRequire(
            controller.authenticationModePopup.selectedItem?.representedObject as? String
                == AuthenticationMode.pureAPI.rawValue,
            "pure API is the default"
        )
        try uiRequire(
            controller.authorizationStatusLabel.stringValue
                == "默认使用所选模型 API。有 OpenAI 账号？推荐同时授权；模型仍由当前 API 运行，并解锁全部官方插件入口与最佳兼容性。",
            "pure API explains the optional OpenAI authorization"
        )
        let keyControl: NSControl = controller.apiKeyField
        try uiRequire(keyControl is NSSecureTextField, "secure key field")
        try uiRequire(controller.applyKeyButton.toolTip?.contains("API Key") == true, "apply link tooltip")
        try uiRequire(controller.configGrid.row(at: 1).isHidden, "Kimi type hidden for DeepSeek")
        try uiRequire(controller.modelPopup.numberOfItems == 2, "DeepSeek offline models")
        try uiRequire(!controller.restoreButton.isHidden, "restore visible when backup exists")
        try uiRequire(!effectivelyHidden(controller.promotionCard), "promotion card is visible")
        try uiRequire(controller.uniScholarButton.title == "Uni-Scholar 官网", "Uni-Scholar action")
        try uiRequire(controller.researchKitButton.title == "Research Kit", "Research Kit action")
        try uiRequire(
            controller.uniScholarButton.toolTip?.contains("uni-scholar.asia") == true,
            "Uni-Scholar link tooltip"
        )
        try uiRequire(
            controller.researchKitButton.toolTip?.contains("/research-kit") == true,
            "Research Kit link tooltip"
        )

        controller.openApplyKeyPage(nil)
        controller.providerPopup.selectItem(withTitle: "Kimi")
        controller.providerChanged(nil)
        try uiRequire(!controller.configGrid.row(at: 1).isHidden, "Kimi type visible")
        try uiRequire(
            controller.modelPopup.selectedItem?.representedObject as? String == "kimi-k3",
            "Kimi Open prefers K3"
        )
        try uiRequire(
            controller.kimiTypePopup.itemArray.map(\.title) == ["Kimi 开放平台", "Kimi Code 会员"],
            "Kimi types"
        )
        controller.openApplyKeyPage(nil)
        controller.kimiTypePopup.selectItem(withTitle: "Kimi Code 会员")
        controller.kimiTypeChanged(nil)
        try uiRequire(controller.modelPopup.numberOfItems == 3, "Kimi Code offline models")
        try uiRequire(
            controller.modelPopup.selectedItem?.representedObject as? String == "k3",
            "Kimi Code prefers k3"
        )
        controller.openApplyKeyPage(nil)
        for (title, preferredModel) in [
            ("智谱 GLM", "glm-5.2"),
            ("阿里千问", "qwen3.7-max"),
            ("小米 MiMo", "mimo-v2.5-pro")
        ] {
            controller.providerPopup.selectItem(withTitle: title)
            controller.providerChanged(nil)
            try uiRequire(controller.configGrid.row(at: 1).isHidden, "\(title) hides Kimi type")
            try uiRequire(
                controller.modelPopup.selectedItem?.representedObject as? String == preferredModel,
                "\(title) preferred model"
            )
            controller.openApplyKeyPage(nil)
        }
        controller.providerPopup.selectItem(withTitle: "Kimi")
        controller.providerChanged(nil)
        controller.openUniScholar(nil)
        controller.openResearchKit(nil)
        try uiRequire(
            openedURLs == [
                ProviderKind.deepSeek.applyURL,
                ProviderKind.kimiOpen.applyURL,
                ProviderKind.kimiCode.applyURL,
                ProviderKind.zhipu.applyURL,
                ProviderKind.qwen.applyURL,
                ProviderKind.xiaomiMiMo.applyURL,
                InstallerViewController.uniScholarURL,
                InstallerViewController.researchKitURL
            ],
            "provider and promotion links"
        )

        controller.view.frame = NSRect(origin: .zero, size: NSSize(width: 800, height: 640))
        controller.view.layoutSubtreeIfNeeded()
        controller.preflightStatusLabel.stringValue =
            "预检失败：安装器资源不完整，请从完整 DMG 重新打开。" +
            "安装器资源不完整，请从完整 DMG 重新打开。" +
            "安装器资源不完整，请从完整 DMG 重新打开。"
        controller.preflightStatusLabel.invalidateIntrinsicContentSize()
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        let statusTextSize = controller.preflightStatusLabel.attributedStringValue.boundingRect(
            with: NSSize(
                width: controller.preflightStatusLabel.bounds.width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        try uiRequire(
            statusTextSize.height > 26,
            "status regression fixture wraps to two lines; label=\(controller.preflightStatusLabel.frame) " +
                "statusBox=\(controller.layoutSections[1].frame) measured=\(statusTextSize)"
        )
        try uiRequire(
            controller.preflightStatusLabel.bounds.height + 0.5 >= ceil(statusTextSize.height),
            "wrapped status text is not clipped"
        )

        let inputFrames = [
            controller.providerPopup,
            controller.kimiTypePopup,
            controller.authenticationModePopup,
            controller.apiKeyField,
            controller.modelPopup
        ].map { $0.convert($0.bounds, to: controller.view) }
        let firstInput = inputFrames[0]
        try uiRequire(inputFrames.allSatisfy { abs($0.minX - firstInput.minX) < 0.5 }, "form inputs share leading edge")
        try uiRequire(inputFrames.allSatisfy { abs($0.maxX - firstInput.maxX) < 0.5 }, "form inputs share trailing edge")
        try uiRequire(inputFrames.allSatisfy { abs($0.height - firstInput.height) < 0.5 }, "form inputs share height")

        let actionFrames = [controller.applyKeyButton, controller.refreshModelsButton]
            .map { $0.convert($0.bounds, to: controller.view) }
        try uiRequire(abs(actionFrames[0].minX - actionFrames[1].minX) < 0.5, "form actions share leading edge")
        try uiRequire(abs(actionFrames[0].maxX - actionFrames[1].maxX) < 0.5, "form actions share trailing edge")

        controller.providerPopup.selectItem(withTitle: "DeepSeek")
        controller.providerChanged(nil)
        controller.view.layoutSubtreeIfNeeded()
        let hiddenKeyY = controller.apiKeyField.convert(controller.apiKeyField.bounds, to: controller.view).minY

        controller.providerPopup.selectItem(withTitle: "Kimi")
        controller.providerChanged(nil)
        controller.view.layoutSubtreeIfNeeded()
        let visibleKeyY = controller.apiKeyField.convert(controller.apiKeyField.bounds, to: controller.view).minY
        try uiRequire(abs(visibleKeyY - hiddenKeyY) >= 28, "visible Kimi row consumes one control row")

        controller.providerPopup.selectItem(withTitle: "DeepSeek")
        controller.providerChanged(nil)
        controller.view.layoutSubtreeIfNeeded()
        let hiddenAgainY = controller.apiKeyField.convert(controller.apiKeyField.bounds, to: controller.view).minY
        try uiRequire(abs(hiddenAgainY - hiddenKeyY) < 0.5, "hidden Kimi row leaves no gap")

        controller.providerPopup.selectItem(withTitle: "Kimi")
        controller.providerChanged(nil)
        controller.view.layoutSubtreeIfNeeded()

        for size in [NSSize(width: 800, height: 640), NSSize(width: 1024, height: 720), NSSize(width: 1280, height: 800)] {
            controller.view.frame = NSRect(origin: .zero, size: size)
            controller.view.layoutSubtreeIfNeeded()
            let visible = controller.layoutSections.filter { !effectivelyHidden($0) }
            let frames = visible.map { $0.convert($0.bounds, to: controller.view) }
            try uiRequire(frames.allSatisfy { $0.width > 0 && $0.height > 0 }, "\(size) positive frames")
            try uiRequire(frames.allSatisfy { controller.view.bounds.insetBy(dx: -1, dy: -1).contains($0) }, "\(size) frames in bounds")
            for index in frames.indices {
                for other in frames.indices where other > index {
                    try uiRequire(!frames[index].intersects(frames[other]), "\(size) vertical sections do not overlap")
                }
            }
        }

        try uiRequire(window.minSize == NSSize(width: 800, height: 640), "minimum window size")

        let upgradeBackend = FakeBackend()
        upgradeBackend.preflightResult = PreflightResult(
            macOSVersion: "15.0",
            architecture: .x86_64,
            translated: false,
            availableDiskBytes: 20_000_000_000,
            mode: "upgrade",
            installedApplications: ["ChatGPT": "1.0"],
            runningApplications: [],
            latestBackup: nil
        )
        let upgradeController = InstallerViewController(
            backend: upgradeBackend,
            transport: transport,
            openURL: { _ in }
        )
        upgradeController.loadView()
        try waitUntil { upgradeController.installButton.title == "复用 Codex，一键配置" }
        try uiRequire(
            upgradeController.preflightStatusLabel.stringValue.contains(
                "已检测到 Codex 1.0，安装时校验并复用"
            ),
            "existing Codex reuse is explained before installation"
        )
        try uiRequire(upgradeController.restoreButton.isHidden, "restore hidden without backup")
    }

    @MainActor
    private static func testInteractionsAndFallback() async throws {
        let backend = FakeBackend()
        let transport = FakeTransport()
        let controller = InstallerViewController(
            backend: backend,
            transport: transport,
            openURL: { _ in }
        )
        controller.loadView()
        try await waitUntilAsync { controller.preflightStatusLabel.stringValue.contains("macOS 14.6") }
        controller.apiKeyField.stringValue = ""
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.apiKeyField)
        )
        let requestCountBeforeInvalidRefresh = transport.requestCount
        let logBeforeInvalidRefresh = controller.logTextView.string
        controller.refreshModels(nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        try uiRequire(transport.requestCount == requestCountBeforeInvalidRefresh, "invalid Key skips model request")
        try uiRequire(controller.logTextView.string == logBeforeInvalidRefresh, "invalid Key does not add log")
        try uiRequire(
            controller.modelSourceLabel.stringValue == "输入有效 API Key 后可刷新上游模型",
            "invalid Key shows inline refresh guidance"
        )
        controller.apiKeyField.stringValue = "sk-ui-secret-value"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.apiKeyField)
        )
        controller.beginInstallation(nil)
        try await waitUntilAsync {
            backend.request != nil
                && controller.launchButton.isHidden == false
                && controller.launchButton.isEnabled
        }
        try uiRequire(backend.request?.apiKey == "sk-ui-secret-value", "request includes secure field value")
        try uiRequire(backend.request?.provider == .deepSeek, "selected provider submitted")
        try uiRequire(backend.request?.availableModels.count == 2, "available model list submitted")
        try uiRequire(
            backend.request?.authenticationMode == .pureAPI,
            "pure API mode submitted by default"
        )
        try uiRequire(controller.launchButton.isHidden == false, "completion actions visible")
        try uiRequire(controller.launchButton.isEnabled, "authenticated account enables Codex++")
        try uiRequire(!controller.logTextView.string.contains("sk-ui-secret-value"), "UI log redacts Key")
        try uiRequire(controller.logTextView.string.contains("[REDACTED]"), "UI log shows redaction marker")

        transport.shouldFail = false
        controller.refreshModels(nil)
        try await waitUntilAsync { controller.modelSourceLabel.stringValue == "已从上游刷新" }
        let refreshedModelIDs = controller.modelPopup.itemArray.compactMap {
            $0.representedObject as? String
        }
        try uiRequire(refreshedModelIDs == transport.modelIDs, "upstream models replace popup")
        backend.request = nil
        controller.beginInstallation(nil)
        try await waitUntilAsync { backend.request != nil }
        try uiRequire(backend.request?.modelSource == .upstreamRefresh, "live model provenance submitted")

        let modelsBeforeFailedRefresh = controller.modelPopup.itemArray.compactMap {
            $0.representedObject as? String
        }
        transport.shouldFail = true
        controller.refreshModels(nil)
        try await waitUntilAsync { controller.refreshModelsButton.isEnabled }
        controller.refreshModels(nil)
        try await waitUntilAsync { controller.refreshModelsButton.isEnabled }
        let refreshFailures = controller.logTextView.string
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains("模型刷新失败") }
        try uiRequire(refreshFailures.count == 1, "duplicate refresh failures are coalesced")
        let modelsAfterFailedRefresh = controller.modelPopup.itemArray.compactMap {
            $0.representedObject as? String
        }
        try uiRequire(modelsAfterFailedRefresh == modelsBeforeFailedRefresh, "failed refresh preserves current models")
        try uiRequire(
            controller.modelSourceLabel.stringValue == "刷新失败，继续使用上游模型列表",
            "failed refresh identifies retained upstream models"
        )
        backend.request = nil
        controller.beginInstallation(nil)
        try await waitUntilAsync { backend.request != nil }
        try uiRequire(backend.request?.modelSource == .upstreamRefresh, "failed refresh preserves live provenance")
        try uiRequire(controller.installButton.isEnabled, "refresh failure keeps install available")

        let failedBackend = FakeBackend()
        failedBackend.preflightError = InstallerBackendFailure(
            code: "missing_payload_metadata",
            safeMessage: "offline payload metadata is incomplete"
        )
        let failedController = InstallerViewController(
            backend: failedBackend,
            transport: FakeTransport(),
            openURL: { _ in }
        )
        failedController.loadView()
        try await waitUntilAsync { failedController.preflightStatusLabel.stringValue.contains("资源不完整") }
        failedController.apiKeyField.stringValue = "sk-valid-preview-key"
        failedController.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: failedController.apiKeyField)
        )
        try uiRequire(!failedController.refreshModelsButton.isEnabled, "failed preflight blocks refresh")
        try uiRequire(!failedController.installButton.isEnabled, "failed preflight blocks install")
        try uiRequire(!failedController.phaseLabel.stringValue.contains("准备就绪"), "failed preflight stays failed")

        let delayedBackend = FakeBackend()
        let delayedTransport = FakeTransport()
        delayedTransport.delayNanoseconds = 100_000_000
        delayedTransport.modelIDs = ["deepseek-only"]
        let delayedController = InstallerViewController(
            backend: delayedBackend,
            transport: delayedTransport,
            openURL: { _ in }
        )
        delayedController.loadView()
        try await waitUntilAsync { delayedController.preflightStatusLabel.stringValue.contains("macOS 14.6") }
        delayedController.apiKeyField.stringValue = "sk-valid-preview-key"
        delayedController.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: delayedController.apiKeyField)
        )
        delayedController.refreshModels(nil)
        delayedController.providerPopup.selectItem(withTitle: "Kimi")
        delayedController.providerChanged(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        let delayedIDs = delayedController.modelPopup.itemArray.compactMap {
            $0.representedObject as? String
        }
        try uiRequire(delayedIDs.contains("kimi-k3"), "stale DeepSeek refresh ignored after provider switch")
        try uiRequire(!delayedIDs.contains("deepseek-only"), "stale models never enter Kimi list")

        controller.restoreLatest(nil)
        try await waitUntilAsync { backend.restored }
        controller.stopInstallation(nil)
        try uiRequire(backend.cancelled, "stop forwards cancellation")
    }

    @MainActor
    private static func testDirectOpenAIAuthorizationFlow() async throws {
        let backend = FakeBackend()
        let transport = FakeTransport()
        backend.preflightResult = PreflightResult(
            macOSVersion: "14.6",
            architecture: .arm64,
            translated: false,
            availableDiskBytes: 10_000_000_000,
            mode: "upgrade",
            installedApplications: ["ChatGPT/Codex": "1.0"],
            runningApplications: [],
            latestBackup: nil
        )
        let fakeAuthorization = FakeAuthorizationClient()
        var openedApplications: [URL] = []
        let controller = InstallerViewController(
            backend: backend,
            transport: transport,
            authorizationClient: fakeAuthorization,
            openURL: { _ in },
            openApplication: { openedApplications.append($0) }
        )
        controller.loadView()
        try await waitUntilAsync {
            controller.preflightStatusLabel.stringValue.contains("macOS 14.6")
        }
        try uiRequire(
            controller.authenticationModePopup.selectedItem?.representedObject as? String
                == AuthenticationMode.pureAPI.rawValue,
            "pure API is the default"
        )
        controller.selectAuthenticationMode(.openAIAccountWithAPI)
        try uiRequire(controller.loginOpenAIButton.title == "获取 OpenAI 授权", "authorization action is shown")
        try uiRequire(controller.loginOpenAIButton.isEnabled, "healthy installed Codex enables pre-install authorization")
        controller.loginOpenAIAccount(nil)
        try await fakeAuthorization.waitUntilStarted()
        try uiRequire(fakeAuthorization.methods == [.browser], "browser authorization starts directly")
        controller.apiKeyField.stringValue = "sk-authorization-valid-key"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.apiKeyField)
        )
        let modelRequestsBeforeAuthorization = transport.requestCount
        controller.beginInstallation(nil)
        controller.refreshModels(nil)
        controller.restoreLatest(nil)
        try uiRequire(backend.request == nil && !backend.restored, "authorization blocks installation and restore")
        try uiRequire(
            transport.requestCount == modelRequestsBeforeAuthorization,
            "authorization blocks model refresh"
        )
        fakeAuthorization.finish(.authorized)
        try await waitUntilAsync { controller.authorizationStatusLabel.stringValue == "OpenAI 已授权" }
        try await waitUntilAsync { !controller.hasActiveBackendOperation }

        controller.apiKeyField.stringValue = "sk-recommended-login-key"
        controller.controlTextDidChange(
            Notification(
                name: NSControl.textDidChangeNotification,
                object: controller.apiKeyField
            )
        )
        controller.beginInstallation(nil)
        try await waitUntilAsync { backend.request != nil }
        try uiRequire(
            !openedApplications.contains(URL(fileURLWithPath: "/Applications/ChatGPT.app")),
            "mixed installation never opens ChatGPT automatically"
        )

        let unavailableAuthorization = FakeAuthorizationClient(state: .unavailable(.codexNotInstalled))
        let unavailableController = InstallerViewController(
            backend: FakeBackend(),
            transport: FakeTransport(),
            authorizationClient: unavailableAuthorization,
            openURL: { _ in },
            openApplication: { openedApplications.append($0) }
        )
        unavailableController.loadView()
        try await waitUntilAsync {
            unavailableController.preflightStatusLabel.stringValue.contains("macOS 14.6")
        }
        unavailableController.selectAuthenticationMode(.openAIAccountWithAPI)
        try uiRequire(
            unavailableController.authorizationStatusLabel.stringValue == "安装 Codex 后获取授权",
            "missing Codex explains how to enable authorization"
        )

        let failingAuthorization = FakeAuthorizationClient()
        let failingBackend = FakeBackend()
        let failingController = InstallerViewController(
            backend: failingBackend,
            transport: FakeTransport(),
            authorizationClient: failingAuthorization,
            openURL: { _ in },
            openApplication: { openedApplications.append($0) }
        )
        failingController.loadView()
        try await waitUntilAsync { failingController.preflightStatusLabel.stringValue.contains("macOS 14.6") }
        failingController.selectAuthenticationMode(.openAIAccountWithAPI)
        failingController.loginOpenAIAccount(nil)
        try await failingAuthorization.waitUntilStarted()
        let unsafeClientFailure = "browser unavailable sk-unsafe-client-secret device code WXYZ-1234"
        failingAuthorization.finish(.failed(unsafeClientFailure))
        try await waitUntilAsync {
            failingController.authorizationStatusLabel.stringValue
                == "OpenAI 授权失败，请重试或使用设备码授权"
        }
        try uiRequire(
            !failingController.authorizationStatusLabel.stringValue.contains(unsafeClientFailure),
            "authorization UI never displays an unsafe client failure message"
        )
        try await waitUntilAsync { !failingController.hasActiveBackendOperation }
        try uiRequire(
            failingController.deviceCodeAuthorizationButton.title == "使用设备码授权"
                && !failingController.deviceCodeAuthorizationButton.isHidden
                && failingController.usePureAPIFallbackButton.title == "改用所选模型 API"
                && !failingController.usePureAPIFallbackButton.isHidden,
            "browser failure shows authorization fallbacks"
        )
        failingController.authorizeWithDeviceCode(nil)
        try await waitUntilAsync { failingAuthorization.methods == [.browser, .deviceCode] }
        failingAuthorization.emit(.deviceCode(URL(string: "https://auth.openai.com")!, "ABCD-EFGH"))
        failingController.cancelAuthorization(nil)
        try uiRequire(failingAuthorization.cancelCount == 1, "cancel calls authorization client")
        try uiRequire(!failingBackend.cancelled, "cancel authorization never rolls back installation")
        try await waitUntilAsync { !failingController.hasActiveBackendOperation }
        failingController.selectAuthenticationMode(.pureAPI)
        failingController.apiKeyField.stringValue = "sk-pure-api-mode-key"
        failingController.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: failingController.apiKeyField)
        )
        failingController.beginInstallation(nil)
        try await waitUntilAsync { failingController.launchButton.isEnabled }
        failingController.launchCodexPlus(nil)
        try uiRequire(
            openedApplications.last == URL(fileURLWithPath: "/Applications/Codex++.app"),
            "pure API remains launchable after failed authorization"
        )
        let sensitiveStrings = ["sk-fake-token", "ABCD-EFGH", "person@example.com"]
        try uiRequire(
            sensitiveStrings.allSatisfy { !failingController.logTextView.string.contains($0) },
            "authorization UI log excludes tokens, device codes, and email"
        )
    }

    @MainActor
    private static func testPostInstallAuthorizationRefresh() async throws {
        let backend = FakeBackend()
        let authorization = FakeAuthorizationClient(state: .unavailable(.codexNotInstalled))
        authorization.refreshedState = .ready
        var openedApplications: [URL] = []
        let controller = InstallerViewController(
            backend: backend,
            transport: FakeTransport(),
            authorizationClient: authorization,
            openURL: { _ in },
            openApplication: { openedApplications.append($0) }
        )
        controller.loadView()
        try await waitUntilAsync { controller.preflightStatusLabel.stringValue.contains("macOS 14.6") }
        controller.apiKeyField.stringValue = "sk-post-install-refresh-key"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.apiKeyField)
        )
        controller.beginInstallation(nil)
        try await waitUntilAsync { authorization.refreshCount == 1 }
        controller.selectAuthenticationMode(.openAIAccountWithAPI)
        try uiRequire(
            controller.authorizationStatusLabel.stringValue == "将在系统浏览器打开 OpenAI 官方登录页面",
            "post-install refresh makes authorization ready"
        )
        try uiRequire(controller.loginOpenAIButton.isEnabled, "post-install authorization is usable")
        try uiRequire(authorization.methods.isEmpty, "refresh does not start authorization")
        try uiRequire(
            !openedApplications.contains(URL(fileURLWithPath: "/Applications/ChatGPT.app")),
            "refresh does not open ChatGPT"
        )
    }

    private static func testBackendUsesStandardInputOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-backend-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("installer-core.sh")
        let source = """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\n' "$@" > "$CAPTURE_DIR/arguments.txt"
        env > "$CAPTURE_DIR/environment.txt"
        case "$1" in
          preflight)
            printf '%s\\n' '{"macOSVersion":"14.6","architecture":"arm64","translated":false,"availableDiskBytes":10000000000,"mode":"fresh","installedApplications":{},"runningApplications":[],"latestBackup":null}'
            ;;
          install)
            cat > "$CAPTURE_DIR/stdin.json"
            printf '%s\\n' '::event::{"kind":"install_completed","progress":1,"message":"done","code":null}'
            ;;
          restore-latest)
            printf '%s\\n' '::event::{"kind":"restore_completed","progress":1,"message":"done","code":null}'
            ;;
        esac
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = BackendRunner(
            coreURL: script,
            environment: ["PATH": "/usr/bin:/bin", "CAPTURE_DIR": root.path]
        )
        let secret = "sk-process-metadata-secret"
        var events: [InstallerEvent] = []
        try await runner.install(
            request: InstallRequest(
                provider: .deepSeek,
                apiKey: secret,
                defaultModel: "deepseek-v4-pro",
                availableModels: ["deepseek-v4-pro"]
            ),
            onEvent: { events.append($0) }
        )
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
        let environment = try String(contentsOf: root.appendingPathComponent("environment.txt"), encoding: .utf8)
        let standardInput = try String(contentsOf: root.appendingPathComponent("stdin.json"), encoding: .utf8)
        try uiRequire(!arguments.contains(secret), "Key absent from process arguments")
        try uiRequire(!environment.contains(secret), "Key absent from process environment")
        try uiRequire(standardInput.contains(secret), "Key delivered through standard input")
        try uiRequire(events.map(\.kind) == ["install_completed"], "backend event parsed")
    }

    @MainActor
    private static func testBackendFailureDetails() async throws {
        let preflightMessages = [
            ("missing_backend_resource", "安装器资源不完整，请从完整 DMG 重新打开"),
            ("missing_payload_metadata", "安装器资源不完整，请从完整 DMG 重新打开"),
            ("unsupported_macos", "需要 macOS 14 或更高版本"),
            ("insufficient_disk", "可用空间不足，至少需要 4 GB"),
            ("invalid_payload_manifest", "安装包校验失败，请重新获取完整 DMG")
        ]
        for (code, expected) in preflightMessages {
            let presentation = InstallerViewController.preflightPresentation(
                for: InstallerBackendFailure(code: code, safeMessage: "safe")
            )
            try uiRequire(presentation.message == expected, "preflight presentation for \(code)")
            try uiRequire(presentation.code == code, "preflight code for \(code)")
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-installer-core-\(UUID().uuidString).sh")
        do {
            _ = try await BackendRunner(coreURL: missing).preflight()
            throw UITestFailure.failed("missing backend must fail")
        } catch let failure as InstallerBackendFailure {
            try uiRequire(failure.code == "missing_backend_resource", "missing backend code")
            try uiRequire(!failure.safeMessage.contains(missing.path), "missing backend hides local path")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-backend-failure-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("installer-core.sh")
        let source = """
        #!/usr/bin/env bash
        printf '%s\\n' '::event::{"kind":"error","progress":null,"message":"offline payload metadata is incomplete","code":"missing_payload_metadata"}'
        exit 66
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        do {
            _ = try await BackendRunner(coreURL: script).preflight()
            throw UITestFailure.failed("structured backend error must fail")
        } catch let failure as InstallerBackendFailure {
            try uiRequire(failure.code == "missing_payload_metadata", "structured backend code")
            try uiRequire(failure.safeMessage == "offline payload metadata is incomplete", "structured backend message")
        }
    }

    private static func testBackendCancellationWaitsForRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-backend-cancel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("installer-core.sh")
        let source = """
        #!/usr/bin/env bash
        set -euo pipefail
        trap 'printf "%s\\n" "::event::{\\"kind\\":\\"rollback\\",\\"progress\\":0.8,\\"message\\":\\"restoring\\",\\"code\\":null}"; printf "%s\\n" "::event::{\\"kind\\":\\"rollback_completed\\",\\"progress\\":1,\\"message\\":\\"restored\\",\\"code\\":null}"; exit 130' TERM
        cat >/dev/null
        touch "$CAPTURE_DIR/started"
        while true; do sleep 0.05; done
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = BackendRunner(
            coreURL: script,
            environment: ["PATH": "/usr/bin:/bin", "CAPTURE_DIR": root.path]
        )
        let lock = NSLock()
        var events: [InstallerEvent] = []
        let task = Task {
            try await runner.install(
                request: InstallRequest(
                    provider: .deepSeek,
                    apiKey: "sk-cancel-secret",
                    defaultModel: "deepseek-v4-pro",
                    availableModels: ["deepseek-v4-pro"]
                ),
                onEvent: { event in
                    lock.withLock {
                        events.append(event)
                    }
                }
            )
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try uiRequire(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), "cancel backend started")
        runner.cancel()
        var cancelledWithError = false
        do {
            try await task.value
        } catch {
            cancelledWithError = true
        }
        try uiRequire(cancelledWithError, "cancelled backend exits non-zero after rollback")
        let kinds = lock.withLock { events.map(\.kind) }
        try uiRequire(kinds.suffix(2) == ["rollback", "rollback_completed"], "cancel waits for rollback events")
    }
}
