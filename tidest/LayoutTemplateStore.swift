import Combine
import Foundation

@MainActor
final class LayoutTemplateStore: ObservableObject {
    @Published private(set) var templates: [LayoutTemplate] = []
    @Published private(set) var errorKey: String?
    private let defaults: UserDefaults
    private let persistChanges: Bool
    private static let key = "multiWindowLayoutTemplates.v1"

    init(defaults: UserDefaults = .standard, persistChanges: Bool = true) {
        self.defaults = defaults
        self.persistChanges = persistChanges
        guard let data = defaults.data(forKey: Self.key) else { return }
        guard let decoded = try? JSONDecoder().decode([LayoutTemplate].self, from: data),
              Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy({ $0.root.isValid && Self.validName($0.name) }) else {
            errorKey = "保存的模板无法读取，原数据已保留。"
            return
        }
        templates = decoded
    }

    func suggestedName(using makeName: (Int) -> String) -> String {
        var number = 1
        while templates.contains(where: { $0.name.localizedCaseInsensitiveCompare(makeName(number)) == .orderedSame }) {
            number += 1
        }
        return makeName(number)
    }

    func matchingTemplate(for root: LayoutRegion) -> LayoutTemplate? {
        templates.first { $0.root.hasSameLayout(as: root) }
    }

    @discardableResult
    func save(name: String, root: LayoutRegion, replacing id: UUID? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard errorKey == nil else { return false }
        guard Self.validName(name), root.isValid else { return false }
        guard !templates.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return false }
        var updated = templates
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
            updated[index].name = name
        } else {
            guard root.leafIDs.count > 1,
                  !LayoutStartingPoint.allCases.contains(where: { $0.makeRegion().hasSameLayout(as: root) }),
                  matchingTemplate(for: root) == nil else { return false }
            updated.append(LayoutTemplate(name: name, root: root))
        }
        return commit(updated)
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard errorKey == nil else { return false }
        return commit(templates.filter { $0.id != id })
    }

    private func commit(_ updated: [LayoutTemplate]) -> Bool {
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        if persistChanges { defaults.set(data, forKey: Self.key) }
        templates = updated
        return true
    }

    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60
    }
}
