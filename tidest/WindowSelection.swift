import Foundation

nonisolated struct WindowSelection {
    private(set) var count = 0
    private(set) var index = 0

    mutating func begin(count: Int, steps: Int) {
        self.count = max(0, count)
        index = count > 0 ? ((steps % count) + count) % count : 0
    }
    mutating func move(_ direction: Int) {
        guard count > 0 else { return }
        index = ((index + direction) % count + count) % count
    }
    mutating func select(_ index: Int) {
        guard (0..<count).contains(index) else { return }
        self.index = index
    }
    func distance(to index: Int) -> Int {
        guard count > 0 else { return 0 }
        var distance = index - self.index
        if distance > count / 2 { distance -= count }
        if distance < -(count / 2) { distance += count }
        return distance
    }
}
