import CoreGraphics
import Foundation
import XCTest
@testable import tidest

final class PinnedWindowPreviewStoreTests: XCTestCase {
    func testSavedPreviewSurvivesRestartWithItsSizeAndTransparency() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let original = try image(width: 2, height: 3)
        let store = PinnedWindowPreviewStore(directoryURL: directory)
        store.save(original, for: id)
        store.finishPendingWrites()

        let restarted = PinnedWindowPreviewStore(directoryURL: directory)
        let loaded = await restarted.load(for: [id])
        let restored = try XCTUnwrap(loaded[id])
        XCTAssertEqual(restored.width, 2)
        XCTAssertEqual(restored.height, 3)
        XCTAssertEqual(try pixels(restored), try pixels(original))
        XCTAssertEqual(try pixels(restored)[3], 0)
    }

    func testNewPreviewReplacesPreviousImage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = PinnedWindowPreviewStore(directoryURL: directory)
        store.save(try image(width: 2, height: 3), for: id)
        store.save(try image(width: 5, height: 2), for: id)

        let loaded = await store.load(for: [id])
        XCTAssertEqual(loaded[id]?.width, 5)
        XCTAssertEqual(loaded[id]?.height, 2)
    }

    func testRemovingPreviewAfterPendingWriteCannotRecreateIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = PinnedWindowPreviewStore(directoryURL: directory)
        store.save(try image(width: 2, height: 3), for: id)
        store.remove(for: id)

        let loaded = await store.load(for: [id])
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL(id, in: directory).path))
    }

    func testCleanupKeepsRetainedPreviewsAndUnrelatedFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = UUID()
        let removed = UUID()
        let store = PinnedWindowPreviewStore(directoryURL: directory)
        store.save(try image(width: 2, height: 3), for: kept)
        store.save(try image(width: 2, height: 3), for: removed)
        store.finishPendingWrites()
        let unrelated = directory.appendingPathComponent("other.png")
        try Data("unrelated file".utf8).write(to: unrelated)
        store.removeExcept([kept])

        let loaded = await store.load(for: [kept, removed])
        XCTAssertNotNil(loaded[kept])
        XCTAssertNil(loaded[removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL(removed, in: directory).path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated file".utf8))
    }

    func testMissingOrDamagedImageDoesNotPreventOtherPreviewsLoading() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = UUID()
        let damaged = UUID()
        let missing = UUID()
        let store = PinnedWindowPreviewStore(directoryURL: directory)
        store.save(try image(width: 2, height: 3), for: valid)
        store.finishPendingWrites()
        try Data("damaged PNG".utf8).write(to: previewURL(damaged, in: directory))

        let loaded = await store.load(for: [valid, damaged, missing])
        XCTAssertEqual(Set(loaded.keys), [valid])
        XCTAssertEqual(try Data(contentsOf: previewURL(damaged, in: directory)), Data("damaged PNG".utf8))
    }

    func testWriteFailureKeepsLastSuccessfullySavedPreview() async throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let id = UUID()
        let store = PinnedWindowPreviewStore(directoryURL: directory)
        store.save(try image(width: 2, height: 3), for: id)
        store.finishPendingWrites()
        let previous = try Data(contentsOf: previewURL(id, in: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        store.save(try image(width: 5, height: 2), for: id)

        let loaded = await store.load(for: [id])
        XCTAssertEqual(loaded[id]?.width, 2)
        XCTAssertEqual(try Data(contentsOf: previewURL(id, in: directory)), previous)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PinnedWindowPreviewStoreTests-\(UUID())",
                                                                      isDirectory: true)
    }

    private func previewURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 1..<(width * height) {
            bytes[pixel * 4] = 255
            bytes[pixel * 4 + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }
}
