import Foundation
import Observation

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

    init(clock: Clock = .continuous) { self.clock = clock }

    static func description(shown: SidebarPetMood, current: SidebarPetMood) -> String {
        shown.mood == current.mood ? current.description
            : String(localized: "mood.held", defaultValue: "Shown: \(shown.description). Current: \(current.description)")
    }

    func update(_ input: SidebarPetMoodInput) {
        self.input = input
        sample()
    }

    func stop() {
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
        if shown == nil || identity != input.identity || candidate.preemptsHold
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
        if shown?.mood != candidate.mood, let shownAt {
            next = shownAt.addingTimeInterval(SidebarPetMood.minimumMoodHold)
        }
        if input.observationAvailable, let sleepy = SidebarPetMood.sleepyDeadline(input), sleepy > now,
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
