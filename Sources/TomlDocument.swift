import Foundation

enum TomlScalar: Equatable {
    case string(String)
    case boolean(Bool)
    case integer(Int)

    var encoded: String {
        switch self {
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        case .boolean(let value):
            return value ? "true" : "false"
        case .integer(let value):
            return String(value)
        }
    }
}

struct TomlDocument: Equatable {
    private var lines: [String]
    private var hasTrailingNewline: Bool

    static func parse(_ text: String) throws -> TomlDocument {
        let hasTrailingNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if hasTrailingNewline {
            lines.removeLast()
        }
        if text.isEmpty {
            lines = []
        }

        var currentTable: [String] = []
        var seenTables = Set<[String]>()
        var seenKeys: [[String]: Set<String>] = [:]

        for (index, line) in lines.enumerated() {
            if isArrayTableHeader(line) {
                currentTable = ["__array_table_\(index)"]
                continue
            }
            if let table = try parseTableHeader(line) {
                guard seenTables.insert(table).inserted else {
                    throw parseError("duplicate table header at line \(index + 1)")
                }
                currentTable = table
                continue
            }
            if let key = parseAssignmentKey(line) {
                var keys = seenKeys[currentTable, default: []]
                guard keys.insert(key).inserted else {
                    throw parseError("duplicate key at line \(index + 1)")
                }
                seenKeys[currentTable] = keys
            }
        }

        return TomlDocument(lines: lines, hasTrailingNewline: hasTrailingNewline)
    }

    mutating func set(table: [String], key: String, value: TomlScalar) {
        let replacement = "\(Self.renderKey(key)) = \(value.encoded)"
        let range = tableRange(for: table)

        if let existingIndex = range.flatMap({ assignmentIndex(for: key, in: $0) }) {
            lines[existingIndex] = replacement
            return
        }

        if let range {
            var insertionIndex = range.upperBound
            while insertionIndex > range.lowerBound, lines[insertionIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertionIndex -= 1
            }
            lines.insert(replacement, at: insertionIndex)
            return
        }

        if table.isEmpty {
            let insertionIndex = firstTableIndex() ?? lines.endIndex
            lines.insert(replacement, at: insertionIndex)
            return
        }

        if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
            lines.append("")
        }
        lines.append(Self.renderTableHeader(table))
        lines.append(replacement)
    }

    mutating func remove(table: [String], key: String) {
        guard let range = tableRange(for: table), let index = assignmentIndex(for: key, in: range) else {
            return
        }
        lines.remove(at: index)
    }

    func render() -> String {
        let body = lines.joined(separator: "\n")
        return hasTrailingNewline && !lines.isEmpty ? body + "\n" : body
    }

    func value(table: [String], key: String) throws -> TomlScalar? {
        guard let range = tableRange(for: table),
              let index = assignmentIndex(for: key, in: range),
              let separator = lines[index].firstIndex(of: "=") else {
            return nil
        }
        let raw = lines[index][lines[index].index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("\"") {
            guard let data = raw.data(using: .utf8) else {
                throw Self.parseError("invalid UTF-8 string value")
            }
            return .string(try JSONDecoder().decode(String.self, from: data))
        }
        if raw == "true" {
            return .boolean(true)
        }
        if raw == "false" {
            return .boolean(false)
        }
        if let integer = Int(raw) {
            return .integer(integer)
        }
        throw Self.parseError("unsupported scalar value")
    }

    private func tableRange(for requestedTable: [String]) -> Range<Int>? {
        if requestedTable.isEmpty {
            return 0..<(firstTableIndex() ?? lines.endIndex)
        }

        for index in lines.indices {
            guard let table = try? Self.parseTableHeader(lines[index]), table == requestedTable else {
                continue
            }
            var end = index + 1
            while end < lines.endIndex, !Self.isAnyTableHeader(lines[end]) {
                end += 1
            }
            return (index + 1)..<end
        }
        return nil
    }

    private func firstTableIndex() -> Int? {
        lines.firstIndex(where: Self.isAnyTableHeader)
    }

    private func assignmentIndex(for key: String, in range: Range<Int>) -> Int? {
        range.first(where: { Self.parseAssignmentKey(lines[$0]) == key })
    }

    private static func renderTableHeader(_ table: [String]) -> String {
        let components = table.enumerated().map { index, component in
            if index == 0, component.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                return component
            }
            return TomlScalar.string(component).encoded
        }
        return "[\(components.joined(separator: "."))]"
    }

    private static func renderKey(_ key: String) -> String {
        key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            ? key
            : TomlScalar.string(key).encoded
    }

    private static func isAnyTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[")
    }

    private static func isArrayTableHeader(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[[")
    }

    private static func parseTableHeader(_ line: String) throws -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else {
            return nil
        }

        var quote: Character?
        var escaped = false
        var closingIndex: String.Index?
        var index = trimmed.index(after: trimmed.startIndex)
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                closingIndex = index
                break
            }
            index = trimmed.index(after: index)
        }

        guard let closingIndex else {
            throw parseError("unterminated table header")
        }
        let suffix = trimmed[trimmed.index(after: closingIndex)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#") else {
            throw parseError("unexpected content after table header")
        }
        let contents = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingIndex])
        return try parseTableComponents(contents)
    }

    private static func parseTableComponents(_ contents: String) throws -> [String] {
        var components: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in contents {
            if let activeQuote = quote {
                current.append(character)
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "." {
                components.append(try decodeTableComponent(current))
                current = ""
            } else {
                current.append(character)
            }
        }

        guard quote == nil else {
            throw parseError("unterminated quoted table component")
        }
        components.append(try decodeTableComponent(current))
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
            throw parseError("empty table component")
        }
        return components
    }

    private static func decodeTableComponent(_ raw: String) throws -> String {
        let component = raw.trimmingCharacters(in: .whitespaces)
        guard !component.isEmpty else {
            throw parseError("empty table component")
        }
        if component.hasPrefix("\"") {
            guard component.hasSuffix("\""), let data = component.data(using: .utf8) else {
                throw parseError("invalid quoted table component")
            }
            return try JSONDecoder().decode(String.self, from: data)
        }
        if component.hasPrefix("'") {
            guard component.hasSuffix("'") else {
                throw parseError("invalid literal table component")
            }
            return String(component.dropFirst().dropLast())
        }
        return component
    }

    private static func parseAssignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else {
            return nil
        }

        var quote: Character?
        var escaped = false
        for index in trimmed.indices {
            let character = trimmed[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                let rawKey = trimmed[..<index].trimmingCharacters(in: .whitespaces)
                if rawKey.hasPrefix("\""), rawKey.hasSuffix("\""), let data = rawKey.data(using: .utf8) {
                    return try? JSONDecoder().decode(String.self, from: data)
                }
                if rawKey.hasPrefix("'"), rawKey.hasSuffix("'") {
                    return String(rawKey.dropFirst().dropLast())
                }
                return rawKey.isEmpty ? nil : rawKey
            }
        }
        return nil
    }

    private static func parseError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.TOML",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
