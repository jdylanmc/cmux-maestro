import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarHoverTests {
    @Test func hiddenAgentPreviewsDoNotBuildCardsUntilOpened() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
        defer { presenter.detach(); window.contentView = nil; window.close() }
        var builds = 0
        var available = true
        let provider: () -> SidebarHoverCardData? = {
            builds += 1
            return available ? .init(id: "synthetic", category: "Agent preview", title: "Synthetic") : nil
        }
        for _ in 0..<60 { presenter.update(anchor: anchor, data: nil, group: nil, dataProvider: provider) }
        #expect(builds == 0)
        presenter.open(explicit: false)
        #expect(builds == 1)
        #expect(presenter.state.mode == .hover)
        available = false
        presenter.update(anchor: anchor, data: nil, group: nil, dataProvider: provider)
        #expect(builds == 2)
        #expect(presenter.state.mode == .hidden)
    }

    @Test(.enabled(if: SidebarAppKitTestScope.localAcceptanceEnabled), arguments: [false, true])
    func mountedProductionSidebarStopsRequestingLayoutWhenUnchanged(visualActivity: Bool) async throws {
        try await withProductionKeyboardSidebar(visualActivity: visualActivity, animatedPet: true) { window, host, _, _, _, _, _ in
            let hosting = try #require(host as? IdleLayoutHostingView<AnyView>)
            try #require(descendants(host).contains { $0 is SidebarPetAnimationView })
            func flush() {
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                _ = RunLoop.current.run(mode: .default, before: .distantPast)
            }
            func observeDisplayCycles() {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            }
            observeDisplayCycles()
            for _ in 0..<10 { flush(); await Task.yield() }
            let settled = hosting.layouts
            observeDisplayCycles()
            for _ in 0..<20 { flush(); await Task.yield() }
            print("Mounted sidebar layouts: warmup=\(settled), unchanged=\(hosting.layouts - settled)")
            #expect(hosting.layouts == settled)
        }
    }

    @Test func compositorAnimationsKeepTheirFramesAndStopWhenHiddenOrDetached() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSView(frame: window.frame)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let first = try #require(context.makeImage())
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let second = try #require(context.makeImage())
        let pet = SidebarPetAnimationView(frame: CGRect(x: 0, y: 0, width: 38, height: 42))
        pet.setFrames([first, second])
        hosting.addSubview(pet)
        pet.layoutSubtreeIfNeeded()
        let image = try #require(pet.layer?.sublayers?.first)
        let sequence = try #require(image.animation(forKey: SidebarPetAnimationView.animationKey) as? CAKeyframeAnimation)
        #expect(sequence.calculationMode == .discrete && sequence.values?.count == 2)
        #expect(sequence.keyTimes == [0, 0.5])
        #expect(sequence.duration == 2.0 / 7 && sequence.repeatCount == .infinity)
        #expect(image.frame == pet.bounds)
        pet.isHidden = true
        #expect(image.animationKeys()?.isEmpty != false)
        pet.isHidden = false
        #expect(image.animationKeys()?.count == 1)
        pet.setFrames([second])
        #expect(image.animationKeys()?.isEmpty != false)
        #expect((image.contents as AnyObject?) === second)
        pet.setFrames([first, second])
        pet.removeFromSuperview()
        #expect(image.animationKeys()?.isEmpty != false)

        let status = SidebarStatusAnimationView(frame: CGRect(x: 0, y: 0, width: 14, height: 16))
        hosting.addSubview(status)
        for (kind, count) in [(SidebarStatusAnimationView.Kind.working, 1), (.question, 2), (.background, 1)] {
            status.configure(kind)
            status.layoutSubtreeIfNeeded()
            let layers = try #require(status.layer?.sublayers)
            func animations() -> [CAAnimation] {
                layers.compactMap { $0.animation(forKey: SidebarStatusAnimationView.animationKey) }
            }
            #expect(animations().count == count)
            #expect(animations().allSatisfy { $0.repeatCount == .infinity })
            status.isHidden = true
            #expect(animations().isEmpty)
            status.isHidden = false
            #expect(animations().count == count)
        }
        status.removeFromSuperview()
        #expect(status.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true)
        #expect(!window.isVisible)
    }

    @Test(arguments: [false, true])
    func productionDecorationsHonorReduceMotion(reduceMotion: Bool) throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let petID = try installSyntheticPet(in: stores)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HStack {
            SidebarPetView(store: stores.pets, petID: petID, state: .idle)
            SidebarStateBadge(visual: SidebarPresentation.state(.working))
            SidebarStateBadge(visual: SidebarPresentation.state(.blocked), needsInput: true)
        }.background(SidebarActivityBackground(visual: SidebarPresentation.state(.blocked), needsInput: true))
            .environment(\._accessibilityReduceMotion, reduceMotion))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let views = descendants(host)
        #expect(views.compactMap { $0 as? SidebarPetAnimationView }.count == (reduceMotion ? 0 : 1))
        #expect(views.compactMap { $0 as? SidebarStatusAnimationView }.count == (reduceMotion ? 0 : 3))
    }

    @Test func titleIdealSizeRetainsTheLabelWidth() {
        let button = SidebarTitleNativeButton()
        button.labelContent = AnyView(Text("Activity").frame(width: 64, height: 28))
        #expect(button.measure(width: nil) == CGSize(width: 64, height: 28))
        #expect(button.measure(width: .infinity) == CGSize(width: 64, height: 28))
    }

    @MainActor
    private final class IdleLayoutHostingView<Content: View>: NSHostingView<Content> {
        private(set) var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    @Test func repeatedTitleMeasurementDoesNotInvalidateTheMountedLabel() {
        let button = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        button.labelContent = AnyView(Text("Unchanged title").frame(maxWidth: .infinity, alignment: .leading))
        _ = button.measure(width: 200)
        button.layout()
        button.hosting.layoutSubtreeIfNeeded()
        button.hosting.needsLayout = false

        for _ in 0..<20 {
            _ = button.measure(width: 200)
            #expect(!button.hosting.needsLayout, "Measuring unchanged content must not schedule another layout")
        }
        for width: CGFloat? in [80, 320, 0, nil, .infinity] {
            let size = button.measure(width: width)
            #expect(size.width.isFinite && size.height >= 24)
            #expect(button.hosting.frame.width == 200, "Speculative proposals must not resize the mounted label")
            #expect(!button.hosting.needsLayout)
        }
    }

    @Test func titleMeasurementTracksContentAndWrappingWithoutChangingTheMountedFrame() {
        let button = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        button.labelContent = AnyView(Text("Short").fixedSize(horizontal: false, vertical: true))
        let short = button.measure(width: 100)
        button.labelContent = AnyView(
            Text(String(repeating: "Wrapping title ", count: 12)).fixedSize(horizontal: false, vertical: true)
        )
        let narrow = button.measure(width: 100)
        let wide = button.measure(width: 300)
        #expect(narrow.width == 100 && wide.width == 300)
        #expect(narrow.height > short.height && narrow.height > wide.height)
        #expect(button.bounds.size == CGSize(width: 240, height: 24))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func installSyntheticPet(in stores: SidebarStoreFixture) throws -> String {
        let image = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 768, pixelsHigh: 936, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let file = stores.root.appendingPathComponent("synthetic-pet.png")
        try FileManager.default.createDirectory(at: stores.root, withIntermediateDirectories: true)
        try #require(image.representation(using: .png, properties: [:])).write(to: file)
        return try #require(stores.pets.upload(from: file))
    }

    private func withProductionKeyboardSidebar(
        visualActivity: Bool = false,
        animatedPet: Bool = false,
        _ check: @MainActor (NSWindow, NSView, SidebarConnectionModel, SidebarPreferences,
                  SidebarTitleNativeButton, SidebarTitleNativeButton, NSPasteboard) async throws -> Void
    ) async throws {
        let fixture = SidebarTreeFixtures()
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        if animatedPet {
            let petID = try installSyntheticPet(in: stores)
            stores.pets.choose(petID, session: fixture.sessionID)
            stores.pets.choose(petID, session: fixture.otherSessionID)
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let preferences = preferenceFixture.preferences()
        let date = Date()
        let evidence = AgentAttention(kind: visualActivity ? .answer : .turnFinished,
                                      evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: date)
        let observations = [
            CopilotSessionObservation(
                sessionID: fixture.sessionID, surfaceID: fixture.surfaceA, launchWorkspaceID: fixture.workspaceA,
                liveness: .alive, state: .idle, model: "keyboard-model", children: [], observedAt: date,
                attention: [evidence]
            ),
            fixture.session(id: fixture.otherSessionID, surface: fixture.surfaceB,
                            state: visualActivity ? .working : .idle, now: date)
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
        let hosting = IdleLayoutHostingView(rootView: AnyView(SidebarView(model: model, preferences: preferences, stores: stores)
            .environment(\._accessibilityReduceMotion, false)
            .environment(\.sidebarClipboardWrite, { SidebarSessionCopy.copy($0, to: pasteboard) })))
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
            try #require(controls.count == 7 && copyControls.count == 6 && copyControls.first === copy)
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
            .appearance(icon: nil, agent: true, child: true), .placement(.movesWithParentSession), .lifecycle(child: true)
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
        let clock = SidebarManualHoverClock()
        let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in }, schedule: clock.schedule)
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
        #expect(clock.elapse(SidebarHoverPresenter.openDelay) == 0, "Leaving the name must cancel every pending open")
        #expect(clock.pending.isEmpty)
        #expect(presenter.state.mode == .hidden && presenter.panel == nil)
        anchor.mouseEntered(with: event)
        #expect(clock.pending == [SidebarHoverPresenter.openDelay])
        #expect(presenter.state.mode == .hidden, "Hover must wait for the open delay")
        #expect(clock.elapse(SidebarHoverPresenter.openDelay) == 1)
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
        let clock = SidebarManualHoverClock()
        let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in }, schedule: clock.schedule)
        defer { presenter.detach() }
        presenter.update(anchor: anchor, data: .init(
            id: "focus-retained", category: "Agent preview", title: "Synthetic agent",
            lines: [.sessionID(UUID())]
        ), group: nil)
        presenter.hoverAnchor(true)
        presenter.open(explicit: false)
        presenter.hoverAnchor(false)
        presenter.copyActionFocus(true)
        #expect(clock.pending == [SidebarHoverPresenter.closeDelay])
        #expect(clock.elapse(SidebarHoverPresenter.closeDelay) == 1, "The delayed close must run its recheck")
        #expect(presenter.state.mode == .hover)
        #expect(presenter.panel != nil)
        presenter.copyActionFocus(false)
        #expect(clock.pending == [SidebarHoverPresenter.closeDelay])
        #expect(presenter.state.mode == .hover, "Dismissal must wait for the close delay")
        #expect(clock.elapse(SidebarHoverPresenter.closeDelay) == 1)
        #expect(presenter.state.mode == .hidden)
        #expect(presenter.panel?.contentView == nil)
        #expect(!presenter.isMonitoring)
    }

    @Test func leavingOrDetachingCancelsPendingHover() async throws {
        let clock = SidebarManualHoverClock()
        let presenter = SidebarHoverPresenter(schedule: clock.schedule)
        presenter.hoverAnchor(true)
        #expect(clock.pending == [SidebarHoverPresenter.openDelay])
        presenter.hoverAnchor(false)
        #expect(clock.pending.isEmpty)
        #expect(clock.elapse(SidebarHoverPresenter.openDelay) == 0, "Leaving cancels the pending open")
        #expect(presenter.panel == nil && presenter.state.mode == .hidden)
        presenter.hoverAnchor(true)
        #expect(clock.pending == [SidebarHoverPresenter.openDelay])
        presenter.detach()
        #expect(clock.pending.isEmpty)
        #expect(clock.elapse(SidebarHoverPresenter.openDelay) == 0, "Detaching cancels the pending open")
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
        #expect(a.lines.contains(.init(title: "Shared surfaces", value: "1 terminal", copyableValue: "1 terminal")))
        #expect(a.lines.contains(.init(title: "Workspace ID", value: fixtures.workspaceA.uuidString, copyableValue: fixtures.workspaceA.uuidString)))
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
        #expect(ambiguous.lines.contains(.init(title: "Shared surfaces", value: "Unavailable · Placement: Ambiguous")))
        let moved = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(moved: true), connected: true
        ))
        #expect(moved.lines.contains(.init(title: "Shared surfaces", value: "None", copyableValue: "None")))
    }

    @Test func workspacePortsAreLabelledAsCMUXReportedAndWorkspaceWide() throws {
        let fixtures = SidebarTreeFixtures()
        let card = try #require(SidebarHoverContent.workspace(fixtures.workspaceA, hierarchy: fixtures.hierarchy(), connected: true))
        #expect(card.lines.contains(.init(title: "Ports (CMUX, workspace-wide)", value: "Not granted")))
        #expect(SidebarHoverContent.ports(.available([])) == .init(title: "Ports (CMUX, workspace-wide)", value: "None reported"))
        #expect(SidebarHoverContent.ports(.available([3000, 5173]))
            == .init(title: "Ports (CMUX, workspace-wide)", value: "3000, 5173", copyableValue: "3000, 5173"))
    }

    @Test func passiveComponentsHaveNoNavigationOrPreferenceMutationDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarHoverCard.swift"), encoding: .utf8)
        for forbidden in ["SidebarNavigation", "SidebarPreferences", "SidebarSeen", "UserDefaults", "context.host", "markSeen", "acknowledge"] {
            #expect(!source.contains(forbidden))
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        defer { window.contentView = nil; window.close() }
        let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
        defer { presenter.detach() }
        presenter.update(anchor: anchor, data: .init(id: "passive", category: "Workspace", title: "Synthetic"), group: nil)
        for explicit in [false, true] {
            presenter.open(explicit: explicit)
            let panel = try #require(presenter.panel)
            #expect(panel.styleMask.contains(.nonactivatingPanel), "Previews never activate the app")
            #expect(!panel.canBecomeMain)
            #expect(panel.canBecomeKey == explicit, "Only an explicit preview may take keyboard focus")
            presenter.dismiss(restoreFocus: false)
        }
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
            let text = try SidebarRenderingEvidence.recognizedLines(in: image, dark: dark, naturalLanguage: true)
            #expect(text.contains("Maestro design"), "OCR: \(text)")
            // The leading shortcut glyph OCRs inconsistently; the reminder wording must end its line.
            #expect(text.contains { $0.hasSuffix(" to rename") }, "OCR: \(text)")
        }
        #expect(preferences.history == before.0 && preferences.attention == before.1)
        #expect(preferences.layout == before.2 && preferences.icons == before.3)
    }
}

/// Hover open/close delays advance only when a test elapses them. Elapsing runs each due, uncancelled
/// action synchronously, so a returned count means every recheck has completed; nothing depends on
/// executor scheduling order.
@MainActor
final class SidebarManualHoverClock {
    private struct Entry {
        let duration: Duration
        let task: Task<Void, Never>
        let action: @MainActor () -> Void
    }
    private var entries: [Entry] = []
    var pending: [Duration] { entries.filter { !$0.task.isCancelled }.map(\.duration) }

    func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        // The handle only carries the presenter's cancellation; it suspends until cancelled.
        let task = Task<Void, Never> { _ = try? await sidebarFrozenExpiry(0) }
        entries.append(Entry(duration: delay, task: task, action: action))
        return task
    }

    @discardableResult
    func elapse(_ duration: Duration) -> Int {
        let due = entries.filter { $0.duration <= duration }
        entries.removeAll { $0.duration <= duration }
        var ran = 0
        for entry in due {
            if !entry.task.isCancelled {
                entry.action()
                ran += 1
            }
            entry.task.cancel()
        }
        return ran
    }
}
