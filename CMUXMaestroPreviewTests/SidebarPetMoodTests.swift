import Foundation
import Observation
import Testing

@MainActor
struct SidebarPetMoodTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        var state: AgentWorkState = .idle
        var liveness: AgentProcessLiveness = .alive
        var available = true
        var facts = AgentPresentationInputs()
        var attention: [AgentAttention] = []
        var nodes: [SidebarCopilotNode] = []
        var activity: AgentActivity?
        var report: SidebarMoodObservation.Mood?
        var sequence: Int? = 1
        let sessionID = UUID()
        let workspace = UUID()
        let surface = UUID()
        var generation = 1
        let now: Date

        var input: SidebarPetMoodInput {
            var session = SidebarCopilotSession(
                id: sessionID, workspaceID: workspace, surfaceID: surface, liveness: liveness,
                state: state, model: nil, observedAt: now, nodes: nodes, childrenComplete: true,
                treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0)
            session.presentation = facts
            session.attention = attention
            session.activity = activity
            return .init(identity: .init(session: sessionID, workspace: workspace, surface: surface, generation: generation),
                         observationAvailable: available, session: session, selfReport: report, selfReportSequence: sequence)
        }

        mutating func add(_ condition: String) {
            switch condition {
            case "permission": attention.append(signal(.permission))
            case "question": attention.append(signal(.answer))
            case "gone": liveness = .dead
            case "unavailable": available = false
            case "sad": state = .failed
            case "startled": state = .cancelled; facts.abortReason = .userAbort
            case "confused": facts.modelTrouble = true
            case "proud": report = .happy
            case "celebrating": report = .celebrating
            case "compacting": facts.compactionActive = true
            case "delegating":
                var child = SidebarCopilotNode(id: "task", parentID: nil, depth: 0, kind: .subagent,
                                               name: "Synthetic task", state: .working, model: nil,
                                               ancestryUnresolved: false, hasChildren: false)
                child.observedParent = .session(.init(providerID: CopilotSnapshotAdapter.providerID,
                                                      sessionID: sessionID.uuidString))
                nodes.append(child)
            case "working": activity = .init(kind: .executing)
            case "thinking": facts.primaryTurnOpen = true
            case "sleepy":
                attention.removeAll { $0.kind == .turnFinished }
                attention.append(signal(.turnFinished, at: now.addingTimeInterval(-SidebarPetMood.sleepyAfter - 1)))
            case "content": facts.turnClean = true; attention.append(signal(.turnFinished))
            default: break
            }
        }

        func signal(_ kind: AgentAttentionKind, at date: Date? = nil) -> AgentAttention {
            .init(kind: kind, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: date ?? now)
        }
    }

    @Test(arguments: [
        ("idle", SidebarPetSheet.Mood.idle), ("thinking", .thinking), ("working", .working),
        ("delegating", .delegating), ("question", .question), ("permission", .needsPermission),
        ("confused", .confused), ("content", .content), ("startled", .startled), ("sad", .sad),
        ("compacting", .compacting), ("sleepy", .sleepy), ("gone", .gone),
        ("proud", .proud), ("celebrating", .celebrating)
    ])
    func everyMood(_ example: (String, SidebarPetSheet.Mood)) {
        var fixture = Fixture(now: epoch)
        fixture.add(example.0)
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == example.1)
    }

    @Test(arguments: [
        ("permission", "question", SidebarPetSheet.Mood.needsPermission),
        ("question", "gone", .question), ("gone", "unavailable", .gone),
        ("unavailable", "sad", .idle), ("sad", "startled", .sad),
        ("startled", "confused", .startled), ("confused", "proud", .confused),
        ("proud", "compacting", .proud), ("compacting", "delegating", .compacting),
        ("delegating", "working", .delegating), ("working", "thinking", .working),
        ("thinking", "sleepy", .thinking), ("sleepy", "content", .sleepy),
        ("content", "idle", .content), ("permission", "gone", .needsPermission)
    ])
    func adjacentPrecedence(_ pair: (String, String, SidebarPetSheet.Mood)) {
        var fixture = Fixture(now: epoch)
        fixture.add(pair.1)
        fixture.add(pair.0)
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == pair.2)
    }

    @Test func unknownInputsNeverInventCleanTurnsOrPlanning() {
        var fixture = Fixture(now: epoch)
        fixture.state = .working
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        fixture.attention = [fixture.signal(.turnFinished)]
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        fixture.facts.turnClean = false
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        fixture.state = .cancelled
        for reason in [nil, .userExit, .streamingError, .other] as [AgentPresentationInputs.AbortReason?] {
            fixture.facts.abortReason = reason
            fixture.report = .celebrating
            #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        }
    }

    @Test func troubleThresholdAndAllowlistDoNotRelabelFailure() {
        var fixture = Fixture(now: epoch)
        for category in [AgentPresentationInputs.ErrorCategory.quota, .authorization] {
            fixture.facts.errorCategory = category
            #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .confused)
        }
        for category in [nil, .execution, .query, .other] as [AgentPresentationInputs.ErrorCategory?] {
            fixture.facts.errorCategory = category
            #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        }
        fixture.facts.consecutiveToolFailures = SidebarPetMood.confusedToolFailureThreshold - 1
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        fixture.facts.consecutiveToolFailures = SidebarPetMood.confusedToolFailureThreshold
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .confused)
        fixture.state = .failed
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .sad)
    }

    @Test func onlyInternalTasksDelegateAndOnlyOutstandingTaskErrorsAreSad() {
        var fixture = Fixture(now: epoch)
        fixture.add("delegating")
        let task = fixture.nodes.removeFirst()
        var unrelated = task
        unrelated.observedParent = nil
        fixture.nodes = [unrelated]
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        var failed = SidebarCopilotNode(id: task.id, parentID: nil, depth: 0, kind: .subagent,
                                       name: task.name, state: .failed, model: nil,
                                       ancestryUnresolved: false, hasChildren: false)
        failed.observedParent = task.observedParent
        failed.attention = [fixture.signal(.error)]
        fixture.nodes = [failed]
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .sad)
        fixture.nodes[0].attention = []
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
    }

    @Test func selfReportsAreLabelledAndCannotDisplaceUrgentFacts() {
        for condition in ["permission", "question", "sad", "gone", "unavailable", "startled", "confused"] {
            var fixture = Fixture(now: epoch)
            fixture.add(condition)
            let derived = SidebarPetMood.resolve(fixture.input, now: epoch)
            for report in [SidebarMoodObservation.Mood.happy, .celebrating, .confused] {
                fixture.report = report
                #expect(SidebarPetMood.resolve(fixture.input, now: epoch) == derived)
            }
        }
        var fixture = Fixture(now: epoch)
        fixture.report = .happy
        let proud = SidebarPetMood.resolve(fixture.input, now: epoch)
        #expect(proud.description.contains("Self-reported: happy"))
        fixture.sequence = nil
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        fixture.sequence = 2
        fixture.report = .clear
        let idle = SidebarPetMood.resolve(fixture.input, now: epoch)
        #expect(idle.mood == .idle)
        let held = SidebarPetMoodDisplay.description(shown: proud, current: idle)
        #expect(held.contains("Shown:") && held.contains("Current:") && held.contains("Self-reported: happy"))
    }

    @Test func holdSkipsEndedMoodsAndDeadlineResamplesWithoutAnEvent() async {
        let clock = SidebarMoodTestClock(now: epoch)
        let display = SidebarPetMoodDisplay(clock: clock.clock)
        defer { display.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.add("thinking")
        display.update(fixture.input)
        clock.now = epoch.addingTimeInterval(1)
        fixture.facts.primaryTurnOpen = false
        fixture.add("content")
        display.update(fixture.input)
        await clock.registered()
        #expect(display.shown?.mood == .thinking)
        #expect(display.current?.mood == .content)
        let originalDeadline = display.deadline
        clock.now = epoch.addingTimeInterval(2)
        fixture.add("working")
        display.update(fixture.input)
        #expect(display.deadline == originalDeadline)
        await clock.advance(to: epoch.addingTimeInterval(SidebarPetMood.minimumMoodHold), observing: display)
        #expect(display.shown?.mood == .working)
        #expect(display.deadline == nil)
    }

    @Test func previewShowsEveryExpressionForFiveSecondsAndRestoresAtSeventyFive() async throws {
        let clock = SidebarMoodTestClock(now: epoch)
        let display = SidebarPetMoodDisplay(clock: clock.clock)
        defer { display.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.report = .happy
        var input = fixture.input
        input.preview = .init(sequence: 2, startedAt: epoch)
        let original = input
        let ordinary = SidebarPetMood.resolve(input, now: epoch)
        display.update(input)
        let expected: [SidebarPetSheet.Mood] = [
            .idle, .thinking, .working, .delegating, .question, .needsPermission, .confused,
            .content, .startled, .sad, .compacting, .sleepy, .gone, .proud, .celebrating,
        ]
        for (index, mood) in expected.enumerated() {
            await clock.registered()
            let shown = try #require(display.shown)
            #expect(shown.mood == mood && shown.isPreview && !shown.preemptsHold)
            #expect(display.current == ordinary)
            #expect(SidebarPetMoodDisplay.description(shown: shown, current: ordinary).contains("Cosmetic preview"))
            #expect(display.deadline == epoch.addingTimeInterval(Double(index + 1) * 5))
            clock.now = epoch.addingTimeInterval(Double(index + 1) * 5 - 0.001)
            display.update(input)
            #expect(display.shown?.mood == mood)
            await clock.advance(to: epoch.addingTimeInterval(Double(index + 1) * 5), observing: display)
        }
        #expect(display.shown == ordinary && display.current == ordinary)
        #expect(display.deadline == nil)
        #expect(input == original, "Preview cannot change lifecycle, attention, or the prior self-report")
        display.update(input)
        #expect(display.shown == ordinary, "An expired request cannot restart its timeline")
    }

    @Test(arguments: ["cancel", "permission", "question", "sad", "gone", "unavailable", "identity", "stop"])
    func previewIsImmediatelyCancelledOrPreemptedWithoutReplay(_ boundary: String) async {
        let clock = SidebarMoodTestClock(now: epoch)
        let display = SidebarPetMoodDisplay(clock: clock.clock)
        defer { display.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.report = .happy
        var input = fixture.input
        let preview = SidebarMoodObservation.Playback(sequence: 2, startedAt: epoch)
        input.preview = preview
        display.update(input)
        await clock.registered()
        clock.now = epoch.addingTimeInterval(1)
        if boundary == "cancel" {
            input.preview = nil
        } else if boundary == "stop" {
            display.stop()
        } else if boundary == "identity" {
            fixture.generation = 2
            input = fixture.input
            input.preview = preview
        } else {
            fixture.add(boundary)
            input = fixture.input
            input.preview = boundary == "unavailable" ? nil : preview
        }
        display.update(input)
        #expect(display.shown?.isPreview == false)
        #expect(display.shown == display.current)
        #expect(display.deadline == nil)
        if boundary != "cancel" {
            clock.now = epoch.addingTimeInterval(10)
            var restored = Fixture(now: epoch).input
            restored.identity = input.identity
            restored.preview = preview
            display.update(restored)
            #expect(display.shown?.isPreview == false)
        }
    }

    @Test(arguments: ["permission", "question", "sad", "gone", "unavailable", "identity"])
    func previewHaltedByRealEventDoesNotResumeInANewlyMountedView(_ boundary: String) async {
        let clock = SidebarMoodTestClock(now: epoch)
        let halts = SidebarMoodPreviewHalts()
        let footer = SidebarPetMoodDisplay(clock: clock.clock, previewHalts: halts)
        defer { footer.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.report = .happy
        let preview = SidebarMoodObservation.Playback(sequence: 2, startedAt: epoch)
        var input = fixture.input
        input.preview = preview
        footer.update(input)
        await clock.registered()
        #expect(footer.shown?.isPreview == true)
        clock.now = epoch.addingTimeInterval(10)
        if boundary == "identity" {
            fixture.generation = 2
        } else {
            fixture.add(boundary)
        }
        input = fixture.input
        input.preview = boundary == "unavailable" ? nil : preview
        footer.update(input)
        #expect(footer.shown?.isPreview == false)

        // The urgent fact is gone, but the shared reader still offers the same playback inside its window.
        clock.now = epoch.addingTimeInterval(20)
        var restored = Fixture(now: epoch).input
        restored.identity = input.identity
        restored.preview = preview
        footer.update(restored)
        let hoverClock = SidebarMoodTestClock(now: clock.now)
        let hover = SidebarPetMoodDisplay(clock: hoverClock.clock, previewHalts: halts)
        defer { hover.stop(); hoverClock.finish() }
        hover.update(restored)
        #expect(footer.shown?.isPreview == false)
        #expect(hover.shown?.isPreview == false)
        #expect(hover.shown == hover.current)

        let unrelatedClock = SidebarMoodTestClock(now: clock.now)
        let unrelated = SidebarPetMoodDisplay(clock: unrelatedClock.clock, previewHalts: SidebarMoodPreviewHalts())
        defer { unrelated.stop(); unrelatedClock.finish() }
        unrelated.update(restored)
        await unrelatedClock.registered()
        #expect(unrelated.shown?.isPreview == true, "Only the recorded halt suppresses the playback")
        var requested = restored
        requested.preview = .init(sequence: 3, startedAt: clock.now)
        let nextClock = SidebarMoodTestClock(now: clock.now)
        let next = SidebarPetMoodDisplay(clock: nextClock.clock, previewHalts: halts)
        defer { next.stop(); nextClock.finish() }
        next.update(requested)
        await nextClock.registered()
        #expect(next.shown?.isPreview == true, "A later explicit request is a new preview instance")
    }

    @Test func sameMoodDoesNotRearmAndNewShownMoodGetsItsOwnHold() async {
        let clock = SidebarMoodTestClock(now: epoch)
        let display = SidebarPetMoodDisplay(clock: clock.clock)
        defer { display.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.add("thinking")
        display.update(fixture.input)
        clock.now = epoch.addingTimeInterval(2)
        display.update(fixture.input)
        fixture.add("working")
        display.update(fixture.input)
        await clock.registered()
        #expect(display.deadline == epoch.addingTimeInterval(SidebarPetMood.minimumMoodHold))
        await clock.advance(to: epoch.addingTimeInterval(3), observing: display)
        fixture.activity = nil
        display.update(fixture.input)
        await clock.registered()
        #expect(display.shown?.mood == .working)
        #expect(display.deadline == epoch.addingTimeInterval(6))
        await clock.advance(to: epoch.addingTimeInterval(6), observing: display)
        #expect(display.shown?.mood == .thinking)
    }

    @Test(arguments: ["question", "permission", "sad", "gone"])
    func urgentMoodsPreempt(_ urgent: String) {
        let clock = SidebarMoodTestClock(now: epoch)
        let display = SidebarPetMoodDisplay(clock: clock.clock)
        defer { display.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.add("thinking")
        display.update(fixture.input)
        clock.now = epoch.addingTimeInterval(1)
        fixture.add(urgent)
        display.update(fixture.input)
        #expect(display.shown == display.current)
        #expect(display.shown?.preemptsHold == true)
    }

    @Test(arguments: ["session", "workspace", "surface", "node", "run", "generation", "process"])
    func exactIdentityAndGenerationResetHold(_ field: String) {
        let clock = SidebarMoodTestClock(now: epoch)
        let display = SidebarPetMoodDisplay(clock: clock.clock)
        defer { display.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.add("thinking")
        display.update(fixture.input)
        clock.now = epoch.addingTimeInterval(1)
        fixture.add("working")
        var changed = fixture.input
        changed.identity = .init(
            session: field == "session" ? UUID() : fixture.sessionID,
            workspace: field == "workspace" ? UUID() : fixture.workspace,
            surface: field == "surface" ? UUID() : fixture.surface,
            node: field == "node" ? UUID() : nil,
            run: field == "run" ? UUID() : nil,
            generation: field == "generation" ? 2 : 1,
            process: field == "process" ? .init(pid: 100, startSeconds: 100, startMicroseconds: 1) : nil)
        display.update(changed)
        #expect(display.shown?.mood == .working)
        let other = Fixture(now: epoch)
        display.update(other.input)
        #expect(display.shown?.mood == .idle)
    }

    @Test func outstandingInternalFailureBeatsUserAbortButAcknowledgementClearsIt() {
        var fixture = Fixture(now: epoch)
        fixture.add("startled")
        var task = SidebarCopilotNode(id: "failed", parentID: nil, depth: 0, kind: .subagent,
                                       name: "Synthetic task", state: .failed, model: nil,
                                       ancestryUnresolved: false, hasChildren: false)
        task.observedParent = .session(.init(providerID: CopilotSnapshotAdapter.providerID,
                                            sessionID: fixture.sessionID.uuidString))
        task.attention = [fixture.signal(.error)]
        fixture.nodes = [task]
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .sad)
        fixture.nodes[0].attention = []
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .startled)
    }

    @Test func sleepyRequiresTimestampAndNeverOverridesCurrentWork() {
        var fixture = Fixture(now: epoch)
        fixture.attention = [.init(kind: .turnFinished, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: nil)]
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch.addingTimeInterval(1000)).mood == .idle)
        fixture.attention = [fixture.signal(.turnFinished, at: epoch.addingTimeInterval(100))]
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .idle)
        fixture.add("sleepy")
        fixture.add("working")
        #expect(SidebarPetMood.resolve(fixture.input, now: epoch).mood == .working)
    }

    @Test func sleepyDeadlineAndAcknowledgementArePresentationOnly() async throws {
        let clock = SidebarMoodTestClock(now: epoch)
        let display = SidebarPetMoodDisplay(clock: clock.clock)
        defer { display.stop(); clock.finish() }
        var fixture = Fixture(now: epoch)
        fixture.add("content")
        let original = fixture.input
        display.update(original)
        await clock.registered()
        #expect(display.shown?.mood == .content)
        let boundary = epoch.addingTimeInterval(SidebarPetMood.sleepyAfter)
        #expect(SidebarPetMood.resolve(original, now: boundary).mood == .content)
        let deadline = try #require(SidebarPetMood.sleepyDeadline(original))
        #expect(deadline > boundary)
        await clock.advance(to: deadline, observing: display)
        #expect(display.shown?.mood == .sleepy)
        #expect(original.session?.attention.count == 1)
        var acknowledged = SidebarAttentionSettings()
        acknowledged.acknowledged.insert(.init(sessionID: fixture.sessionID, ownerID: nil,
                                              evidence: fixture.attention[0].evidence))
        #expect(acknowledged.isValid)
        fixture.attention = fixture.attention.filter {
            !acknowledged.contains($0, sessionID: fixture.sessionID, ownerID: nil)
        }
        display.update(fixture.input)
        await clock.registered()
        #expect(display.current?.mood == .idle)
        await clock.advance(to: clock.now.addingTimeInterval(SidebarPetMood.minimumMoodHold), observing: display)
        #expect(display.shown?.mood == .idle)
        #expect(display.deadline == nil)
    }

    @Test func projectionFencesReportsAndRetainsGenerationWithoutSessionEvidence() throws {
        var fixture = Fixture(now: epoch)
        fixture.add("thinking")
        let session = try #require(fixture.input.session)
        var tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: epoch)
        var node = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Synthetic",
            workspaceId: session.workspaceID, surfaceId: session.surfaceID, generation: 1,
            phase: "turn-running", availability: "verified", copilotSessionId: session.id,
            executionMode: .interactive, createdAt: epoch, updatedAt: epoch)
        node.selfReportedMood = .happy
        node.selfReportedMoodSequence = 1
        node.moodPreview = .init(sequence: 2, startedAt: epoch)
        var managed = SidebarOrchestrationSnapshot(version: 1, generatedAt: epoch, complete: true, omittedCount: 0, nodes: [node])
        func project() -> SidebarPetMoodInput {
            .project(session: session, tree: tree, managed: managed, availability: .ready, now: epoch)
        }
        #expect(SidebarPetMood.resolve(project(), now: epoch).mood == .proud)
        #expect(project().preview == node.moodPreview)
        managed.moodsUnavailable = true
        #expect(project().preview == nil)
        #expect(SidebarPetMood.resolve(project(), now: epoch).mood == .thinking)
        managed.moodsUnavailable = false
        managed.nodes.append(node)
        #expect(SidebarPetMood.resolve(project(), now: epoch).mood == .thinking)
        managed.nodes = [node]
        tree.availability = .unavailable
        let lost = project()
        #expect(lost.identity?.generation == 1)
        #expect(lost.selfReport == nil)
        #expect(lost.preview == nil)
        #expect(SidebarPetMood.resolve(lost, now: epoch).mood == .idle)
    }
}

@MainActor
private final class SidebarMoodTestClock {
    var now: Date
    private var sleeper: CheckedContinuation<Void, Error>?
    private var registration: CheckedContinuation<Void, Never>?
    init(now: Date) { self.now = now }

    var clock: SidebarPetMoodDisplay.Clock {
        .init(now: { self.now }, sleepUntil: { _ in
            try await withCheckedThrowingContinuation { continuation in
                self.sleeper = continuation
                self.registration?.resume()
                self.registration = nil
            }
        })
    }

    func registered() async {
        if sleeper != nil { return }
        await withCheckedContinuation { registration = $0 }
    }

    func advance(to date: Date, observing display: SidebarPetMoodDisplay) async {
        now = date
        await withCheckedContinuation { changed in
            withObservationTracking { _ = display.shown } onChange: { changed.resume() }
            let pending = sleeper
            sleeper = nil
            pending?.resume()
        }
    }

    func finish() {
        sleeper?.resume(throwing: CancellationError())
        sleeper = nil
    }
}
