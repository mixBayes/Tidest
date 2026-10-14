import AppKit
import Carbon

@MainActor
final class GlobalShortcut {
    private static var nextIdentifier: UInt32 = 0
    private let identifier: UInt32
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private(set) var registeredShortcut: WindowShortcut?
    var onPress: ((Int) -> Void)?
    var onRelease: (() -> Void)?

    init() {
        Self.nextIdentifier += 1
        identifier = Self.nextIdentifier
    }

    func start(_ value: WindowShortcut = .default) -> OSStatus {
        if registeredShortcut?.hasSameKeys(as: value) == true { return noErr }
        guard value.isValid else { return OSStatus(paramErr) }
        if handler == nil {
            var events = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr else { return status }
                guard identifier.signature == 0x54494445 else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                    guard identifier.id == shortcut.identifier else { return OSStatus(eventNotHandledErr) }
                    if GetEventKind(event) == UInt32(kEventHotKeyPressed) { shortcut.onPress?(1) }
                    else { shortcut.onRelease?() }
                    return noErr
                }
            }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return result }
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(value.keyCode), value.carbonModifiers, EventHotKeyID(signature: 0x54494445, id: identifier), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            if hotKey == nil { stop() }
            return status == noErr ? OSStatus(eventNotHandledErr) : status
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = reference
        registeredShortcut = value
        return noErr
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
