import Foundation
import Observation

/// Halts cosmetic previews when the observations that feed every pet report a real event, whether or not
/// any pet view is mounted. Pet views consume the resulting snapshot; a halted request never resumes.
struct SidebarMoodPreviewHalts {
    private struct Key: Hashable {
        let node: UUID
        let playback: SidebarMoodObservation.Playback
    }

    private struct Seen {
        let playback: SidebarMoodObservation.Playback
        let identity: SidebarPetMoodInput.Identity?
    }

    private var halted: Set<Key> = []
    private var seen: [UUID: Seen] = [:]

    /// A failed read or disconnect loses every observation; hiding or re-scoping the sidebar does not.
    mutating func observationLost(now: Date) {
        for (node, entry) in seen where entry.playback.isCurrent(at: now) {
            halted.insert(.init(node: node, playback: entry.playback))
        }
        seen = [:]
    }

    /// Removes halted playback. Current urgent facts halt immediately; observation loss or a changed
    /// binding halts only a playback already observed eligible for that exact node.
    mutating func applying(
        _ snapshot: SidebarOrchestrationSnapshot, tree: SidebarCopilotTree,
        availability: SidebarOrchestrationAvailability, now: Date
    ) -> SidebarOrchestrationSnapshot {
        // Entries end with their own fixed window, so both stay bounded by concurrent previews.
        halted = halted.filter { $0.playback.isCurrent(at: now) }
        let present = Dictionary(snapshot.nodes.map { ($0.id, $0.moodPreview) }, uniquingKeysWith: { first, _ in first })
        // A node missing from this projection (hidden or re-scoped sidebar) keeps its entry until expiry.
        seen = seen.filter { entry in
            entry.value.playback.isCurrent(at: now) && present[entry.key].map { $0 == entry.value.playback } ?? true
        }
        var result = snapshot
        result.nodes = snapshot.nodes.map { node in
            guard let playback = node.moodPreview else { return node }
            let key = Key(node: node.id, playback: playback)
            if !halted.contains(key) {
                let input = SidebarPetMoodInput.project(
                    session: nil, node: node, tree: tree, managed: snapshot, availability: availability, now: now)
                // The projection exposes attention, failure and death only from current exact observations.
                let urgent = SidebarPetMood.resolve(input, now: now).preemptsHold
                let lost = seen[node.id].map { input.preview != playback || input.identity != $0.identity } ?? false
                if urgent || lost {
                    halted.insert(key)
                    seen[node.id] = nil
                } else if input.preview == playback {
                    seen[node.id] = .init(playback: playback, identity: input.identity)
                }
            }
            guard halted.contains(key) else { return node }
            var updated = node
            updated.moodPreview = nil
            return updated
        }
        return result
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
    @ObservationIgnored private var previewOwner: SidebarPetMoodInput.Identity?

    init(clock: Clock = .continuous) { self.clock = clock }

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
        // The orchestration observer halts previews for every view; this keeps a mounted view from
        // replaying one between observations. Switching to another session is not a real event.
        let sameSubject = input.identity != nil && input.identity?.session == previewOwner?.session
        if input.preview != nil && candidate.preemptsHold {
            rejectedPreview = input.preview
        } else if sameSubject && (!input.observationAvailable || candidate.preemptsHold || input.identity != previewOwner) {
            rejectedPreview = observedPreview
        }
        if let playback = input.preview, let owner = input.identity {
            observedPreview = playback
            previewOwner = owner
        }
        let preview = input.preview.flatMap {
            $0 != rejectedPreview && input.identity != nil && input.observationAvailable && !candidate.preemptsHold
                ? SidebarPetMood.preview($0, now: now) : nil
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
