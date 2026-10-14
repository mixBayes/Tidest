import Foundation

nonisolated struct ShortcutRepeat {
    static let interval: TimeInterval = 1
    private var held = false
    private var nextAdvance: TimeInterval?

    // A physical press advances immediately; system-generated repeats are ignored.
    mutating func keyDown(at time: TimeInterval) -> Bool {
        guard !held else { return false }
        held = true
        nextAdvance = time + Self.interval
        return true
    }

    mutating func keyUp() {
        held = false
        nextAdvance = nil
    }

    mutating func tick(at time: TimeInterval, modifiersDown: Bool, keyDown: Bool) -> Bool {
        guard modifiersDown && keyDown else { keyUp(); return false }
        guard let nextAdvance, time >= nextAdvance else { return false }
        // Do not catch up in a burst if window enumeration briefly stalls.
        self.nextAdvance = time + Self.interval
        return true
    }
}
