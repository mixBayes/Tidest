import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let shortcut = GlobalShortcut()
    private let layoutShortcut = GlobalShortcut()
    private let multiLayoutShortcut = GlobalShortcut()
    private let pinShortcut = GlobalShortcut()
    private let switcher = SwitcherController()
    private let quickLayout = QuickLayoutController()
    private lazy var multiLayout = MultiWindowLayoutController(settings: settings)
    private let settings = AppSettings.shared
    private lazy var pinnedWindows = PinnedWindowsController(settings: settings, catalog: switcher.catalog)
    private var guideWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let providedUpdateChecker: UpdateChecker?
    private lazy var updateChecker = providedUpdateChecker ?? makeUpdateChecker()
    private let updateReminder = UpdateReminder()
    private var updateObservation: AnyCancellable?
    private var usageWindow: NSWindow?
    private var statisticsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var currentGuide: PermissionGuide?
    private var guideOpenedManually = false
    private var isRecordingShortcut = false
    private var permissionTimer: Timer?
    private var languageObservation: AnyCancellable?
    private var activityEventMonitor: Any?
    private var permissions: PermissionStore
    private var lastAccessibilityGranted = false
    private var lastScreenCaptureGranted: Bool?

    override convenience init() {
        self.init(permissions: PermissionStore(preview: AppDelegate.isPreviewMode))
    }

    init(permissions: PermissionStore, updateChecker: UpdateChecker? = nil) {
        self.permissions = permissions
        self.providedUpdateChecker = updateChecker
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        languageObservation = settings.$language.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            settingsWindow?.title = settings.text("设置")
            aboutWindow?.title = settings.text("关于 Tidest")
            usageWindow?.title = settings.text("使用说明")
            statisticsWindow?.title = settings.text("使用统计")
            updateReminder.hide()
            refreshUpdateIndicators()
        }
        updateObservation = updateChecker.$availableUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUpdateIndicators() }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if isPreview {
            if arguments.contains("--ui-preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            settings.displayMode = arguments.contains("--ui-preview-tiled") ? .tiled : .carousel
            if let rawLanguage = arguments.first(where: { $0.hasPrefix("--ui-preview-language=") }),
               let language = AppLanguage(rawValue: String(rawLanguage.dropFirst("--ui-preview-language=".count))) {
                settings.language = language
            }
        }
        if arguments.contains("--ui-preview-update-reminder") { return }
        if arguments.contains("--ui-preview-about") {
            showAbout()
            return
        }
        if arguments.contains("--ui-preview-usage") {
            showUsageGuide()
            return
        }
        if arguments.contains("--ui-preview-statistics") {
            showStatistics()
            return
        }
        if arguments.contains("--ui-preview-settings") {
            permissions = PermissionStore(preview: true,
                                          accessibility: arguments.contains("--ui-preview-granted-accessibility"),
                                          screenCapture: arguments.contains("--ui-preview-granted-screen"))
            showSettings()
            return
        }
        if arguments.contains("--ui-preview-switcher") {
            let count = arguments.first { $0.hasPrefix("--ui-preview-count=") }
                .flatMap { Int($0.dropFirst("--ui-preview-count=".count)) } ?? 5
            switcher.showPreview(count: count)
            return
        }
        if arguments.contains("--ui-preview-multi-layout") {
            multiLayout.present(preview: true)
            return
        }
        if arguments.contains("--ui-preview-layout") {
            quickLayout.showPreview(constrained: arguments.contains("--ui-preview-layout-constrained"))
            return
        }
        if arguments.contains("--ui-preview-pinned") {
            let count = arguments.first { $0.hasPrefix("--ui-preview-count=") }
                .flatMap { Int($0.dropFirst("--ui-preview-count=".count)) } ?? 5
            pinnedWindows.showPreview(count: count,
                withThumbnails: arguments.contains("--ui-preview-thumbnails"))
            return
        }
        if arguments.contains("--ui-preview-accessibility") {
            permissions = PermissionStore(preview: true)
            showGuide()
            return
        }
        if arguments.contains("--ui-preview-screen") {
            permissions = PermissionStore(preview: true, accessibility: true)
            showGuide()
            return
        }
        #endif
        updateChecker.start()
        // Local input belongs to Tidest's own windows and menus. Record only
        // that an interaction happened; never retain keys or pointer positions.
        // This also catches a new day's use of a panel left open overnight.
        activityEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { _ = DailyActivityReporter.shared.recordActivity() }
            return event
        }
        shortcut.onPress = { [weak self] direction in
            guard let self else { return }
            refreshPermissions()
            guard permissions.accessibilityGranted, !multiLayout.isApplying else { return }
            quickLayout.dismiss()
            multiLayout.dismiss()
            pinnedWindows.cancelInteraction()
            switcher.press(direction, captureEnabled: permissions.screenCaptureGranted)
        }
        shortcut.onRelease = { [weak self] in self?.switcher.releaseShortcutKey() }
        layoutShortcut.onPress = { [weak self] _ in
            guard let self else { return }
            refreshPermissions()
            guard permissions.accessibilityGranted, !isRecordingShortcut, !multiLayout.isApplying else { return }
            switcher.dismiss()
            pinnedWindows.cancelInteraction()
            multiLayout.dismiss()
            quickLayout.present()
        }
        layoutShortcut.onRelease = { [weak self] in self?.quickLayout.releaseShortcutKey() }
        pinShortcut.onPress = { [weak self] _ in
            guard let self else { return }
            refreshPermissions()
            guard permissions.accessibilityGranted, settings.pinningEnabled, !isRecordingShortcut, !multiLayout.isApplying,
                  !pinnedWindows.isShortcutHeld else { return }
            switcher.dismiss()
            quickLayout.dismiss()
            multiLayout.dismiss()
            pinnedWindows.pressShortcut()
        }
        pinShortcut.onRelease = { [weak self] in self?.pinnedWindows.releaseShortcut() }
        multiLayoutShortcut.onPress = { [weak self] _ in self?.showMultiWindowLayout() }
        startPermissionPolling()
        refreshPermissions()
        if let guide = permissions.startupGuide {
            if currentGuide != guide || guideWindow?.isVisible != true { presentGuide(guide, manuallyOpened: false) }
        }
        else if hasShortcutMessage { showSettings() }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Tidest")
            button.setAccessibilityIdentifier("tidestMenuBarIcon")
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        updateReminder.hide()
        DailyActivityReporter.shared.recordActivity()
        if NSApp.currentEvent?.type != .rightMouseUp {
            refreshPermissions()
        }
        // Rebuild the menu with the current language and shortcuts each time.
        statusItem?.menu = makeStatusMenu()
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        func addAction(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        func addShortcut(_ title: String, _ shortcut: WindowShortcut) {
            let item = NSMenuItem(title: settings.text("%@ · %@", settings.text(title), shortcut.symbolDisplayName),
                                  action: nil, keyEquivalent: "")
            item.setAccessibilityLabel(settings.text("%@ · %@", settings.text(title), shortcut.displayName))
            menu.addItem(item)
        }
        addAction(settings.text("设置"), #selector(showSettings), key: ",")
        menu.addItem(.separator())
        addShortcut("窗口切换", settings.shortcut)
        addShortcut("窗口定位", settings.layoutShortcut)
        let multiTitle = settings.multiLayoutShortcut.map { settings.text("%@ · %@", settings.text("快速布局"), $0.symbolDisplayName) } ?? settings.text("快速布局…")
        addAction(multiTitle, #selector(showMultiWindowLayout))
        menu.items.last?.setAccessibilityIdentifier("openMultiWindowLayout")
        if multiLayout.undoAvailable {
            addAction(settings.text("撤销上次快速布局"), #selector(undoMultiWindowLayout))
        }
        if settings.pinningEnabled { addShortcut("拾取窗口", settings.pinShortcut) }
        addAction(settings.text("使用说明"), #selector(showUsageGuide))
        addAction(settings.text("使用统计"), #selector(showStatistics))
        menu.addItem(.separator())
        let aboutTitle = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .map { settings.text("关于 Tidest %@", $0) } ?? settings.text("关于 Tidest")
        addAction(aboutTitle, #selector(showAbout))
        if let about = menu.items.last, updateChecker.availableUpdate != nil {
            about.attributedTitle = UpdateReminder.aboutTitle(aboutTitle)
            about.setAccessibilityLabel(settings.text("%@，有新版本", aboutTitle))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: settings.text("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func refreshUpdateIndicators() {
        guard let button = statusItem?.button else { return }
        let hasUpdate = updateChecker.availableUpdate != nil
        button.image = UpdateReminder.statusImage(hasUpdate: hasUpdate)
        button.image?.isTemplate = true
        button.setAccessibilityLabel(hasUpdate ? settings.text("Tidest，有新版本") : "Tidest")
        guard hasUpdate else {
            updateReminder.hide()
            return
        }
        if aboutWindow?.isVisible != true, !updateChecker.shouldPromptForDownload,
           updateChecker.needsUpdateReminder,
           updateReminder.show(relativeTo: button, settings: settings, onClick: { [weak self] in self?.showAbout() }) {
            updateChecker.markUpdateReminderShown()
        }
    }

    @discardableResult
    private func bringGuideToFront() -> Bool {
        guard currentGuide != nil, let window = guideWindow else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // A menu request always shows the missing permission, even when reminders are suppressed.
    func showGuide() {
        permissions.refresh()
        presentGuide(permissions.manualGuide, manuallyOpened: true)
    }

    @objc func showUsageGuide() {
        switcher.dismiss()
        quickLayout.dismiss()
        multiLayout.dismiss()
        pinnedWindows.cancelInteraction()
        if usageWindow == nil {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: UsageGuideView.windowSize),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            let content = NSHostingView(rootView: UsageGuideView(settings: settings))
            window.contentView = content
            window.setContentSize(content.fittingSize)
            window.center()
            usageWindow = window
        }
        usageWindow?.title = settings.text("使用说明")
        NSApp.activate()
        usageWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showStatistics() {
        switcher.dismiss()
        quickLayout.dismiss()
        multiLayout.dismiss()
        pinnedWindows.cancelInteraction()
        if statisticsWindow == nil {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: UsageStatisticsView.windowSize),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            let content = NSHostingView(rootView: UsageStatisticsView(settings: settings, statistics: .shared))
            window.contentView = content
            window.setContentSize(content.fittingSize)
            window.center()
            statisticsWindow = window
        }
        statisticsWindow?.title = settings.text("使用统计")
        NSApp.activate()
        statisticsWindow?.makeKeyAndOrderFront(nil)
    }

    private func presentGuide(_ guide: PermissionGuide, manuallyOpened: Bool) {
        switcher.dismiss()
        quickLayout.dismiss()
        multiLayout.dismiss()
        pinnedWindows.cancelInteraction()
        if guide == .accessibility && !isPreview {
            shortcut.stop()
            layoutShortcut.stop()
            multiLayoutShortcut.stop()
            pinShortcut.stop()
            switcher.stop()
            quickLayout.stop()
            multiLayout.stop()
            pinnedWindows.stop()
            settingsWindow?.makeFirstResponder(nil)
            settingsWindow?.orderOut(nil)
            isRecordingShortcut = false
        }
        if guideWindow == nil {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: ContentView.windowSize(for: guide)),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Tidest"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            guideWindow = window
        }
        currentGuide = guide
        guideOpenedManually = manuallyOpened
        guideWindow?.setContentSize(ContentView.windowSize(for: guide))
        guideWindow?.contentView = NSHostingView(rootView: ContentView(
            permissions: permissions, settings: settings, guide: guide,
            onFinish: { [weak self] in self?.finishGuide() },
            onQuit: { [weak self] in self?.quitGuide() }))
        bringGuideToFront()
        startPermissionPolling()
    }

    private func finishGuide() {
        let finishingGuide = currentGuide
        if !isPreview {
            refreshPermissions()
            guard permissions.accessibilityGranted else { return }
        }
        if finishingGuide == .screenCapture {
            presentGuide(.granted, manuallyOpened: guideOpenedManually)
            return
        }
        guideWindow?.close()
        guard !isPreview else { return }
        startShortcuts()
        if hasShortcutMessage { showSettings() }
    }

    private func quitGuide() {
        if isPreview { guideWindow?.close() }
        else { NSApp.terminate(nil) }
    }

    @objc func showSettings() {
        switcher.dismiss()
        quickLayout.dismiss()
        multiLayout.dismiss()
        pinnedWindows.cancelInteraction()
        refreshPermissions()
        guard isPreview || permissions.accessibilityGranted else {
            bringGuideToFront()
            return
        }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsView.windowSize),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(permissions: permissions, settings: settings,
                onShortcutChange: { [weak self] value in self?.changeShortcut(value) },
                onRecordingChange: { [weak self] recording in self?.setShortcutRecording(recording) },
                onLayoutShortcutChange: { [weak self] value in self?.changeLayoutShortcut(value) },
                onMultiLayoutShortcutChange: { [weak self] value in self?.changeMultiLayoutShortcut(value) },
                onPinShortcutChange: { [weak self] value in self?.changePinShortcut(value) },
                onPinEnabledChange: { [weak self] enabled in self?.setPinningEnabled(enabled) }))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = settings.text("设置")
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout() {
        updateReminder.hide()
        switcher.dismiss()
        quickLayout.dismiss()
        multiLayout.dismiss()
        pinnedWindows.cancelInteraction()
        if aboutWindow == nil {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: AboutView.windowSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            let checker = updateChecker
            let content = NSHostingView(rootView: AboutView(settings: settings, updateChecker: checker,
                onUpdateAvailable: { [weak self] in
                    Task { @MainActor [weak self] in self?.showUpdatePrompt(checker) }
                }))
            window.contentView = content
            window.setContentSize(content.fittingSize)
            window.center()
            aboutWindow = window
        }
        aboutWindow?.title = settings.text("关于 Tidest")
        NSApp.activate()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    private func showUpdatePrompt(_ checker: UpdateChecker) {
        guard aboutWindow?.isVisible == true,
              case .updateAvailable(let version) = checker.state else { return }
        let alert = NSAlert()
        alert.messageText = settings.text("发现新版本")
        alert.informativeText = settings.text("Tidest %@ 已可下载，是否现在下载？", version)
        alert.addButton(withTitle: settings.text("下载"))
        alert.addButton(withTitle: settings.text("稍后")).keyEquivalent = "\u{1b}"
        alert.window.identifier = NSUserInterfaceItemIdentifier("updatePrompt")
        alert.window.title = settings.text("Tidest 更新")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { checker.downloadUpdate() }
        else { checker.deferUpdate() }
    }

    private func makeUpdateChecker() -> UpdateChecker {
        let checker: UpdateChecker
        #if DEBUG
        if isPreview, let preview = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-preview-update=") }) {
            let outcome = String(preview.dropFirst("--ui-preview-update=".count))
            checker = UpdateChecker.preview(outcome: outcome)
        } else {
            checker = UpdateChecker()
        }
        #else
        checker = UpdateChecker()
        #endif
        checker.onFocus = { [weak self] in self?.showAbout() }
        checker.onReadyToInstall = { [weak self, weak checker] in
            Task { @MainActor [weak self, weak checker] in
                guard let self, let checker else { return }
                showAbout()
                showRestartPrompt(checker)
            }
        }
        return checker
    }

    private func showRestartPrompt(_ checker: UpdateChecker) {
        guard case .readyToInstall(let version) = checker.state else { return }
        let alert = NSAlert()
        alert.messageText = settings.text("更新已准备好")
        alert.informativeText = settings.text("Tidest %@ 已准备好。现在重启，或在下次退出 Tidest 时完成更新。", version)
        alert.addButton(withTitle: settings.text("重启并更新"))
        alert.addButton(withTitle: settings.text("稍后")).keyEquivalent = "\u{1b}"
        alert.window.identifier = NSUserInterfaceItemIdentifier("updateReadyPrompt")
        alert.window.title = settings.text("Tidest 更新")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { checker.restartAndInstall() }
        else { checker.deferUpdate() }
    }

    private func changeShortcut(_ value: WindowShortcut) -> String? {
        if let multi = settings.multiLayoutShortcut, value.hasSameKeys(as: multi) { return "这个快捷键用于快速布局，请选择其他快捷键。" }
        guard value.isValid else { return "请按住 Control、Option 或 Command，再按另一个键。" }
        guard !value.hasSameKeys(as: settings.layoutShortcut) else { return "这个快捷键用于窗口定位，请选择其他快捷键。" }
        guard !value.hasSameKeys(as: settings.pinShortcut) else { return "这个快捷键用于拾取窗口，请选择其他快捷键。" }
        switcher.dismiss()
        quickLayout.dismiss()
        multiLayout.dismiss()
        pinnedWindows.cancelInteraction()
        permissions.refresh()
        if !isPreview && permissions.accessibilityGranted {
            let status = shortcut.start(value)
            guard status == noErr else {
                return status == eventHotKeyExistsErr ? "这个快捷键已被占用，请换一个。" : "暂时无法启用这个快捷键，请再试一次。"
            }
        }
        settings.shortcut = value
        permissions.shortcutMessage = nil
        refreshPermissions()
        return nil
    }

    private func changeLayoutShortcut(_ value: WindowShortcut) -> String? {
        if let multi = settings.multiLayoutShortcut, value.hasSameKeys(as: multi) { return "这个快捷键用于快速布局，请选择其他快捷键。" }
        guard value.isValid else { return "请按住 Control、Option 或 Command，再按另一个键。" }
        guard !value.hasSameKeys(as: settings.shortcut) else { return "这个快捷键用于窗口切换，请选择其他快捷键。" }
        guard !value.hasSameKeys(as: settings.pinShortcut) else { return "这个快捷键用于拾取窗口，请选择其他快捷键。" }
        switcher.dismiss()
        quickLayout.dismiss()
        multiLayout.dismiss()
        pinnedWindows.cancelInteraction()
        permissions.refresh()
        if !isPreview && permissions.accessibilityGranted {
            let status = layoutShortcut.start(value)
            guard status == noErr else {
                return status == eventHotKeyExistsErr ? "这个快捷键已被占用，请换一个。" : "暂时无法启用这个快捷键，请再试一次。"
            }
        }
        settings.layoutShortcut = value
        permissions.layoutShortcutMessage = nil
        refreshPermissions()
        return nil
    }

    @objc func showMultiWindowLayout() {
        refreshPermissions()
        guard !isRecordingShortcut, !multiLayout.isApplying else { return }
        guard isPreview || permissions.accessibilityGranted else { showGuide(); return }
        switcher.dismiss()
        quickLayout.stop()
        pinnedWindows.cancelInteraction()
        multiLayout.present(preview: isPreview)
    }

    @objc private func undoMultiWindowLayout() {
        guard !multiLayout.isApplying else { return }
        switcher.dismiss()
        quickLayout.stop()
        pinnedWindows.cancelInteraction()
        multiLayout.presentUndo()
    }

    private func changeMultiLayoutShortcut(_ value: WindowShortcut?) -> String? {
        if let value {
            guard value.isValid else { return "请按住 Control、Option 或 Command，再按另一个键。" }
            guard !value.hasSameKeys(as: settings.shortcut) else { return "这个快捷键用于窗口切换，请选择其他快捷键。" }
            guard !value.hasSameKeys(as: settings.layoutShortcut) else { return "这个快捷键用于窗口定位，请选择其他快捷键。" }
            guard !value.hasSameKeys(as: settings.pinShortcut) else { return "这个快捷键用于拾取窗口，请选择其他快捷键。" }
            permissions.refresh()
            if !isPreview && permissions.accessibilityGranted {
                let status = multiLayoutShortcut.start(value)
                guard status == noErr else { return status == eventHotKeyExistsErr ? "这个快捷键已被占用，请换一个。" : "暂时无法启用这个快捷键，请再试一次。" }
            }
        } else { multiLayoutShortcut.stop() }
        settings.multiLayoutShortcut = value
        permissions.multiLayoutShortcutMessage = nil
        return nil
    }

    private func startMultiLayoutShortcut() {
        guard let value = settings.multiLayoutShortcut else { multiLayoutShortcut.stop(); return }
        guard ![settings.shortcut, settings.layoutShortcut, settings.pinShortcut].contains(where: { $0.hasSameKeys(as: value) }) else {
            multiLayoutShortcut.stop()
            permissions.multiLayoutShortcutMessage = "这个快捷键已被占用，请在设置中换一个。"
            return
        }
        let status = multiLayoutShortcut.start(value)
        permissions.multiLayoutShortcutMessage = status == noErr ? nil : "这个快捷键已被占用，请在设置中换一个。"
    }

    private func changePinShortcut(_ value: WindowShortcut) -> String? {
        if let multi = settings.multiLayoutShortcut, value.hasSameKeys(as: multi) { return "这个快捷键用于快速布局，请选择其他快捷键。" }
        guard value.isValid else { return "请按住 Control、Option 或 Command，再按另一个键。" }
        guard !value.hasSameKeys(as: settings.shortcut) else { return "这个快捷键用于窗口切换，请选择其他快捷键。" }
        guard !value.hasSameKeys(as: settings.layoutShortcut) else { return "这个快捷键用于窗口定位，请选择其他快捷键。" }
        pinnedWindows.cancelInteraction()
        permissions.refresh()
        if !isPreview && permissions.accessibilityGranted && settings.pinningEnabled {
            guard pinnedWindows.start(captureEnabled: permissions.screenCaptureGranted) else {
                return "暂时无法启用拾取窗口，请重新打开 Tidest。"
            }
            let status = pinShortcut.start(value)
            guard status == noErr else {
                return status == eventHotKeyExistsErr ? "这个快捷键已被占用，请换一个。" : "暂时无法启用这个快捷键，请再试一次。"
            }
        }
        settings.pinShortcut = value
        permissions.pinShortcutMessage = nil
        return nil
    }

    private func setPinningEnabled(_ enabled: Bool) {
        settings.pinningEnabled = enabled
        permissions.refresh()
        if enabled && !isPreview && permissions.accessibilityGranted && !isRecordingShortcut {
            startPinning()
        } else if !enabled {
            pinShortcut.stop()
            pinnedWindows.stop()
            permissions.pinShortcutMessage = nil
        }
    }

    private func setShortcutRecording(_ recording: Bool) {
        guard recording != isRecordingShortcut else { return }
        isRecordingShortcut = recording
        guard !isPreview else { return }
        if recording {
            shortcut.stop()
            layoutShortcut.stop()
            multiLayoutShortcut.stop()
            pinShortcut.stop()
            quickLayout.dismiss()
            multiLayout.dismiss()
            pinnedWindows.stop()
        }
        else {
            permissions.refresh()
            startShortcuts()
        }
    }

    private func startPermissionPolling() {
        guard !isPreview, permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshPermissions() {
        permissions.refresh()
        guard !isPreview else { return }
        let accessibilityChanged = lastAccessibilityGranted != permissions.accessibilityGranted
        lastAccessibilityGranted = permissions.accessibilityGranted
        if lastScreenCaptureGranted != permissions.screenCaptureGranted {
            lastScreenCaptureGranted = permissions.screenCaptureGranted
            switcher.updateCapturePermission(permissions.screenCaptureGranted)
            pinnedWindows.updateCapturePermission(permissions.screenCaptureGranted)
            if permissions.screenCaptureGranted && permissions.accessibilityGranted { switcher.scheduleStartupPreviews() }
        }
        if !permissions.accessibilityGranted {
            if accessibilityChanged || shortcut.registeredShortcut != nil || layoutShortcut.registeredShortcut != nil || pinShortcut.registeredShortcut != nil || multiLayoutShortcut.registeredShortcut != nil || switcher.isPresented || quickLayout.isPresented || multiLayout.isPresented || pinnedWindows.isEnabled {
                shortcut.stop()
                layoutShortcut.stop()
                multiLayoutShortcut.stop()
                pinShortcut.stop()
                switcher.stop()
                quickLayout.stop()
                multiLayout.stop()
                pinnedWindows.stop()
            }
            if aboutWindow?.isVisible != true, usageWindow?.isVisible != true, statisticsWindow?.isVisible != true,
               currentGuide != .accessibility || guideWindow?.isVisible != true {
                presentGuide(.accessibility, manuallyOpened: guideOpenedManually)
            }
            return
        }
        if accessibilityChanged { startShortcuts() }
        if guideWindow?.isVisible == true {
            if currentGuide == .accessibility {
                let nextGuide = guideOpenedManually
                    ? permissions.manualGuide
                    : (permissions.startupGuide ?? .granted)
                presentGuide(nextGuide, manuallyOpened: guideOpenedManually)
            } else if currentGuide == .screenCapture && permissions.screenCaptureGranted {
                presentGuide(.granted, manuallyOpened: guideOpenedManually)
            }
        }
        if accessibilityChanged && currentGuide == nil && hasShortcutMessage { showSettings() }
    }

    private static var isPreviewMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-preview-") }
        #else
        false
        #endif
    }

    private var isPreview: Bool { Self.isPreviewMode }

    private var hasShortcutMessage: Bool {
        permissions.shortcutMessage != nil || permissions.layoutShortcutMessage != nil || permissions.pinShortcutMessage != nil || permissions.multiLayoutShortcutMessage != nil
    }

    private func startShortcuts() {
        guard !isPreview, permissions.accessibilityGranted, !isRecordingShortcut else { return }
        let layoutStatus = layoutShortcut.start(settings.layoutShortcut)
        permissions.layoutShortcutMessage = layoutStatus == noErr ? nil :
            (layoutStatus == eventHotKeyExistsErr ? "这个快捷键已被占用，请在设置中换一个。" : "暂时无法启用快捷键，请在设置中重新选择。")
        startPinning()
        startMultiLayoutShortcut()
        guard !settings.shortcut.hasSameKeys(as: settings.layoutShortcut) else {
            shortcut.stop()
            permissions.shortcutMessage = "这个快捷键用于窗口定位，请选择其他快捷键。"
            return
        }
        let wasRegistered = shortcut.registeredShortcut != nil
        let status = shortcut.start(settings.shortcut)
        if status != noErr {
            permissions.shortcutMessage = status == eventHotKeyExistsErr ? "这个快捷键已被占用，请在设置中换一个。" : "暂时无法启用快捷键，请在设置中重新选择。"
            return
        }
        permissions.shortcutMessage = nil
        if !wasRegistered { switcher.scheduleStartupPreviews() }
    }

    private func startPinning() {
        guard !isPreview, permissions.accessibilityGranted, !isRecordingShortcut else { return }
        guard settings.pinningEnabled else {
            pinShortcut.stop()
            pinnedWindows.stop()
            permissions.pinShortcutMessage = nil
            return
        }
        guard !settings.pinShortcut.hasSameKeys(as: settings.shortcut) else {
            pinShortcut.stop()
            permissions.pinShortcutMessage = "这个快捷键用于窗口切换，请选择其他快捷键。"
            return
        }
        guard !settings.pinShortcut.hasSameKeys(as: settings.layoutShortcut) else {
            pinShortcut.stop()
            permissions.pinShortcutMessage = "这个快捷键用于窗口定位，请选择其他快捷键。"
            return
        }
        guard pinnedWindows.start(captureEnabled: permissions.screenCaptureGranted) else {
            pinShortcut.stop()
            permissions.pinShortcutMessage = "暂时无法启用拾取窗口，请重新打开 Tidest。"
            return
        }
        let status = pinShortcut.start(settings.pinShortcut)
        permissions.pinShortcutMessage = status == noErr ? nil :
            (status == eventHotKeyExistsErr ? "这个快捷键已被占用，请在设置中换一个。" : "暂时无法启用快捷键，请在设置中重新选择。")
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPermissions() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DailyActivityReporter.shared.recordActivity()
        refreshPermissions()
        if bringGuideToFront() { return true }
        if let guide = permissions.startupGuide { presentGuide(guide, manuallyOpened: false) }
        else { showSettings() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow,
              isRecordingShortcut else { return }
        window.makeFirstResponder(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow === aboutWindow {
            updateChecker.deferUpdate()
            closingWindow.contentView = nil
            aboutWindow = nil
        }
        if closingWindow === usageWindow {
            closingWindow.contentView = nil
            usageWindow = nil
        }
        if closingWindow === statisticsWindow {
            closingWindow.contentView = nil
            statisticsWindow = nil
        }
        if closingWindow === settingsWindow {
            closingWindow.makeFirstResponder(nil)
            setShortcutRecording(false)
        }
        if closingWindow === guideWindow {
            currentGuide = nil
            guideOpenedManually = false
            permissions.refresh()
            if !isPreview && !permissions.accessibilityGranted { NSApp.terminate(nil) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        updateReminder.hide()
        updateObservation?.cancel()
        if let activityEventMonitor { NSEvent.removeMonitor(activityEventMonitor) }
        activityEventMonitor = nil
        permissionTimer?.invalidate()
        shortcut.stop()
        layoutShortcut.stop()
        multiLayoutShortcut.stop()
        pinShortcut.stop()
        switcher.stop()
        quickLayout.stop()
        multiLayout.stop()
        pinnedWindows.stop()
        switcher.catalog.stop()
        pinnedWindows.finishSavingPreviews()
    }
}
