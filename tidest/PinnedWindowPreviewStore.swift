import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// All file work uses one serial queue, so removing an item cannot be followed
// by an older pending write that brings its preview back.
nonisolated final class PinnedWindowPreviewStore: @unchecked Sendable {
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.mixbayes.tidest.pinned-previews", qos: .utility)

    init(directoryURL: URL = URL.applicationSupportDirectory
        .appendingPathComponent("com.mixbayes.tidest", isDirectory: true)
        .appendingPathComponent("PinnedPreviews", isDirectory: true)) {
        self.directoryURL = directoryURL
    }

    func load(for ids: Set<UUID>) async -> [UUID: CGImage] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var images: [UUID: CGImage] = [:]
                for id in ids {
                    guard let data = try? Data(contentsOf: fileURL(for: id)),
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let type = CGImageSourceGetType(source), type as String == UTType.png.identifier,
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                    images[id] = image
                }
                continuation.resume(returning: images)
            }
        }
    }

    func save(_ image: CGImage, for id: UUID) {
        queue.async { [self] in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try (data as Data).write(to: fileURL(for: id), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL(for: id).path)
            } catch {
                // A preview is optional. Keep the last saved image and leave
                // window switching, reopening and retention available.
            }
        }
    }

    func remove(for id: UUID) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
    }

    func removeExcept(_ ids: Set<UUID>) {
        queue.async { [self] in
            guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                          includingPropertiesForKeys: nil)
            else { return }
            for file in files where file.pathExtension == "png" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      !ids.contains(id) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func finishPendingWrites() {
        queue.sync {}
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }
}
