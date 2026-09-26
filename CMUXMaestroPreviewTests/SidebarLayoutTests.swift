import Foundation
import Observation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarLayoutTests {
    private let fixtures = SidebarTreeFixtures()

    @Test(arguments: [0, 1, 2])
    func countCaptionsUseSingularOnlyForOne(_ count: Int) {
        let session = count == 1 ? "session" : "sessions"
        let task = count == 1 ? "task" : "tasks"
        let verb = count == 1 ? "needs" : "need"
        let row = count == 1 ? "row" : "rows"
        #expect(SidebarCountText.copilotSessions(count) == "\(count) Copilot \(session)")
        #expect(SidebarCountText.runningChildren(count) == "\(count) child \(task) running")
        #expect(SidebarCountText.runningChildren(count, known: true) == "\(count) known child \(task) running")
        #expect(SidebarCountText.attention(count) == "\(count) \(verb) attention")
        #expect(SidebarCountText.attentionRows(count) == "\(count) session/child \(row) \(verb) attention")
        var summary = SidebarBranchSummary(nodes: [])
        summary.attention = count
        #expect(summary.lines[0] == "0 known running · 0 blocked · \(count) \(verb) attention")
    }

    @Test func ciPublishesOnlySyntheticOffscreenPNGs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        #expect(workflow.contains("uses: actions/upload-artifact@v4"))
        #expect(workflow.contains("name: sidebar-layout-offscreen"))
        #expect(workflow.contains("path: .build/layout-validation/offscreen/*.png"))
        #expect(workflow.contains("include-hidden-files: true"))
        #expect(workflow.contains("if-no-files-found: error"))
        let source = try String(
            contentsOf: root.appendingPathComponent("CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift"), encoding: .utf8
        )
        #expect(source.contains("#expect(!window.isVisible)"))
        #expect(source.contains(".accessibilityHighContrastAqua"))
        #expect(source.contains(".accessibilityHighContrastDarkAqua"))
        #expect(source.contains("/synthetic/workspaces/"))
        #expect(!source.contains("CGWindowListCreateImage"))
        #expect(!source.contains("ScreenCaptureKit"))
        #expect(!source.contains("orderFront("))
    }

    @Test func defaultsAreOriginalDensityAndExpandedWithoutWritingOnRead() throws {
        try withFile { file in
            let store = SidebarLayoutStore(file: file)
            #expect(store.value.settings.density == .compact)
            #expect(store.value.settings.collapsed.isEmpty)
            #expect(store.value.notice == nil)
            for _ in 0..<100 {
                #expect(store.value.settings.isExpanded(.workspace(fixtures.workspaceA)))
                #expect(store.value.settings.isExpanded(.child("one", sessionID: fixtures.sessionID)))
                _ = tree().sessions.first?.childRows(layout: store.value.settings)
                store.refresh()
            }
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func everyIdentityAndDensityRoundTripAcrossStoreReconstruction() throws {
        try withFile { file in
            let store = SidebarLayoutStore(file: file)
            let keys: [SidebarExpansionID] = [
                .workspace(fixtures.workspaceA), .surface(fixtures.surfaceA), .session(fixtures.sessionID),
                .child("root", sessionID: fixtures.sessionID)
            ]
            store.apply(.density(.comfortable))
            for key in keys { store.apply(.expansion(key, false)) }
            let reloaded = SidebarLayoutStore(file: file)
            #expect(reloaded.value == store.value)
            #expect(reloaded.value.settings.density == .comfortable)
            #expect(reloaded.value.settings.collapsed == keys)
            for key in keys { reloaded.apply(.expansion(key, true)) }
            reloaded.apply(.density(.compact))
            #expect(reloaded.value.settings.densityOverride == nil)
            #expect(reloaded.value.settings.collapsed.isEmpty)
            #expect(store.value == reloaded.value)
            let data = try Data(contentsOf: file.url)
            #expect(!String(decoding: data, as: UTF8.self).contains("Same name"))
            #expect(!String(decoding: data, as: UTF8.self).contains("/repo"))
            #expect(file.read().settings.isValid)
        }
    }

    @Test func existingLayoutBytesAndMissingFileDefaultsArePreservedBySharedAdapters() throws {
        try withFile { file in
            let missing = file.read()
            #expect(missing == .init())
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
            let bytes = Data("""
            {"version":1,"densityOverride":"comfortable","collapsed":[{"kind":"workspace","id":"\(fixtures.workspaceA.uuidString)"}]}
            """.utf8)
            try write(bytes, to: file)
            let stamp = try file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let first = SidebarLayoutStore(file: file)
            let second = SidebarLayoutStore(file: file)
            first.refresh()
            second.refresh()
            #expect(first.value.settings.density == .comfortable)
            #expect(first.value.settings.collapsed == [.workspace(fixtures.workspaceA)])
            #expect(first.value == second.value)
            #expect(try Data(contentsOf: file.url) == bytes)
            #expect(try file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
        }
    }

    @Test func duplicateLabelsAndReusedChildIDsDoNotShareExpansionAcrossSessionsOrProviders() {
        var settings = SidebarLayoutSettings()
        settings.setExpanded(false, for: .child("root", sessionID: fixtures.sessionID))
        let first = tree().sessions[0]
        #expect(first.nodes.allSatisfy { $0.name == "Same name" })
        #expect(first.childRows(layout: settings).map(\.id) == ["root", "other"])
        #expect(!settings.isExpanded(.child("root", sessionID: fixtures.sessionID)))
        #expect(settings.isExpanded(.child("other", sessionID: fixtures.sessionID)))
        #expect(settings.isExpanded(.child("root", sessionID: fixtures.otherSessionID)))
        #expect(settings.isExpanded(.child("root", sessionID: fixtures.sessionID, provider: "other")))
        #expect(settings.isExpanded(.session(fixtures.sessionID)))
        settings.setExpanded(false, for: .session(fixtures.sessionID))
        #expect(settings.isExpanded(.session(fixtures.otherSessionID)))
        #expect(settings.isExpanded(.session(fixtures.sessionID, provider: "other")))
        #expect(settings.isExpanded(.workspace(fixtures.sessionID)))
        // Same identity returning later intentionally retains its layout, not a lifecycle outcome.
        #expect(tree().sessions[0].childRows(layout: settings).map(\.id) == ["root", "other"])
    }

    @Test func workspaceAndSurfaceMovesKeepStableExpansionWithoutPruningOtherWindows() throws {
        try withFile { file in
            let keys: [SidebarExpansionID] = [
                .workspace(fixtures.workspaceA), .surface(fixtures.surfaceA),
                .session(fixtures.sessionID), .child("root", sessionID: fixtures.sessionID)
            ]
            let store = SidebarLayoutStore(file: file)
            for key in keys { store.apply(.expansion(key, false)) }
            let moved = tree(moved: true).sessions[0]
            #expect(moved.workspaceID == fixtures.workspaceB)
            #expect(moved.surfaceID == fixtures.surfaceA)
            #expect(!store.value.settings.isExpanded(.surface(moved.surfaceID)))
            #expect(!store.value.settings.isExpanded(.session(moved.id)))
            #expect(moved.childRows(layout: store.value.settings).map(\.id) == ["root", "other"])
            // Empty/current-window projections never mutate saved off-window keys.
            _ = SidebarCopilotTree.waiting.sessions
            store.refresh()
            #expect(store.value.settings.collapsed == keys)
            #expect(store.value.settings.isExpanded(.workspace(fixtures.workspaceB)))
            #expect(store.value.settings.isExpanded(.surface(UUID())))
        }
    }

    @Test func collapsedAncestorsKeepRunningBlockingAndAttentionSummaryWithoutChangingProjection() throws {
        let original = tree()
        let session = try #require(original.sessions.first)
        var layout = SidebarLayoutSettings()
        layout.setExpanded(false, for: .child("root", sessionID: session.id))
        let rows = session.childRows(layout: layout)
        let summary = try #require(rows.first?.collapsedSummary)
        #expect(summary.running == 1)
        #expect(summary.blocked == 1)
        #expect(summary.attention == 2)
        #expect(summary.lines[0] == "1 known running · 1 blocked · 2 need attention")
        #expect(rows.map(\.id) == ["root", "other"])
        for key in [
            SidebarExpansionID.workspace(session.workspaceID), .surface(session.surfaceID), .session(session.id)
        ] {
            layout.setExpanded(false, for: key)
            let ancestorSummary = SidebarBranchSummary(sessions: [session])
            #expect(ancestorSummary.running == 2) // Main turn and child are separate owners.
            #expect(ancestorSummary.blocked == 1)
            #expect(ancestorSummary.attention == 2)
        }
        #expect(original.sessions[0].nodes.count == 5)
        #expect(original.knownRunningChildren == 1)
        #expect(original.attentionOwnerCount == 2)
        #expect(original.acknowledgeableOutcomes.count == 1)
        #expect(original.dismissibleOutcomes.count == 1)
        #expect(original.hiddenHistoryCount == 0)
        #expect(original.retainedHistoryCount == 2)
    }

    @Test func partialAndOmittedWorkNeverClaimsCompleteCollapsedCounts() {
        let session = tree(partial: true).sessions[0]
        let summary = SidebarBranchSummary(sessions: [session])
        #expect(summary.incomplete)
        #expect(summary.lines.contains("Counts may be incomplete"))
        var layout = SidebarLayoutSettings()
        layout.setExpanded(false, for: .child("root", sessionID: session.id))
        #expect(session.childRows(layout: layout)[0].collapsedSummary?.incomplete == true)
        var capped = summary
        capped.omittedActive = 2
        #expect(capped.lines.contains("2 additional working/blocked tasks exceed display limits"))
        let unknown = SidebarCopilotNode(id: "unknown", parentID: nil, depth: 0, kind: .unknown,
                                        name: "Unknown", state: .unknown, model: nil,
                                        ancestryUnresolved: true, hasChildren: false, attentionDegraded: true)
        let unknownSummary = SidebarBranchSummary(nodes: [unknown])
        #expect(unknownSummary.incomplete)
        #expect(unknownSummary.attention == 1)
    }

    @Test func twoIndependentViewsMergeActionsImmediatelyAndObserveWithoutGetterWrites() throws {
        try withFile { file in
            let first = SidebarLayoutStore(file: file)
            let second = SidebarLayoutStore(file: file)
            first.apply(.expansion(.workspace(fixtures.workspaceA), false))
            #expect(first.value == second.value)
            second.apply(.expansion(.workspace(fixtures.workspaceB), false))
            first.apply(.density(.comfortable))
            #expect(first.value == second.value)
            #expect(first.value.settings.collapsed.count == 2)
            let before = try Data(contentsOf: file.url)
            let stamp = try file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            var invalidations = 0
            withObservationTracking {
                _ = first.value
            } onChange: {
                MainActor.assumeIsolated { invalidations += 1 }
            }
            for _ in 0..<100 {
                _ = first.value.settings.isExpanded(.workspace(fixtures.workspaceA))
                _ = tree().sessions[0].childRows(layout: first.value.settings)
            }
            #expect(invalidations == 0)
            #expect(try Data(contentsOf: file.url) == before)
            #expect(try file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
            second.apply(.expansion(.workspace(fixtures.workspaceA), true))
            #expect(invalidations == 1)
            #expect(first.value.settings.collapsed == [.workspace(fixtures.workspaceB)])
        }
    }

    @Test func coordinatedConcurrentWritersDoNotOverwriteUnrelatedKeys() async throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let keys = (0..<32).map { _ in SidebarExpansionID.workspace(UUID()) }
        // Non-main-actor clients emulate independent extension view processes.
        let results = await withTaskGroup(of: SidebarLayoutRead.self, returning: [SidebarLayoutRead].self) { group in
            for key in keys {
                group.addTask { file.apply(.expansion(key, false)) }
            }
            group.addTask { file.apply(.density(.comfortable)) }
            var results: [SidebarLayoutRead] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.allSatisfy { $0.notice == nil })
        #expect(Set(file.read().settings.collapsed) == Set(keys))
        #expect(file.read().settings.density == .comfortable)
        let store = SidebarLayoutStore(file: file)
        _ = file.apply(.expansion(keys[0], true))
        store.refresh()
        #expect(store.value.settings.collapsed.count == keys.count - 1)
    }

    @Test func filePresentationRefreshesAnIdleViewWithoutAProviderSnapshot() async throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        _ = file.apply(.density(.compact))
        var store: SidebarLayoutStore? = SidebarLayoutStore(file: file)
        let released = WeakLayoutStore(store)
        let key = SidebarExpansionID.surface(fixtures.surfaceA)
        // Bypasses the local store registry, as an external writer would.
        #expect(file.apply(.expansion(key, false)).notice == nil)
        await sidebarEventually { store?.value.settings.isExpanded(key) == false }
        #expect(file.apply(.density(.comfortable)).notice == nil)
        await sidebarEventually { store?.value.settings.density == .comfortable }
        store = nil
        await sidebarEventually { released.value == nil }
    }

    @MainActor
    private final class WeakLayoutStore {
        weak var value: SidebarLayoutStore?
        init(_ value: SidebarLayoutStore?) { self.value = value }
    }

    @Test func boundedStoreEvictsOldestCollapseOnlyToExpandedDefaults() throws {
        try withFile { file in
            var settings = SidebarLayoutSettings()
            let oldest = SidebarExpansionID.child("root", sessionID: fixtures.sessionID)
            settings.setExpanded(false, for: oldest)
            for _ in 1..<SidebarLayoutSettings.maximumOverrides {
                settings.setExpanded(false, for: .workspace(UUID()))
            }
            try write(try JSONEncoder().encode(settings), to: file)
            let newKey = SidebarExpansionID.surface(UUID())
            let result = file.apply(.expansion(newKey, false))
            #expect(result.notice == nil)
            #expect(result.settings.collapsed.count == SidebarLayoutSettings.maximumOverrides)
            #expect(result.settings.isExpanded(oldest))
            #expect(!result.settings.isExpanded(newKey))
            #expect(tree().sessions[0].childRows(layout: result.settings).count == 5)
            #expect(try Data(contentsOf: file.url).count <= SidebarLayoutSettings.maximumStoredBytes)
            let expanded = file.apply(.expandAll)
            #expect(expanded.settings.collapsed.isEmpty)
        }
    }

    @Test func byteBoundAndInvalidIdentitiesCannotSilentlyHideWork() throws {
        try withFile { file in
            let badIDs: [SidebarExpansionID] = [
                .child("", sessionID: fixtures.sessionID),
                .child(String(repeating: "a", count: 513), sessionID: fixtures.sessionID),
                .child("line\nbreak", sessionID: fixtures.sessionID),
                .session(fixtures.sessionID, provider: "not/a/provider"),
                .init(kind: .workspace, id: fixtures.workspaceA, childID: "invalid")
            ]
            for id in badIDs {
                #expect(!id.isValid)
                #expect(file.apply(.expansion(id, false)).settings.collapsed.isEmpty)
            }
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
            var large = SidebarLayoutSettings()
            for _ in 0..<SidebarLayoutSettings.maximumOverrides {
                large.setExpanded(false, for: .child(String(repeating: "x", count: 512), sessionID: UUID()))
            }
            // Feed a just-under-byte-budget valid store, then force byte-budget eviction.
            while try JSONEncoder().encode(large).count > SidebarLayoutSettings.maximumStoredBytes {
                large.setExpanded(true, for: large.collapsed[0])
            }
            let oldest = try #require(large.collapsed.first)
            try write(try JSONEncoder().encode(large), to: file)
            let next = file.apply(.expansion(.child(String(repeating: "y", count: 512), sessionID: UUID()), false))
            #expect(next.notice == nil)
            #expect(next.settings.isExpanded(oldest))
            #expect(try Data(contentsOf: file.url).count <= SidebarLayoutSettings.maximumStoredBytes)
        }
    }

    @Test func corruptionUnknownSchemaAndInvalidPrimitiveRecordsRequireExplicitRecovery() async throws {
        for data in [
            Data("not JSON".utf8),
            Data(#"{"version":99,"collapsed":[]}"#.utf8),
            Data(#"{"version":1,"densityOverride":"dense","collapsed":[]}"#.utf8),
            Data(#"{"version":1,"collapsed":[{"kind":"workspace","id":"not-a-uuid"}]}"#.utf8),
            Data(repeating: 0, count: SidebarLayoutSettings.maximumStoredBytes + 1)
        ] {
            try withFile { file in
                try write(data, to: file)
                let store = SidebarLayoutStore(file: file)
                #expect(store.value.notice != nil)
                #expect(store.value.settings == SidebarLayoutSettings())
                #expect(tree().sessions[0].childRows(layout: store.value.settings).count == 5)
                store.apply(.density(.comfortable))
                store.apply(.expansion(.session(fixtures.sessionID), false))
                #expect(try Data(contentsOf: file.url) == data)
                #expect(store.value.notice != nil)
                store.apply(.reset)
                #expect(store.value.notice == nil)
                #expect(file.read().settings == SidebarLayoutSettings())
            }
            await Task.yield()
        }
    }

    @Test func duplicateAndOverflowRecordsFailOpenAndUnwritableStorageReportsRecovery() throws {
        let key = SidebarExpansionID.workspace(fixtures.workspaceA)
        let encoded = try JSONEncoder().encode(key)
        let object = try JSONSerialization.jsonObject(with: encoded)
        for count in [2, SidebarLayoutSettings.maximumOverrides + 1] {
            try withFile { file in
                let data = try JSONSerialization.data(withJSONObject: [
                    "version": 1, "collapsed": Array(repeating: object, count: count)
                ])
                try write(data, to: file)
                #expect(file.read().notice != nil)
                #expect(file.read().settings.collapsed.isEmpty)
            }
        }
        try withFile { file in
            // A directory at the record path is unreadable and cannot be atomically replaced.
            try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
            #expect(file.read().notice != nil)
            let reset = file.apply(.reset)
            #expect(reset.notice == SidebarLayoutFile.saveNotice)
            #expect(reset.settings.collapsed.isEmpty)
        }
    }

    @Test func layoutActionsDoNotChangeHistoryAttentionModeOrNavigation() throws {
        try withFile { file in
            let suite = "SidebarLayoutTests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let prefs = SidebarPreferences(
                defaults: defaults,
                historyFile: file.url.deletingLastPathComponent().appendingPathComponent("history.json"),
                attentionFile: file.url.deletingLastPathComponent().appendingPathComponent("attention.json"),
                layoutStore: .init(file: file)
            )
            let model = SidebarConnectionModel()
            model.showDegraded(message: "Synthetic disconnect")
            prefs.selectedMode = .taskboard
            prefs.setRetention(.never)
            prefs.acknowledge(tree().acknowledgeableOutcomes, in: tree())
            prefs.dismiss(tree().dismissibleOutcomes)
            let history = prefs.history
            let attention = prefs.attention
            let connection = model.state
            let navigation = model.navigation.status
            prefs.setDensity(.comfortable)
            prefs.setExpanded(false, for: .workspace(fixtures.workspaceA))
            prefs.expandAll()
            prefs.resetLayout()
            #expect(prefs.history == history)
            #expect(prefs.attention == attention)
            #expect(prefs.selectedMode == .taskboard)
            #expect(model.state == connection)
            #expect(model.navigation.status == navigation)
            #expect(defaults.string(forKey: "sidebar.selectedMode") == "taskboard")
        }
    }

    @Test func separateProcessesMergeLayoutActionsAndObserveLazyCreationWithoutChangingOtherStores() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let layoutFile = fixture.root.appendingPathComponent("uncreated/nested/layout.json")
        let preferences = fixture.preferences(layoutFile: layoutFile)
        preferences.selectedMode = .taskboard
        preferences.setRetention(.never)
        let attention = PreferenceAttentionFixture()
        preferences.acknowledge([attention.key("a")], in: attention.tree())
        let historyBytes = try Data(contentsOf: fixture.historyFile)
        let attentionBytes = try Data(contentsOf: fixture.attentionFile)
        let a = try PreferenceTestChild(fixture, layoutFile: layoutFile)
        let b = try PreferenceTestChild(fixture, layoutFile: layoutFile)
        defer { a.stop(); b.stop() }
        #expect(try await a.line() == "ready")
        #expect(try await b.line() == "ready")
        #expect(!FileManager.default.fileExists(atPath: layoutFile.deletingLastPathComponent().path))
        var invalidations = 0
        withObservationTracking {
            _ = preferences.layout
        } onChange: {
            MainActor.assumeIsolated { invalidations += 1 }
        }
        try a.send("hold-layout \(fixtures.workspaceA.uuidString)")
        #expect(try await a.line() == "locked")
        try b.send("collapse \(fixtures.workspaceB.uuidString)")
        #expect(try await b.line() == "applying")
        try a.send("continue")
        #expect(try await a.line() == "done")
        #expect(try await b.line() == "done")
        try await layoutEventually { preferences.layout.collapsed.count == 2 }
        #expect(Set(preferences.layout.collapsed) == [.workspace(fixtures.workspaceA), .workspace(fixtures.workspaceB)])
        #expect(invalidations == 1)
        try a.send("expect-layout 2 compact")
        #expect(try await a.line() == "done")
        try a.send("density comfortable")
        #expect(try await a.line() == "done")
        try await layoutEventually { preferences.layout.density == .comfortable }
        #expect(preferences.layout.collapsed.count == 2)

        preferences.expandAll()
        try a.send("expect-layout 0 comfortable")
        try b.send("expect-layout 0 comfortable")
        #expect(try await a.line() == "done")
        #expect(try await b.line() == "done")
        try b.send("collapse \(fixtures.workspaceB.uuidString)")
        #expect(try await b.line() == "applying")
        #expect(try await b.line() == "done")
        try a.send("reset-layout")
        #expect(try await a.line() == "done")
        try await layoutEventually { preferences.layout == .init() }
        try b.send("expect-layout 0 compact")
        #expect(try await b.line() == "done")
        preferences.setExpanded(false, for: .workspace(fixtures.workspaceA))
        try a.send("expect-layout 1 compact")
        #expect(try await a.line() == "done")
        #expect(preferences.layout.collapsed == [.workspace(fixtures.workspaceA)])
        #expect(try Data(contentsOf: fixture.historyFile) == historyBytes)
        #expect(try Data(contentsOf: fixture.attentionFile) == attentionBytes)
        #expect(preferences.selectedMode == .taskboard)
        let layoutBytes = try Data(contentsOf: layoutFile)
        preferences.resetHistory()
        preferences.resetAcknowledgements()
        #expect(try Data(contentsOf: layoutFile) == layoutBytes)
    }

    private func layoutEventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Existing layout observation did not converge from file presentation", sourceLocation: sourceLocation)
    }

    @Test func narrowLayoutValuesKeepControlsAndStatusRoomWithoutDecorativeAnimation() throws {
        #expect(SidebarDensity.allCases.map(\.title) == ["Compact", "Comfortable"])
        #expect(SidebarDensity.compact.spacing(10) == 10)
        #expect(SidebarDensity.comfortable.spacing(10) == 13.5)
        for density in SidebarDensity.allCases {
            for width in [160.0, 200, 240, 320, 480] {
                let indent = density.indentation(depth: 12, unresolved: true, width: width)
                #expect(indent <= width * 0.15)
                #expect(width - indent - density.controlSize >= width * 0.65)
                #expect(density.controlSize >= 20)
            }
            #expect(density.stacksActions(width: 200))
            #expect(!density.stacksActions(width: 480))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarView.swift"), encoding: .utf8)
        #expect(view.contains("sidebar-density"))
        #expect(view.contains("sidebar-layout-notice"))
        #expect(view.contains(".accessibilityValue(expanded ? \"Expanded\" : \"Collapsed\")"))
        #expect(view.contains(".accessibilityHint(expanded"))
        #expect(view.contains(".accessibilityLabel(\"\\(label): \\(displayText)\")"))
        #expect(view.contains(".help(displayText)"))
        #expect(!view.contains("@State private var expanded"))
        #expect(!view.contains("@State private var collapsed"))
        #expect(!view.contains("withAnimation"))
        let workingRingSchedule = "TimelineView(.animation(minimumInterval: 1.0 / 30))"
        #expect(view.components(separatedBy: workingRingSchedule).count == 2)
        #expect(!view.replacingOccurrences(of: workingRingSchedule, with: "").contains(".animation("))
        #expect(!view.contains(".phaseAnimator"))
        #expect(view.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(SidebarBranchSummary(sessions: [], complete: false).incomplete)
        #expect(view.contains("model.navigation.permissionSummary"))
        #expect(view.contains("model.copilot.updateHistory(preferences.history)"))
        #expect(view.contains("model.copilot.updateAttention(preferences.attention)"))
    }

    private func tree(moved: Bool = false, partial: Bool = false) -> SidebarCopilotTree {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let evidence = AgentEvidenceID(source: "copilot.events", eventID: fixtures.sessionID)
        let blocking = AgentAttention(kind: .permission, evidence: evidence, occurredAt: now)
        let error = AgentAttention(kind: .error, evidence: evidence, occurredAt: now)
        let children: [CopilotChildWork] = [
            fixtures.child("root", state: .idle),
            fixtures.child("running", parent: "root", state: .working),
            .init(id: "blocked", parentID: "root", kind: .subagent, name: "Same name",
                  state: .blocked, model: nil, attention: [blocking]),
            .init(id: "attention", parentID: "root", kind: .subagent, name: "Same name",
                  state: .failed, model: nil, terminalEvent: .init(id: fixtures.sessionID, timestamp: now),
                  attention: [error]),
            .init(id: "other", parentID: nil, kind: .subagent, name: "Same name",
                  state: .completed, model: nil, terminalEvent: .init(id: fixtures.otherSessionID, timestamp: now))
        ]
        return SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(state: .working, children: children, now: now)],
                              complete: !partial, now: now),
            onto: fixtures.topology(moved: moved), now: now, history: .init(retention: .never)
        )
    }

    private func makeFile() -> SidebarLayoutFile {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return SidebarLayoutFile(url: root.appendingPathComponent(".build/layout-tests/\(UUID())/layout.json"))
    }

    private func withFile(_ body: (SidebarLayoutFile) throws -> Void) throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try body(file)
    }

    private func write(_ data: Data, to file: SidebarLayoutFile) throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file.url)
    }
}
