import Foundation

/// Sanitized primary-owner facts for presentation, never lifecycle or completion evidence.
nonisolated struct AgentPresentationInputs: Codable, Equatable, Sendable {
    enum AbortReason: String, Codable, Sendable {
        case userAbort = "user_abort"
        case userExit = "user_exit"
        case streamingError = "streaming_error"
        case other
    }

    enum ErrorCategory: String, Codable, Sendable {
        case quota, authorization, execution, query, other
    }

    var primaryTurnOpen: Bool?
    /// No supported persisted failure in a fully observed turn; not proof of a good outcome
    /// or the absence of ephemeral model failures.
    var turnClean: Bool?
    var abortReason: AbortReason?
    var errorCategory: ErrorCategory?
    /// Unknown when the provider omits its ephemeral model events.
    var modelTrouble: Bool?
    /// Saturates at 255; completions are counted in admitted event order.
    var consecutiveToolFailures: UInt8?
    var compactionActive: Bool?
}
