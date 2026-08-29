import Foundation

enum PreviewConnectionState: Equatable, CaseIterable {
    case waiting
    case connected
    case degraded

    var title: String {
        switch self {
        case .waiting:
            "Waiting"
        case .connected:
            "Connected"
        case .degraded:
            "Degraded"
        }
    }

    var detail: String {
        switch self {
        case .waiting:
            "Waiting for CMUX to connect and provide a sidebar snapshot."
        case .connected:
            "CMUX is connected and sharing its permitted workspace metadata."
        case .degraded:
            "The sidebar remains visible and reports the connection error."
        }
    }

    var symbolName: String {
        switch self {
        case .waiting:
            "clock"
        case .connected:
            "checkmark.circle.fill"
        case .degraded:
            "exclamationmark.triangle.fill"
        }
    }
}
