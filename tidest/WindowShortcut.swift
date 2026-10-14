import AppKit
import Carbon

nonisolated struct WindowShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifierRawValue: UInt
    let keyName: String

    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
    static let primaryModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    static let `default` = WindowShortcut(keyCode: UInt16(kVK_Tab), modifiers: .option, keyName: "Tab")
    static let quickLayout = WindowShortcut(keyCode: UInt16(kVK_ANSI_Q), modifiers: .option, keyName: "Q")
    static let pinWindow = WindowShortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: .option, keyName: "W")

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        modifierRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
        self.keyName = keyName
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard !modifiers.intersection(Self.primaryModifiers).isEmpty,
              let name = Self.name(for: event) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers, keyName: name)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }
    var isValid: Bool {
        keyCode <= 127 && keyCode != kVK_Escape && !keyName.isEmpty && keyName.count <= 20 &&
        modifierRawValue == modifiers.intersection(Self.supportedModifiers).rawValue &&
        !modifiers.intersection(Self.primaryModifiers).isEmpty
    }
    var modifierName: String {
        [(NSEvent.ModifierFlags.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined(separator: " + ")
    }
    var displayName: String { "\(modifierName) + \(keyName)" }
    var symbolDisplayName: String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + " " + keyName
    }
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(Self.supportedModifiers) == modifiers
    }
    func modifiersAreHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.isSuperset(of: modifiers)
    }
    func hasSameKeys(as other: WindowShortcut) -> Bool {
        keyCode == other.keyCode && modifierRawValue == other.modifierRawValue
    }

    private static func name(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Escape: return nil
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_ANSI_KeypadEnter: return "Enter"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default:
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            if let index = functionKeys.firstIndex(of: Int(event.keyCode)) { return "F\(index + 1)" }
            guard let characters = event.charactersIgnoringModifiers,
                  !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return characters.uppercased()
        }
    }
}
