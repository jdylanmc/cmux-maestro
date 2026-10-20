import Foundation

// Copilot's own session title from `<session-state>/<session-id>/workspace.yaml`.
// Only the top-level `name:` scalar is read (ADR 0022). Any other field, a block,
// multi-line, flow, tagged, aliased or malformed value leaves the name unavailable.
nonisolated enum CopilotSessionName {
    static let filename = "workspace.yaml"
    static let maximumFileBytes = 16_384
    static let maximumCharacters = 200
    /// YAML separates only with ASCII space and tab; other Unicode spaces are scalar content.
    private static let yamlBlank = CharacterSet(charactersIn: " \t")

    static func parse(_ data: Data) -> String? {
        scalar(forKey: "name", in: data, escapedTab: " ").flatMap(sanitize)
    }

    /// One top-level plain or quoted scalar, unsanitized, under the same strict rules as `name:`.
    /// A double-quoted `\t` decodes to a real tab unless display asks for `escapedTab`.
    static func scalar(forKey key: String, in data: Data, escapedTab: String = "\t") -> String? {
        guard data.count <= maximumFileBytes, var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // YAML line breaks only; "\r\n" is one Swift Character.
        let lines = text.split(omittingEmptySubsequences: false) { ["\n", "\r\n", "\r"].contains($0) }
        var found: String??
        // A top-level quoted scalar may continue on unindented lines; those lines are its content.
        var openQuote: Character?
        for (index, line) in lines.enumerated() {
            if let quote = openQuote {
                if closes(line[...], quote: quote) { openQuote = nil }
                continue
            }
            guard let first = line.first, first != " ", first != "\t", first != "#" else { continue }
            openQuote = unclosedQuote(line)
            guard line.hasPrefix(key + ":") else { continue }
            let value = line.dropFirst(key.count + 1)
            // `name:x` is a different plain key, not `name`.
            guard value.isEmpty || value.first == " " || value.first == "\t" else { continue }
            // A duplicate top-level key is ambiguous.
            guard found == nil else { return nil }
            found = .some(scalar(value, continued: continues(lines, after: index), escapedTab: escapedTab))
        }
        return found.flatMap { $0 }
    }

    /// A top-level scalar from a `workspace.yaml` that is entirely a flat mapping this parser models;
    /// anything else makes the value unavailable, never a guess (ADR 0027). Modeled: blank and comment
    /// lines; `plain_key: value` at column 0 with each key once; plain values on one line; quoted values
    /// closed on their own line; and block scalars (`|`, `>`) whose content is indented. Refused:
    /// documents markers, quoted or complex keys, flow collections, anchors, aliases, tags, multi-line
    /// plain or quoted values, nested mappings and sequences, and duplicate keys.
    static func rootScalar(forKey key: String, in data: Data, escapedTab: String = "\t") -> String? {
        guard data.count <= maximumFileBytes, var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(omittingEmptySubsequences: false) { ["\n", "\r\n", "\r"].contains($0) }
        var keys: Set<Substring> = []
        var found: Substring?
        var inBlockScalar = false
        for line in lines {
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) { continue }
            if line.first == " " || line.first == "\t" {
                // Only a block scalar's content is indented.
                guard inBlockScalar else { return nil }
                continue
            }
            inBlockScalar = false
            if line.first == "#" { continue }
            guard !line.hasPrefix("---"), !line.hasPrefix("..."), let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon]
            guard let head = name.unicodeScalars.first, CharacterSet.letters.contains(head) || head == "_",
                  name.unicodeScalars.allSatisfy({
                      ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-"
                  }),
                  keys.insert(name).inserted else { return nil }
            let rest = line[line.index(after: colon)...]
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            let value = rest.drop { $0 == " " || $0 == "\t" }
            switch value.first {
            case nil, "#":
                break
            case "|", ">":
                guard value.dropFirst().prefix(while: { $0 != " " && $0 != "\t" && $0 != "#" })
                        .allSatisfy({ "+-123456789".contains($0) }),
                      blankOrComment(value.drop { $0 != " " && $0 != "\t" && $0 != "#" }) else { return nil }
                inBlockScalar = true
            case "\"", "'":
                guard let quote = value.first, let end = quotedEnd(value.dropFirst(), quote: quote),
                      blankOrComment(value[end...]) else { return nil }
            case "{", "[", "&", "*", "!", "%", "@", "`", "-", "?", ":", ",", "]", "}":
                return nil
            default:
                guard mappingSeparator(in: value) == nil else { return nil }
            }
            if name == key { found = value }
        }
        guard let found, !found.isEmpty, found.first != "|", found.first != ">" else { return nil }
        return scalar(found, continued: false, escapedTab: escapedTab)
    }

    private static func blankOrComment(_ text: Substring) -> Bool {
        let rest = text.drop { $0 == " " || $0 == "\t" }
        return rest.isEmpty || rest.first == "#"
    }

    /// Just past the quote that closes a scalar opened by `quote`, on this line.
    private static func quotedEnd(_ text: Substring, quote: Character) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quote == "\"" && character == "\\" {
                guard next < text.endIndex else { return nil }
                index = text.index(after: next)
                continue
            }
            if character == quote {
                if quote == "'", next < text.endIndex, text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                return next
            }
            index = next
        }
        return nil
    }

    /// The quote character of a top-level quoted key or value left open at the end of `line`.
    private static func unclosedQuote(_ line: Substring) -> Character? {
        var candidate = line
        if candidate.first != "\"" && candidate.first != "'" {
            if candidate.hasPrefix("- ") || candidate.hasPrefix("-\t") {
                candidate = candidate.dropFirst(2)
            } else if let separator = mappingSeparator(in: candidate) {
                candidate = candidate[separator...]
            } else {
                return nil
            }
            candidate = candidate.drop { $0 == " " || $0 == "\t" }
        }
        guard let quote = candidate.first, quote == "\"" || quote == "'" else { return nil }
        return closes(candidate.dropFirst(), quote: quote) ? nil : quote
    }

    /// Just past the first `:` followed by a YAML blank (space or tab): a key's value starts there.
    private static func mappingSeparator(in line: Substring) -> Substring.Index? {
        var index = line.startIndex
        while let colon = line[index...].firstIndex(of: ":") {
            let next = line.index(after: colon)
            if next < line.endIndex, line[next] == " " || line[next] == "\t" { return line.index(after: next) }
            index = next
        }
        return nil
    }

    /// Whether `text`, inside a scalar opened by `quote`, contains its closing quote.
    private static func closes(_ text: Substring, quote: Character) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quote == "\"" && character == "\\" {
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if character == quote {
                if quote == "'", next < text.endIndex, text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                return true
            }
            index = next
        }
        return false
    }

    private static func continues(_ lines: [Substring], after index: Int) -> Bool {
        guard let next = lines.dropFirst(index + 1).first(where: {
            !$0.trimmingCharacters(in: yamlBlank).isEmpty
        }) else { return false }
        return next.first == " " || next.first == "\t"
    }

    private static func scalar(_ raw: Substring, continued: Bool, escapedTab: String) -> String? {
        let value = raw.trimmingCharacters(in: yamlBlank)
        // Indented lines after the key would extend a plain scalar or form a nested block.
        guard !value.isEmpty, !continued, let first = value.first else { return nil }
        switch first {
        case "\"": return doubleQuoted(value, escapedTab: escapedTab)
        case "'": return singleQuoted(value)
        // Block scalars, anchors, aliases, tags, flow collections and reserved indicators.
        case "|", ">", "&", "*", "!", "[", "]", "{", "}", "@", "`", "%", "#", ",": return nil
        default: return plain(value)
        }
    }

    private static func plain(_ value: String) -> String? {
        if ["-", "?", ":"].contains(value)
            || ["- ", "-\t", "? ", "?\t", ": ", ":\t"].contains(where: value.hasPrefix) { return nil }
        var result = Substring(value)
        // A comment starts at the first `#` after a YAML blank.
        if let hash = result.indices.first(where: {
            result[$0] == "#" && $0 > result.startIndex && [" ", "\t"].contains(result[result.index(before: $0)])
        }) {
            result = result[..<hash]
        }
        let trimmed = String(result).trimmingCharacters(in: yamlBlank)
        // `key: value` inside a plain scalar is a nested mapping, not a title.
        guard !trimmed.isEmpty, mappingSeparator(in: Substring(trimmed)) == nil, !trimmed.hasSuffix(":") else { return nil }
        // Plain null is no name.
        guard trimmed != "~", trimmed.lowercased() != "null" else { return nil }
        return trimmed
    }

    private static func singleQuoted(_ value: String) -> String? {
        var result = ""
        var iterator = value.dropFirst().makeIterator()
        while let character = iterator.next() {
            if character == "'" {
                guard let next = iterator.next() else { return result }
                if next == "'" { result.append("'"); continue }
                return trailingIsEmpty(next, &iterator) ? result : nil
            }
            result.append(character)
        }
        return nil
    }

    private static func doubleQuoted(_ value: String, escapedTab: String) -> String? {
        var result = ""
        var iterator = value.dropFirst().makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\"":
                guard let next = iterator.next() else { return result }
                return trailingIsEmpty(next, &iterator) ? result : nil
            case "\\":
                switch iterator.next() {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "/": result.append("/")
                case "t": result.append(escapedTab)
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let digit = iterator.next() { hex.append(digit) } }
                    guard hex.count == 4, let code = UInt32(hex, radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    result.unicodeScalars.append(scalar)
                default: return nil
                }
            default: result.append(character)
            }
        }
        return nil
    }

    private static func trailingIsEmpty(
        _ first: Character, _ iterator: inout IndexingIterator<Substring>
    ) -> Bool {
        var rest = String(first)
        while let character = iterator.next() { rest.append(character) }
        let trimmed = rest.trimmingCharacters(in: yamlBlank)
        return trimmed.isEmpty || ((rest.first == " " || rest.first == "\t") && trimmed.hasPrefix("#"))
    }

    static func sanitize(_ value: String) -> String? {
        CopilotDisplayText.sanitize(value, limit: maximumCharacters)
    }
}
