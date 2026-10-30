import AppKit
import SwiftUI

/// Draw the chosen grid, never a screenshot of the desktop behind the editor.
@MainActor
struct LayoutSavePreview: View {
    let root: LayoutRegion
    var icons: [UUID: NSImage] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(root.leaves, id: \.region.id) { leaf in
                    let width = max(0, leaf.frame.width * geometry.size.width - 3)
                    let height = max(0, leaf.frame.height * geometry.size.height - 3)
                    RoundedRectangle(cornerRadius: min(10, min(width, height) * 0.08))
                        .fill(Color(red: 0.10, green: 0.17, blue: 0.24).opacity(0.96))
                        .overlay {
                            RoundedRectangle(cornerRadius: min(10, min(width, height) * 0.08))
                                .strokeBorder(Color(red: 0.40, green: 0.71, blue: 1).opacity(0.85), lineWidth: 1)
                        }
                        .overlay {
                            if let icon = icons[leaf.region.id] {
                                Image(nsImage: icon).resizable().scaledToFit()
                                    .frame(width: min(42, width * 0.3), height: min(42, height * 0.3))
                            }
                        }
                        .frame(width: width, height: height)
                        .offset(x: leaf.frame.minX * geometry.size.width + 1.5,
                                y: leaf.frame.minY * geometry.size.height + 1.5)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func image(root: LayoutRegion, windows: [UUID: WindowItem] = [:], size: CGSize) -> NSImage? {
        let renderer = ImageRenderer(content: LayoutSavePreview(root: root, icons: windows.compactMapValues(\.icon))
            .frame(width: size.width, height: size.height))
        return renderer.nsImage
    }
}
