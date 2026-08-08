import Cocoa

private final class StatusTextField: NSTextField {
    var statusTextDidChange: (() -> Void)?

    override var stringValue: String {
        didSet { statusTextDidChange?() }
    }
}

private final class FittingStatusBox: NSBox {
    weak var statusLabel: NSTextField?

    override var intrinsicContentSize: NSSize {
        guard let statusLabel else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 42)
        }
        let availableWidth = max(
            0,
            bounds.width - (2 * contentViewMargins.width) - (2 * borderWidth)
        )
        let contentWidth = statusLabel.bounds.width > 0
            ? min(statusLabel.bounds.width, availableWidth)
            : availableWidth
        guard contentWidth > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 42)
        }
        let textHeight = statusLabel.attributedStringValue.boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let chromeHeight = (2 * contentViewMargins.height) + (2 * borderWidth)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(42, ceil(textHeight) + chromeHeight)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) >= 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

private final class PromotionCardView: NSView {
    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(calibratedRed: 0.09, green: 0.19, blue: 0.58, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.32, green: 0.16, blue: 0.72, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.16, green: 0.35, blue: 0.84, alpha: 1).cgColor
        ]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = 13
        gradient.borderWidth = 1
        gradient.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        return gradient
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class InstallerViewController: NSViewController, NSTextFieldDelegate {
    static let uniScholarURL = URL(string: "https://uni-scholar.asia")!
    static let researchKitURL = URL(string: "https://uni-scholar.asia/research-kit")!

    let providerPopup = NSPopUpButton()
    let kimiTypePopup = NSPopUpButton()
    let authenticationModePopup = NSPopUpButton()
    let apiKeyField = NSSecureTextField()
    let modelPopup = NSPopUpButton()
    let skinPopup = NSPopUpButton()
    let refreshModelsButton = NSButton(title: "刷新上游模型", target: nil, action: nil)
    let applyKeyButton = NSButton(title: "申请 API Key", target: nil, action: nil)
    let installButton = NSButton(title: "开始一键安装", target: nil, action: nil)
    let stopButton = NSButton(title: "停止并回滚", target: nil, action: nil)
    let launchButton = NSButton(title: "启动 Codex++", target: nil, action: nil)
    let reportButton = NSButton(title: "打开脱敏报告", target: nil, action: nil)
    let loginOpenAIButton = NSButton(title: "获取 OpenAI 授权", target: nil, action: nil)
    let deviceCodeAuthorizationButton = NSButton(title: "使用设备码授权", target: nil, action: nil)
    let cancelAuthorizationButton = NSButton(title: "取消授权", target: nil, action: nil)
    let usePureAPIFallbackButton = NSButton(title: "改用所选模型 API", target: nil, action: nil)
    let authorizationStatusLabel = NSTextField(labelWithString: "OpenAI 未授权")
    let restoreButton = NSButton(title: "恢复最近备份", target: nil, action: nil)
    let progressIndicator = NSProgressIndicator()
    let preflightStatusLabel: NSTextField = StatusTextField(labelWithString: "正在检查系统与离线包…")
    let retryPreflightButton = NSButton(title: "重新检查", target: nil, action: nil)
    let phaseLabel = NSTextField(labelWithString: "准备中")
    let modelSourceLabel = NSTextField(labelWithString: "内置离线快照")
    let logTextView = NSTextView()
    let logScrollView = NSScrollView()
    let uniScholarButton = NSButton(title: "Uni-Scholar 官网", target: nil, action: nil)
    let researchKitButton = NSButton(title: "Research Kit", target: nil, action: nil)
    private(set) var configGrid: NSGridView!
    private(set) var promotionCard: NSView!
    private var authorizationSection: NSView!
    private(set) var layoutSections: [NSView] = []

    private let backend: any InstallerBackend
    private let transport: any HTTPTransport
    private let authorizationClient: any OpenAIAuthorizationClient
    private let openURLHandler: (URL) -> Void
    private let openApplicationHandler: (URL) -> Void
    private let state: InstallerState
    private var cancellationRequested = false
    private var didBuildView = false
    private var kimiGridRow: NSGridRow!
    private var modelSourceStatus = "内置离线快照"
    private var modelRefreshGeneration = 0
    private var openAIAuthenticated = false
    private var authorizationState: OpenAIAuthorizationState
    private(set) var activeBackendOperation: BackendOperation?

    var hasActiveBackendOperation: Bool {
        activeBackendOperation != nil
    }

    private var hasValidAPIKey: Bool {
        apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
    }

    private var selectedAuthenticationMode: AuthenticationMode {
        guard let rawValue = authenticationModePopup.selectedItem?.representedObject as? String,
              let mode = AuthenticationMode(rawValue: rawValue) else {
            return .openAIAccountWithAPI
        }
        return mode
    }

    init(
        backend: any InstallerBackend,
        transport: any HTTPTransport,
        authorizationClient: (any OpenAIAuthorizationClient)? = nil,
        catalog: ProviderCatalogStore? = nil,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        openApplication: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.backend = backend
        self.transport = transport
        let resolvedAuthorizationClient = authorizationClient ?? OfficialCodexAuthorizationClient()
        self.authorizationClient = resolvedAuthorizationClient
        self.authorizationState = resolvedAuthorizationClient.state
        self.openURLHandler = openURL
        self.openApplicationHandler = openApplication
        self.state = InstallerState(catalog: catalog ?? Self.defaultCatalog())
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        if didBuildView { return }
        didBuildView = true

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 800).isActive = true
        view = root

        let title = NSTextField(labelWithString: "Codex 一键安装")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "离线安装 Codex + Codex++，并配置模型、插件市场与脚本市场")
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        let header = verticalStack([title, subtitle], spacing: 3)

        preflightStatusLabel.maximumNumberOfLines = 2
        preflightStatusLabel.lineBreakMode = .byWordWrapping
        preflightStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retryPreflightButton.bezelStyle = .rounded
        retryPreflightButton.target = self
        retryPreflightButton.action = #selector(retryPreflight(_:))
        retryPreflightButton.isHidden = true
        let statusContent = horizontalStack(
            [preflightStatusLabel, retryPreflightButton],
            spacing: 10
        )
        preflightStatusLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 120
        ).isActive = true
        let statusBox = FittingStatusBox()
        statusBox.boxType = .custom
        statusBox.borderWidth = 1
        statusBox.borderColor = .separatorColor
        statusBox.cornerRadius = 7
        statusBox.contentViewMargins = NSSize(width: 12, height: 8)
        statusContent.translatesAutoresizingMaskIntoConstraints = false
        if let boxContent = statusBox.contentView {
            boxContent.addSubview(statusContent)
            NSLayoutConstraint.activate([
                statusContent.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor),
                statusContent.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor),
                statusContent.topAnchor.constraint(equalTo: boxContent.topAnchor),
                statusContent.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor)
            ])
        }
        statusBox.statusLabel = preflightStatusLabel
        (preflightStatusLabel as? StatusTextField)?.statusTextDidChange = { [weak statusBox] in
            statusBox?.invalidateIntrinsicContentSize()
        }
        statusBox.setContentHuggingPriority(.required, for: .vertical)

        providerPopup.addItems(withTitles: ["DeepSeek", "Kimi", "智谱 GLM", "阿里千问", "小米 MiMo"])
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))

        kimiTypePopup.addItems(withTitles: ["Kimi 开放平台", "Kimi Code 会员"])
        kimiTypePopup.target = self
        kimiTypePopup.action = #selector(kimiTypeChanged(_:))

        for mode in [AuthenticationMode.pureAPI, .openAIAccountWithAPI] {
            authenticationModePopup.addItem(withTitle: mode.displayName)
            authenticationModePopup.lastItem?.representedObject = mode.rawValue
        }
        authenticationModePopup.selectItem(at: 0)
        authenticationModePopup.target = self
        authenticationModePopup.action = #selector(authenticationModeChanged(_:))
        authenticationModePopup.toolTip = "默认使用所选模型 API；可选 OpenAI 授权以解锁官方插件入口。"

        apiKeyField.placeholderString = "仅在本机写入配置，不进入参数或日志"
        apiKeyField.toolTip = "请输入所选服务商的 API Key"
        apiKeyField.delegate = self
        applyKeyButton.bezelStyle = .inline
        applyKeyButton.target = self
        applyKeyButton.action = #selector(openApplyKeyPage(_:))
        apiKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(refreshModels(_:))
        refreshModelsButton.bezelStyle = .rounded
        modelSourceLabel.textColor = .secondaryLabelColor
        modelSourceLabel.lineBreakMode = .byTruncatingTail
        modelSourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        skinPopup.addItem(withTitle: "Gothic Void Crusade（推荐）")
        skinPopup.lastItem?.representedObject = "preset-gothic-void-crusade"
        skinPopup.addItem(withTitle: "官方默认外观（不启用 Dream Skin）")
        skinPopup.lastItem?.representedObject = "none"
        skinPopup.selectItem(at: 0)
        skinPopup.toolTip = "预装 Codex Dream Skin；也可保留官方默认外观。"

        configGrid = NSGridView(views: [
            [formLabel("服务商"), providerPopup, NSGridCell.emptyContentView],
            [formLabel("Kimi 类型"), kimiTypePopup, NSGridCell.emptyContentView],
            [formLabel("登录模式"), authenticationModePopup, NSGridCell.emptyContentView],
            [formLabel("API Key"), apiKeyField, applyKeyButton],
            [formLabel("默认模型"), modelPopup, refreshModelsButton],
            [NSGridCell.emptyContentView, modelSourceLabel, NSGridCell.emptyContentView],
            [formLabel("预设皮肤"), skinPopup, NSGridCell.emptyContentView]
        ])
        configGrid.columnSpacing = 10
        configGrid.rowSpacing = 8
        configGrid.column(at: 0).width = 112
        configGrid.column(at: 1).xPlacement = .fill
        configGrid.column(at: 2).width = 168
        configGrid.column(at: 2).xPlacement = .fill
        kimiGridRow = configGrid.row(at: 1)
        kimiGridRow.isHidden = true
        [
            providerPopup, kimiTypePopup, authenticationModePopup, apiKeyField, modelPopup, skinPopup,
            applyKeyButton, refreshModelsButton
        ]
            .forEach { $0.heightAnchor.constraint(equalToConstant: 28).isActive = true }
        configGrid.setContentHuggingPriority(.defaultLow, for: .horizontal)

        installButton.target = self
        installButton.action = #selector(beginInstallation(_:))
        installButton.keyEquivalent = "\r"
        installButton.bezelStyle = .rounded
        installButton.controlSize = .large
        stopButton.target = self
        stopButton.action = #selector(stopInstallation(_:))
        stopButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restoreLatest(_:))
        restoreButton.bezelStyle = .rounded
        let actionRow = horizontalStack([installButton, stopButton, restoreButton], spacing: 10)

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .regular
        phaseLabel.textColor = .secondaryLabelColor
        let progressSection = verticalStack([progressIndicator, phaseLabel], spacing: 4)

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textColor = .secondaryLabelColor
        logTextView.backgroundColor = .textBackgroundColor
        logTextView.textContainerInset = NSSize(width: 8, height: 7)
        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder

        launchButton.target = self
        launchButton.action = #selector(launchCodexPlus(_:))
        reportButton.target = self
        reportButton.action = #selector(openReport(_:))
        loginOpenAIButton.target = self
        loginOpenAIButton.action = #selector(loginOpenAIAccount(_:))
        deviceCodeAuthorizationButton.target = self
        deviceCodeAuthorizationButton.action = #selector(authorizeWithDeviceCode(_:))
        cancelAuthorizationButton.target = self
        cancelAuthorizationButton.action = #selector(cancelAuthorization(_:))
        usePureAPIFallbackButton.target = self
        usePureAPIFallbackButton.action = #selector(usePureAPIFallback(_:))
        authorizationStatusLabel.maximumNumberOfLines = 2
        authorizationStatusLabel.lineBreakMode = .byWordWrapping
        let authorizationRow = horizontalStack(
            [
                loginOpenAIButton, deviceCodeAuthorizationButton, cancelAuthorizationButton,
                usePureAPIFallbackButton
            ],
            spacing: 8
        )
        let authorizationSection = verticalStack(
            [authorizationStatusLabel, authorizationRow],
            spacing: 4
        )
        self.authorizationSection = authorizationSection
        let completionRow = horizontalStack(
            [launchButton, reportButton],
            spacing: 8
        )
        completionRow.isHidden = true

        let promotionBadge = NSTextField(labelWithString: "推荐 · UNI-SCHOLAR 科研生态")
        promotionBadge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        promotionBadge.textColor = NSColor.white.withAlphaComponent(0.74)
        let promotionTitle = NSTextField(
            labelWithString: "云端工作站 + 本地 Research Kit + Codex 执行层"
        )
        promotionTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        promotionTitle.textColor = .white
        let promotionDescription = NSTextField(
            labelWithString: "文献调研 → PDF 精读 → 知识库 → 写作 → 引用核验 → 投稿"
        )
        promotionDescription.font = .systemFont(ofSize: 11.5, weight: .regular)
        promotionDescription.textColor = NSColor.white.withAlphaComponent(0.82)
        promotionDescription.lineBreakMode = .byTruncatingTail
        let promotionText = verticalStack(
            [promotionBadge, promotionTitle, promotionDescription],
            spacing: 2
        )
        promotionText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configurePromotionButton(
            uniScholarButton,
            symbol: "sparkles",
            action: #selector(openUniScholar(_:)),
            tooltip: "打开 Uni-Scholar 云端 AI 科研工作站：\(Self.uniScholarURL.absoluteString)"
        )
        configurePromotionButton(
            researchKitButton,
            symbol: "shippingbox.fill",
            action: #selector(openResearchKit(_:)),
            tooltip: "打开连接 Zotero、Obsidian 与 Codex 的本地 Research Kit：\(Self.researchKitURL.absoluteString)"
        )
        let promotionActions = horizontalStack(
            [uniScholarButton, researchKitButton],
            spacing: 8
        )
        promotionActions.setContentHuggingPriority(.required, for: .horizontal)
        promotionActions.setContentCompressionResistancePriority(.required, for: .horizontal)

        promotionCard = PromotionCardView()
        let promotionContent = horizontalStack(
            [promotionText, promotionActions],
            spacing: 16
        )
        promotionContent.translatesAutoresizingMaskIntoConstraints = false
        promotionCard.addSubview(promotionContent)
        NSLayoutConstraint.activate([
            promotionContent.leadingAnchor.constraint(equalTo: promotionCard.leadingAnchor, constant: 16),
            promotionContent.trailingAnchor.constraint(equalTo: promotionCard.trailingAnchor, constant: -14),
            promotionContent.topAnchor.constraint(equalTo: promotionCard.topAnchor, constant: 11),
            promotionContent.bottomAnchor.constraint(equalTo: promotionCard.bottomAnchor, constant: -11),
            promotionCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 78)
        ])

        let stack = verticalStack(
            [
                header,
                statusBox,
                configGrid,
                authorizationSection,
                actionRow,
                progressSection,
                logScrollView,
                promotionCard,
                completionRow
            ],
            spacing: 8
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            statusBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            logScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        logScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        layoutSections = [
            header, statusBox, configGrid, authorizationSection, actionRow, progressSection, logScrollView,
            promotionCard, completionRow
        ]

        populateModels()
        updateApplyLink()
        updateModelSourceLabel()
        authenticationModeChanged(nil)
        Task { [weak self] in
            await self?.runPreflight()
        }
    }

    @objc func providerChanged(_ sender: Any?) {
        let isKimi = providerPopup.titleOfSelectedItem == "Kimi"
        kimiGridRow.isHidden = !isKimi
        let provider: ProviderKind
        switch providerPopup.titleOfSelectedItem {
        case "Kimi":
            provider = kimiTypePopup.indexOfSelectedItem == 1 ? .kimiCode : .kimiOpen
        case "智谱 GLM":
            provider = .zhipu
        case "阿里千问":
            provider = .qwen
        case "小米 MiMo":
            provider = .xiaomiMiMo
        default:
            provider = .deepSeek
        }
        modelRefreshGeneration += 1
        state.selectProvider(provider)
        state.restoreOfflineModels(for: provider)
        populateModels()
        modelSourceStatus = "内置离线快照"
        updateModelSourceLabel()
        if case .refreshingModels = state.phase {
            state.setPhase(.ready)
        }
        updateApplyLink()
        render()
        view.needsLayout = true
    }

    @objc func kimiTypeChanged(_ sender: Any?) {
        modelRefreshGeneration += 1
        state.selectProvider(kimiTypePopup.indexOfSelectedItem == 1 ? .kimiCode : .kimiOpen)
        state.restoreOfflineModels(for: state.selectedProvider)
        populateModels()
        modelSourceStatus = "内置离线快照"
        updateModelSourceLabel()
        if case .refreshingModels = state.phase {
            state.setPhase(.ready)
        }
        updateApplyLink()
        render()
    }

    @objc func authenticationModeChanged(_ sender: Any?) {
        if selectedAuthenticationMode == .openAIAccountWithAPI {
            authorizationStatusLabel.stringValue = authorizationStatusText(for: authorizationState)
        } else {
            authorizationStatusLabel.stringValue =
                "默认使用所选模型 API。有 OpenAI 账号？推荐同时授权；模型仍由当前 API 运行，并解锁全部官方插件入口与最佳兼容性。"
        }
        render()
    }

    func selectAuthenticationMode(_ mode: AuthenticationMode) {
        guard let index = authenticationModePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == mode.rawValue
        }) else { return }
        authenticationModePopup.selectItem(at: index)
        authenticationModeChanged(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === apiKeyField else { return }
        updateModelSourceLabel()
        render()
    }

    private func updateModelSourceLabel() {
        modelSourceLabel.stringValue = hasValidAPIKey
            ? modelSourceStatus
            : "输入有效 API Key 后可刷新上游模型"
    }

    @objc func openApplyKeyPage(_ sender: Any?) {
        openURLHandler(state.selectedProvider.applyURL)
    }

    @objc func retryPreflight(_ sender: Any?) {
        guard activeBackendOperation == nil else { return }
        Task { [weak self] in
            await self?.runPreflight()
        }
    }

    @objc func refreshModels(_ sender: Any?) {
        guard activeBackendOperation == nil, state.isPreflightReady, hasValidAPIKey else {
            updateModelSourceLabel()
            render()
            return
        }
        modelRefreshGeneration += 1
        let generation = modelRefreshGeneration
        let provider = state.selectedProvider
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        state.setPhase(.refreshingModels)
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await ProviderCatalogClient(transport: transport)
                    .fetchModels(provider: provider, apiKey: key)
                guard generation == modelRefreshGeneration,
                      provider == state.selectedProvider else { return }
                state.replaceModels(models, for: provider)
                populateModels()
                modelSourceStatus = "已从上游刷新"
                updateModelSourceLabel()
            } catch {
                guard generation == modelRefreshGeneration,
                      provider == state.selectedProvider else { return }
                modelSourceStatus = state.modelSource(for: provider) == .upstreamRefresh
                    ? "刷新失败，继续使用上游模型列表"
                    : "刷新失败，继续使用内置离线快照"
                updateModelSourceLabel()
                state.appendLog("模型刷新失败，\(modelSourceStatus)")
            }
            if case .refreshingModels = state.phase {
                state.setPhase(.ready)
            }
            render()
        }
    }

    @objc func beginInstallation(_ sender: Any?) {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeBackendOperation == nil, state.isPreflightReady else {
            render()
            return
        }
        guard key.count >= 8,
              let selectedModel = modelPopup.selectedItem?.representedObject as? String else {
            state.setPhase(.failed("请输入有效 API Key 并选择默认模型"))
            render()
            return
        }
        let models = state.models().map(\.id)
        let request = InstallRequest(
            provider: state.selectedProvider,
            apiKey: key,
            defaultModel: selectedModel,
            availableModels: models,
            modelSource: state.modelSource(),
            authenticationMode: selectedAuthenticationMode,
            dreamSkinPreset: (skinPopup.selectedItem?.representedObject as? String)
                ?? "preset-gothic-void-crusade"
        )
        cancellationRequested = false
        state.setPhase(.installing(0, "准备安装…"))
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await withBackendOperation(.install) {
                    try await self.backend.install(request: request) { [weak self] event in
                        Task { @MainActor in
                            self?.state.receive(event)
                            self?.render()
                        }
                    }
                }
                if state.phase != .completed {
                    state.setPhase(.completed)
                }
                await refreshAuthorizationStatus()
            } catch {
                if cancellationRequested {
                    state.setPhase(.ready)
                    state.appendLog("安装已取消，回滚流程已结束")
                } else {
                    state.setPhase(.failed("安装失败，请查看脱敏日志"))
                }
            }
            cancellationRequested = false
            render()
        }
    }

    @objc func stopInstallation(_ sender: Any?) {
        cancellationRequested = true
        backend.cancel()
        if case .installing(let progress, _) = state.phase {
            state.setPhase(.installing(progress, "正在取消并等待回滚…"))
            render()
        }
    }

    @objc func restoreLatest(_ sender: Any?) {
        guard activeBackendOperation == nil else { return }
        state.setPhase(.restoring)
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await withBackendOperation(.restore) {
                    try await self.backend.restoreLatest { [weak self] event in
                        Task { @MainActor in
                            self?.state.receive(event)
                            self?.render()
                        }
                    }
                }
                state.setPhase(.ready)
            } catch {
                state.setPhase(.failed("恢复最近备份失败"))
            }
            render()
        }
    }

    @objc func launchCodexPlus(_ sender: Any?) {
        if selectedAuthenticationMode == .openAIAccountWithAPI, !openAIAuthenticated {
            authorizationStatusLabel.stringValue = "请先完成 OpenAI 授权，或改用所选模型 API"
            render()
            return
        }
        openApplicationHandler(URL(fileURLWithPath: "/Applications/Codex++.app"))
    }

    @objc func openReport(_ sender: Any?) {
        if let reportURL = state.reportURL {
            openApplicationHandler(reportURL)
        }
    }

    @objc func loginOpenAIAccount(_ sender: Any?) {
        beginAuthorization(using: .browser)
    }

    @objc func authorizeWithDeviceCode(_ sender: Any?) {
        beginAuthorization(using: .deviceCode)
    }

    @objc func cancelAuthorization(_ sender: Any?) {
        authorizationClient.cancel()
        applyAuthorizationState(.cancelled)
    }

    @objc func usePureAPIFallback(_ sender: Any?) {
        selectAuthenticationMode(.pureAPI)
    }

    @objc func openUniScholar(_ sender: Any?) {
        openURLHandler(Self.uniScholarURL)
    }

    @objc func openResearchKit(_ sender: Any?) {
        openURLHandler(Self.researchKitURL)
    }

    private func runPreflight() async {
        guard activeBackendOperation == nil else { return }
        state.beginPreflight()
        render()
        do {
            let result = try await withBackendOperation(.preflight) {
                try await backend.preflight()
            }
            state.applyPreflight(result)
            let architecture = result.architecture == .arm64 ? "Apple Silicon" : "Intel"
            let translation = result.translated ? "，当前进程经 Rosetta 运行" : ""
            let existingCodexVersion =
                result.installedApplications["ChatGPT/Codex"]
                    ?? result.installedApplications["ChatGPT"]
            let reuseDescription = existingCodexVersion.map {
                " · 已检测到 Codex \($0)，安装时校验并复用"
            } ?? ""
            preflightStatusLabel.stringValue =
                "macOS \(result.macOSVersion) · \(architecture)\(translation) · 可用空间 \(formatBytes(result.availableDiskBytes))\(reuseDescription)"
            if existingCodexVersion != nil {
                installButton.title = "复用 Codex，一键配置"
            } else {
                installButton.title = result.mode == "upgrade" ? "升级并修复" : "开始一键安装"
            }
        } catch {
            let presentation = Self.preflightPresentation(for: error)
            state.markPreflightFailed(presentation.message)
            preflightStatusLabel.stringValue = "预检失败：\(presentation.message)"
            state.appendLog("预检错误 [\(presentation.code)]")
        }
        render()
    }

    func requestClose() -> Bool {
        guard activeBackendOperation == nil else {
            state.appendLog("后台操作仍在完成或回滚，请稍候")
            render()
            return false
        }
        return true
    }

    private func withBackendOperation<T>(
        _ operation: BackendOperation,
        body: () async throws -> T
    ) async rethrows -> T {
        precondition(activeBackendOperation == nil)
        activeBackendOperation = operation
        render()
        defer {
            activeBackendOperation = nil
            render()
        }
        return try await body()
    }

    private func beginAuthorization(using method: OpenAIAuthorizationMethod) {
        guard selectedAuthenticationMode == .openAIAccountWithAPI,
              activeBackendOperation == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.withBackendOperation(.authorization) {
                await self.authorizationClient.authorize(using: method) { [weak self] nextState in
                    self?.applyAuthorizationState(nextState)
                }
            }
        }
    }

    private func refreshAuthorizationStatus() async {
        applyAuthorizationState(await authorizationClient.refreshStatus())
    }

    private func applyAuthorizationState(_ nextState: OpenAIAuthorizationState) {
        authorizationState = nextState
        openAIAuthenticated = nextState == .authorized
        authorizationStatusLabel.stringValue = authorizationStatusText(for: nextState)
        render()
    }

    private func authorizationStatusText(for state: OpenAIAuthorizationState) -> String {
        switch state {
        case .unavailable(.codexNotInstalled):
            "安装 Codex 后获取授权"
        case .unavailable:
            "当前 Codex 不支持授权，请重新安装官方 Codex"
        case .ready:
            "将在系统浏览器打开 OpenAI 官方登录页面"
        case .launching:
            "正在准备 OpenAI 授权…"
        case .waitingForBrowser:
            "已在系统浏览器打开 OpenAI 官方登录页面"
        case .deviceCode:
            "请在 OpenAI 官方页面完成设备码授权"
        case .verifying:
            "正在验证 OpenAI 授权…"
        case .authorized:
            "OpenAI 已授权"
        case .cancelled:
            "OpenAI 授权已取消"
        case .timedOut:
            "OpenAI 授权超时，请重试或使用设备码授权"
        case .failed:
            "OpenAI 授权失败，请重试或使用设备码授权"
        }
    }

    static func preflightPresentation(for error: Error) -> (message: String, code: String) {
        let failure = error as? InstallerBackendFailure
        let code = failure?.code ?? "unknown"
        let message: String
        switch code {
        case "missing_backend_resource", "missing_support_tool", "missing_payload_metadata",
             "missing_plugin_payload", "missing_script_payload":
            message = "安装器资源不完整，请从完整 DMG 重新打开"
        case "unsupported_macos":
            message = "需要 macOS 14 或更高版本"
        case "insufficient_disk":
            message = "可用空间不足，至少需要 4 GB"
        case "invalid_plugin_payload", "invalid_payload_manifest":
            message = "安装包校验失败，请重新获取完整 DMG"
        default:
            message = "预检失败，请查看脱敏日志"
        }
        return (message, code)
    }

    private func populateModels() {
        let previous = modelPopup.selectedItem?.representedObject as? String
        modelPopup.removeAllItems()
        for model in state.models() {
            modelPopup.addItem(withTitle: model.displayName)
            modelPopup.lastItem?.representedObject = model.id
        }
        if let previous,
           let index = modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == previous }) {
            modelPopup.selectItem(at: index)
        } else if let preferred = preferredModelID(for: state.selectedProvider),
                  let index = modelPopup.itemArray.firstIndex(where: {
                      $0.representedObject as? String == preferred
                  }) {
            modelPopup.selectItem(at: index)
        } else if modelPopup.numberOfItems > 0 {
            modelPopup.selectItem(at: 0)
        }
    }

    private func preferredModelID(for provider: ProviderKind) -> String? {
        switch provider {
        case .kimiOpen: "kimi-k3"
        case .kimiCode: "k3"
        case .zhipu: "glm-5.2"
        case .qwen: "qwen3.7-max"
        case .xiaomiMiMo: "mimo-v2.5-pro"
        case .deepSeek: nil
        }
    }

    private func updateApplyLink() {
        let provider = state.selectedProvider
        applyKeyButton.title = "申请 \(provider.displayName) API Key"
        applyKeyButton.toolTip = "打开 \(provider.displayName) API Key 申请页面：\(provider.applyURL.absoluteString)"
    }

    private func render() {
        let phase = state.phase
        let phaseIsBusy: Bool
        switch phase {
        case .preflight:
            phaseIsBusy = true
            phaseLabel.stringValue = "正在执行安装前检查…"
            progressIndicator.doubleValue = 0
        case .ready:
            phaseIsBusy = false
            phaseLabel.stringValue = "准备就绪"
            progressIndicator.doubleValue = 0
        case .refreshingModels:
            phaseIsBusy = true
            phaseLabel.stringValue = "正在读取上游可用模型…"
        case .installing(let progress, let message):
            phaseIsBusy = true
            phaseLabel.stringValue = message
            progressIndicator.doubleValue = max(0, min(1, progress))
        case .completed:
            phaseIsBusy = false
            phaseLabel.stringValue = "安装完成"
            progressIndicator.doubleValue = 1
        case .failed(let message):
            phaseIsBusy = false
            phaseLabel.stringValue = message
        case .restoring:
            phaseIsBusy = true
            phaseLabel.stringValue = "正在恢复最近备份…"
        }

        let isBusy = phaseIsBusy || hasActiveBackendOperation
        let isInstalling: Bool
        if case .installing = phase { isInstalling = true } else { isInstalling = false }
        providerPopup.isEnabled = !isBusy
        kimiTypePopup.isEnabled = !isBusy
        authenticationModePopup.isEnabled = !isBusy
        apiKeyField.isEnabled = !isBusy
        modelPopup.isEnabled = !isBusy
        skinPopup.isEnabled = !isBusy
        refreshModelsButton.isEnabled = !isBusy && state.isPreflightReady && hasValidAPIKey
        applyKeyButton.isEnabled = !isBusy
        installButton.isEnabled = !isBusy
            && state.isPreflightReady
            && hasValidAPIKey
            && modelPopup.numberOfItems > 0
        stopButton.isEnabled = isInstalling
        restoreButton.isHidden = state.latestBackup == nil
        restoreButton.isEnabled = !isBusy && state.latestBackup != nil
        retryPreflightButton.isHidden = state.isPreflightReady || hasActiveBackendOperation
        retryPreflightButton.isEnabled = !state.isPreflightReady && !hasActiveBackendOperation
        let completed = phase == .completed
        let usesOpenAIAccount = selectedAuthenticationMode == .openAIAccountWithAPI
        let authorizationInProgress: Bool
        switch authorizationState {
        case .launching, .waitingForBrowser, .deviceCode, .verifying:
            authorizationInProgress = true
        default:
            authorizationInProgress = false
        }
        let authorizationUnavailable: Bool
        if case .unavailable = authorizationState {
            authorizationUnavailable = true
        } else {
            authorizationUnavailable = false
        }
        loginOpenAIButton.isHidden = !usesOpenAIAccount || openAIAuthenticated
        loginOpenAIButton.isEnabled = usesOpenAIAccount && !isBusy && !authorizationUnavailable
        deviceCodeAuthorizationButton.isHidden = !usesOpenAIAccount || openAIAuthenticated
        deviceCodeAuthorizationButton.isEnabled = usesOpenAIAccount && !isBusy && !authorizationUnavailable
        cancelAuthorizationButton.isHidden = !usesOpenAIAccount || !authorizationInProgress
        cancelAuthorizationButton.isEnabled = authorizationInProgress
        let needsFallback: Bool
        switch authorizationState {
        case .failed, .timedOut, .cancelled:
            needsFallback = true
        default:
            needsFallback = false
        }
        usePureAPIFallbackButton.isHidden = !usesOpenAIAccount || !needsFallback
        usePureAPIFallbackButton.isEnabled = !isBusy
        launchButton.superview?.isHidden = !completed
        launchButton.isHidden = !completed
        launchButton.isEnabled = completed
            && !isBusy
            && (!usesOpenAIAccount || openAIAuthenticated)
        reportButton.isHidden = !completed
        reportButton.isEnabled = state.reportURL != nil
        logTextView.string = state.redactedLogLines.joined(separator: "\n")
        if !logTextView.string.isEmpty {
            logTextView.scrollToEndOfDocument(nil)
        }
    }

    private func formLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func configurePromotionButton(
        _ button: NSButton,
        symbol: String,
        action: Selector,
        tooltip: String
    ) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: button.title
        )
        button.imagePosition = .imageLeading
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.distribution = .fill
        views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func defaultCatalog() -> ProviderCatalogStore {
        if let url = Bundle.main.url(forResource: "model-catalog", withExtension: "json"),
           let catalog = try? ProviderCatalogStore.load(from: url) {
            return catalog
        }
        return ProviderCatalogStore(
            schemaVersion: 1,
            generatedAt: "offline",
            providers: [
                ProviderDefinition(
                    kind: .deepSeek,
                    protocolName: "chatCompletions",
                    models: [
                        ModelDefinition(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", contextWindow: 1_000_000),
                        ModelDefinition(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", contextWindow: 1_000_000)
                    ]
                ),
                ProviderDefinition(
                    kind: .kimiOpen,
                    protocolName: "chatCompletions",
                    models: [
                        ModelDefinition(id: "kimi-k2.6", displayName: "Kimi K2.6", contextWindow: 262_144),
                        ModelDefinition(id: "kimi-k2.7-code", displayName: "Kimi K2.7 Code", contextWindow: 262_144),
                        ModelDefinition(id: "kimi-k2.7-code-highspeed", displayName: "Kimi K2.7 Code HighSpeed", contextWindow: 262_144),
                        ModelDefinition(id: "kimi-k3", displayName: "Kimi K3", contextWindow: 1_000_000)
                    ]
                ),
                ProviderDefinition(
                    kind: .kimiCode,
                    protocolName: "chatCompletions",
                    models: [
                        ModelDefinition(id: "k3", displayName: "Kimi K3", contextWindow: 1_048_576),
                        ModelDefinition(id: "kimi-for-coding", displayName: "Kimi K2.7 Code", contextWindow: 262_144),
                        ModelDefinition(id: "kimi-for-coding-highspeed", displayName: "Kimi K2.7 Code HighSpeed", contextWindow: 262_144)
                    ]
                ),
                ProviderDefinition(
                    kind: .zhipu,
                    protocolName: "chatCompletions",
                    models: [
                        ModelDefinition(id: "glm-4-flash-250414", displayName: "GLM-4-Flash-250414", contextWindow: nil),
                        ModelDefinition(id: "glm-4-flashx-250414", displayName: "GLM-4-FlashX-250414", contextWindow: nil),
                        ModelDefinition(id: "glm-4.5-air", displayName: "GLM-4.5-Air", contextWindow: nil),
                        ModelDefinition(id: "glm-4.5-airx", displayName: "GLM-4.5-AirX", contextWindow: nil),
                        ModelDefinition(id: "glm-4.5-flash", displayName: "GLM-4.5-Flash", contextWindow: nil),
                        ModelDefinition(id: "glm-4.6", displayName: "GLM-4.6", contextWindow: nil),
                        ModelDefinition(id: "glm-4.7", displayName: "GLM-4.7", contextWindow: nil),
                        ModelDefinition(id: "glm-4.7-flash", displayName: "GLM-4.7-Flash", contextWindow: nil),
                        ModelDefinition(id: "glm-4.7-flashx", displayName: "GLM-4.7-FlashX", contextWindow: nil),
                        ModelDefinition(id: "glm-5", displayName: "GLM-5", contextWindow: nil),
                        ModelDefinition(id: "glm-5-turbo", displayName: "GLM-5-Turbo", contextWindow: nil),
                        ModelDefinition(id: "glm-5.1", displayName: "GLM-5.1", contextWindow: nil),
                        ModelDefinition(id: "glm-5.2", displayName: "GLM-5.2", contextWindow: 1_000_000)
                    ]
                ),
                ProviderDefinition(
                    kind: .qwen,
                    protocolName: "chatCompletions",
                    models: [
                        ModelDefinition(id: "qwen3.7-flash", displayName: "Qwen3.7-Flash", contextWindow: 1_000_000),
                        ModelDefinition(id: "qwen3.7-max", displayName: "Qwen3.7-Max", contextWindow: 1_000_000),
                        ModelDefinition(id: "qwen3.7-plus", displayName: "Qwen3.7-Plus", contextWindow: 1_000_000)
                    ]
                ),
                ProviderDefinition(
                    kind: .xiaomiMiMo,
                    protocolName: "chatCompletions",
                    models: [
                        ModelDefinition(id: "mimo-v2.5", displayName: "MiMo-V2.5", contextWindow: 1_000_000),
                        ModelDefinition(id: "mimo-v2.5-pro", displayName: "MiMo-V2.5-Pro", contextWindow: 1_000_000)
                    ]
                )
            ]
        )
    }
}

@MainActor
func makeInstallerWindow(controller: InstallerViewController) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Codex 一键安装"
    window.minSize = NSSize(width: 800, height: 640)
    window.contentViewController = controller
    window.center()
    return window
}

@MainActor
final class InstallerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var controller: InstallerViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let backend = BackendRunner(coreURL: resources.appendingPathComponent("installer-core.sh"))
        let controller = InstallerViewController(
            backend: backend,
            transport: URLSessionTransport(),
            authorizationClient: OfficialCodexAuthorizationClient()
        )
        let window = makeInstallerWindow(controller: controller)
        self.controller = controller
        self.window = window
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        controller?.requestClose() ?? true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.hasActiveBackendOperation == true ? .terminateCancel : .terminateNow
    }
}

@main
struct CodexOneClickInstallerApplication {
    @MainActor private static let appDelegate = InstallerAppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        app.run()
    }
}
