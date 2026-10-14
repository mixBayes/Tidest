import AppKit
import SwiftUI

@MainActor
struct QuickLayoutView: View {
    static let panelSize = CGSize(width: 356, height: 390)

    @ObservedObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredLayout: QuickLayout?

    private let title: String
    private let applicationName: String
    private let icon: NSImage?
    private let onChoose: (QuickLayout) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    init(settings: AppSettings, title: String, applicationName: String, icon: NSImage?,
         onChoose: @escaping (QuickLayout) -> Void) {
        self.settings = settings
        self.title = title
        self.applicationName = applicationName
        self.icon = icon
        self.onChoose = onChoose
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 60)
            Spacer().frame(height: 14)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(QuickLayout.allCases) { layout in
                    layoutButton(layout)
                }
            }
            Spacer().frame(height: 12)
            HStack(spacing: 8) {
                Text(settings.text("点击布局或按 1–9"))
                Spacer(minLength: 0)
                Text(settings.text("Esc 取消"))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: 16)
        }
        .padding(16)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .environment(\.locale, settings.locale)
        .transaction { if reduceMotion { $0.animation = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickLayoutPanel")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(settings.text("快速布局"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("⌃ Q")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                applicationIcon.frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? applicationName : title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(title.isEmpty ? applicationName : title)
                    if !title.isEmpty && title != applicationName {
                        Text(applicationName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var applicationIcon: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "macwindow")
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    private func layoutButton(_ layout: QuickLayout) -> some View {
        let hovered = hoveredLayout == layout
        return Button { onChoose(layout) } label: {
            VStack(spacing: 6) {
                QuickLayoutDiagram(layout: layout, highlighted: hovered)
                    .frame(width: 70, height: 40)
                HStack(spacing: 5) {
                    Text("\(layout.rawValue)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
                        .frame(width: 15, height: 15)
                        .background(hovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 4))
                    Text(settings.text(layout.titleKey))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 10)
            .padding(.bottom, 9)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovered ? Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.10)
                          : Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovered ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.04), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredLayout = layout
            } else if hoveredLayout == layout {
                hoveredLayout = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel("\(layout.rawValue), \(settings.text(layout.titleKey))")
        .accessibilityIdentifier("quickLayout\(layout.rawValue)")
    }
}

private struct QuickLayoutDiagram: View {
    let layout: QuickLayout
    let highlighted: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let screen = CGRect(origin: .zero, size: geometry.size)
            let content = screen.insetBy(dx: 4, dy: 4)
            // The diagram and the layout service both use a top-left origin.
            let selected = layout.frame(in: content)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
                Path { path in
                    path.move(to: CGPoint(x: screen.midX, y: content.minY))
                    path.addLine(to: CGPoint(x: screen.midX, y: content.maxY))
                    path.move(to: CGPoint(x: content.minX, y: screen.midY))
                    path.addLine(to: CGPoint(x: content.maxX, y: screen.midY))
                }
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted ? 1 : 0.72))
                    .frame(width: selected.width, height: selected.height)
                    .offset(x: selected.minX, y: selected.minY)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(highlighted ? 0.24 : 0.16), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct QuickLayoutTipView: View {
    static let panelSize = CGSize(width: 380, height: 84)

    @ObservedObject private var settings: AppSettings
    private let messageKey: String

    init(settings: AppSettings, messageKey: String) {
        self.settings = settings
        self.messageKey = messageKey
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(settings.text(messageKey))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .environment(\.locale, settings.locale)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quickLayoutTip")
    }
}
