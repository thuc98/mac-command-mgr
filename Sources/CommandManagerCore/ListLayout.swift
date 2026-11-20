import Foundation

/// A named folder of commands in the list. One level only (no nested groups).
public struct ServiceGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Collapsed groups show only their header row.
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, isCollapsed: Bool = true) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }
}

/// An entry of the top level of the list: a group or a command that is in no group.
public enum ListItem: Hashable, Sendable, Codable {
    case group(UUID)
    case service(UUID)

    // Stored as "g:<uuid>" / "s:<uuid>" to keep services.json readable.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard raw.count > 2, let id = UUID(uuidString: String(raw.dropFirst(2))) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad list item \(raw)"))
        }
        switch raw.prefix(2) {
        case "g:": self = .group(id)
        case "s:": self = .service(id)
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad list item \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .group(let id): try c.encode("g:" + id.uuidString)
        case .service(let id): try c.encode("s:" + id.uuidString)
        }
    }
}

/// How the list is arranged. Member order inside a group is the order of `services` itself.
public struct ListLayout: Codable, Equatable, Sendable {
    public var groups: [ServiceGroup]
    /// Top-level order of groups and ungrouped commands.
    public var order: [ListItem]

    public init(groups: [ServiceGroup] = [], order: [ListItem] = []) {
        self.groups = groups
        self.order = order
    }

    public func group(_ id: UUID) -> ServiceGroup? { groups.first { $0.id == id } }

    /// Makes the layout consistent with `services`: unknown groups are dropped (their members become
    /// ungrouped), every group and ungrouped command appears exactly once at the top level, and
    /// anything missing is appended in `services` order.
    public mutating func normalize(services: inout [ServiceDefinition]) {
        var seenGroups = Set<UUID>()
        groups = groups.filter { seenGroups.insert($0.id).inserted }
        for i in services.indices where services[i].groupID.map({ !seenGroups.contains($0) }) ?? false {
            services[i].groupID = nil
        }
        let ungrouped = Set(services.filter { $0.groupID == nil }.map(\.id))
        var seen = Set<ListItem>()
        order = order.filter { item in
            switch item {
            case .group(let id): guard seenGroups.contains(id) else { return false }
            case .service(let id): guard ungrouped.contains(id) else { return false }
            }
            return seen.insert(item).inserted
        }
        for g in groups where !seen.contains(.group(g.id)) { order.append(.group(g.id)); seen.insert(.group(g.id)) }
        for s in services where s.groupID == nil && !seen.contains(.service(s.id)) {
            order.append(.service(s.id)); seen.insert(.service(s.id))
        }
    }
}

/// One row of the list as shown to the user (groups carry their members in order).
public enum ListRow: Identifiable, Equatable {
    case group(ServiceGroup, members: [ServiceDefinition])
    case service(ServiceDefinition)

    public var id: String {
        switch self {
        case .group(let g, _): return "g:" + g.id.uuidString
        case .service(let s): return "s:" + s.id.uuidString
        }
    }
}
