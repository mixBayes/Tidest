import AppKit
import Carbon
import XCTest
@testable import tidest

final class WindowShortcutTests: XCTestCase {
    @MainActor
    func testRecorderWaitsForKeyReleaseAndDiscardsCancelledInput() throws {
        let recorder = ShortcutRecorder.RecorderButton()
        var recorded: [WindowShortcut] = []
        recorder.onChange = { recorded.append($0) }
        let down = try keyEvent(key: kVK_ANSI_K, flags: .option, characters: "k")
        let up = try keyEvent(key: kVK_ANSI_K, flags: .option, characters: "k", type: .keyUp)
        recorder.toggleRecording()
        recorder.keyDown(with: down)
        recorder.keyDown(with: down)
        XCTAssertTrue(recorded.isEmpty)
        recorder.keyUp(with: up)
        XCTAssertEqual(recorded.map(\.displayName), ["Option + K"])
        XCTAssertFalse(recorder.recording)

        recorder.toggleRecording()
        recorder.keyDown(with: down)
        recorder.keyDown(with: try keyEvent(key: kVK_Escape, flags: [], characters: "\u{1b}"))
        recorder.keyUp(with: up)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertFalse(recorder.recording)
    }

    @MainActor
    func testCommandCombinationFinishesWhenModifierIsReleasedWithoutKeyUp() throws {
        let recorder = ShortcutRecorder.RecorderButton()
        var recorded: [WindowShortcut] = []
        recorder.onChange = { recorded.append($0) }
        recorder.toggleRecording()
        XCTAssertTrue(recorder.performKeyEquivalent(with: try keyEvent(key: kVK_ANSI_K, flags: [.command, .shift], characters: "K")))
        XCTAssertTrue(recorded.isEmpty)
        recorder.flagsChanged(with: try keyEvent(key: kVK_Shift, flags: .command, characters: "", type: .flagsChanged))
        XCTAssertEqual(recorded.map(\.displayName), ["Shift + Command + K"])
        XCTAssertFalse(recorder.recording)
    }

    @MainActor
    func testRecordingRequiresPrimaryModifierAndIgnoresCapsLock() throws {
        XCTAssertNil(WindowShortcut(event: try keyEvent(key: kVK_ANSI_K, flags: [], characters: "k")))
        XCTAssertNil(WindowShortcut(event: try keyEvent(key: kVK_ANSI_K, flags: .shift, characters: "K")))
        XCTAssertNil(WindowShortcut(event: try keyEvent(key: kVK_Escape, flags: .control, characters: "\u{1b}")))
        let value = try XCTUnwrap(WindowShortcut(event: try keyEvent(key: kVK_ANSI_K, flags: [.option, .capsLock], characters: "k")))
        XCTAssertEqual(value.modifiers, .option)
        XCTAssertEqual(value.displayName, "Option + K")
        XCTAssertEqual(value.carbonModifiers, UInt32(optionKey))
    }

    @MainActor
    func testConfiguredCombinationAndModifierRelease() throws {
        let value = WindowShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option], keyName: "K")
        XCTAssertTrue(value.matches(try keyEvent(key: kVK_ANSI_K, flags: [.control, .option], characters: "k")))
        XCTAssertFalse(value.matches(try keyEvent(key: kVK_ANSI_K, flags: .control, characters: "k")))
        XCTAssertFalse(value.matches(try keyEvent(key: kVK_Tab, flags: [.control, .option], characters: "\t")))
        XCTAssertFalse(value.matches(try keyEvent(key: kVK_ANSI_K, flags: [.control, .option, .shift], characters: "K")))
        XCTAssertTrue(value.modifiersAreHeld([.control, .option, .capsLock]))
        XCTAssertFalse(value.modifiersAreHeld(.control))
        XCTAssertFalse(value.modifiersAreHeld(.option))
    }

    @MainActor
    func testFailedRegistrationPreservesOldShortcutAndSuccessfulChangeReleasesIt() {
        let first = WindowShortcut(keyCode: UInt16(kVK_F19), modifiers: [.control, .option], keyName: "F19")
        let second = WindowShortcut(keyCode: UInt16(kVK_F20), modifiers: [.control, .option], keyName: "F20")
        let active = GlobalShortcut()
        let occupied = GlobalShortcut()
        let probe = GlobalShortcut()
        defer { active.stop(); occupied.stop(); probe.stop() }
        XCTAssertEqual(active.start(first), noErr)
        XCTAssertEqual(occupied.start(second), noErr)
        XCTAssertEqual(active.start(second), OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(active.registeredShortcut, first)
        XCTAssertEqual(probe.start(first), OSStatus(eventHotKeyExistsErr))
        occupied.stop()
        XCTAssertEqual(active.start(second), noErr)
        XCTAssertEqual(active.registeredShortcut, second)
        XCTAssertEqual(probe.start(first), noErr)
    }

    @MainActor
    func testSwitcherUsesConfiguredKeyBeforeArrowNavigation() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WindowShortcutTests.\(UUID().uuidString)")!, persistChanges: false)
        settings.language = .simplifiedChinese
        settings.shortcut = WindowShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: .option, keyName: "←")
        let controller = SwitcherController(settings: settings)
        controller.showPreview(count: 3)
        defer { controller.stop() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Tidest 窗口切换" && $0.isVisible })
        let initialIndex = controller.selection.index
        let forward = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: UInt16(kVK_LeftArrow)))
        NSApp.sendEvent(forward)
        XCTAssertEqual(controller.selection.index, (initialIndex + 1) % 3)
        controller.releaseShortcutKey()
        NSApp.sendEvent(try keyEvent(key: kVK_Tab, flags: .control, characters: "\t", window: panel.windowNumber))
        XCTAssertEqual(controller.selection.index, (initialIndex + 1) % 3)
        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    private func keyEvent(key: Int, flags: NSEvent.ModifierFlags, characters: String, window: Int = 0, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(key)))
    }
}
