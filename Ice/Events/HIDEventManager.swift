//
//  HIDEventManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Manager that monitors input events and implements the features
/// that are triggered by them, such as showing hidden items on
/// click/hover/scroll.
@MainActor
final class HIDEventManager: ObservableObject {
    /// A Boolean value that indicates whether the user is dragging
    /// a menu bar item.
    @Published private(set) var isDraggingMenuBarItem = false

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// History of the manager's enabled states.
    private var enabledStateStack = [Bool]()

    /// The last empty menu bar spot hovered on each display (see `ItemClicker27`).
    private var lastEmptyMenuBarPoints = [CGDirectDisplayID: CGPoint]()

    /// Until when the release of a held-back click is held back as well (see
    /// `handleSystemItemClick27`). The deadline keeps a release that never comes from
    /// swallowing an unrelated one later.
    private var heldBackReleaseUntil: ContinuousClock.Instant?

    /// Where the last left mouse button press landed, in Core Graphics coordinates. A drag
    /// is reported only once the pointer has moved, so this is the point the item was taken by.
    private var leftMouseDownLocation: CGPoint?

    /// The application item a Command-drag on the macOS 27 bar picked up, once it is known
    /// (see `beginMenuBarItemDrag27`).
    private var menuBarItemDragPick27: Task<PickedMenuBarItem27?, Never>?

    /// Whether ``systemItemClickTap`` is running (see `updateSystemItemClickTap`).
    private var isSystemItemClickTapRunning = false

    /// Whether ``mouseMovedTap`` is running (see `updateMouseMovedTap`).
    private var isMouseMovedTapRunning = false

    /// The pending show or hide from hovering, and whether it shows. One at a time, so the
    /// moves within the delay do not each start their own.
    private var showOnHoverTask: (task: Task<Void, Never>, shows: Bool)?

    /// The display whose menu bar the last mouse move was inside, if any.
    private var menuBarUnderMouse: CGDirectDisplayID?

    /// The stretch of each display's bar the application menus occupy on macOS 27, worked out
    /// whenever the menus are read (see `refreshApplicationMenus27`).
    private var applicationMenuAreas27 = [CGDirectDisplayID: CGRect]()

    /// Whether the application menus are being read, and whether to read them again after.
    private var isReadingApplicationMenus27 = false
    private var needsApplicationMenuReread27 = false

    /// A second read shortly after the owner changes, for menus the application builds late.
    private var applicationMenuRereadTask27: Task<Void, Never>?

    /// How far an application's menus reached on a display, the last time it was the active one
    /// there. Each display draws the menus of whatever is frontmost on it, and Accessibility
    /// describes only the active display's, so this is the one exact measurement to be had of
    /// the others (measured on macOS 27.0: asked about any display, Accessibility answers with
    /// the active one's menu bar, in its coordinates).
    ///
    /// Kept for this run only: the menus are read at every activation, so it fills as the user
    /// goes round the displays, and display identifiers do not stay put across launches.
    private var menuReachByDisplay27 = [CGDirectDisplayID: [String: CGFloat]]()

    /// Which application last owned the menu bar of each display.
    ///
    /// A display that is not the active one goes on drawing the menus of the application that was
    /// last active on it, which is not the same as whatever window happens to lie topmost there —
    /// measured 2026-10-08, where the topmost window on the external display belonged to one
    /// application and its bar was drawing another's menus.
    private var menuOwnerByDisplay27 = [CGDirectDisplayID: String]()

    /// A Boolean value that indicates whether the manager is enabled.
    private var isEnabled = false {
        didSet {
            if isEnabled {
                for monitor in allMonitors {
                    monitor.start()
                }
            } else {
                for monitor in allMonitors {
                    monitor.stop()
                }
            }
            updateMouseMovedTap()
            if #available(macOS 27.0, *) {
                updateSystemItemClickTap()
            }
        }
    }

    // MARK: Monitors

    /// Monitor for mouse down events.
    private(set) lazy var mouseDownMonitor = EventMonitor.universal(
        for: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
        guard let self, isEnabled, let appState, let screen = bestScreen(appState: appState) else {
            return event
        }
        // Ice's own click that makes a display's menu bar active (see `ItemClicker27`).
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == HIDEventManager.menuBarActivationMarker {
            return event
        }
        switch event.type {
        case .leftMouseDown:
            leftMouseDownLocation = MouseHelpers.locationCoreGraphics
            handleShowOnClick(appState: appState, screen: screen)
            handleSmartRehide(with: event, appState: appState, screen: screen)
        case .rightMouseDown:
            handleSecondaryContextMenu(appState: appState, screen: screen)
        default:
            return event
        }
        handlePreventShowOnHover(with: event, appState: appState, screen: screen)
        return event
    }

    /// Monitor for mouse up events.
    private(set) lazy var mouseUpMonitor = EventMonitor.universal(
        for: .leftMouseUp
    ) { [weak self] event in
        guard let self, isEnabled else {
            return event
        }
        handleMenuBarItemDragStop()
        return event
    }

    /// Monitor for mouse dragged events.
    private(set) lazy var mouseDraggedMonitor = EventMonitor.universal(
        for: .leftMouseDragged
    ) { [weak self] event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleMenuBarItemDragStart(with: event, appState: appState, screen: screen)
        }
        return event
    }

    /// Tap for mouse moved events, running only while show-on-hover is on (see
    /// `updateMouseMovedTap`).
    private(set) lazy var mouseMovedTap = EventTap(
        type: .mouseMoved,
        location: .hidEventTap,
        placement: .tailAppendEventTap,
        option: .listenOnly
    ) { [weak self] _, event in
        let location = MouseLocation(event)
        if let self, isEnabled, let appState, let screen = bestScreen(for: location) {
            if #available(macOS 27.0, *) {
                let menuBar = isMouseInsideMenuBar(appState: appState, screen: screen, at: location) ? screen.displayID : nil
                if let menuBar, menuBar != menuBarUnderMouse {
                    // Catches menus that changed without the application being activated again.
                    refreshApplicationMenus27()
                }
                menuBarUnderMouse = menuBar
            }
            handleShowOnHover(appState: appState, screen: screen, at: location)
        }
        return event
    }

    /// Monitor for scroll wheel events.
    private(set) lazy var scrollWheelMonitor = EventMonitor.universal(
        for: .scrollWheel
    ) { [weak self] event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleShowOnScroll(with: event, appState: appState, screen: screen)
        }
        return event
    }

    /// Tap that lets clicks reach the system items while items are concealed on macOS 27.
    ///
    /// While an assessment-mode assertion is live, MenuBarAgent ignores clicks on the
    /// clock (measured on macOS 27.0). The tap holds such a click back, releases the
    /// assertions for a moment, and replays the click. It runs only while that is so
    /// (see `updateSystemItemClickTap`).
    private(set) lazy var systemItemClickTap = EventTap(
        types: [.leftMouseDown, .leftMouseUp],
        location: .hidEventTap,
        placement: .headInsertEventTap,
        option: .defaultTap
    ) { [weak self] _, event in
        guard let self, isEnabled, let appState else {
            return event
        }
        if #available(macOS 27.0, *) {
            return handleSystemItemClick27(event, appState: appState)
        }
        return event
    }

    // MARK: All Monitors

    /// The monitors that run whenever the manager is enabled.
    private lazy var allMonitors: [any EventMonitorProtocol] = [
        mouseDownMonitor,
        mouseUpMonitor,
        mouseDraggedMonitor,
        scrollWheelMonitor,
    ]

    // MARK: Setup

    /// Sets up the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        startAll()
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState, let hiddenSection = appState.menuBarManager.section(withName: .hidden) {
            // In fullscreen mode, the menu bar slides down from the top on hover. Observe the
            // frame of the hidden section's control item, which we know will always be in the
            // menu bar, and run the show-on-hover check when it changes.
            Publishers.CombineLatest3(
                hiddenSection.controlItem.$frame,
                appState.$activeSpace.map(\.isFullscreen),
                appState.menuBarManager.$isMenuBarHiddenBySystem
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _, isFullscreen, isMenuBarHiddenBySystem in
                guard let self, isEnabled, let appState, isFullscreen || isMenuBarHiddenBySystem else {
                    return
                }
                if let screen = bestScreen(appState: appState) {
                    handleShowOnHover(appState: appState, screen: screen)
                }
            }
            .store(in: &c)
        }

        appState?.settings.general.$showOnHover
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateMouseMovedTap()
                }
            }
            .store(in: &c)

        if #available(macOS 27.0, *), let appState {
            // The menus are read when they change hands, and when the active display changes,
            // rather than on every mouse move (see `refreshApplicationMenus27`).
            NSWorkspace.shared.publisher(for: \.menuBarOwningApplication)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.applicationMenuOwnerDidChange27()
                    }
                }
                .store(in: &c)
            Publishers.Merge(
                appState.$activeSpace.map { _ in () },
                NotificationCenter.default
                    .publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .map { _ in () }
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.refreshApplicationMenus27()
                }
            }
            .store(in: &c)
        }

        if #available(macOS 27.0, *), let concealer = appState?.concealer27 {
            // The backend is set by the same `update` that publishes `isConcealing`.
            concealer.$isConcealing
                .combineLatest(concealer.$isSuspended)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateSystemItemClickTap()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Runs ``mouseMovedTap`` only while show-on-hover is on, which is all it serves.
    private func updateMouseMovedTap() {
        let shouldRun = isEnabled && appState?.settings.general.showOnHover == true
        if !shouldRun {
            showOnHoverTask?.task.cancel()
            showOnHoverTask = nil
            menuBarUnderMouse = nil
        }
        guard shouldRun != isMouseMovedTapRunning else {
            return
        }
        isMouseMovedTapRunning = shouldRun
        if shouldRun {
            mouseMovedTap.start()
        } else {
            mouseMovedTap.stop()
        }
    }

    /// Runs ``systemItemClickTap`` only while assessment mode conceals something.
    ///
    /// The tap is an active filter at the head of the HID stream, so while it runs every click
    /// on the system waits on Ice's main thread. With the native switch it has nothing to do.
    @available(macOS 27.0, *)
    private func updateSystemItemClickTap() {
        guard let appState else {
            return
        }
        let concealer = appState.concealer27
        // A lift lasts while the replayed click goes through, so it keeps the tap.
        var isNeeded = concealer.needsClickLift && (concealer.isConcealing || concealer.isSuspended)
        if !isNeeded, let until = heldBackReleaseUntil, ContinuousClock.now < until {
            // The release of a click already held back must still be swallowed.
            isNeeded = true
            Task { [weak self] in
                try? await Task.sleep(until: until, clock: .continuous)
                self?.updateSystemItemClickTap()
            }
        }
        let shouldRun = isEnabled && isNeeded
        guard shouldRun != isSystemItemClickTapRunning else {
            return
        }
        isSystemItemClickTapRunning = shouldRun
        if shouldRun {
            systemItemClickTap.start()
        } else {
            systemItemClickTap.stop()
        }
    }

    // MARK: Start/Stop

    /// Starts all monitors.
    func startAll() {
        isEnabled = enabledStateStack.popLast() ?? true
    }

    /// Stops all monitors.
    func stopAll() {
        enabledStateStack.append(isEnabled)
        isEnabled = false
    }
}

// MARK: - Handler Methods

extension HIDEventManager {

    // MARK: Handle Show On Click

    private func handleShowOnClick(appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnClick,
            isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen)
        else {
            return
        }

        Task {
            if NSEvent.modifierFlags == .control {
                handleSecondaryContextMenu(appState: appState, screen: screen)
                return
            }

            let targetSection: MenuBarSection

            if
                NSEvent.modifierFlags == .option,
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden),
                alwaysHiddenSection.isEnabled
            {
                targetSection = alwaysHiddenSection
            } else if
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                hiddenSection.isEnabled
            {
                targetSection = hiddenSection
            } else {
                return
            }

            targetSection.toggle()
        }
    }

    // MARK: Handle Smart Rehide

    private func handleSmartRehide(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.autoRehide,
            case .smart = appState.settings.general.rehideStrategy
        else {
            return
        }

        // Make sure clicking the Ice icon doesn't trigger rehide.
        if let iceIcon = appState.menuBarManager.controlItem(withName: .visible) {
            guard event.window !== iceIcon.window else {
                return
            }
        }

        // Only continue if the click is not inside the Ice Bar, at
        // least one section is visible, and the mouse is not inside
        // the menu bar.
        guard
            event.window !== appState.menuBarManager.iceBarPanel,
            appState.menuBarManager.hasVisibleSection,
            !isMouseInsideMenuBar(appState: appState, screen: screen)
        else {
            return
        }

        let initialSpaceID = Bridging.getActiveSpaceID()

        Task {
            // Give the window under the mouse a chance to focus.
            try await Task.sleep(for: .milliseconds(250))

            // Don't bother checking the window if the click caused
            // a space change.
            if Bridging.getActiveSpaceID() != initialSpaceID {
                for section in appState.menuBarManager.sections {
                    section.hide()
                }
                return
            }

            // Get the window that was clicked.
            guard
                let mouseLocation = MouseHelpers.locationCoreGraphics,
                let windowUnderMouse = WindowInfo.createWindows(option: .onScreen)
                    .filter({ $0.layer < CGWindowLevelForKey(.cursorWindow) })
                    .first(where: { $0.bounds.contains(mouseLocation) && $0.title?.isEmpty == false }),
                let owningApplication = windowUnderMouse.owningApplication
            else {
                return
            }

            // Note: The Dock is an exception to the following check.
            if owningApplication.bundleIdentifier != "com.apple.dock" {
                // Only continue if the clicked app is active, and has
                // a regular activation policy.
                guard
                    owningApplication.isActive,
                    owningApplication.activationPolicy == .regular
                else {
                    return
                }
            }

            // All checks have passed, hide the sections.
            for section in appState.menuBarManager.sections {
                section.hide()
            }
        }
    }

    // MARK: Handle Secondary Context Menu

    private func handleSecondaryContextMenu(appState: AppState, screen: NSScreen) {
        Task {
            guard
                appState.settings.advanced.enableSecondaryContextMenu,
                isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen),
                let mouseLocation = MouseHelpers.locationAppKit
            else {
                return
            }
            // Delay prevents the menu from immediately closing.
            try await Task.sleep(for: .milliseconds(100))
            appState.menuBarManager.showSecondaryContextMenu(at: mouseLocation)
        }
    }

    // MARK: Handle Menu Bar Item Drag Stop

    private func handleMenuBarItemDragStop() {
        guard isDraggingMenuBarItem else {
            return
        }
        isDraggingMenuBarItem = false
        if #available(macOS 27.0, *), let appState {
            resolveMenuBarItemDrop27(appState: appState)
        }
    }

    // MARK: Handle Menu Bar Item Drag Start

    private func handleMenuBarItemDragStart(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            !isDraggingMenuBarItem,
            event.modifierFlags.contains(.command),
            isMouseInsideMenuBar(appState: appState, screen: screen)
        else {
            return
        }

        isDraggingMenuBarItem = true

        if #available(macOS 27.0, *) {
            // Before the reveal, which moves the items under the point the drag began at.
            beginMenuBarItemDrag27(appState: appState)
        }

        if appState.settings.advanced.showAllSectionsOnUserDrag {
            for section in appState.menuBarManager.sections {
                section.controlItem.state = .showSection
            }
            if #available(macOS 27.0, *) {
                // On macOS 27 the sections are drawn by the concealer, not by Ice's dividers,
                // and setting the control items' state directly does not reach it.
                appState.concealer27.update()
            }
        }
    }

    // MARK: Handle Menu Bar Item Drags (macOS 27)

    /// An application item picked up by a Command-drag on the bar.
    struct PickedMenuBarItem27 {
        let bundleID: String
        /// Where the item was when the drag began, to tell a drop back in place.
        let frame: CGRect?
    }

    /// Logs what a drag on the bar did to the layout.
    private static let dragLogger = Logger(subsystem: "com.jordanbaird.Ice", category: "ItemDrag27")

    /// Learns which application's item a Command-drag on the bar has picked up.
    ///
    /// macOS 27 keeps its own order: Command-drags reorder items on the bar and MenuBarAgent
    /// persists the order itself (measured on macOS 27.0.1, 2026-10-23). Ice does not follow the
    /// item, it only needs to know whose it is, so that the drop can say which section the user
    /// meant (see ``resolveMenuBarItemDrop27(appState:)``). The point is the one the button went
    /// down at, tested against the frames Ice cached for the drawn items; only when none of them
    /// is under it is the bar read again. Ice's own control items and MenuBarAgent's system items
    /// are never picked: neither belongs to a section.
    @available(macOS 27.0, *)
    private func beginMenuBarItemDrag27(appState: AppState) {
        guard let point = leftMouseDownLocation ?? MouseHelpers.locationCoreGraphics else {
            menuBarItemDragPick27 = nil
            return
        }
        let concealer = appState.concealer27
        let displayBounds = Self.displayBounds27(containing: point)
        let cached = Self.applicationItems27(
            appState.itemManager.itemCache.managedItems,
            concealedPIDs: concealer.concealedPIDs,
            displayBounds: displayBounds
        )
        if let hit = Self.applicationItem27(at: point, in: cached) {
            menuBarItemDragPick27 = Task { PickedMenuBarItem27(bundleID: hit.bundleID, frame: hit.frame) }
            return
        }
        // Read before the reveal begins, which moves the items under the point.
        let pick = Task { () -> PickedMenuBarItem27? in
            let fresh = Self.applicationItems27(
                await MenuBarItemProvider27.items(),
                concealedPIDs: concealer.concealedPIDs,
                displayBounds: displayBounds
            )
            return Self.applicationItem27(at: point, in: fresh).map { PickedMenuBarItem27(bundleID: $0.bundleID, frame: $0.frame) }
        }
        menuBarItemDragPick27 = pick
    }

    /// Reads where a Command-dragged item came to rest and moves its application to the section
    /// it was dropped into.
    ///
    /// Before macOS 27 dragging an item past Ice's divider was the way to hide it, and users still
    /// reach for it. On 27 the order is MenuBarAgent's (see ``beginMenuBarItemDrag27(appState:)``),
    /// so Ice leaves it alone and reads the drop only to learn the section: once the bar has settled
    /// it reads the items again, finds the dragged application's item nearest the drop, and judges it
    /// against the runs of items the saved layout puts in each section (see `DropSection27`).
    ///
    /// The bar is held as revealed as it was at the drop until the section is saved, so a rehide in
    /// the meantime neither takes the run away before it is read nor hides the old layout: it lands
    /// after the change, on the new one.
    @available(macOS 27.0, *)
    private func resolveMenuBarItemDrop27(appState: AppState) {
        let leftMouseDownLocation = leftMouseDownLocation
        self.leftMouseDownLocation = nil
        guard
            let pick = menuBarItemDragPick27,
            let dropPoint = MouseHelpers.locationCoreGraphics
        else {
            menuBarItemDragPick27 = nil
            return
        }
        menuBarItemDragPick27 = nil
        let concealer = appState.concealer27
        concealer.holdReveal()
        let hiddenRevealed = concealer.currentRevealState != .allHidden
        Task {
            defer {
                concealer.releaseRevealHold()
            }
            guard let picked = await pick.value else {
                return
            }
            // The item lands once MenuBarAgent has finished moving the bar, after any reveal.
            try? await Task.sleep(for: (concealer.timeUntilSettled() ?? .zero) + .milliseconds(150))
            let displayBounds = Self.displayBounds27(containing: dropPoint)
            let items = Self.applicationItems27(
                await MenuBarItemProvider27.items(),
                concealedPIDs: concealer.concealedPIDs,
                displayBounds: displayBounds
            )
            let layout = concealer.savedLayout
            var runs = DropSection27.Runs()
            var ownFrames = [CGRect]()
            for item in items {
                if item.bundleID == picked.bundleID {
                    ownFrames.append(item.frame)
                    continue
                }
                switch layout[item.bundleID] ?? .visible {
                case .visible: runs.visible.append(item.frame)
                case .hidden: runs.hidden.append(item.frame)
                case .alwaysHidden: runs.alwaysHidden.append(item.frame)
                }
            }
            let current = layout[picked.bundleID] ?? .visible
            let dropped = DropSection27.nearest(to: dropPoint, in: ownFrames)
            guard let section = DropSection27.section(
                dropped: dropped,
                picked: picked.frame,
                runs: runs,
                current: current,
                hiddenRevealed: hiddenRevealed
            ) else {
                Self.dragLogger.debug("""
                    Drop of \(picked.bundleID, privacy: .public) leaves it \(String(describing: current), privacy: .public) \
                    (found: \(dropped != nil, privacy: .public), hidden revealed: \(hiddenRevealed, privacy: .public), \
                    taken at \(String(describing: leftMouseDownLocation), privacy: .public))
                    """)
                return
            }
            Self.dragLogger.notice("""
                Drop moves \(picked.bundleID, privacy: .public) from \(String(describing: current), privacy: .public) \
                to \(String(describing: section), privacy: .public)
                """)
            concealer.setSection(section, for: picked.bundleID)
        }
    }

    /// The bounds of the display holding the given point, in Core Graphics coordinates.
    @available(macOS 27.0, *)
    private static func displayBounds27(containing point: CGPoint) -> CGRect? {
        NSScreen.screens
            .map { CGDisplayBounds($0.displayID) }
            .first { $0.contains(point) }
    }

    /// The drawn items that belong to an application with a section, with its bundle identifier.
    ///
    /// Ice's own control items and MenuBarAgent's system items are left out, as are items of
    /// concealed applications, whose frames Accessibility keeps where they were last drawn.
    @available(macOS 27.0, *)
    private static func applicationItems27(
        _ items: [MenuBarItem],
        concealedPIDs: Set<pid_t>,
        displayBounds: CGRect?
    ) -> [(bundleID: String, frame: CGRect)] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return items.compactMap { item in
            guard
                item.isOnScreen,
                item.ownerPID != ownPID,
                !item.isControlItem,
                !concealedPIDs.contains(item.ownerPID),
                item.bounds.width > 4,
                displayBounds?.intersects(item.bounds) ?? true,
                let bundleID = item.sourceApplication?.bundleIdentifier,
                bundleID != MenuBarItemProvider27.menuBarAgentBundleID
            else {
                return nil
            }
            return (bundleID, item.bounds)
        }
    }

    /// The item under the given point, judged along the bar alone: the pointer is in the menu bar
    /// whenever a drag there begins, and Accessibility frames can sit a point off its height.
    @available(macOS 27.0, *)
    private static func applicationItem27(
        at point: CGPoint,
        in items: [(bundleID: String, frame: CGRect)]
    ) -> (bundleID: String, frame: CGRect)? {
        items.first { $0.frame.minX <= point.x && point.x <= $0.frame.maxX }
    }

    // MARK: Handle System Item Clicks (macOS 27)

    /// Marks the clicks Ice replays, so the tap lets them through.
    private static let replayedClickMarker: Int64 = 0x1CE_27_C1C

    /// Times the steps of a bridged click, which happen on both opening and closing a panel.
    private static let bridgeLogger = Logger(subsystem: "com.jordanbaird.Ice", category: "ClickBridge27")

    /// Marks Ice's click that makes a display's menu bar active before an item is pressed.
    static let menuBarActivationMarker: Int64 = 0x1CE_27_BA2

    /// The last empty menu bar spot hovered on the given display.
    func lastEmptyMenuBarPoint(for displayID: CGDirectDisplayID) -> CGPoint? {
        lastEmptyMenuBarPoints[displayID]
    }

    /// System items that do not open from an Accessibility press, so a click on them has to
    /// go through MenuBarAgent. Seeded with what was measured on macOS 27.0; anything else
    /// that turns out to ignore the press joins them at its first click.
    private nonisolated(unsafe) static var systemItemsIgnoringPress: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.battery",
        "com.apple.menuextra.wifi",
    ]

    /// The system item whose panel Ice last opened, so a second click on the same item is
    /// understood as the click that dismisses it.
    private nonisolated(unsafe) static var itemShowingPanel: String?

    @available(macOS 27.0, *)
    private func handleSystemItemClick27(_ event: CGEvent, appState: AppState) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.replayedClickMarker else {
            return event
        }
        if event.type == .leftMouseUp {
            // A press Ice holds back has its release held back with it. MenuBarAgent would
            // otherwise be handed a release with no press behind it, moments before the
            // replayed click that carries both.
            guard let until = heldBackReleaseUntil, ContinuousClock.now < until else {
                heldBackReleaseUntil = nil
                return event
            }
            heldBackReleaseUntil = nil
            return nil
        }
        let concealer = appState.concealer27
        // With the native switch the system items keep taking their clicks while applications
        // are hidden (measured on macOS 27.0.1, 2026-10-22), so there is nothing to bridge.
        guard concealer.needsClickLift else {
            return event
        }
        // The frames of the display the click landed on, so the clock of the display whose bar
        // is not active is recognised as well.
        let clickedDisplay = NSScreen.screens.first { CGDisplayBounds($0.displayID).contains(event.location) }?.displayID
        let framesOnDisplay = clickedDisplay.map { MenuBarItemProvider27.systemItemFrames(for: $0) } ?? []
        guard ClockBridgeZone27.shouldBridge(
            click: event.location,
            systemItemFrames: framesOnDisplay.isEmpty ? MenuBarItemProvider27.systemItemFrames() : framesOnDisplay,
            isConcealing: concealer.isConcealing
        ) else {
            return event
        }
        let location = event.location
        // Control Centre opens from an Accessibility press even while items are concealed
        // (measured on macOS 27.0: its panel appears after about 177 ms). The clock, the
        // battery and Wi-Fi ignore the press, so for those the concealment is lifted and the
        // click replayed — and put back the moment their panel is up, rather than after a
        // fixed second and a half, which is what made every hidden item flash into view.
        let systemItem = MenuBarItemProvider27.systemItem(at: location)
        let mayOpenFromPress = systemItem.map { !Self.systemItemsIgnoringPress.contains($0.identifier) } ?? false
        Task {
            // A click that lands while a panel is up is the click that dismisses it, and
            // Escape dismisses it just as well — with no lift of concealment at all. Lifting
            // for such a click brought every hidden item back on screen first, and the panel
            // only answered once MenuBarAgent had finished moving the bar: the icons appeared,
            // and the panel closed late behind them.
            // A banner shows in the same window as the panel — same process, same level, the
            // size of the display (measured on macOS 27.0) — so the window alone cannot say
            // whether a panel is open, and a click that arrived while a banner happened to be
            // up was answered with Escape, dismissing the banner instead of opening the panel.
            // A click is treated as dismissing a panel only when Ice opened one itself and its
            // window is still there; a panel opened some other way is closed by the replayed
            // click, as it would be without Ice.
            if Self.itemShowingPanel != nil, ItemClick27.openPanelWindow(windows: Self.windowsForPanelCheck()) != nil {
                Self.postEscape()
                Self.bridgeLogger.debug("Click bridge: a panel was open, dismissed with Escape")
                guard systemItem?.identifier != Self.itemShowingPanel else {
                    Self.itemShowingPanel = nil
                    return
                }
                // A different system item was clicked, so its own panel still has to open.
                try? await Task.sleep(for: Self.panelDismissWait)
            }
            if mayOpenFromPress, let systemItem {
                let baseline = Self.windowNumbers()
                await Self.press(systemItem.element)
                if await Self.waitForPanel(baseline: baseline, pollsOf50ms: 5) {
                    // Remembered here as well, or the next click on this item would dismiss
                    // its panel and open it again in the same breath.
                    Self.itemShowingPanel = systemItem.identifier
                    return
                }
                // Waiting for a panel that never comes only delays the click, so an item
                // that ignored the press is not asked again while Ice runs.
                Self.systemItemsIgnoringPress.insert(systemItem.identifier)
            }
            // The click is replayed the moment the assertion is really gone rather than on a
            // timer: releasing it queues behind other concealment work, and MenuBarAgent ignores
            // a click that arrives while the assertion still stands, which is why the clock
            // sometimes did nothing and opened on the second try. Nothing else is done before
            // the replay, so the click is as quick as the release allows.
            let bridgeStarted = ProcessInfo.processInfo.systemUptime
            Self.bridgeLogger.debug("Click bridge: holding the click, lifting concealment")
            await concealer.suspendReleased(for: Self.clickRestoreDelay)
            let released = (ProcessInfo.processInfo.systemUptime - bridgeStarted) * 1000
            Self.replayClick(at: location)
            Self.itemShowingPanel = systemItem?.identifier
            Self.bridgeLogger.debug("Click bridge: lifted in \(released, privacy: .public) ms, click replayed")
        }
        heldBackReleaseUntil = .now + .seconds(1)
        return nil
    }

    /// How long concealment stays lifted around a replayed click.
    ///
    /// MenuBarAgent needs the lift to act on the click at all, and every millisecond of it is
    /// a millisecond of the bar moving: the items slide back in, then out again. The panel's
    /// own window appears about 166 ms after the click (measured on macOS 27.0), so a lift
    /// that ends around then has the bar settling while the panel animates, which is what made
    /// the animation stutter.
    ///
    /// Measured on macOS 27.0 with `Scripts/macos27/clock-restore.swift`, on both displays: a
    /// lift of 40 ms loses the click 6 times in 16, 60 ms once in 16, and 80, 100 and 120 ms
    /// each opened the panel 16 times in 16. So the floor is around 60 ms, and 120 ms keeps
    /// double that margin while still ending before the panel appears. The
    /// `MacOS27ClickRestoreDelay` default overrides it, in milliseconds, for measuring.
    private static var clickRestoreDelay: Duration {
        let stored = Defaults.integer(forKey: .macOS27ClickRestoreDelay)
        return .milliseconds(stored > 0 ? min(max(stored, 30), 2000) : 120)
    }



    /// The window numbers currently on screen.
    private static func windowNumbers() -> Set<Int> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    /// The processes that draw the system items' panels.
    ///
    /// Without this, the Dock passes for an open panel: its window stands at layer 20 and the
    /// full size of the display, and it is always there, so every click looked like a click
    /// that closes a panel and every wait for that panel to go ran into its timeout (measured
    /// on macOS 27.0: 12 clicks in a row judged "panel already open").
    private static let panelOwnerBundleIDs: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
    ]

    /// The windows on screen that could be a system item's panel, as `ItemClick27` wants them.
    private static func windowsForPanelCheck() -> [(number: Int, layer: Int, height: CGFloat)] {
        let owners = Set(
            NSWorkspace.shared.runningApplications
                .filter { panelOwnerBundleIDs.contains($0.bundleIdentifier ?? "") }
                .map(\.processIdentifier)
        )
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard
                let number = window[kCGWindowNumber as String] as? Int,
                let layer = window[kCGWindowLayer as String] as? Int,
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                owners.contains(ownerPID),
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let height = bounds["Height"]
            else {
                return nil
            }
            return (number: number, layer: layer, height: height)
        }
    }

    /// How long the panel that was open takes to go after Escape, before the item that was
    /// clicked is given its own turn.
    private static let panelDismissWait = Duration.milliseconds(120)

    /// Presses Escape, which dismisses an open system panel.
    ///
    /// Notification Center and Control Centre both answer it while items stay concealed, so a
    /// click that dismisses a panel needs no lift of concealment at all.
    private static func postEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    /// Waits for a system item's panel to appear.
    @available(macOS 27.0, *)
    private static func waitForPanel(baseline: Set<Int>, pollsOf50ms: Int) async -> Bool {
        for _ in 0..<pollsOf50ms {
            try? await Task.sleep(for: .milliseconds(50))
            if ItemClick27.panelOpened(before: baseline, windows: windowsForPanelCheck()) {
                return true
            }
        }
        return false
    }

    /// Presses an Accessibility element off the main thread, which the call can block.
    private static func press(_ element: AXUIElement) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
                continuation.resume()
            }
        }
    }

    private static func replayClick(at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: .left
            ) else {
                continue
            }
            event.setIntegerValueField(.eventSourceUserData, value: replayedClickMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Handle Show On Hover

    private func handleShowOnHover(appState: AppState, screen: NSScreen, at location: MouseLocation? = nil) {
        // Make sure the "ShowOnHover" feature is enabled and allowed.
        guard
            appState.settings.general.showOnHover,
            appState.menuBarManager.showOnHoverAllowed,
            let location = location ?? .current
        else {
            return
        }

        // Only continue if we have a hidden section (we should).
        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }

        if hiddenSection.isHidden {
            guard isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen, at: location) else {
                cancelShowOnHover(shows: true)
                return
            }
            lastEmptyMenuBarPoints[screen.displayID] = location.coreGraphics
            scheduleShowOnHover(shows: true, appState: appState) { [weak self] in
                // Make sure the mouse is still inside.
                guard let self, isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) else {
                    return
                }
                hiddenSection.show()
            }
        } else {
            guard
                !isMouseInsideMenuBar(appState: appState, screen: screen, at: location),
                !isMouseInsideIceBar(appState: appState, at: location)
            else {
                cancelShowOnHover(shows: false)
                return
            }
            scheduleShowOnHover(shows: false, appState: appState) { [weak self] in
                // Make sure the mouse is still outside.
                guard
                    let self,
                    let location = MouseLocation.current,
                    !isMouseInsideMenuBar(appState: appState, screen: screen, at: location),
                    !isMouseInsideIceBar(appState: appState, at: location)
                else {
                    return
                }
                hiddenSection.hide()
            }
        }
    }

    /// Runs the given show or hide once the hover delay has passed, unless one of the same kind
    /// is already waiting, which keeps its place: the delay counts from the first move.
    private func scheduleShowOnHover(shows: Bool, appState: AppState, action: @escaping @MainActor () -> Void) {
        if let pending = showOnHoverTask {
            guard pending.shows != shows else {
                return
            }
            pending.task.cancel()
        }
        let delay = appState.settings.advanced.showOnHoverDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else {
                return
            }
            self?.showOnHoverTask = nil
            action()
        }
        showOnHoverTask = (task, shows)
    }

    /// Drops a waiting show or hide of the given kind, the pointer having left where it applies.
    private func cancelShowOnHover(shows: Bool) {
        guard let pending = showOnHoverTask, pending.shows == shows else {
            return
        }
        pending.task.cancel()
        showOnHoverTask = nil
    }

    // MARK: Handle Prevent Show On Hover

    private func handlePreventShowOnHover(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnHover,
            !appState.settings.general.useIceBar
        else {
            return
        }

        guard
            let location = MouseLocation.current,
            isMouseInsideMenuBar(appState: appState, screen: screen, at: location)
        else {
            return
        }

        if isMouseInsideMenuBarItem(appState: appState, screen: screen, at: location) {
            switch event.type {
            case .leftMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                if isMouseInsideIceIcon(appState: appState) {
                    break
                }
                return
            case .rightMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                return
            default:
                return
            }
        } else if isMouseInsideApplicationMenu(appState: appState, screen: screen, at: location) {
            return
        }

        // Mouse is inside the menu bar, outside an item or application
        // menu, so it must be inside an empty menu bar space.
        appState.menuBarManager.showOnHoverAllowed = false
    }

    // MARK: Handle Show On Scroll

    private func handleShowOnScroll(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnScroll,
            isMouseInsideMenuBar(appState: appState, screen: screen),
            let hiddenSection = appState.menuBarManager.section(withName: .hidden)
        else {
            return
        }

        let averageDelta = (event.scrollingDeltaX + event.scrollingDeltaY) / 2

        if averageDelta > 5 {
            hiddenSection.show()
        } else if averageDelta < -5 {
            hiddenSection.hide()
        }
    }
}

// MARK: - Helper Methods

extension HIDEventManager {
    /// Where the pointer is, in both coordinate spaces, read once for a whole hit test.
    struct MouseLocation {
        /// Origin at the top left of the main display.
        let coreGraphics: CGPoint
        /// Origin at the bottom left of the main display.
        let appKit: CGPoint

        init(_ event: CGEvent) {
            coreGraphics = event.location
            appKit = event.unflippedLocation
        }

        /// Where the pointer is right now.
        static var current: MouseLocation? {
            CGEvent(source: nil).map(MouseLocation.init)
        }
    }

    /// Returns the best screen to use for event manager calculations.
    /// Uses the screen under the mouse so menu bar hover/click work correctly
    /// with multiple displays (e.g. external monitor).
    func bestScreen(appState: AppState) -> NSScreen? {
        NSScreen.screenWithMouse ?? NSScreen.main
    }

    /// The screen under the given location, or the main screen.
    private func bestScreen(for location: MouseLocation) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(location.appKit) } ?? NSScreen.main
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the menu bar.
    func isMouseInsideMenuBar(appState: AppState, screen: NSScreen, at location: MouseLocation? = nil) -> Bool {
        guard let mouseLocation = (location ?? .current)?.appKit else {
            return false
        }

        // Ice icon must be vertically visible. Otherwise, we can infer
        // that the menu bar is hidden and the mouse is not inside.
        //
        // On macOS 27 the icon's window is only a placeholder, and its frame says
        // nothing about the menu bar (measured past a display's left edge, below its
        // bottom, and with no height). The visible frame check below remains.
        if #unavailable(macOS 27.0) {
            guard
                let iceIcon = appState.menuBarManager.controlItem(withName: .visible),
                let iceIconFrame = iceIcon.frame,
                iceIconFrame.maxY <= screen.frame.maxY
            else {
                return false
            }
        }

        // Infer the menu bar frame from the screen frame.
        return mouseLocation.x >= screen.frame.minX &&
        mouseLocation.x <= screen.frame.maxX &&
        mouseLocation.y <= screen.frame.maxY &&
        mouseLocation.y >= screen.visibleFrame.maxY
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the current application menu.
    func isMouseInsideApplicationMenu(appState: AppState, screen: NSScreen, at location: MouseLocation? = nil) -> Bool {
        guard let mouseLocation = (location ?? .current)?.coreGraphics else {
            return false
        }
        if #available(macOS 27.0, *) {
            // Read ahead of time, off the main thread (see `refreshApplicationMenus27`).
            return applicationMenuAreas27[screen.displayID]?.contains(mouseLocation) ?? false
        }
        guard var applicationMenuFrame = screen.getApplicationMenuFrame() else {
            return false
        }
        applicationMenuFrame.size.width += applicationMenuFrame.origin.x - screen.frame.origin.x
        applicationMenuFrame.origin.x = screen.frame.origin.x
        return applicationMenuFrame.contains(mouseLocation)
    }

    // MARK: Application Menus (macOS 27)

    /// How long each Accessibility message of a menu read may take. The menus belong to another
    /// application, which may be busy, and the default wait is about six seconds.
    private nonisolated static let applicationMenuTimeout: Float = 0.25

    private nonisolated static let applicationMenuQueue = DispatchQueue(
        label: "HIDEventManager.applicationMenuQueue",
        qos: .userInitiated
    )

    /// Reads the menus now, and once more shortly after: an application that has just been
    /// activated may not have built them yet.
    @available(macOS 27.0, *)
    private func applicationMenuOwnerDidChange27() {
        refreshApplicationMenus27()
        applicationMenuRereadTask27?.cancel()
        applicationMenuRereadTask27 = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else {
                return
            }
            self?.refreshApplicationMenus27()
        }
    }

    /// Reads the menus of the application that owns the menu bar off the main thread, and works
    /// out from them the stretch of each display's bar they occupy.
    @available(macOS 27.0, *)
    private func refreshApplicationMenus27() {
        guard !isReadingApplicationMenus27 else {
            needsApplicationMenuReread27 = true
            return
        }
        // Ice's own menus are left out, as they always were.
        guard
            let owner = NSWorkspace.shared.menuBarOwningApplication,
            owner.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            applicationMenuAreas27 = [:]
            return
        }
        isReadingApplicationMenus27 = true
        let pid = owner.processIdentifier
        let bundleID = owner.bundleIdentifier
        Self.applicationMenuQueue.async { [weak self] in
            let menuFrame = Self.readApplicationMenuFrame(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.isReadingApplicationMenus27 = false
                    self.updateApplicationMenuAreas27(menuFrame: menuFrame, owner: bundleID)
                    if self.needsApplicationMenuReread27 {
                        self.needsApplicationMenuReread27 = false
                        self.refreshApplicationMenus27()
                    }
                }
            }
        }
    }

    /// The union of the enabled application menus of the given process, as Accessibility reports
    /// them. Gives up at the first message that times out.
    private nonisolated static func readApplicationMenuFrame(pid: pid_t) -> CGRect? {
        var timedOut = false
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, applicationMenuTimeout)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            timedOut = timedOut || result == .cannotComplete
            return result == .success ? value : nil
        }
        guard
            let menuBar = value(AXUIElementCreateApplication(pid), kAXMenuBarAttribute),
            CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
            let children = value(menuBar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] // swiftlint:disable:this force_cast
        else {
            return nil
        }
        var menuFrame = CGRect.null
        for child in children {
            var frame = CGRect.zero
            guard
                value(child, kAXEnabledAttribute) as? Bool == true,
                let frameValue = value(child, "AXFrame"),
                CFGetTypeID(frameValue) == AXValueGetTypeID(),
                AXValueGetValue(frameValue as! AXValue, .cgRect, &frame) // swiftlint:disable:this force_cast
            else {
                if timedOut {
                    return nil
                }
                continue
            }
            menuFrame = menuFrame.union(frame)
        }
        return menuFrame.isNull || menuFrame.width <= 0 ? nil : menuFrame
    }

    /// Works out the menus' stretch of every display's bar from a fresh read of them.
    @available(macOS 27.0, *)
    private func updateApplicationMenuAreas27(menuFrame: CGRect?, owner: String?) {
        guard let menuFrame else {
            applicationMenuAreas27 = [:]
            return
        }
        let screens = NSScreen.screens
        if
            let owner,
            let ownerScreen = screens.first(where: { CGDisplayBounds($0.displayID).intersects(menuFrame) })
        {
            // Measurable right now, so it is remembered for when this display is not the active
            // one and the same application is still frontmost on it.
            let displayID = ownerScreen.displayID
            menuOwnerByDisplay27[displayID] = owner
            menuReachByDisplay27[displayID, default: [:]][owner] = menuFrame.maxX - CGDisplayBounds(displayID).minX
        }
        applicationMenuAreas27 = screens.reduce(into: [:]) { areas, screen in
            areas[screen.displayID] = applicationMenuArea27(menuFrame: menuFrame, screen: screen)
        }
    }

    /// The application frontmost on the given display, by its topmost ordinary window there.
    private static func frontmostApplication(on displayBounds: CGRect) -> String? {
        WindowInfo.createWindows(option: .onScreen)
            .first { $0.layer == 0 && displayBounds.intersects($0.bounds) }?
            .owningApplication?
            .bundleIdentifier
    }

    /// The stretch of the given screen's bar the application menus occupy on macOS 27.
    ///
    /// The menus come from the application that owns the menu bar, so the frame is in its
    /// display's coordinates whichever display is asked about. See `ApplicationMenuArea27`.
    @available(macOS 27.0, *)
    private func applicationMenuArea27(menuFrame: CGRect, screen: NSScreen) -> CGRect {
        let displayBounds = CGDisplayBounds(screen.displayID)
        let ownerScreen = NSScreen.screens.first { CGDisplayBounds($0.displayID).intersects(menuFrame) } ?? screen
        let ownerBounds = CGDisplayBounds(ownerScreen.displayID)
        var rememberedReach: CGFloat?
        if
            ownerScreen != screen,
            // The application whose menus that bar is drawing: the one that last owned the menu
            // bar there, or, until Ice has seen that happen, whatever lies topmost on it.
            let drawing = menuOwnerByDisplay27[screen.displayID] ?? Self.frontmostApplication(on: displayBounds)
        {
            rememberedReach = ApplicationMenuArea27.reach(
                onThisDisplay: menuReachByDisplay27[screen.displayID]?[drawing],
                onOtherDisplays: menuReachByDisplay27
                    .filter { $0.key != screen.displayID }
                    .compactMap { $0.value[drawing] }
            )
        }
        // A notch on the owning display sits inside the measurement whenever the menus reach past
        // it, and no other display has it.
        var notchGap: CGFloat = 0
        if
            ownerScreen != screen,
            let left = ownerScreen.auxiliaryTopLeftArea,
            let right = ownerScreen.auxiliaryTopRightArea,
            menuFrame.maxX - ownerBounds.minX > left.width
        {
            notchGap = max(right.minX - left.maxX, 0)
        }
        return ApplicationMenuArea27.area(
            menuFrame: menuFrame,
            ownerDisplay: ownerBounds,
            display: displayBounds,
            barHeight: screen.getMenuBarHeight() ?? menuFrame.height,
            notchGap: notchGap,
            itemsLeftEdge: ownerScreen == screen ? nil : MenuBarItemProvider27.leftEdge(for: screen.displayID),
            rememberedReach: rememberedReach
        )
    }

    // MARK: Hit Tests

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of a menu bar item.
    func isMouseInsideMenuBarItem(appState: AppState, screen: NSScreen, at location: MouseLocation? = nil) -> Bool {
        guard let mouseLocation = (location ?? .current)?.coreGraphics else {
            return false
        }
        if #available(macOS 27.0, *) {
            // There are no item windows on macOS 27. See `ItemHitTest27`.
            let items = appState.itemManager.itemCache.managedItems.map { item in
                ItemHitTest27.Item(frame: item.bounds, ownerPID: item.ownerPID, isOnScreen: item.isOnScreen)
            }
            let systemFrames = MenuBarItemProvider27.systemItemFrames()
                + [
                    MenuBarItemProvider27.overflowButtonFrame(),
                    CaptureIndicatorPanel27.indicatorFrame(),
                    FocusIndicatorPanel27.indicatorFrame(),
                ].compactMap { $0 }
            return ItemHitTest27.isInsideItem(
                point: mouseLocation,
                items: items,
                concealedPIDs: appState.concealer27.concealedPIDs,
                systemFrames: systemFrames
            )
        }
        let windowIDs = Bridging.getMenuBarWindowList(option: [.onScreen, .activeSpace, .itemsOnly])
        return windowIDs.contains { windowID in
            guard let bounds = Bridging.getWindowBounds(for: windowID) else {
                return false
            }
            return bounds.contains(mouseLocation)
        }
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the screen's notch, if it has one.
    ///
    /// If the screen does not have a notch, this property returns `false`.
    func isMouseInsideNotch(appState: AppState, screen: NSScreen, at location: MouseLocation? = nil) -> Bool {
        guard
            let mouseLocation = (location ?? .current)?.appKit,
            var frameOfNotch = screen.frameOfNotch
        else {
            return false
        }
        frameOfNotch.size.height += 1
        return frameOfNotch.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of an empty space in the menu bar.
    ///
    /// The cheapest checks come first: this runs on every mouse move over the bar.
    func isMouseInsideEmptyMenuBarSpace(appState: AppState, screen: NSScreen, at location: MouseLocation? = nil) -> Bool {
        guard
            let location = location ?? .current,
            isMouseInsideMenuBar(appState: appState, screen: screen, at: location),
            !isMouseInsideNotch(appState: appState, screen: screen, at: location)
        else {
            return false
        }
        if #available(macOS 27.0, *) {
            // The items area takes in the items themselves, and the gaps between them.
            return !isMouseInsideApplicationMenu(appState: appState, screen: screen, at: location) &&
            !isMouseInsideItemsArea(appState: appState, screen: screen, at: location)
        }
        return !isMouseInsideMenuBarItem(appState: appState, screen: screen, at: location) &&
        !isMouseInsideApplicationMenu(appState: appState, screen: screen, at: location)
    }

    /// A Boolean value that indicates whether the mouse pointer rests in the part of the
    /// menu bar that holds items, including the gaps between them.
    @available(macOS 27.0, *)
    func isMouseInsideItemsArea(appState: AppState, screen: NSScreen, at location: MouseLocation? = nil) -> Bool {
        guard let mouseLocation = (location ?? .current)?.coreGraphics else {
            return false
        }
        let items = appState.itemManager.itemCache.managedItems.map { item in
            ItemHitTest27.Item(frame: item.bounds, ownerPID: item.ownerPID, isOnScreen: item.isOnScreen)
        }
        let systemFrames = MenuBarItemProvider27.systemItemFrames()
            + [
                MenuBarItemProvider27.overflowButtonFrame(),
                CaptureIndicatorPanel27.indicatorFrame(),
                FocusIndicatorPanel27.indicatorFrame(),
            ].compactMap { $0 }
        return ItemHitTest27.isInsideItemsArea(
            point: mouseLocation,
            displayBounds: CGDisplayBounds(screen.displayID),
            items: items,
            concealedPIDs: appState.concealer27.concealedPIDs,
            systemFrames: systemFrames,
            rememberedLeftEdge: MenuBarItemProvider27.leftEdge(for: screen.displayID)
        )
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice Bar panel.
    func isMouseInsideIceBar(appState: AppState, at location: MouseLocation? = nil) -> Bool {
        guard let mouseLocation = (location ?? .current)?.appKit else {
            return false
        }
        let panel = appState.menuBarManager.iceBarPanel
        // Pad the frame to be more forgiving if the user accidentally
        // moves their mouse outside of the Ice Bar.
        let paddedFrame = panel.frame.insetBy(dx: -15, dy: -15)
        return paddedFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice icon.
    func isMouseInsideIceIcon(appState: AppState) -> Bool {
        guard
            let visibleSection = appState.menuBarManager.section(withName: .visible),
            let iceIconFrame = visibleSection.controlItem.frame,
            let mouseLocation = MouseHelpers.locationAppKit
        else {
            return false
        }
        return iceIconFrame.contains(mouseLocation)
    }
}

// MARK: - EventMonitor Helpers

/// Helper protocol to enable group operations across event
/// monitoring types.
@MainActor
private protocol EventMonitorProtocol {
    func start()
    func stop()
}

extension EventMonitor: EventMonitorProtocol { }

extension EventTap: EventMonitorProtocol {
    fileprivate func start() {
        enable()
    }

    fileprivate func stop() {
        disable()
    }
}
