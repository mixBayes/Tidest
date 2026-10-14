import AppKit
import ScreenCaptureKit

@MainActor
enum WindowThumbnailCapture {
    nonisolated static func isAllowed(applicationBundleIdentifier: String?) -> Bool {
        applicationBundleIdentifier != "com.tencent.xinWeChat"
    }

    static func capture(_ target: WindowItem, maximumDimension: CGFloat = 640) async -> NSImage? {
        let images = await capture(for: [target], maximumDimension: maximumDimension)
        return Task.isCancelled ? nil : images[target.id]
    }

    // Refreshing a shelf uses one ScreenCaptureKit directory snapshot, then
    // captures only the exact system window ID and process recorded by AX lookup.
    static func capture(for targets: [WindowItem], maximumDimension: CGFloat = 640) async -> [UUID: NSImage] {
        let targets = targets.filter(\.allowsThumbnail)
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess(),
              maximumDimension.isFinite, maximumDimension > 0,
              maximumDimension < CGFloat(Int.max),
              targets.contains(where: { $0.captureID != nil }) else { return [:] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return [:] }
            let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            var images: [UUID: NSImage] = [:]
            for target in targets {
                guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return [:] }
                guard let id = target.captureID, let window = windows[id],
                      window.owningApplication?.processID == target.processID,
                      window.frame.width.isFinite, window.frame.height.isFinite,
                      window.frame.width > 1, window.frame.height > 1 else { continue }
                let configuration = SCStreamConfiguration()
                let scale = min(1, maximumDimension / max(window.frame.width, window.frame.height))
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.scalesToFit = true
                configuration.preservesAspectRatio = true
                configuration.ignoreShadowsSingleWindow = true
                if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
                configuration.showsCursor = false
                configuration.capturesAudio = false
                if #available(macOS 15.0, *) {
                    configuration.showMouseClicks = false
                    configuration.captureMicrophone = false
                }
                do {
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window),
                        configuration: configuration)
                    guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return [:] }
                    images[target.id] = NSImage(cgImage: image,
                                              size: NSSize(width: image.width, height: image.height))
                } catch {
                    // A window can stop being capturable while it is still
                    // selectable. Keep its shelf item and leave the image out.
                    guard !Task.isCancelled else { return [:] }
                }
            }
            return images
        } catch {
            return [:]
        }
    }
}
