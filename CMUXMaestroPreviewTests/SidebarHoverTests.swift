import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarHoverTests {
    // Exact frozen S27 stress token/path; the six-paragraph History fixture stays in its archive.
    private var disclosureStressToken: String { String(repeating: "UnbrokenSyntheticIdentifier", count: 16) }
    private var disclosureStressPath: String { "/demo/stress/\(disclosureStressToken)/workspace" }

    @Test(arguments: [280.0, 350.0, 460.0], [SidebarDensity.compact, .comfortable])
    func readOnlyPinnedPathsUseFittingInlineOrFullWrappedCompact(width: Double, density: SidebarDensity) async throws {
        // The existing sidebar style specifies regular weight, not the text style's default weight.
        let font = Font.system(density == .compact ? .caption2 : .caption).weight(.regular)
        func textHeight(_ text: String) -> CGFloat {
            let reference = NSHostingView(rootView: Text(text).font(font)
                .fixedSize(horizontal: false, vertical: true).frame(width: width))
            reference.frame = NSRect(x: 0, y: 0, width: width, height: 1_000)
            reference.layoutSubtreeIfNeeded()
            return reference.fittingSize.height
        }
        let oneLine = textHeight("Ag"), threeLines = textHeight("Ag\nAg\nAg")
        let candidates = (1...40).map { "/synthetic/" + String(repeating: "directory/", count: $0) }
        let labelWrap = try #require(candidates.first {
            let display = SidebarSurfaceDirectory.line(.available($0)).value
            return textHeight(display) <= oneLine + 0.5
                && textHeight("Surface directory: \(display)") > oneLine + 0.5
        })
        let medium = try #require(candidates.first {
            let display = SidebarSurfaceDirectory.line(.available($0)).value
            return textHeight(display) > oneLine + 0.5 && textHeight(display) <= threeLines + 0.5
        })
        func footer(_ lines: [SidebarDetailLine]) -> some View {
            SidebarPinnedFooter(
                content: .init(title: "Synthetic", lines: lines), maximumHeight: 1_000,
                inspect: {}, copyValue: { _ in Issue.record("Read-only directory must not copy"); return false }
            ).environment(\.sidebarDensity, density).frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        let baseline = NSHostingView(rootView: footer([]))
        let baselineWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        baselineWindow.isReleasedWhenClosed = false
        baselineWindow.appearance = NSAppearance(named: .aqua)
        baselineWindow.contentView = baseline
        baseline.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        defer { baselineWindow.contentView = nil; baselineWindow.close() }
        baseline.layoutSubtreeIfNeeded()
        await sidebarEventually { baseline.fittingSize.height < 80 }
        let baselineHeight = baseline.fittingSize.height
        for (name, raw) in [("short", "/x"), ("label-wrap", labelWrap),
                            ("wrapped", medium), ("stress", disclosureStressPath)] {
            let line = SidebarSurfaceDirectory.line(.available(raw))
            if name == "stress" { #expect(line.value == disclosureStressPath && line.value.count == 455) }
            let host = NSHostingView(rootView: footer([line]))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            let expectedField = name == "short" ? oneLine
                : name == "stress" ? 24 + 2 + threeLines : oneLine + 2 + textHeight(line.value)
            await sidebarEventually {
                abs(host.fittingSize.height - (baselineHeight + 5 + expectedField)) <= 2
            }
            #expect(abs(host.fittingSize.height - (baselineHeight + 5 + expectedField)) <= 2,
                    "The real pinned footer must show the entire medium compact value at its density-aware font")
            let buttons = descendants(host).compactMap { $0 as? NSButton }
            #expect(!buttons.contains { $0.accessibilityIdentifier() == "hover-copy-value" })
            let toggle = buttons.first { $0.accessibilityIdentifier() == "sidebar-path-disclosure" }
            if name == "stress" {
                let toggle = try #require(toggle)
                #expect(window.makeFirstResponder(toggle))
                #expect(toggle.accessibilityPerformPress())
                await sidebarEventually { toggle.accessibilityValue() as? String == "Expanded" }
                let expectedExpanded = baselineHeight + 5 + 24 + 2 + textHeight(line.value)
                await sidebarEventually {
                    abs(host.fittingSize.height - expectedExpanded) <= 2
                }
                #expect(abs(host.fittingSize.height - expectedExpanded) <= 2)
                #expect(window.firstResponder === toggle)
            } else {
                #expect(toggle == nil, "Complete fitting compact text needs no dead control")
            }
            print("PATH133 pinned width=\(width) density=\(density) case=\(name) oneLine=\(oneLine) threeLines=\(threeLines) fullDisplay=\(textHeight(line.value)) baseline=\(baselineHeight) actual=\(host.fittingSize.height) field=\(host.fittingSize.height - baselineHeight - 5)")
            host.layoutSubtreeIfNeeded()
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = try SidebarRenderingEvidence.captureNativeBitmap(of: host)
            #expect(bitmap.pixelsWide == Int(width) * 2)
            #expect(bitmap.pixelsHigh == Int(host.bounds.height) * 2)
            let image = output.appendingPathComponent("path133-\(Int(width))-\(density)-\(name).png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
            let recognized = try SidebarRenderingEvidence.recognizedNativeLines(in: image).joined(separator: " ")
            #expect(recognized.contains("Synthetic") && recognized.contains("Surface directory"),
                    "Native-scale text recognition: \(recognized)")
        }
    }

    @Test(arguments: [280.0, 350.0, 460.0])
    func pathCompactHeightUsesActualCaptionAndWidth(width: Double) async throws {
        let line = try #require(SidebarPresentation.paths(.init(
            rootPath: .available(disclosureStressPath), projectRootPath: .available(nil),
            workingDirectory: .unavailable
        )).first)
        let host = NSHostingView(rootView: SidebarPathDetailValue(
            line: line, copy: { _ in Issue.record("Read-only path must not copy"); return false }
        ).frame(width: width).fixedSize(horizontal: false, vertical: true))
        let full = NSHostingView(rootView: Text(line.value).font(.caption)
            .fixedSize(horizontal: false, vertical: true).frame(width: width))
        let threeLines = NSHostingView(rootView: Text("Ag\nAg\nAg").font(.caption)
            .fixedSize(horizontal: false, vertical: true).frame(width: width))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func button() -> NSButton? {
            descendants(host).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "sidebar-path-disclosure" }
        }
        host.layoutSubtreeIfNeeded()
        await sidebarEventually { button() != nil }
        let toggle = try #require(button())
        host.layoutSubtreeIfNeeded()
        let compact = host.fittingSize.height
        let budget = threeLines.fittingSize.height
        let fullHeight = full.fittingSize.height
        #expect(compact <= 24 + 2 + budget + 1)
        #expect(fullHeight > budget)
        #expect(host.fittingSize.width <= width + 1)
        #expect(!descendants(host).contains { $0.accessibilityIdentifier() == "hover-copy-value" })
        #expect(toggle.accessibilityPerformPress())
        await sidebarEventually { toggle.accessibilityValue() as? String == "Expanded" }
        host.layoutSubtreeIfNeeded()
        let expanded = host.fittingSize.height
        #expect(abs(expanded - (24 + 2 + fullHeight)) <= 1,
                "Expanded path must occupy the complete original display value's actual wrapped height")
        #expect(expanded > compact)
        #expect(host.fittingSize.width <= width + 1)
        #expect(toggle.accessibilityPerformPress())
        await sidebarEventually { toggle.accessibilityValue() as? String == "Collapsed" }
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - compact) <= 1)
        print("PATH133 measured width=\(width) caption threeLines=\(budget) fullValue=\(fullHeight) compactField=\(compact) expandedField=\(expanded)")
    }

    @Test func pathEligibilityComesFromSourceNotLabelCopyOrSlash() {
        let values: [HierarchyAvailability<String?>] = [
            .available(nil), .available(""), .unavailable, .available(disclosureStressToken)
        ]
        for source in values {
            let lines = SidebarPresentation.paths(.init(
                rootPath: source, projectRootPath: source, workingDirectory: source
            ))
            #expect(lines.map { $0.path?.field } == [.workspace, .project, .surfaceDirectory])
            #expect(lines.allSatisfy { $0.copyableValue == nil })
            #expect(lines.allSatisfy { $0.path?.isAvailable == (source.copyablePathValue != nil) })
        }
        let parent = SidebarSurfaceDirectory.line(.available(disclosureStressPath), isParent: true)
        #expect(parent.path?.field == .parentSurfaceDirectory && parent.path?.isAvailable == true)
        let retained = SidebarSurfaceDirectory.line(.available(disclosureStressPath), isParent: true, retained: true)
        #expect(retained.path?.isAvailable == false && retained.copyableValue == nil)
        for title in ["Workspace path", "Worktree", "Session ID", "Child history"] {
            let foreign = SidebarDetailLine(title: title, value: disclosureStressPath, copyableValue: disclosureStressPath)
            #expect(foreign.path == nil, "Unrelated line titles and slash-shaped values cannot acquire disclosure")
        }
    }

    @Test func nativeDisclosureFocusProtectsTheExistingDelayedHoverDismissal() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        defer { window.contentView = nil; window.close() }
        var writes = 0
        let presenter = SidebarHoverPresenter(copyValue: { _ in writes += 1; return true }, showPanel: { _, _, _ in })
        defer { presenter.detach() }
        let lines = SidebarPresentation.paths(.init(
            rootPath: .available(disclosureStressPath), projectRootPath: .available(nil),
            workingDirectory: .unavailable
        ))
        presenter.update(anchor: anchor, data: .init(
            id: "path-focus", category: "Workspace preview", title: "Synthetic", lines: lines
        ), group: nil)
        presenter.hoverAnchor(true)
        presenter.open(explicit: false)
        let panel = try #require(presenter.panel)
        let root = try #require(panel.contentView)
        root.layoutSubtreeIfNeeded()
        func disclosure() -> NSButton? {
            descendants(root).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "sidebar-path-disclosure" }
        }
        await sidebarEventually { disclosure() != nil }
        let toggle = try #require(disclosure())
        presenter.hoverAnchor(false)
        #expect(panel.makeFirstResponder(toggle))
        #expect(presenter.state.copyActionFocused)
        try await Task.sleep(for: .milliseconds(260))
        #expect(presenter.state.mode == .hover && panel.firstResponder === toggle)
        #expect(toggle.accessibilityPerformPress())
        await sidebarEventually { toggle.accessibilityValue() as? String == "Expanded" }
        presenter.hoverAnchor(false, nameOnly: true)
        #expect(presenter.state.mode == .hover)
        #expect(writes == 0)
        #expect(panel.makeFirstResponder(nil))
        try await Task.sleep(for: .milliseconds(260))
        #expect(presenter.state.mode == .hidden)
    }

    @Test func hoverAndPinnedPathStateStayIndependentAndUnavailableReturnsLocalFocus() async throws {
        let workspaceID = UUID(), surfaceID = UUID(), windowID = UUID()
        let raw = NSHomeDirectory() + "/" + disclosureStressToken
        let long = SidebarPresentation.paths(.init(
            rootPath: .available(raw), projectRootPath: .available("/short"),
            workingDirectory: .available("/short")
        ), copyable: true)
        try #require(long.first?.value != raw, "Display abbreviation must not replace raw clipboard value")
        var writes: [String] = []
        func content(_ session: UUID, _ lines: [SidebarDetailLine]) -> SidebarDetailContent {
            .init(title: "Synthetic same title", lines: lines, inspection: .init(
                windowID: windowID, workspaceID: workspaceID, surfaceID: surfaceID,
                surfaceKind: .terminal, sessionID: session, target: .unmanaged(.session(session))
            ))
        }
        func footer(_ session: UUID, _ lines: [SidebarDetailLine]) -> SidebarPinnedFooter {
            .init(content: content(session, lines), inspect: {},
                  copyValue: { writes.append($0); return true })
        }
        let subjectA = UUID(), subjectB = UUID()
        let pinned = NSHostingView(rootView: footer(subjectA, long))
        let hover = NSHostingView(rootView: SidebarHoverCard(
            data: .init(id: "independent", category: "Agent preview", title: "Synthetic", lines: long),
            close: {}, copyValue: { writes.append($0); return true }
        ))
        let windows = [pinned as NSView, hover as NSView].map { host in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 220),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return window
        }
        defer { for window in windows { window.contentView = nil; window.close() } }
        func disclosure(_ host: NSView) -> NSButton? {
            descendants(host).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "sidebar-path-disclosure" }
        }
        await sidebarEventually { disclosure(pinned) != nil && disclosure(hover) != nil }
        let first = try #require(disclosure(pinned))
        #expect(first.accessibilityPerformPress())
        await sidebarEventually { first.accessibilityValue() as? String == "Expanded" }
        #expect(disclosure(hover)?.accessibilityValue() as? String == "Collapsed")
        pinned.rootView = footer(subjectA, long)
        pinned.layoutSubtreeIfNeeded()
        await sidebarEventually { disclosure(pinned)?.accessibilityValue() as? String == "Expanded" }
        #expect(disclosure(pinned) === first && writes.isEmpty)
        let copy = try #require(descendants(pinned).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Copy workspace path" })
        #expect(copy.accessibilityPerformPress())
        #expect(writes == [raw])
        pinned.rootView = footer(subjectB, long)
        pinned.layoutSubtreeIfNeeded()
        await sidebarEventually { disclosure(pinned) !== first }
        let replacement = try #require(disclosure(pinned))
        #expect(replacement.accessibilityValue() as? String == "Collapsed")
        #expect(windows[0].makeFirstResponder(replacement))
        let short = SidebarPresentation.paths(.init(
            rootPath: .available("/short"), projectRootPath: .available("/short"),
            workingDirectory: .available("/short")
        ), copyable: true)
        pinned.rootView = footer(subjectB, short)
        pinned.layoutSubtreeIfNeeded()
        await sidebarEventually { disclosure(pinned) == nil }
        let fallback = try #require(windows[0].firstResponder as? NSButton)
        #expect(fallback.accessibilityLabel() == "Copy workspace path")
        #expect(fallback.canBecomeKeyView)
        #expect(writes == [raw])
        #expect(fallback.accessibilityPerformPress())
        #expect(writes == [raw, "/short"])
        #expect(disclosure(hover)?.accessibilityValue() as? String == "Collapsed")
    }

    @Test(arguments: [280.0, 350.0, 460.0])
    func existingPathDisclosureKeepsFullValueCopyAndFieldFocus(width: Double) async throws {
        #expect(disclosureStressToken.count == 432 && disclosureStressPath.count == 455)
        let lines = SidebarPresentation.paths(.init(
            rootPath: .available(disclosureStressPath),
            projectRootPath: .available(disclosureStressToken),
            workingDirectory: .available("/short")
        ), copyable: true)
        let panel = SidebarHoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 220),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.allowsKeyboard = true
        var writes: [String] = []
        var focused = false
        func card(_ id: String, _ fields: [SidebarDetailLine]) -> SidebarHoverCard {
            SidebarHoverCard(
                data: .init(id: id, category: "Workspace preview", title: "Synthetic path", lines: fields),
                close: {}, copyValue: { writes.append($0); return true },
                copyActionFocusChanged: { focused = $0 }
            )
        }
        let host = NSHostingView(rootView: card("subject-A", lines))
        panel.contentView = host
        defer { panel.contentView = nil; panel.close() }
        func disclosures() -> [NSButton] {
            descendants(host).compactMap { $0 as? NSButton }
                .filter { $0.accessibilityIdentifier() == "sidebar-path-disclosure" }
        }
        host.layoutSubtreeIfNeeded()
        await sidebarEventually { disclosures().count == 2 }
        let toggle = try #require(disclosures().first, "Overflowing existing paths need a visible label-row disclosure")
        let other = try #require(disclosures().last)
        #expect(disclosures().count == 2, "Short surface directory must not acquire a dead control")
        #expect(toggle.accessibilityValue() as? String == "Collapsed")
        #expect(toggle.accessibilityLabel()?.contains("Workspace path") == true)
        #expect(!toggle.isHidden && toggle.alphaValue == 1 && writes.isEmpty)
        let labelOrigin = host.convert(toggle.bounds, from: toggle).origin
        #expect(panel.makeFirstResponder(toggle))
        #expect(focused)
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        toggle.keyDown(with: enter)
        await sidebarEventually { toggle.accessibilityValue() as? String == "Expanded" }
        host.layoutSubtreeIfNeeded()
        #expect(panel.firstResponder === toggle && disclosures().first === toggle)
        #expect(other.accessibilityValue() as? String == "Collapsed" && writes.isEmpty)
        #expect(abs(host.convert(toggle.bounds, from: toggle).origin.y - labelOrigin.y) <= 1)
        let copy = try #require(descendants(host).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Copy workspace path" })
        copy.performClick(nil)
        #expect(writes == [disclosureStressPath])
        host.rootView = card("subject-A", lines)
        host.layoutSubtreeIfNeeded()
        await sidebarEventually { disclosures().first?.accessibilityValue() as? String == "Expanded" }
        #expect(disclosures().first === toggle && panel.firstResponder === toggle)
        let space = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        toggle.keyDown(with: space)
        await sidebarEventually { toggle.accessibilityValue() as? String == "Collapsed" }
        #expect(writes == [disclosureStressPath] && panel.firstResponder === toggle)
        host.rootView = card("subject-B", lines)
        host.layoutSubtreeIfNeeded()
        await sidebarEventually { disclosures().first !== toggle }
        #expect(disclosures().first?.accessibilityValue() as? String == "Collapsed")
        #expect(!panel.isVisible)
        print("PATH133 width=\(width): original 455-path/432-token, independent field, stable control, Enter/Space, exact copy, refresh/replacement")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func withProductionKeyboardSidebar(
        _ check: @MainActor (NSWindow, NSView, SidebarConnectionModel, SidebarPreferences,
                  SidebarTitleNativeButton, SidebarTitleNativeButton, NSPasteboard) async throws -> Void
    ) async throws {
        let fixture = SidebarTreeFixtures()
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let preferences = preferenceFixture.preferences()
        let date = Date()
        let evidence = AgentAttention(kind: .turnFinished,
                                      evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: date)
        let observations = [
            CopilotSessionObservation(
                sessionID: fixture.sessionID, surfaceID: fixture.surfaceA, launchWorkspaceID: fixture.workspaceA,
                liveness: .alive, state: .idle, model: "keyboard-model", children: [], observedAt: date,
                attention: [evidence]
            ),
            fixture.session(id: fixture.otherSessionID, surface: fixture.surfaceB, now: date)
        ]
        let snapshot = fixture.snapshot(sessions: observations, now: date)
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }, expiryPause: sidebarFrozenExpiry, now: { date }
        )
        let orchestration = SidebarOrchestrationPolling(
            read: { .empty }, pause: { try await Task.sleep(for: .seconds(60)) }
        )
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: [.init(
                id: fixture.workspaceA, title: .available("Keyboard workspace"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .available("/synthetic/keyboard"), projectRootPath: .available(nil),
                surfaces: .available([
                    .init(id: fixture.surfaceA, title: "First row", kind: .terminal, isFocused: true,
                          isPinned: false, unreadCount: 0, workingDirectory: .available("/synthetic/keyboard")),
                    .init(id: fixture.surfaceB, title: "Following row", kind: .terminal, isFocused: false,
                          isPinned: false, unreadCount: 0, workingDirectory: .available("/synthetic/keyboard"))
                ])
            )], windowID: fixture.windowID
        )
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 2)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Keyboard preview must not navigate the host") })
        model.setVisible(true)
        defer { model.setVisible(false) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences)
            .environment(\.sidebarClipboardWrite, { SidebarSessionCopy.copy($0, to: pasteboard) }))
        window.contentView = hosting
        defer {
            for anchor in descendants(hosting).compactMap({ $0 as? SidebarHoverAnchorView }) {
                anchor.presenter?.detach()
            }
            window.contentView = nil
            window.close()
        }
        await sidebarEventually { polling.tree.sessions.count == 2 && polling.tree.attentionOwnerCount == 1 }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        let titles = descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
        let origin = try #require(titles.first { $0.accessibilityLabel() == "Focus Terminal First row" })
        let following = try #require(titles.first { $0.accessibilityLabel() == "Focus Terminal Following row" })
        try #require(origin.preview.available && following.preview.available)
        window.autorecalculatesKeyViewLoop = true
        window.recalculateKeyViewLoop()
        try await check(window, hosting, model, preferences, origin, following, pasteboard)
    }

    private func automaticPath(from origin: NSView, to following: NSView) throws -> [NSView] {
        var path: [NSView] = []
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(origin)]
        var next = origin.nextValidKeyView
        while let view = next, path.count < 64, visited.insert(ObjectIdentifier(view)).inserted {
            path.append(view)
            if view === following { return path }
            next = view.nextValidKeyView
        }
        try #require(path.last === following,
                     "The production key loop must reach the exact following row without wrapping to the origin")
        return path
    }

    @Test func productionSidebarAutomaticallyLinksExactFollowingRow() async throws {
        try await withProductionKeyboardSidebar { window, _, model, preferences, origin, following, _ in
            let path = try automaticPath(from: origin, to: following)
            #expect(path.last === following && !path.contains { $0 === origin })
            #expect(!window.isVisible && model.navigation.status == .idle)
            #expect(preferences.attention.acknowledged.isEmpty && model.copilot.tree.attentionOwnerCount == 1)
            print("R1 automatic production key loop: First row -> \(path.map { $0.accessibilityLabel() ?? String(describing: type(of: $0)) }); exact surfaces/session identities; no nextKeyView assignments")
        }
    }

    @Test(arguments: ["tab", "escape", "shift-tab"])
    func hostedPreviewKeysContinueToFollowingRow(exit: String) async throws {
        let fixture = SidebarTreeFixtures()
        try await withProductionKeyboardSidebar { window, hosting, model, preferences, origin, following, pasteboard in
            @MainActor func pinned() -> SidebarDetailContent {
                SidebarPresentation.pinnedDetails(
                    hierarchy: model.hierarchy, connected: true, tree: model.copilot.tree,
                    managed: model.orchestration.snapshot, availability: model.orchestration.availability, now: Date()
                )
            }
            let pinnedBefore = pinned()
            try #require(pinnedBefore.inspection?.sessionID == fixture.sessionID)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            await sidebarEventually { window.isKeyWindow }
            try #require(window.isKeyWindow)
            #expect(window.makeFirstResponder(origin))
            let presenter = try #require(descendants(hosting).compactMap { ($0 as? SidebarHoverAnchorView)?.presenter }
                .first { $0.state.mode == .keyboard })
            try #require(window.isKeyWindow && presenter.state.mode == .keyboard)
            func send(_ code: UInt16, to target: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
                let characters = code == 48 ? "\t" : code == 49 ? " " : code == 36 ? "\r" : "\u{1b}"
                NSApp.sendEvent(try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: target.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                )))
            }
            try send(48, to: window)
            let panel = try #require(presenter.panel)
            try #require(panel.isKeyWindow && !window.isKeyWindow && presenter.state.mode == .explicit)
            try #require((panel.firstResponder as? NSButton)?.accessibilityIdentifier() == "hover-close")
            try send(48, to: panel)
            let copy = try #require(panel.firstResponder as? NSButton)
            try #require(copy.accessibilityIdentifier() == "hover-copy-value"
                         && copy.accessibilityLabel() == "Copy session ID")
            try send(49, to: panel)
            await sidebarEventually { copy.accessibilityValue() as? String == "Copied" }
            #expect(pasteboard.string(forType: .string) == fixture.sessionID.uuidString)
            try #require(panel.isKeyWindow && panel.firstResponder === copy)
            let controls = descendants(try #require(panel.contentView)).compactMap { $0 as? NSButton }
                .filter { ["hover-close", "hover-copy-value"].contains($0.accessibilityIdentifier()) && $0.canBecomeKeyView }
            let copyControls = controls.filter { $0.accessibilityIdentifier() == "hover-copy-value" }
            try #require(controls.count == 6 && copyControls.count == 5 && copyControls.first === copy)
            let path = try automaticPath(from: origin, to: following)
            if exit == "tab" {
                for _ in 1..<copyControls.count {
                    try send(48, to: panel)
                    try #require(copyControls.contains { $0 === panel.firstResponder })
                }
                try #require(panel.firstResponder === copyControls.last)
                try send(48, to: panel)
            } else if exit == "escape" {
                try send(53, to: panel)
                #expect(window.isKeyWindow && window.firstResponder === origin)
                #expect(presenter.state.mode == .hidden && !panel.isVisible)
                try send(48, to: window)
            } else {
                try send(48, to: panel, flags: .shift)
                #expect(window.isKeyWindow && window.firstResponder === origin)
                #expect(presenter.state.mode == .hidden && !panel.isVisible)
                try send(48, to: window)
            }
            try #require(window.isKeyWindow && window.firstResponder === path.first)
            #expect(presenter.state.mode == .hidden && !panel.isVisible && !presenter.isMonitoring)
            for target in path.dropFirst() {
                try send(48, to: window)
                try #require(window.isKeyWindow && window.firstResponder === target)
            }
            #expect(window.firstResponder === following)
            #expect(model.navigation.status == .idle && preferences.attention.acknowledged.isEmpty)
            #expect(model.copilot.tree.attentionOwnerCount == 1 && pinned() == pinnedBefore)
            print("R1 \(exit): production SidebarView title -> actual key panel -> exact native Copy -> automatic following row; host/seen=0; pinned unchanged")
        }
    }

    @Test func nativeTitleContinuesForwardAfterReturningAndReentersOnANewVisit() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 120),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        let origin = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 60, width: 200, height: 30))
        let following = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 20, width: 200, height: 30))
        root.addSubview(origin)
        root.addSubview(following)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        window.autorecalculatesKeyViewLoop = false
        origin.nextKeyView = following
        following.nextKeyView = origin
        var entries = 0, activations = 0
        origin.preview = .init(enter: { entries += 1; return true })
        origin.activate = { activations += 1 }
        following.activate = { activations += 1 }
        let tab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        #expect(window.makeFirstResponder(origin))
        window.sendEvent(tab)
        #expect(entries == 1 && window.firstResponder === origin)
        window.sendEvent(tab)
        #expect(entries == 1 && window.firstResponder === following && activations == 0)
        #expect(window.makeFirstResponder(origin))
        window.sendEvent(tab)
        #expect(entries == 2 && activations == 0)
    }

    @Test func previewTabExitsAtLastNativeControlInsteadOfWrapping() throws {
        let panel = SidebarHoverPanel(contentRect: NSRect(x: 100, y: 100, width: 280, height: 240),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 240))
        let close = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 204, width: 200, height: 24))
        close.setAccessibilityIdentifier("hover-close")
        root.addSubview(close)
        let copies = (0..<6).map { index in
            let copy = SidebarTitleNativeButton(
                frame: NSRect(x: 0, y: CGFloat(168 - index * 24), width: 200, height: 24)
            )
            copy.setAccessibilityIdentifier("hover-copy-value")
            root.addSubview(copy)
            return copy
        }
        let firstCopy = try #require(copies.first)
        let lastCopy = try #require(copies.last)
        panel.contentView = root
        panel.allowsKeyboard = true
        var exits = 0, returns = 0
        panel.advanceFromPreview = { exits += 1 }
        panel.returnToOrigin = { returns += 1 }
        #expect(panel.focusControls() && panel.firstResponder === close)
        panel.selectNextKeyView(nil)
        #expect(panel.firstResponder === firstCopy && exits == 0)
        for copy in copies.dropFirst() {
            panel.selectNextKeyView(nil)
            #expect(panel.firstResponder === copy && exits == 0)
        }
        panel.selectNextKeyView(nil)
        #expect(panel.firstResponder === lastCopy && exits == 1)
        #expect(panel.makeFirstResponder(firstCopy))
        panel.selectPreviousKeyView(nil)
        #expect(panel.firstResponder === firstCopy && returns == 1)
    }

    @Test func previewShiftTabReturnsFromFirstNativeControlWithoutWrapping() throws {
        let panel = SidebarHoverPanel(contentRect: NSRect(x: 100, y: 100, width: 280, height: 180),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
        let close = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 140, width: 200, height: 24))
        close.setAccessibilityIdentifier("hover-close")
        root.addSubview(close)
        for index in 0..<6 {
            let copy = SidebarTitleNativeButton(frame: NSRect(x: 0, y: CGFloat(108 - index * 24), width: 200, height: 24))
            copy.setAccessibilityIdentifier("hover-copy-value")
            root.addSubview(copy)
        }
        panel.contentView = root
        panel.allowsKeyboard = true
        var returns = 0
        panel.returnToOrigin = { returns += 1 }
        #expect(panel.focusControls() && panel.firstResponder === close)
        panel.selectNextKeyView(nil)
        let copy = try #require(panel.firstResponder as? NSButton)
        try #require(panel.firstResponder === copy)
        try #require(copy.accessibilityIdentifier() == "hover-copy-value")
        panel.selectPreviousKeyView(nil)
        #expect(panel.firstResponder === copy && returns == 1)
    }

    @Test func nativeTabTraversesIntoExactCopyControlWithoutPressingOrReplacingOrigin() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 200))
        let button = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 150, width: 240, height: 30))
        root.addSubview(button)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let sessionID = UUID()
        var copied: [String] = []
        var pressed = 0
        let presenter = SidebarHoverPresenter(copyValue: { copied.append($0); return true }, showPanel: { _, _, _ in })
        defer { presenter.detach() }
        presenter.update(anchor: button, data: .init(
            id: "keyboard-session", category: "Agent preview", title: "Synthetic keyboard agent",
            lines: [.sessionID(sessionID)]
        ), group: SidebarHoverGroup())
        button.activate = { pressed += 1 }
        button.preview = .init(
            available: true, focus: { presenter.keyboardFocus($0) }, enter: { presenter.enterFromKeyboard() },
            origin: { presenter.rememberKeyboardOrigin($0) }, dismiss: { presenter.dismiss(restoreFocus: false) }
        )
        #expect(window.makeFirstResponder(button))
        #expect(presenter.state.mode == .keyboard && pressed == 0 && copied.isEmpty)
        func key(_ code: UInt16, in target: NSWindow, characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }
        button.keyDown(with: try key(48, in: window, characters: "\t"))
        let panel = try #require(presenter.panel)
        #expect(presenter.state.mode == .explicit && panel.canBecomeKey)
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let panelContent = try #require(panel.contentView)
        let copy = try #require(descendants(panelContent).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "hover-copy-value" })
        panel.recalculateKeyViewLoop()
        for _ in 0..<12 where panel.firstResponder !== copy {
            panel.selectNextKeyView(nil)
        }
        print("P57 preview key loop: copyEligible=\(copy.canBecomeKeyView), responder=\(String(describing: panel.firstResponder))")
        #expect(panel.firstResponder === copy, "Native Tab order must reach the preview's copy control")
        try #require(panel.firstResponder === copy)
        panel.sendEvent(try key(49, in: panel, characters: " "))
        await sidebarEventually { copy.accessibilityValue() as? String == "Copied" }
        #expect(copied == [sessionID.uuidString] && pressed == 0)
        #expect(copy.accessibilityValue() as? String == "Copied")
        presenter.dismiss(restoreFocus: true)
        #expect(presenter.state.mode == .hidden)
        #expect(window.firstResponder === button)
        #expect(!window.isVisible && !panel.isVisible)
        print("P57 native keyboard: passive row focus -> Tab -> exact copy -> Copied; origin retained; host activations=0")
    }

    @Test func sharedNativeMenusKeepTargetsAndUnavailableActionsInert() async throws {
        let fixture = SidebarTreeFixtures()
        let navigation = SidebarNavigation()
        var selected: [SidebarNavigationTarget] = []
        var seen: [SidebarSeenTarget] = []
        navigation.update(topology: SidebarTopology(fixture.hierarchy()), connected: true,
                          workspaceAllowed: true, surfaceAllowed: true, perform: { selected.append($0) })
        let focus = SidebarRowAction.focus(
            .surface(workspaceID: fixture.workspaceA, surfaceID: fixture.surfaceA),
            navigation: navigation, prepareSeen: { target in { seen.append(target) } }, parentChat: true
        )
        let presenter = SidebarRowMenuPresenter()
        presenter.groups = [
            .init(title: "Navigation", actions: [focus]),
            .appearance(icon: nil, agent: true, child: true), .placement, .lifecycle(child: true)
        ]
        let menu = presenter.menu()
        #expect(menu.items.map(\.title) == ["Navigation", "Appearance", "Organization", "Lifecycle"])
        #expect(selected.isEmpty && seen.isEmpty && navigation.status == .idle)
        let command = try #require(menu.items[0].submenu?.items.first)
        #expect(command.title == "Open parent chat" && command.isEnabled)
        for group in menu.items.dropFirst() {
            for item in try #require(group.submenu).items {
                #expect(!item.isEnabled)
                presenter.invoke(item)
            }
        }
        #expect(selected.isEmpty && seen.isEmpty)
        presenter.invoke(command)
        await sidebarEventually { navigation.status == .selected }
        #expect(selected == [.surface(workspaceID: fixture.workspaceA, surfaceID: fixture.surfaceA)])
        #expect(seen == [.surface(workspaceID: fixture.workspaceA, surfaceID: fixture.surfaceA)])
        navigation.update(topology: SidebarTopology(fixture.hierarchy(moved: true)), connected: true,
                          workspaceAllowed: true, surfaceAllowed: true, perform: { selected.append($0) })
        presenter.invoke(command)
        #expect(navigation.status == .staleTarget)
        #expect(selected.count == 1 && seen.count == 1)
        let denied = SidebarRowAction.focus(.workspace(fixture.workspaceA), navigation: SidebarNavigation(),
                                          prepareSeen: { _ in { Issue.record("Denied menu cannot acknowledge") } })
        #expect(denied.unavailable != nil)
    }

    @Test func nativeContextBoundaryDistinguishesIconRowAndOutsideAndKeyboardUsesSameMenu() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        let anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let icon = SidebarIconNativeButton()
        icon.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let title = SidebarTitleNativeButton(frame: NSRect(x: 28, y: 0, width: 180, height: 24))
        root.addSubview(anchor)
        root.addSubview(icon)
        root.addSubview(title)
        window.contentView = root
        defer { anchor.detach(); window.contentView = nil; window.close() }
        let presenter = SidebarRowMenuPresenter()
        presenter.anchor = anchor
        anchor.presenter = presenter
        var presses = 0, menus = 0, icons = 0
        presenter.groups = [.init(title: "Navigation", actions: [.init(title: "Exact action", perform: { presses += 1 })])]
        presenter.present = { menu, _, _ in
            #expect(menu.items.first?.submenu?.items.first?.title == "Exact action")
            menus += 1
        }
        title.showActions = { presenter.show() }
        icon.activate = { icons += 1 }
        func event(_ point: NSPoint, type: NSEvent.EventType = .rightMouseDown,
                   flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1))
        }
        #expect(!anchor.handles(try event(NSPoint(x: 10, y: 10))))
        #expect(anchor.handles(try event(NSPoint(x: 80, y: 10))))
        #expect(anchor.handles(try event(NSPoint(x: 80, y: 10), type: .leftMouseDown, flags: .control)))
        #expect(!anchor.handles(try event(NSPoint(x: 260, y: 10))))
        #expect(!anchor.handles(try event(NSPoint(x: 80, y: 10), type: .leftMouseDown)))
        icon.rightMouseDown(with: try event(NSPoint(x: 10, y: 10)))
        #expect(icons == 1 && menus == 0 && presses == 0)
        presenter.show()
        title.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 109
        )))
        #expect(menus == 2 && presses == 0 && icons == 1)
        #expect(!window.isVisible)
    }

    @Test func realHostedWorkspaceNameHasNoTrackingOverBlankFillOrControls() async throws {
        for text in ["Short", String(repeating: "Long workspace ", count: 12)] {
            let content = HStack(spacing: 5) {
                Button("Disclosure") {}
                SidebarHoverRegion(data: .init(id: "workspace", category: "Workspace", title: text), nameOnly: true) {
                    SidebarTitleButton(label: text, hint: text, action: { Issue.record("Passive render must not press") }) {
                        HStack {
                            Text(text).font(.caption).lineLimit(1).sidebarNameHover()
                            Spacer(minLength: 0)
                        }
                    }
                }
                Button("Actions") {}
            }.frame(width: 280)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let name = try #require(descendants(host).compactMap { $0 as? SidebarHoverAnchorView }.first)
            let button = try #require(descendants(host).compactMap { $0 as? SidebarTitleNativeButton }.first)
            let textRect = host.convert(name.bounds, from: name)
            let buttonRect = host.convert(button.bounds, from: button)
            #expect(buttonRect.contains(textRect))
            #expect(textRect.width > 0 && textRect.width <= buttonRect.width)
            if text == "Short" { #expect(textRect.width < buttonRect.width - 10) }
            #expect(textRect.minX > 0 && textRect.maxX < 280)
            #expect(!window.isVisible)
        }
    }

    @Test func nativeNameTrackingCancelsPendingAndVisiblePreviewAtItsBoundary() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let anchor = SidebarHoverAnchorView(frame: NSRect(x: 24, y: 340, width: 90, height: 14))
        root.addSubview(anchor)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
        anchor.presenter = presenter
        anchor.tracksName = true
        presenter.update(anchor: anchor, data: .init(id: "name", category: "Workspace", title: "Long workspace name"),
                         group: SidebarHoverGroup())
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        for _ in 0..<3 {
            anchor.mouseEntered(with: event)
            anchor.mouseExited(with: event)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.state.mode == .hidden && presenter.panel == nil)
        anchor.mouseEntered(with: event)
        await sidebarEventually { presenter.state.mode == .hover }
        #expect(presenter.state.mode == .hover)
        anchor.mouseExited(with: event)
        #expect(presenter.state.mode == .hidden)
        #expect(!presenter.isMonitoring)
        #expect(anchor.hitTest(NSPoint(x: 25, y: 345)) == nil, "Tracking must not intercept name activation")
        #expect(anchor.bounds.width == 90, "Blank name fill and adjacent controls are outside the tracking area")
        presenter.detach()
    }

    @Test func nativeKeyboardPreviewDoesNotPressTitleAndTabEntersControls() throws {
        let button = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        var activations = 0, entries = 0, dismissals = 0
        button.activate = { activations += 1 }
        button.preview = .init(focus: { _ in }, enter: { entries += 1; return true }, dismiss: { dismissals += 1 })
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code))
        }
        button.keyDown(with: try key(48))
        #expect(entries == 1 && activations == 0)
        button.keyDown(with: try key(53))
        #expect(dismissals == 1 && activations == 0)
        button.keyDown(with: try key(36))
        #expect(activations == 1 && dismissals == 2)
        button.keyDown(with: try key(49))
        #expect(activations == 2)
    }

    @Test func pointerTravelAndExplicitDismissalHaveSeparateState() {
        var state = SidebarHoverState()
        #expect(!state.shouldOpen)
        state.anchor(true)
        #expect(state.shouldOpen)
        state.open(explicit: false)
        state.anchor(false)
        #expect(state.shouldClose)
        state.card(true)
        #expect(!state.shouldClose)
        state.card(false)
        #expect(state.shouldClose)
        state.dismiss()
        #expect(state.mode == .hidden)
        state.anchor(true)
        state.open(explicit: true)
        state.anchor(false)
        state.card(false)
        #expect(!state.shouldClose)
        state.anchor(true)
        state.dismiss()
        #expect(!state.shouldOpen)
        state.anchor(false)
        state.anchor(true)
        #expect(state.shouldOpen)
    }

    @Test func delayedPointerDismissalRechecksPreviewCopyFocus() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        defer { window.contentView = nil; window.close() }
        let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
        defer { presenter.detach() }
        presenter.update(anchor: anchor, data: .init(
            id: "focus-retained", category: "Agent preview", title: "Synthetic agent",
            lines: [.sessionID(UUID())]
        ), group: nil)
        presenter.hoverAnchor(true)
        presenter.open(explicit: false)
        presenter.hoverAnchor(false)
        presenter.copyActionFocus(true)
        try await Task.sleep(for: .milliseconds(260))
        #expect(presenter.state.mode == .hover)
        #expect(presenter.panel != nil)
        presenter.copyActionFocus(false)
        try await Task.sleep(for: .milliseconds(260))
        #expect(presenter.state.mode == .hidden)
        #expect(presenter.panel?.contentView == nil)
        #expect(!presenter.isMonitoring)
    }

    @Test func leavingOrDetachingCancelsPendingHover() async throws {
        let presenter = SidebarHoverPresenter()
        presenter.hoverAnchor(true)
        presenter.hoverAnchor(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.panel == nil && presenter.state.mode == .hidden)
        presenter.hoverAnchor(true)
        presenter.detach()
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.panel == nil && presenter.state.mode == .hidden)
    }

    @Test func hoverPanelsCannotBecomeKeyOrMainUnlessExplicitlyRequested() {
        let panel = SidebarHoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        panel.allowsKeyboard = true
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isVisible)
    }

    @Test func losingPanelFocusOrApplicationActivationReleasesPreviewOwnership() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        defer { window.contentView = nil; window.close() }
        let group = SidebarHoverGroup()
        for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
            presenter.update(anchor: anchor, data: .init(id: "one", category: "Preview", title: "One"), group: group)
            let original = window.firstResponder
            presenter.open(explicit: true)
            #expect(presenter.state.mode == .explicit)
            #expect(presenter.isMonitoring)
            let panel = try #require(presenter.panel)
            #expect(!panel.isVisible && !window.isVisible)
            let other = SidebarHoverPresenter(showPanel: { _, _, _ in })
            #expect(!group.claim(other, explicit: false))
            NotificationCenter.default.post(
                name: notification,
                object: notification == NSWindow.didResignKeyNotification ? panel : NSApp
            )
            #expect(presenter.state.mode == .hidden)
            #expect(!presenter.isMonitoring && panel.contentView == nil)
            #expect(window.firstResponder === original)
            #expect(group.claim(other, explicit: false))
        }
    }

    @Test func placementFitsScreenEdgesAndShortAvailableSpace() {
        for visible in [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1440, y: 70, width: 1440, height: 830),
            CGRect(x: 100, y: 100, width: 240, height: 180)
        ] {
            for anchor in [
                CGRect(x: visible.minX + 10, y: visible.maxY - 40, width: 180, height: 24),
                CGRect(x: visible.maxX - 190, y: visible.minY + 10, width: 180, height: 24),
                CGRect(x: visible.midX, y: visible.midY, width: 24, height: 24)
            ] {
                let frame = SidebarHoverPlacement.frame(anchor: anchor, visible: visible,
                                                       preferred: CGSize(width: 300, height: 360))
                #expect(visible.contains(frame))
                #expect(frame.width <= 300 && frame.height <= 360)
            }
        }
        let right = SidebarHoverPlacement.frame(
            anchor: CGRect(x: 20, y: 400, width: 180, height: 24),
            visible: CGRect(x: 0, y: 0, width: 1400, height: 900),
            preferred: CGSize(width: 300, height: 260)
        )
        #expect(right.minX == 206)
    }

    @Test func workspaceCardsUseExactIdentityAndGrantedCurrentMetadata() throws {
        let fixtures = SidebarTreeFixtures()
        let original = fixtures.hierarchy()
        let a = try #require(SidebarHoverContent.workspace(fixtures.workspaceA, hierarchy: original, connected: true))
        let b = try #require(SidebarHoverContent.workspace(fixtures.workspaceB, hierarchy: original, connected: true))
        #expect(a.id != b.id && a.title == b.title)
        #expect(a.category == "Workspace preview")
        #expect(a.lines.contains(.init(title: "Shared surfaces", value: "1 terminal")))
        #expect(a.lines.contains(.init(title: "Workspace ID", value: fixtures.workspaceA.uuidString)))
        #expect(!a.lines.contains { $0.title.contains("Agent") || $0.title.contains("Pet") })
        #expect(SidebarHoverContent.workspace(fixtures.workspaceA, hierarchy: original, connected: false) == nil)
        #expect(SidebarHoverContent.workspace(UUID(), hierarchy: original, connected: true) == nil)
        let denied = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(granted: false), connected: true
        ))
        #expect(denied.lines.isEmpty && denied.notice == "Workspace metadata unavailable")
        let ambiguous = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(duplicateSurface: true), connected: true
        ))
        #expect(ambiguous.lines.contains(.init(title: "Shared surfaces", value: "Count unavailable; placement is ambiguous")))
        let moved = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(moved: true), connected: true
        ))
        #expect(moved.lines.contains(.init(title: "Shared surfaces", value: "None")))
    }

    @Test func passiveComponentsHaveNoNavigationOrPreferenceMutationDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarHoverCard.swift"), encoding: .utf8)
        for forbidden in ["SidebarNavigation", "SidebarPreferences", "SidebarSeen", "UserDefaults", "context.host", "markSeen", "acknowledge"] {
            #expect(!source.contains(forbidden))
        }
        #expect(source.contains(".nonactivatingPanel"))
        #expect(source.contains("override var canBecomeMain: Bool { false }"))
    }

    @Test(arguments: [false, true])
    func renderWorkspaceCardWithoutClippingOrSideEffects(dark: Bool) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let before = (preferences.history, preferences.attention, preferences.layout, preferences.icons)
        let data = SidebarHoverCardData(
            id: "synthetic-workspace", category: "Workspace preview",
            title: "Maestro design", subtitle: "Sidebar and personalization",
            lines: [
                .init(title: "Shared surfaces", value: "3 terminal, 1 browser"),
                .init(title: "Workspace path", value: "/synthetic/repository/with/a/long/path/that/must/wrap/without/clipping"),
                .init(title: "Project path", value: "Path unavailable"),
                .init(title: "Workspace ID", value: UUID().uuidString)
            ]
        )
        for size in [NSSize(width: 300, height: 360), NSSize(width: 224, height: 164)] {
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: SidebarHoverCard(data: data, close: {
                Issue.record("Rendering must not dismiss the card")
            },             copyValue: { _ in
                Issue.record("Rendering must not copy")
                return false
            }).environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.frame = frame
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            #expect(!window.isVisible)
            let metrics = SidebarRenderingEvidence.metrics(for: hosting)
            #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = root.appendingPathComponent("hover-workspace-\(Int(size.width))-\(dark ? "dark" : "light").png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
            let text = try SidebarRenderingEvidence.recognizedLines(in: image, dark: dark, naturalLanguage: true).joined(separator: " ")
            #expect(text.contains("Maestro design"))
            #expect(text.contains("Preview only"))
        }
        #expect(preferences.history == before.0 && preferences.attention == before.1)
        #expect(preferences.layout == before.2 && preferences.icons == before.3)
    }
}
