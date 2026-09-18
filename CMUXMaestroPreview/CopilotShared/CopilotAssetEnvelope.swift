import Foundation

// Only the envelope of a binary-asset event is relevant to this observer.
// Keep root metadata bounded while discarding the opaque data object.
nonisolated struct CopilotAssetEnvelope {
    private let maximumBytes: Int
    private var envelope = Data()
    private var containers: [UInt8] = []
    private var payloadContainers: [UInt8] = []
    private var inString = false
    private var escaped = false
    private var keyBytes = Data()
    private var readingKey = false
    private var expectingKey = false
    private var currentKey: String?
    private var keys: Set<String> = []
    private var awaitingPayload = false
    private var sawPayload = false
    private var valid = true

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func consume(_ bytes: Data) {
        guard valid else { return }
        for byte in bytes {
            guard valid else { return }
            if !payloadContainers.isEmpty {
                consumePayload(byte)
                continue
            }
            if awaitingPayload {
                if Self.whitespace(byte) { continue }
                guard byte == 123 else { valid = false; return }
                envelope.append(contentsOf: [110, 117, 108, 108]) // null
                guard envelope.count <= maximumBytes else { valid = false; return }
                payloadContainers = [byte]
                awaitingPayload = false
                sawPayload = true
                continue
            }
            guard envelope.count < maximumBytes else { valid = false; return }
            envelope.append(byte)
            if inString {
                if readingKey {
                    guard keyBytes.count < 1_024 else { valid = false; return }
                    keyBytes.append(byte)
                }
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                    if readingKey {
                        guard let key = try? JSONDecoder().decode(String.self, from: keyBytes),
                              keys.count < 64, keys.insert(key).inserted else {
                            valid = false
                            return
                        }
                        currentKey = key
                        expectingKey = false
                        readingKey = false
                        keyBytes.removeAll(keepingCapacity: true)
                    }
                }
                continue
            }
            switch byte {
            case 34:
                inString = true
                readingKey = containers.count == 1 && expectingKey
                if readingKey { keyBytes = Data([byte]) }
            case 123, 91:
                guard containers.count < 64 else { valid = false; return }
                containers.append(byte)
                if containers.count == 1 {
                    guard byte == 123 else { valid = false; return }
                    expectingKey = true
                }
            case 125, 93:
                guard let open = containers.popLast(), Self.matches(open, byte) else {
                    valid = false
                    return
                }
            case 44 where containers.count == 1:
                expectingKey = true
                currentKey = nil
            case 58 where containers.count == 1 && currentKey == "data":
                awaitingPayload = true
            default:
                break
            }
        }
    }

    var isIgnorableBinaryAsset: Bool {
        projectedBinaryAsset != nil
    }

    var projectedBinaryAsset: Data? {
        guard valid, sawPayload, !inString, !awaitingPayload,
              containers.isEmpty, payloadContainers.isEmpty,
              let event = try? JSONDecoder().decode(CopilotEventProjection.self, from: envelope),
              event.type == "session.binary_asset" else { return nil }
        return envelope
    }

    private mutating func consumePayload(_ byte: UInt8) {
        if inString {
            guard byte >= 32 else { valid = false; return }
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                inString = false
            }
            return
        }
        switch byte {
        case 34:
            inString = true
        case 123, 91:
            guard payloadContainers.count < 64 else { valid = false; return }
            payloadContainers.append(byte)
        case 125, 93:
            guard let open = payloadContainers.popLast(), Self.matches(open, byte) else {
                valid = false
                return
            }
        default:
            break
        }
    }

    private static func matches(_ open: UInt8, _ close: UInt8) -> Bool {
        (open == 123 && close == 125) || (open == 91 && close == 93)
    }

    private static func whitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 13
    }
}
