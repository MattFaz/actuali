import Foundation

/// One row of `categories.cleanup_def` — the end-of-month cleanup roles a
/// category takes on. Mirrors loot-core's `CleanupTemplate` union
/// (types/models/cleanup-templates.ts): a source gives its leftover balance
/// up, a sink receives (weighted), and an overspend sink only takes enough
/// to cover overspending. `groupId` scopes a row to a cleanup pool
/// (`cleanup_groups` row); nil means the global scope.
struct CleanupTemplate: Equatable, Sendable {
    enum Role: String, Sendable {
        case source, sink, overspend
    }

    var role: Role
    var groupId: String?
    /// Sink share; upstream stores it only on sink rows.
    var weight: Double = 1

    static func source(groupId: String? = nil) -> CleanupTemplate {
        CleanupTemplate(role: .source, groupId: groupId)
    }

    static func sink(groupId: String? = nil, weight: Double = 1) -> CleanupTemplate {
        CleanupTemplate(role: .sink, groupId: groupId, weight: weight)
    }

    static func overspend(groupId: String) -> CleanupTemplate {
        CleanupTemplate(role: .overspend, groupId: groupId)
    }
}

extension CleanupTemplate {
    static func decodeArray(fromJSON json: String) -> [CleanupTemplate]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let array = parsed as? [[String: Any]] else { return nil }
        return array.compactMap { object in
            guard let role = (object["role"] as? String).flatMap(Role.init(rawValue:))
            else { return nil }
            let groupId = object["groupId"] as? String
            if role == .overspend, groupId == nil { return nil }
            return CleanupTemplate(
                role: role,
                groupId: groupId,
                weight: (object["weight"] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    static func encodeArray(_ rows: [CleanupTemplate]) -> String? {
        let objects = rows.map { row -> [String: Any] in
            var object: [String: Any] = ["role": row.role.rawValue]
            object["groupId"] = row.groupId.map { $0 as Any } ?? NSNull()
            if row.role == .sink {
                object["weight"] = row.weight == row.weight.rounded()
                    ? NSNumber(value: Int(row.weight)) : NSNumber(value: row.weight)
            }
            return object
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: objects, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Note lines

/// Port of loot-core's `cleanup-template.pegjs` + cleanup-template-notes.ts:
/// `#cleanup` note lines, parsed with group NAMES (resolved to ids by the
/// caller) and rendered back for the un-migrate flow.
enum CleanupNotes {
    struct ParsedRow: Equatable {
        enum Kind: Equatable {
            case source, sink(weight: Double), overspend
        }

        var kind: Kind
        var groupName: String?
    }

    /// Parse the `#cleanup …` lines of one note. Unparseable lines are
    /// silently skipped, matching the legacy engine.
    static func parseRows(fromNote note: String) -> [ParsedRow] {
        var rows: [ParsedRow] = []
        for line in note.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("#cleanup") else { continue }
            guard let row = parseLine(trimmed) else { continue }
            rows.append(row)
        }
        return rows
    }

    /// Grammar (after "#cleanup "): `source` | `sink [N]` |
    /// `<group> source` | `<group> sink [N]` | `<group>` (overspend).
    private static func parseLine(_ line: String) -> ParsedRow? {
        // The prefix match is case-insensitive (upstream lowercases the line
        // to test the prefix, then feeds the original into the grammar).
        guard line.count > "#cleanup".count else { return nil }
        var body = String(line.dropFirst("#cleanup".count))
        guard body.first == " " else { return nil }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }

        func weight(from text: String) -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return 1 }
            guard trimmed.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }
            return Double(trimmed) == 0 ? 1 : Double(trimmed)
        }

        if body == "source" {
            return ParsedRow(kind: .source, groupName: nil)
        }
        if body.hasPrefix("sink"), let w = weight(from: String(body.dropFirst(4))) {
            return ParsedRow(kind: .sink(weight: w), groupName: nil)
        }
        if let range = body.range(of: " source"), body[range.upperBound...].isEmpty {
            let group = String(body[..<range.lowerBound])
            guard !group.isEmpty else { return nil }
            return ParsedRow(kind: .source, groupName: group)
        }
        if let range = body.range(of: " sink") {
            let group = String(body[..<range.lowerBound])
            let rest = String(body[range.upperBound...])
            if !group.isEmpty, let w = weight(from: rest) {
                return ParsedRow(kind: .sink(weight: w), groupName: group)
            }
        }
        // Bare group name = "cover this group's overspending".
        return ParsedRow(kind: .overspend, groupName: body)
    }

    /// Resolve parsed note rows into cleanup_def rows using a
    /// name-insensitive group map. Rows naming unknown groups are dropped
    /// (the caller creates missing groups first when it wants them kept).
    static func toTemplates(
        _ rows: [ParsedRow],
        groupIdForName: (String) -> String?
    ) -> [CleanupTemplate] {
        rows.compactMap { row in
            let groupId = row.groupName.flatMap(groupIdForName)
            switch row.kind {
            case .source:
                if row.groupName != nil, groupId == nil { return nil }
                return .source(groupId: groupId)
            case .sink(let weight):
                if row.groupName != nil, groupId == nil { return nil }
                return .sink(groupId: groupId, weight: weight)
            case .overspend:
                guard let groupId else { return nil }
                return .overspend(groupId: groupId)
            }
        }
    }

    /// Port of the web's `cleanupToNotes`: render cleanup rows back to
    /// `#cleanup` lines for the un-migrate note preview.
    static func toNotes(
        _ cleanup: [CleanupTemplate],
        groupName: (String) -> String?
    ) -> String {
        cleanup.compactMap { row -> String? in
            switch row.role {
            case .overspend:
                guard let id = row.groupId, let name = groupName(id) else { return nil }
                return "#cleanup \(name)"
            case .source, .sink:
                var scope = ""
                if let id = row.groupId {
                    guard let name = groupName(id) else { return nil }
                    scope = "\(name) "
                }
                if row.role == .source { return "#cleanup \(scope)source" }
                let weight = row.weight != 1 ? " \(formatWeight(row.weight))" : ""
                return "#cleanup \(scope)sink\(weight)"
            }
        }
        .joined(separator: "\n")
    }

    private static func formatWeight(_ weight: Double) -> String {
        weight == weight.rounded() ? String(Int(weight)) : String(weight)
    }
}

// MARK: - Editor model

/// The automation editor's view of a category's cleanup rows — port of the
/// web's `cleanupModel.ts` (`CleanupConfig` and its converters).
struct CleanupConfig: Equatable, Sendable {
    struct Global: Equatable, Sendable {
        var send = false
        var take = false
        var weight: Double = 1
    }

    struct Group: Equatable, Sendable, Identifiable {
        var id: String { groupId }
        var groupId: String
        var send = false
        var take = false
        var weight: Double = 1
        var overspendOnly = false
    }

    var global = Global()
    var groups: [Group] = []

    var isConfigured: Bool {
        global.send || global.take || groups.contains { $0.send || $0.take }
    }

    static func from(cleanup: [CleanupTemplate]) -> CleanupConfig {
        var config = CleanupConfig()
        var groupsById: [String: Int] = [:]

        func groupIndex(_ groupId: String) -> Int {
            if let index = groupsById[groupId] { return index }
            config.groups.append(Group(groupId: groupId))
            groupsById[groupId] = config.groups.count - 1
            return config.groups.count - 1
        }

        for row in cleanup {
            switch row.role {
            case .source:
                if let groupId = row.groupId {
                    config.groups[groupIndex(groupId)].send = true
                } else {
                    config.global.send = true
                }
            case .sink:
                if let groupId = row.groupId {
                    let index = groupIndex(groupId)
                    config.groups[index].take = true
                    config.groups[index].weight = row.weight
                    // A real sink wins over a stray prior overspend row.
                    config.groups[index].overspendOnly = false
                } else {
                    config.global.take = true
                    config.global.weight = row.weight
                }
            case .overspend:
                guard let groupId = row.groupId else { continue }
                let index = groupIndex(groupId)
                // Don't downgrade a real sink row already recorded.
                if !config.groups[index].take {
                    config.groups[index].take = true
                    config.groups[index].overspendOnly = true
                }
            }
        }
        return config
    }

    func toCleanupTemplates() -> [CleanupTemplate] {
        guard isConfigured else { return [] }
        var rows: [CleanupTemplate] = []
        if global.send { rows.append(.source()) }
        if global.take { rows.append(.sink(weight: global.weight)) }
        for group in groups {
            if group.send { rows.append(.source(groupId: group.groupId)) }
            if group.take {
                rows.append(group.overspendOnly
                    ? .overspend(groupId: group.groupId)
                    : .sink(groupId: group.groupId, weight: group.weight))
            }
        }
        return rows
    }
}
