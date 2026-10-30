import Combine
import Foundation

enum DisplayMode: String, CaseIterable, Identifiable {
    case carousel
    case tiled

    var id: String { rawValue }
    var titleKey: String { self == .carousel ? "横向预览" : "平铺预览" }
}

enum PinnedDockSide: String {
    case left
    case right

    var opposite: Self { self == .left ? .right : .left }
}

enum PinnedDisplayMode: String {
    case thumbnails
    case iconsAndTitle

    var opposite: Self { self == .thumbnails ? .iconsAndTitle : .thumbnails }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    static func matching(_ preferredLanguages: [String]) -> AppLanguage {
        let supported = allCases.map(\.rawValue)
        let identifier = Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages).first
        return identifier.flatMap(Self.init(rawValue:)) ?? .english
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared: AppSettings = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-preview-") }) {
            return AppSettings(defaults: UserDefaults(suiteName: "com.mixbayes.tidest.preview")!, persistChanges: false)
        }
        #endif
        return AppSettings()
    }()

    @Published var displayMode: DisplayMode {
        didSet { if persistChanges { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    }
    @Published var language: AppLanguage {
        didSet { if persistChanges { defaults.set(language.rawValue, forKey: "language") } }
    }
    @Published var anonymousUsageEnabled: Bool {
        didSet { if persistChanges { defaults.set(anonymousUsageEnabled, forKey: "anonymousUsageEnabled") } }
    }
    @Published var shortcut: WindowShortcut {
        didSet {
            if persistChanges, let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: "windowShortcut")
            }
        }
    }
    @Published var layoutShortcut: WindowShortcut {
        didSet {
            if persistChanges, let data = try? JSONEncoder().encode(layoutShortcut) {
                defaults.set(data, forKey: "quickLayoutShortcut")
            }
        }
    }
    @Published var multiLayoutShortcut: WindowShortcut? {
        didSet {
            guard persistChanges else { return }
            if let multiLayoutShortcut, let data = try? JSONEncoder().encode(multiLayoutShortcut) {
                defaults.set(data, forKey: "multiWindowLayoutShortcut")
            } else {
                // Distinguish an explicitly cleared shortcut from a first launch.
                defaults.set(false, forKey: "multiWindowLayoutShortcut")
            }
        }
    }
    @Published var pinningEnabled: Bool {
        didSet { if persistChanges { defaults.set(pinningEnabled, forKey: "pinnedToolbarEnabled") } }
    }
    @Published var pinnedDockSide: PinnedDockSide {
        didSet { if persistChanges { defaults.set(pinnedDockSide.rawValue, forKey: "pinnedDockSide") } }
    }
    @Published var pinnedDisplayMode: PinnedDisplayMode {
        didSet { if persistChanges { defaults.set(pinnedDisplayMode.rawValue, forKey: "pinnedDisplayMode") } }
    }
    @Published var pinShortcut: WindowShortcut {
        didSet {
            if persistChanges, let data = try? JSONEncoder().encode(pinShortcut) {
                defaults.set(data, forKey: "pinnedToolbarShortcut")
            }
        }
    }

    private let defaults: UserDefaults
    let persistChanges: Bool

    init(defaults: UserDefaults = .standard, persistChanges: Bool = true, preferredLanguages: () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.persistChanges = persistChanges
        anonymousUsageEnabled = defaults.object(forKey: "anonymousUsageEnabled") as? Bool ?? true
        displayMode = defaults.string(forKey: "displayMode").flatMap(DisplayMode.init(rawValue:)) ?? .carousel
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.matching(preferredLanguages())
        let savedShortcut = defaults.data(forKey: "windowShortcut").flatMap { try? JSONDecoder().decode(WindowShortcut.self, from: $0) }
        shortcut = savedShortcut.flatMap { $0.isValid ? $0 : nil } ?? .default
        let savedLayoutShortcut = defaults.data(forKey: "quickLayoutShortcut").flatMap { try? JSONDecoder().decode(WindowShortcut.self, from: $0) }
        layoutShortcut = savedLayoutShortcut.flatMap { $0.isValid ? $0 : nil } ?? .quickLayout
        if defaults.object(forKey: "multiWindowLayoutShortcut") == nil {
            multiLayoutShortcut = .multiWindowLayout
        } else {
            multiLayoutShortcut = defaults.data(forKey: "multiWindowLayoutShortcut")
                .flatMap { try? JSONDecoder().decode(WindowShortcut.self, from: $0) }
                .flatMap { $0.isValid ? $0 : nil }
        }
        pinningEnabled = defaults.object(forKey: "pinnedToolbarEnabled") as? Bool ?? true
        pinnedDockSide = defaults.string(forKey: "pinnedDockSide").flatMap(PinnedDockSide.init(rawValue:)) ?? .right
        pinnedDisplayMode = defaults.string(forKey: "pinnedDisplayMode").flatMap(PinnedDisplayMode.init(rawValue:)) ?? .thumbnails
        let savedPinShortcut = defaults.data(forKey: "pinnedToolbarShortcut").flatMap { try? JSONDecoder().decode(WindowShortcut.self, from: $0) }
        pinShortcut = savedPinShortcut.flatMap { $0.isValid ? $0 : nil } ?? .pinWindow
    }

    func makeLayoutTemplateStore() -> LayoutTemplateStore {
        LayoutTemplateStore(defaults: defaults, persistChanges: persistChanges)
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    func loadSavedPinnedWindows() throws -> [SavedPinnedWindow] {
        guard let data = defaults.data(forKey: "savedPinnedWindows") else { return [] }
        return try JSONDecoder().decode([SavedPinnedWindow].self, from: data)
    }

    func savePinnedWindows(_ entries: [PinnedWindowEntry]) throws {
        guard persistChanges else { return }
        // A failed load must not turn a later reorder or removal into an
        // implicit replacement of the unreadable saved list.
        if let previousData = defaults.data(forKey: "savedPinnedWindows") {
            _ = try JSONDecoder().decode([SavedPinnedWindow].self, from: previousData)
        }
        let data = try JSONEncoder().encode(entries.compactMap { $0.recordForSaving() })
        defaults.set(data, forKey: "savedPinnedWindows")
    }

    func text(_ key: String) -> String {
        let bundle = Bundle(for: AppSettings.self)
        let path = bundle.path(forResource: language.rawValue, ofType: "lproj")
        let localizedBundle = path.flatMap(Bundle.init(path:)) ?? bundle
        return localizedBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func text(_ key: String, _ arguments: String...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
