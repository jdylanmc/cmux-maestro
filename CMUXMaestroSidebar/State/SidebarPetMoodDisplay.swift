import Foundation
import Observation

/// Cosmetic previews halted by a real event, shared by every pet view so a later view cannot resume them.
@MainActor
final class SidebarMoodPreviewHalts {
    private struct Key: Hashable {
        let session: UUID
        let playback: SidebarMoodObservation.Playback
    }

    static let shared = SidebarMoodPreviewHalts()
    private var halted: Set<Key> = []

    func halt(_ playback: SidebarMoodObservation.Playback, session: UUID, now: Date) {
        // Entries end with their own fixed window, so the set stays bounded by concurrent previews.
        halted = halted.filter { $0.playback.isCurrent(at: now) }
        halted.insert(.init(session: session, playback: playback))
    }

    func contains(_ playback: SidebarMoodObservation.Playback, session: UUID) -> Bool {
        halted.contains(.init(session: session, playback: playback))
    }
}

/// Owned by a visible pet, with one cancellable presentation deadline and no replay queue.
@MainActor @Observable
final class SidebarPetMoodDisplay {
    struct Clock {
        var now: () -> Date
        var sleepUntil: (Date) async throws -> Void

        static var continuous: Self {
            let clock = ContinuousClock()
            let origin = clock.now
            let wallOrigin = Date()
            let now = {
                let elapsed = origin.duration(to: clock.now).components
                return wallOrigin.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            }
            return .init(now: now, sleepUntil: { deadline in
                // This delay is the intended minimum display duration, never observation polling.
                try await clock.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now()))))
            })
        }
    }

    private(set) var shown: SidebarPetMood?
    private(set) var current: SidebarPetMood?
    private(set) var deadline: Date?
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private var input = SidebarPetMoodInput.unavailable
    @ObservationIgnored private var identity: SidebarPetMoodInput.Identity?
    @ObservationIgnored private var shownAt: Date?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var rejectedPreview: SidebarMoodObservation.Playback?
    @ObservationIgnored private var observedPreview: SidebarMoodObservation.Playback?
    @ObservationIgnored private let previewHalts: SidebarMoodPreviewHalts

    init(clock: Clock = .continuous, previewHalts: SidebarMoodPreviewHalts = .shared) {
        self.clock = clock
        self.previewHalts = previewHalts
    }

    static func description(shown: SidebarPetMood, current: SidebarPetMood) -> String {
        shown.mood == current.mood && !shown.isPreview ? current.description
            : String(localized: "mood.held", defaultValue: "Shown: \(shown.description). Current: \(current.description)")
    }

    func update(_ input: SidebarPetMoodInput) {
        self.input = input
        sample()
    }

    func stop() {
        rejectedPreview = observedPreview
        wake?.cancel()
        wake = nil
        deadline = nil
        shown = nil
        current = nil
        shownAt = nil
        identity = nil
    }

    private func sample() {
        let now = clock.now()
        let candidate = SidebarPetMood.resolve(input, now: now)
        current = candidate
        if !input.observationAvailable || candidate.preemptsHold
            || (identity != nil && identity != input.identity && input.preview == observedPreview) {
            rejectedPreview = input.preview ?? observedPreview
            // A real event for this exact session halts the preview everywhere; switching subjects does not.
            if let rejectedPreview, let session = input.identity?.session,
               input.preview != nil || identity?.session == session {
                previewHalts.halt(rejectedPreview, session: session, now: now)
            }
        }
        if let playback = input.preview { observedPreview = playback }
        let preview = input.preview.flatMap { playback in
            input.identity.flatMap { identity in
                playback != rejectedPreview && !previewHalts.contains(playback, session: identity.session)
                    && input.observationAvailable && !candidate.preemptsHold
                    ? SidebarPetMood.preview(playback, now: now) : nil
            }
        }
        if let preview {
            shown = preview
            shownAt = now
            identity = input.identity
        } else if shown?.isPreview == true || shown == nil || identity != input.identity || candidate.preemptsHold
            || now >= (shownAt ?? now).addingTimeInterval(SidebarPetMood.minimumMoodHold) {
            if shown?.mood != candidate.mood || identity != input.identity || shownAt == nil {
                shownAt = now
            }
            shown = candidate
            identity = input.identity
        } else if shown?.mood == candidate.mood {
            // A new basis for the same art is current, not another minimum hold.
            shown = candidate
        }
        var next: Date?
        if preview != nil, let playback = input.preview {
            let step = SidebarMoodObservation.Playback.step
            let index = floor(now.timeIntervalSince(playback.startedAt) / step)
            next = playback.startedAt.addingTimeInterval((index + 1) * step)
        } else if shown?.mood != candidate.mood, let shownAt {
            next = shownAt.addingTimeInterval(SidebarPetMood.minimumMoodHold)
        }
        if preview == nil, input.observationAvailable, let sleepy = SidebarPetMood.sleepyDeadline(input), sleepy > now,
           SidebarPetMood.resolve(input, now: sleepy).mood == .sleepy {
            next = min(next ?? sleepy, sleepy)
        }
        guard next != deadline else { return }
        wake?.cancel()
        deadline = next
        guard let next else { wake = nil; return }
        let sleep = clock.sleepUntil
        wake = Task { [weak self] in
            do { try await sleep(next) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.deadline = nil
            self.sample()
        }
    }
}
