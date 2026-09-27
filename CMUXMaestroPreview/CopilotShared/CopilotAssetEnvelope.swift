import Foundation

// Streaming JSON validation with metadata-only retention. Payload values are
// never accumulated. The ordinary event decoder still owns all interpretation.
nonisolated struct CopilotAssetEnvelope {
    static let maximumDepth = 64
    static let maximumKeysPerObject = 64
    static let maximumKeyBytes = 1_024
    static let maximumLiveKeyBytes = 65_536
    static let maximumScalarBytes = 2_048

    private enum Scope { case root, data, kind, discarded }
    private enum Expectation { case keyOrEnd, key, colon, value, valueOrEnd, commaOrEnd }
    private struct Frame {
        let object: Bool
        let scope: Scope
        var expectation: Expectation
        var key: String?
        var keys: Set<String> = []
        var keyBytes = 0
    }
    private struct Selection {
        let scope: Scope
        let key: String
    }
    private enum NumberState { case sign, zero, integer, dot, fraction, exponent, exponentSign, exponentDigits }
    private enum Token { case none, string, number(NumberState), literal([UInt8], Int) }
    private enum Escape {
        case none, slash, unicode(Int, UInt32), lowSlash, lowU, lowUnicode(Int, UInt32)
    }

    private let maximumBytes: Int
    private var frames: [Frame] = []
    private var root: [String: Data] = [:]
    private var data: [String: Data] = [:]
    private var kind: [String: Data] = [:]
    private var token = Token.none
    private var escape = Escape.none
    private var scalar = Data()
    private var scalarOverflow = false
    private var stringIsKey = false
    private var selection: Selection?
    private var utf8Remaining = 0
    private var utf8Lower: UInt8 = 0x80
    private var utf8Upper: UInt8 = 0xbf
    private var liveKeyBytes = 0
    private var started = false
    private var valid = true

    init(maximumBytes: Int) {
        self.maximumBytes = max(1, maximumBytes)
    }

    mutating func consume(_ bytes: Data) {
        for byte in bytes {
            guard valid else { return }
            switch token {
            case .string:
                appendScalar(byte)
                consumeString(byte)
            case .number(let state):
                if consumeNumber(byte, state: state) { continue }
                guard valid else { return }
                consumeStructure(byte)
            case .literal(let expected, let index):
                guard byte == expected[index] else { valid = false; return }
                appendScalar(byte)
                if index + 1 == expected.count {
                    finishScalar()
                } else {
                    token = .literal(expected, index + 1)
                }
            case .none:
                consumeStructure(byte)
            }
        }
    }

    var projectedEvent: Data? {
        guard valid, started, frames.isEmpty, case .none = token else { return nil }
        let bytes = Self.object(root)
        guard bytes.count <= maximumBytes,
              let event = try? JSONDecoder().decode(CopilotEventProjection.self, from: bytes),
              event.supportsPayloadProjection else { return nil }
        // Preserve the existing asset envelope's object requirement.
        if event.type == "session.binary_asset", root["data"]?.first != 123 { return nil }
        return bytes
    }

    var projectedBinaryAsset: Data? {
        guard let bytes = projectedEvent,
              let event = try? JSONDecoder().decode(CopilotEventProjection.self, from: bytes),
              event.type == "session.binary_asset" else { return nil }
        return bytes
    }

    var isIgnorableBinaryAsset: Bool { projectedBinaryAsset != nil }

    var retainedByteCount: Int {
        liveKeyBytes + scalar.count
            + [root, data, kind].reduce(0) { total, fields in
                total + fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
            }
    }

    private mutating func consumeStructure(_ byte: UInt8) {
        if [9, 10, 13, 32].contains(byte) { return }
        guard started else {
            guard byte == 123 else { valid = false; return }
            started = true
            frames.append(Frame(object: true, scope: .root, expectation: .keyOrEnd))
            return
        }
        guard !frames.isEmpty else { valid = false; return }
        let index = frames.count - 1
        switch frames[index].expectation {
        case .keyOrEnd where byte == 125:
            closeContainer(object: true)
        case .keyOrEnd, .key:
            guard byte == 34 else { valid = false; return }
            startScalar(selection: nil)
            stringIsKey = true
            scalar.append(byte)
            token = .string
        case .colon:
            guard byte == 58 else { valid = false; return }
            frames[index].expectation = .value
        case .valueOrEnd where byte == 93:
            closeContainer(object: false)
        case .value, .valueOrEnd:
            let target = selectedValue(in: frames[index])
            frames[index].expectation = .commaOrEnd
            frames[index].key = nil
            startValue(byte, selection: target)
        case .commaOrEnd:
            if byte == 44 {
                frames[index].expectation = frames[index].object ? .key : .value
            } else if byte == 125 || byte == 93 {
                closeContainer(object: byte == 125)
            } else {
                valid = false
            }
        }
    }

    private func selectedValue(in frame: Frame) -> Selection? {
        guard let key = frame.key else { return nil }
        let selected: Bool
        switch frame.scope {
        case .root: selected = CopilotEventProjection.Keys(rawValue: key) != nil
        case .data: selected = CopilotEventProjection.Fields(rawValue: key) != nil
        case .kind: selected = CopilotEventProjection.NotificationFields(rawValue: key) != nil
        case .discarded: selected = false
        }
        return selected ? Selection(scope: frame.scope, key: key) : nil
    }

    private mutating func startValue(_ byte: UInt8, selection: Selection?) {
        switch byte {
        case 123, 91:
            guard frames.count < Self.maximumDepth else { valid = false; return }
            var scope = Scope.discarded
            if let selection {
                store(Data(byte == 123 ? "{}".utf8 : "[]".utf8), at: selection)
                if byte == 123 {
                    if selection.scope == .root && selection.key == "data" { scope = .data }
                    if selection.scope == .data && selection.key == "kind" { scope = .kind }
                }
            }
            frames.append(Frame(object: byte == 123, scope: scope,
                                expectation: byte == 123 ? .keyOrEnd : .valueOrEnd))
        case 34:
            startScalar(selection: selection)
            appendScalar(byte)
            token = .string
        case 45, 48...57:
            startScalar(selection: selection)
            appendScalar(byte)
            token = .number(byte == 45 ? .sign : byte == 48 ? .zero : .integer)
        case 116, 102, 110:
            startScalar(selection: selection)
            appendScalar(byte)
            token = .literal(Array((byte == 116 ? "true" : byte == 102 ? "false" : "null").utf8), 1)
        default:
            valid = false
        }
    }

    private mutating func closeContainer(object: Bool) {
        guard let frame = frames.last, frame.object == object else { valid = false; return }
        frames.removeLast()
        liveKeyBytes -= frame.keyBytes
        switch frame.scope {
        case .data:
            root["data"] = Self.object(data)
            data.removeAll(keepingCapacity: false)
        case .kind:
            data["kind"] = Self.object(kind)
            kind.removeAll(keepingCapacity: false)
        default: break
        }
    }

    private mutating func startScalar(selection: Selection?) {
        self.selection = selection
        scalar.removeAll(keepingCapacity: true)
        scalarOverflow = false
        stringIsKey = false
        escape = .none
        utf8Remaining = 0
        utf8Lower = 0x80
        utf8Upper = 0xbf
    }

    private mutating func appendScalar(_ byte: UInt8) {
        guard stringIsKey || selection != nil else { return }
        let limit = stringIsKey ? Self.maximumKeyBytes : Self.maximumScalarBytes
        if scalar.count < limit {
            scalar.append(byte)
        } else if stringIsKey {
            valid = false
        } else {
            scalarOverflow = true
        }
    }

    private mutating func finishScalar() {
        if let selection {
            // An over-budget metadata scalar stays present but unusable, never
            // absent/defaulted. Unknown event fields remain opaque to the decoder.
            store(scalarOverflow ? Data("[]".utf8) : scalar, at: selection)
        }
        scalar.removeAll(keepingCapacity: true)
        selection = nil
        token = .none
    }

    private mutating func store(_ bytes: Data, at selection: Selection) {
        switch selection.scope {
        case .root: root[selection.key] = bytes
        case .data: data[selection.key] = bytes
        case .kind: kind[selection.key] = bytes
        case .discarded: break
        }
    }

    private static func object(_ fields: [String: Data]) -> Data {
        var result = Data([123])
        for key in fields.keys.sorted() {
            if result.count > 1 { result.append(44) }
            // Only the decoder's fixed ASCII CodingKeys reach this dictionary.
            result.append(contentsOf: "\"\(key)\":".utf8)
            result.append(fields[key]!)
        }
        result.append(125)
        return result
    }

    private mutating func consumeString(_ byte: UInt8) {
        guard valid else { return }
        if utf8Remaining > 0 {
            guard byte >= utf8Lower && byte <= utf8Upper else { valid = false; return }
            utf8Remaining -= 1
            utf8Lower = 0x80
            utf8Upper = 0xbf
            return
        }
        switch escape {
        case .slash:
            if byte == 117 { escape = .unicode(0, 0) }
            else if [34, 92, 47, 98, 102, 110, 114, 116].contains(byte) { escape = .none }
            else { valid = false }
        case .unicode(let count, let value), .lowUnicode(let count, let value):
            guard let digit = Self.hex(byte) else { valid = false; return }
            let next = value * 16 + digit
            let low: Bool
            if case .lowUnicode = escape { low = true } else { low = false }
            if count < 3 {
                escape = low ? .lowUnicode(count + 1, next) : .unicode(count + 1, next)
            } else if low {
                if (0xdc00...0xdfff).contains(next) { escape = .none } else { valid = false }
            } else if (0xd800...0xdbff).contains(next) {
                escape = .lowSlash
            } else if (0xdc00...0xdfff).contains(next) {
                valid = false
            } else { escape = .none }
        case .lowSlash:
            if byte == 92 { escape = .lowU } else { valid = false }
        case .lowU:
            if byte == 117 { escape = .lowUnicode(0, 0) } else { valid = false }
        case .none:
            switch byte {
            case 34:
                if stringIsKey {
                    guard let key = try? JSONDecoder().decode(String.self, from: scalar),
                          frames[frames.count - 1].keys.count < Self.maximumKeysPerObject,
                          liveKeyBytes + scalar.count <= Self.maximumLiveKeyBytes,
                          frames[frames.count - 1].keys.insert(key).inserted else {
                        valid = false
                        return
                    }
                    liveKeyBytes += scalar.count
                    frames[frames.count - 1].keyBytes += scalar.count
                    frames[frames.count - 1].key = key
                    frames[frames.count - 1].expectation = .colon
                    scalar.removeAll(keepingCapacity: true)
                    token = .none
                } else { finishScalar() }
            case 92: escape = .slash
            case 0...31: valid = false
            case 32...127: break
            case 0xc2...0xdf: utf8Remaining = 1
            case 0xe0:
                utf8Remaining = 2
                utf8Lower = 0xa0
            case 0xe1...0xec, 0xee...0xef: utf8Remaining = 2
            case 0xed:
                utf8Remaining = 2
                utf8Upper = 0x9f
            case 0xf0:
                utf8Remaining = 3
                utf8Lower = 0x90
            case 0xf1...0xf3: utf8Remaining = 3
            case 0xf4:
                utf8Remaining = 3
                utf8Upper = 0x8f
            default: valid = false
            }
        }
    }

    private static func hex(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 48...57: UInt32(byte - 48)
        case 65...70: UInt32(byte - 55)
        case 97...102: UInt32(byte - 87)
        default: nil
        }
    }

    // Returns false only when a complete number leaves a delimiter to the grammar.
    private mutating func consumeNumber(_ byte: UInt8, state: NumberState) -> Bool {
        let next: NumberState?
        switch (state, byte) {
        case (.sign, 48): next = .zero
        case (.sign, 49...57), (.integer, 48...57): next = .integer
        case (.zero, 46), (.integer, 46): next = .dot
        case (.dot, 48...57), (.fraction, 48...57): next = .fraction
        case (.zero, 101), (.zero, 69), (.integer, 101), (.integer, 69),
             (.fraction, 101), (.fraction, 69): next = .exponent
        case (.exponent, 43), (.exponent, 45): next = .exponentSign
        case (.exponent, 48...57), (.exponentSign, 48...57), (.exponentDigits, 48...57):
            next = .exponentDigits
        default: next = nil
        }
        if let next {
            appendScalar(byte)
            token = .number(next)
            return true
        }
        switch state {
        case .zero, .integer, .fraction, .exponentDigits: finishScalar()
        default: valid = false
        }
        return false
    }
}
