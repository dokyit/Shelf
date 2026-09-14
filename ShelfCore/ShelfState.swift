import Foundation

public enum ItemSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case alwaysShow, onShelf, alwaysHide
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .alwaysShow: return "Always Show"
        case .onShelf: return "On Shelf"
        case .alwaysHide: return "Always Hide"
        }
    }
}

public struct ItemRule: Codable, Equatable, Sendable {
    public var section: ItemSection
    public var order: Int
    public init(section: ItemSection = .alwaysShow, order: Int = 0) {
        self.section = section
        self.order = order
    }
}

public struct ShelfLayout: Codable, Equatable, Sendable {
    public var rules: [String: ItemRule] = [:]
    public init() {}
    public func section(for scope: String) -> ItemSection {
        rules[scope]?.section ?? .alwaysShow
    }
    public mutating func assign(_ scope: String, to section: ItemSection) {
        let order = (rules.values.filter { $0.section == section }.map(\.order).max() ?? -1) + 1
        rules[scope] = ItemRule(section: section, order: order)
    }
    public func hiddenScopes(revealed: Set<String> = [], showShelfInMenuBar: Bool = false) -> Set<String> {
        Set(rules.compactMap { scope, rule in
            guard !revealed.contains(scope) else { return nil }
            return rule.section == .alwaysHide || (rule.section == .onShelf && !showShelfInMenuBar) ? scope : nil
        })
    }
}

public extension ShelfLayout {
    static let storageKey = "shelf.layout.v1"

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> ShelfLayout? {
        try? JSONDecoder().decode(ShelfLayout.self, from: data)
    }

    static func bookCount(for itemCount: Int) -> Int {
        switch itemCount {
        case ...0: return 0
        case 1...3: return itemCount
        case 4...7: return 4
        case 8...11: return 5
        default: return 6
        }
    }
}
