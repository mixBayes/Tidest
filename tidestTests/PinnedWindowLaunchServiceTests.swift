import AppKit
import CoreServices
import XCTest
@testable import tidest

final class PinnedWindowLaunchServiceTests: XCTestCase {
    func testWindowSpecifierKeepsUniqueIDSeparateFromCode() throws {
        let value = "window \"text\"; tell application \"Other\" to quit"
        let object = PinnedAppleEvents.object("cwin", form: "ID  ", data: NSAppleEventDescriptor(string: value))
        XCTAssertEqual(object.descriptorType, typeObjectSpecifier)
        XCTAssertEqual(object.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, PinnedAppleEvents.fourCC("cwin"))
        XCTAssertEqual(object.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, PinnedAppleEvents.fourCC("ID  "))
        XCTAssertEqual(object.forKeyword(UInt32(keyAEKeyData))?.stringValue, value)
        XCTAssertEqual(object.forKeyword(UInt32(keyAEContainer))?.descriptorType, typeNull)
        XCTAssertEqual(try PinnedAppleWindowID(NSAppleEventDescriptor(string: value)), .text(value))
        XCTAssertEqual(try PinnedAppleWindowID(NSAppleEventDescriptor(int32: 42)), .number(42))
        XCTAssertThrowsError(try PinnedAppleWindowID(.null()))
    }

    func testAllTabsUsesAnAbsoluteOrdinalDescriptor() {
        let all = PinnedAppleEvents.all("CrTb")
        let ordinal = all.forKeyword(UInt32(keyAEKeyData))
        XCTAssertEqual(ordinal?.descriptorType, typeAbsoluteOrdinal)
        XCTAssertEqual(ordinal?.data, NSAppleEventDescriptor(enumCode: PinnedAppleEvents.fourCC("all ")).data)
    }

    func testCreatedWindowReferenceProvidesItsIDWithoutReadingMetadata() {
        let finder = PinnedAppleEvents.object("brow", form: "ID  ", data: NSAppleEventDescriptor(int32: 88))
        let chrome = PinnedAppleEvents.object("cwin", form: "ID  ", data: NSAppleEventDescriptor(string: "window-123"))
        XCTAssertEqual(PinnedAppleEvents.windowIdentifier(in: finder), .number(88))
        XCTAssertEqual(PinnedAppleEvents.windowIdentifier(in: chrome), .text("window-123"))
        let terminalTab = PinnedAppleEvents.element("ttab", at: 1, of: finder)
        XCTAssertEqual(PinnedAppleEvents.windowIdentifier(in: terminalTab), .number(88))
        let indexedWindow = PinnedAppleEvents.element("cwin", at: 1)
        XCTAssertNil(PinnedAppleEvents.windowIdentifier(in: indexedWindow))
        // A document's own ID is not a window ID.
        let document = PinnedAppleEvents.object("docu", form: "ID  ", data: NSAppleEventDescriptor(int32: 99))
        XCTAssertNil(PinnedAppleEvents.windowIdentifier(in: document))
    }

    func testCreatedReferenceCanRetryAfterFlatteningAcrossBackgroundTasks() throws {
        let window = PinnedAppleEvents.object("cwin", form: "ID  ", data: NSAppleEventDescriptor(int32: 123))
        let tab = PinnedAppleEvents.element("ttab", at: 2, of: window)
        let bytes = try PinnedAppleEvents.flattenReference(tab)
        let retryReference = try PinnedAppleEvents.unflattenReference(bytes)
        XCTAssertEqual(retryReference.descriptorType, typeObjectSpecifier)
        XCTAssertEqual(retryReference.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, PinnedAppleEvents.fourCC("ttab"))
        XCTAssertEqual(retryReference.forKeyword(UInt32(keyAEKeyData))?.int32Value, 2)
        XCTAssertEqual(PinnedAppleEvents.windowIdentifier(in: retryReference), .number(123))
        XCTAssertEqual(try PinnedAppleEvents.flattenReference(retryReference), bytes)
        XCTAssertThrowsError(try PinnedAppleEvents.unflattenReference(Data()))
    }

    func testSafariDocumentReferenceRetainsItsExactObjectSpecifierForRetry() throws {
        let document = PinnedAppleEvents.object("docu", form: "name", data: NSAppleEventDescriptor(string: #"A title "with" 中文"#))
        let bytes = try PinnedAppleEvents.flattenReference(document)
        let retryReference = try PinnedAppleEvents.unflattenReference(bytes)
        XCTAssertEqual(retryReference.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, PinnedAppleEvents.fourCC("docu"))
        XCTAssertEqual(retryReference.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, PinnedAppleEvents.fourCC("name"))
        XCTAssertEqual(retryReference.forKeyword(UInt32(keyAEKeyData))?.stringValue, #"A title "with" 中文"#)
        XCTAssertEqual(try PinnedAppleEvents.flattenReference(retryReference), bytes)
    }

    func testTabPropertySpecifiesTheExactWindowAndTab() {
        let window = PinnedAppleEvents.object("cwin", form: "ID  ", data: NSAppleEventDescriptor(int32: 77))
        let tab = PinnedAppleEvents.element("bTab", at: 3, of: window)
        let url = PinnedAppleEvents.property("pURL", of: tab)
        XCTAssertEqual(url.forKeyword(UInt32(keyAEKeyData))?.typeCodeValue, PinnedAppleEvents.fourCC("pURL"))
        let tabContainer = url.forKeyword(UInt32(keyAEContainer))
        XCTAssertEqual(tabContainer?.forKeyword(UInt32(keyAEKeyData))?.int32Value, 3)
        XCTAssertEqual(tabContainer?.forKeyword(UInt32(keyAEContainer))?.forKeyword(UInt32(keyAEKeyData))?.int32Value, 77)
    }

    func testRectangleDecodingUsesTheActualAppleEventData() throws {
        let rectangle = NSAppleEventDescriptor(listDescriptor: ())
        for (index, edge) in [-200, 30, 800, 730].enumerated() {
            rectangle.insert(NSAppleEventDescriptor(int32: Int32(edge)), at: index + 1)
        }
        XCTAssertEqual(try PinnedAppleEvents.frame(rectangle), CGRect(x: -200, y: 30, width: 1000, height: 700))
        let nativeEdges: [Int16] = [30, -200, 730, 800]
        let nativeData = nativeEdges.withUnsafeBytes { Data($0) }
        let nativeRectangle = NSAppleEventDescriptor(descriptorType: typeQDRectangle, data: nativeData)!
        XCTAssertEqual(try PinnedAppleEvents.frame(nativeRectangle), CGRect(x: -200, y: 30, width: 1000, height: 700))
        XCTAssertThrowsError(try PinnedAppleEvents.frame(.null()))
        let invalidRectangle = NSAppleEventDescriptor(listDescriptor: ())
        for (index, edge) in [100, 100, 50, 50].enumerated() {
            invalidRectangle.insert(NSAppleEventDescriptor(int32: Int32(edge)), at: index + 1)
        }
        XCTAssertThrowsError(try PinnedAppleEvents.frame(invalidRectangle))
    }

    func testBrowserSnapshotPreservesOrderDuplicatesSelectionAndURLCharacters() throws {
        let urls = ["https://example.com/?q=%22%3B%20tell%20application&x=a%26b#中文",
                    "https://example.com/same", "chrome://newtab/", "https://example.com/same"]
        let target = PinnedLaunchTarget.browser(urls: urls, selectedTabIndex: 3)
        try PinnedAppleEvents.validate(target)
        let encoded = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(PinnedLaunchTarget.self, from: encoded)
        XCTAssertEqual(decoded, target)
        for url in urls {
            XCTAssertEqual(NSAppleEventDescriptor(string: url).stringValue, url)
        }
    }

    func testBrowserValidationRejectsIncompleteSnapshotAndExecutableURLs() {
        for target in [PinnedLaunchTarget.browser(urls: [], selectedTabIndex: 0),
                       .browser(urls: ["https://example.com"], selectedTabIndex: 1),
                       .browser(urls: [""], selectedTabIndex: 0),
                       .browser(urls: ["relative/path"], selectedTabIndex: 0),
                       .browser(urls: ["javascript:alert(1)"], selectedTabIndex: 0)] {
            XCTAssertThrowsError(try PinnedAppleEvents.validate(target)) {
                XCTAssertEqual($0 as? PinnedWindowLaunchError, .tabsUnavailable)
            }
        }
    }

    func testTerminalQuotingTreatsShellCharactersAsOneDirectoryArgument() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("tidest-launch-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("folder ' !tidest-history with $HOME `touch sentinel`; $(touch sentinel) 中文", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try PinnedAppleEvents.terminalCommand(path: directory.path)
        let shells: [(String, [String])] = [
            ("/bin/sh", ["-c"]), ("/bin/bash", ["--noprofile", "--norc", "-c"]),
            ("/bin/zsh", ["-f", "-c"]), ("/bin/tcsh", ["-f", "-c"])
        ]
        for (executable, options) in shells {
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.currentDirectoryURL = root
            process.arguments = options + [command + " && /bin/pwd -P"]
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, executable)
            XCTAssertEqual(String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .newlines), directory.path, executable)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sentinel").path), executable)
        }
    }

    func testTerminalCommandRejectsControlCharactersAndRelativePaths() {
        for path in ["relative", "/tmp/line\nbreak", "/tmp/line\rbreak", "/tmp/\0", "/tmp/\u{1B}[A"] {
            XCTAssertThrowsError(try PinnedAppleEvents.terminalCommand(path: path))
        }
        XCTAssertNoThrow(try PinnedAppleEvents.terminalCommand(path: "/tmp/normal folder"))
    }

    func testNestedForegroundShellIsSelectedInsteadOfTheOuterShell() {
        let processes = [shell(10, parent: 1, group: 10, foreground: 20),
                         shell(20, parent: 10, group: 20, foreground: 20)]
        XCTAssertEqual(PinnedAppleEvents.terminalShellPID(processes: processes, deviceID: 7), 20)
    }

    func testForegroundCommandWalksToNearestShellAndIgnoresBackgroundJob() {
        let processes = [shell(10, parent: 1, group: 10, foreground: 30),
                         shell(20, parent: 10, group: 20, foreground: 30),
                         process(30, parent: 20, group: 30, foreground: 30),
                         shell(40, parent: 10, group: 40, foreground: 30)]
        XCTAssertEqual(PinnedAppleEvents.terminalShellPID(processes: processes, deviceID: 7), 20)
    }

    func testSSHForegroundRestoresOnlyItsLocalShellDirectory() {
        let processes = [shell(10, parent: 1, group: 10, foreground: 30),
                         process(30, parent: 10, group: 30, foreground: 30)]
        XCTAssertEqual(PinnedAppleEvents.terminalShellPID(processes: processes, deviceID: 7), 10)
    }

    func testMultipleForegroundCommandsSharingAShellAreUnambiguous() {
        let processes = [shell(10, parent: 1, group: 10, foreground: 30),
                         process(30, parent: 10, group: 30, foreground: 30),
                         process(31, parent: 10, group: 30, foreground: 30)]
        XCTAssertEqual(PinnedAppleEvents.terminalShellPID(processes: processes, deviceID: 7), 10)
    }

    func testSelectedShellDoesNotRequireReadableLoginAncestors() {
        // login is protected and absent from the readable process snapshot.
        let processes = [shell(10, parent: 99, group: 10, foreground: 30),
                         process(30, parent: 10, group: 30, foreground: 30)]
        XCTAssertEqual(PinnedAppleEvents.terminalShellPID(processes: processes, deviceID: 7), 10)
        XCTAssertEqual(PinnedAppleEvents.terminalShellPID(
            processes: [shell(10, parent: 99, group: 10, foreground: 10)], deviceID: 7), 10)
    }

    func testAmbiguousShellsOrAnotherDeviceCannotChooseADirectory() {
        let ambiguous = [shell(10, parent: 1, group: 10, foreground: 30),
                         shell(20, parent: 10, group: 30, foreground: 30),
                         shell(21, parent: 10, group: 30, foreground: 30)]
        XCTAssertNil(PinnedAppleEvents.terminalShellPID(processes: ambiguous, deviceID: 7))
        XCTAssertNil(PinnedAppleEvents.terminalShellPID(processes: [shell(20, parent: 1, group: 20, foreground: 20)],
                                                      deviceID: 8))
        let anotherDevice = PinnedTerminalProcess(pid: 10, parentPID: 1,
            processGroupID: 10, foregroundGroupID: 30, deviceID: 8, isShell: true)
        XCTAssertNil(PinnedAppleEvents.terminalShellPID(
            processes: [anotherDevice, process(30, parent: 10, group: 30, foreground: 30)], deviceID: 7))
    }

    @MainActor
    func testCancelledOpenDoesNotStartAnyApplication() async {
        let saved = SavedPinnedWindow(id: UUID(), applicationBundleIdentifier: "invalid.tidest.test",
                                      applicationURL: "file:///does-not-exist.app", applicationName: "Test", title: "Test",
                                      width: 640, height: 480, target: .application)
        let service = PinnedWindowLaunchService()
        let task = Task { try await service.open(saved) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("An already cancelled open must not launch an application")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func shell(_ pid: Int32, parent: Int32, group: UInt32, foreground: UInt32) -> PinnedTerminalProcess {
        PinnedTerminalProcess(pid: pid, parentPID: parent, processGroupID: group,
                              foregroundGroupID: foreground, deviceID: 7, isShell: true)
    }
    private func process(_ pid: Int32, parent: Int32, group: UInt32, foreground: UInt32) -> PinnedTerminalProcess {
        PinnedTerminalProcess(pid: pid, parentPID: parent, processGroupID: group,
                              foregroundGroupID: foreground, deviceID: 7, isShell: false)
    }
}
