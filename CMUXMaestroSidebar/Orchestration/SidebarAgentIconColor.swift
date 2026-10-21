import Foundation

/// Agent records retain their named-only wire contract; custom hex belongs to human preferences.
@propertyWrapper
nonisolated struct SidebarAgentIconColor: Codable, Equatable, Sendable {
    var wrappedValue: SidebarAvatarColor?

    init(wrappedValue: SidebarAvatarColor? = nil) { self.wrappedValue = wrappedValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { wrappedValue = nil; return }
        let color = try container.decode(SidebarAvatarColor.self)
        guard color.customColor == nil else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Agent colors must use the named palette.")
        }
        wrappedValue = color
    }

    func encode(to encoder: any Encoder) throws {
        guard wrappedValue?.customColor == nil else {
            throw EncodingError.invalidValue(wrappedValue as Any, .init(
                codingPath: encoder.codingPath, debugDescription: "Agent colors must use the named palette."
            ))
        }
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: SidebarAgentIconColor.Type, forKey key: Key) throws -> SidebarAgentIconColor {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: SidebarAgentIconColor, forKey key: Key) throws {
        if value.wrappedValue != nil { try encodeIfPresent(value, forKey: key) }
    }
}
