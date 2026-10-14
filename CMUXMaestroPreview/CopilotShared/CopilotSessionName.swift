import Darwin
import Foundation

// Copilot's own session title from `<session-state>/<session-id>/workspace.yaml`.
// Only the top-level `name:` scalar is read (ADR 0022). Any other field, a block,
// multi-line, flow, tagged, aliased or malformed value leaves the name unavailable.
nonisolated enum CopilotSessionName {
    static let filename = "workspace.yaml"
    static let maximumFileBytes = 16_384
    static let maximumCharacters = 200

    static func parse(_ data: Data) -> String? {
        guard data.count <= maximumFileBytes, var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // YAML line breaks only; "\r\n" is one Swift Character.
        let lines = text.split(omittingEmptySubsequences: false) { ["\n", "\r\n", "\r"].contains($0) }
        var found: String??
        for (index, line) in lines.enumerated() where line.hasPrefix("name:") {
            let value = line.dropFirst("name:".count)
            // `name:x` is a different plain key, not `name`.
            guard value.isEmpty || value.first == " " || value.first == "\t" else { continue }
            // A duplicate top-level key is ambiguous.
            guard found == nil else { return nil }
            found = .some(scalar(value, continued: continues(lines, after: index)))
        }
        return found.flatMap { $0 }.flatMap(sanitize)
    }

    private static func continues(_ lines: [Substring], after index: Int) -> Bool {
        guard let next = lines.dropFirst(index + 1).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return false }
        return next.first == " " || next.first == "\t"
    }

    private static func scalar(_ raw: Substring, continued: Bool) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        // Indented lines after the key would extend a plain scalar or form a nested block.
        guard !value.isEmpty, !continued, let first = value.first else { return nil }
        switch first {
        case "\"": return doubleQuoted(value)
        case "'": return singleQuoted(value)
        // Block scalars, anchors, aliases, tags, flow collections and reserved indicators.
        case "|", ">", "&", "*", "!", "[", "]", "{", "}", "@", "`", "%", "#", ",": return nil
        default: return plain(value)
        }
    }

    private static func plain(_ value: String) -> String? {
        if ["-", "?", ":"].contains(value) || value.hasPrefix("- ") || value.hasPrefix("? ")
            || value.hasPrefix(": ") { return nil }
        var result = value
        if let comment = result.range(of: " #") ?? result.range(of: "\t#") {
            result = String(result[..<comment.lowerBound])
        }
        result = result.trimmingCharacters(in: .whitespaces)
        // `key: value` inside a plain scalar is a nested mapping, not a title.
        guard !result.isEmpty, !result.contains(": "), !result.hasSuffix(":") else { return nil }
        return result
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

    private static func doubleQuoted(_ value: String) -> String? {
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
                case "t": result.append(" ")
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
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || (rest.first?.isWhitespace == true && trimmed.hasPrefix("#"))
    }

    static func sanitize(_ value: String) -> String? {
        let hidden = CharacterSet(charactersIn:
            "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        let kept = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !hidden.contains($0)
        }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maximumCharacters))
    }
}

// Per-session cache keyed only by exact session UUID. A file is re-read only
// when its identity, size or modification time changes.
nonisolated struct CopilotSessionNameCache: Sendable {
    private struct Entry: Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let name: String?

        func matches(_ stamp: CopilotFileStamp) -> Bool {
            device == stamp.device && inode == stamp.inode && size == stamp.size
                && modifiedSeconds == stamp.modifiedSeconds && modifiedNanoseconds == stamp.modifiedNanoseconds
        }
    }

    private var entries: [UUID: Entry] = [:]
    private(set) var reads = 0

    var count: Int { entries.count }

    mutating func name(for sessionID: UUID, sessionDirectory: Int32, owner: UInt32) -> String? {
        guard let stamp = try? CopilotFileAccess.statEntry(at: sessionDirectory, name: CopilotSessionName.filename),
              stamp.isRegular, stamp.uid == owner,
              stamp.size > 0, stamp.size <= Int64(CopilotSessionName.maximumFileBytes) else {
            entries.removeValue(forKey: sessionID)
            return nil
        }
        if let cached = entries[sessionID], cached.matches(stamp) { return cached.name }
        reads += 1
        guard let data = try? CopilotFileAccess.readStableRegular(
            at: sessionDirectory, filename: CopilotSessionName.filename, owner: owner,
            maximum: CopilotSessionName.maximumFileBytes
        ) else {
            entries.removeValue(forKey: sessionID)
            return nil
        }
        let name = CopilotSessionName.parse(data)
        entries[sessionID] = .init(
            device: stamp.device, inode: stamp.inode, size: stamp.size,
            modifiedSeconds: stamp.modifiedSeconds, modifiedNanoseconds: stamp.modifiedNanoseconds, name: name
        )
        return name
    }

    mutating func forget(_ sessionID: UUID) { entries.removeValue(forKey: sessionID) }

    mutating func retain(only sessionIDs: Set<UUID>) {
        entries = entries.filter { sessionIDs.contains($0.key) }
    }

    mutating func removeAll() { entries.removeAll() }
}
