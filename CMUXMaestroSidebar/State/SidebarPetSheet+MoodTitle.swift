import Foundation

extension SidebarPetSheet.Mood {
    var title: String {
        switch self {
        case .idle: String(localized: "mood.idle", defaultValue: "Idle")
        case .thinking: String(localized: "mood.thinking", defaultValue: "Thinking")
        case .working: String(localized: "mood.working", defaultValue: "Working")
        case .delegating: String(localized: "mood.delegating", defaultValue: "Delegating")
        case .question: String(localized: "mood.question", defaultValue: "Question")
        case .needsPermission: String(localized: "mood.needsPermission", defaultValue: "Needs permission")
        case .confused: String(localized: "mood.confused", defaultValue: "Confused")
        case .content: String(localized: "mood.content", defaultValue: "Content")
        case .startled: String(localized: "mood.startled", defaultValue: "Startled")
        case .sad: String(localized: "mood.sad", defaultValue: "Sad")
        case .compacting: String(localized: "mood.compacting", defaultValue: "Compacting")
        case .sleepy: String(localized: "mood.sleepy", defaultValue: "Sleepy")
        case .gone: String(localized: "mood.gone", defaultValue: "Gone")
        case .proud: String(localized: "mood.proud", defaultValue: "Proud")
        case .celebrating: String(localized: "mood.celebrating", defaultValue: "Celebrating")
        }
    }
}
