//
//  Concealer27.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Hides menu bar items on macOS 27, where Ice's expanding dividers no longer work.
///
/// On macOS 27 the section of each application comes from a saved layout, first
/// taken from the user's Ice layout: MenuBarAgent reorders items on its own, so their
/// order on the bar no longer says which section they belong to. The concealer hides
/// applications following that layout and the state of Ice's sections, by one of two methods
/// (see ``MacOS27HidingMethod``):
///
/// - macOS's own "Allow in the Menu Bar" switch, through `NativeAllowListConcealer27`. The
///   default since 2026-10-22, when it was measured to hide an application's items within about
///   250 ms with nothing else on the bar affected: Control Centre's modules stay, and clicks on
///   system items reach them without a lift.
/// - Assessment mode, through `MenuBarAssessmentAssertion27`. It takes Control Centre's modules
///   with it and stops clicks on system items, so Ice draws its own capture and Focus indicators
///   and lifts concealment around such clicks. Kept for systems where the switch does not work,
///   and used whenever the switch cannot be read.
@available(macOS 27.0, *)
@MainActor
final class Concealer27: ObservableObject {
    /// The two ways of hiding, as the concealer applies them.
    private enum Backend {
        case native
        case assessment
    }

    private let controller = ConcealmentController27(backend: MenuBarAssessmentAssertion27())
    private let native = NativeAllowListConcealer27()

    /// Whether the native switch can be read and written, checked once at setup.
    private var nativeIsAvailable = false

    /// Set when the native switch failed in a way that will not mend itself in this run, so
    /// concealment falls back to assessment mode rather than leave everything shown.
    private var nativeFailed = false

    /// The method in force since the last ``update()``.
    private var backend = Backend.assessment

    /// Applications meant to be concealed that MenuBarAgent did not track at the last native
    /// apply, so there was no switch to turn off yet (see ``reapplyWhileLaunching(bundleID:)``).
    private var untrackedConcealed = Set<String>()

    /// Keeps writes of the native switch at least 700 ms apart (see `WritePacer27`).
    ///
    /// Measured on macOS 27.0.1, 2026-10-23: a lone write settles in about 250 ms, while writes
    /// 390–430 ms apart, from revealing and rehiding the hidden section on hover, had MenuBarAgent
    /// black the whole bar out for half a second. Only the write waits: what is concealed, and so
    /// hover, clicks and the Ice Bar, follows each request at once.
    private var nativePacer = WritePacer27<Set<String>>(minimumSpacing: 0.7)

    /// The one task that makes the trailing write once the spacing has passed.
    private var nativeTrailingWrite: Task<Void, Never>?
    private let logger = Logger(category: "Concealer27")
    private weak var appState: AppState?
    private var observers = [NSObjectProtocol]()
    private var applyTask: Task<Void, Never>?
    private var suspendedUntil: ContinuousClock.Instant? {
        didSet {
            if isSuspended != (suspendedUntil != nil) {
                isSuspended = suspendedUntil != nil
            }
        }
    }

    /// Whether concealment is lifted for a moment, so a click can reach a system item.
    ///
    /// The revealed items push the run leftwards, so Ice's own indicators leave the bar for the
    /// length of it rather than stand over an item, and come back once it is over.
    @Published private(set) var isSuspended = false

    /// When concealment last changed, which is when the bar last started moving.
    private var lastChangeAt = ContinuousClock.now

    /// How long MenuBarAgent animates the bar after items are concealed or released
    /// (measured on macOS 27.0: about 250 ms, with a margin here).
    private static let settleAfterChange = Duration.milliseconds(400)

    /// Applications shown for a moment, with the number of callers showing each.
    private var temporarilyShown = [String: Int]() {
        didSet {
            isShowingTemporarily = !temporarilyShown.isEmpty
        }
    }

    /// Whether any application is shown for a moment right now — to be clicked, or photographed.
    ///
    /// An item shown this way is drawn at the left end of the run, which is where Ice's own
    /// camera and microphone indicator stands, so the indicator gets out of the way while it
    /// lasts: it was drawn over the item, and the menu that opened from it came up underneath.
    @Published private(set) var isShowingTemporarily = false
    private var cancellables = Set<AnyCancellable>()
    private var runningApplicationsObservation: NSKeyValueObservation?

    /// Whether any application is meant to be concealed right now.
    private(set) var isConcealing = false

    /// Process identifiers of the applications meant to be concealed right now.
    private(set) var concealedPIDs = Set<pid_t>()

    /// The section of each application. Applications missing from it are visible.
    var savedLayout: [String: MacOS27Section] {
        let stored = Defaults.dictionary(forKey: .macOS27Layout) as? [String: Int] ?? [:]
        return stored.compactMapValues(MacOS27Section.init(rawValue:))
    }

    /// Whether a click on a system item has to lift concealment to reach it.
    ///
    /// Only under assessment mode, which has MenuBarAgent ignore those clicks. With the native
    /// switch the system items are untouched and take their clicks as they would without Ice.
    var needsClickLift: Bool {
        backend == .assessment
    }

    /// The method to apply, from the setting and what this system allows.
    private func resolvedBackend(_ appState: AppState) -> Backend {
        guard
            appState.settings.advanced.macOS27HidingMethod == .nativeAllowList,
            nativeIsAvailable,
            !nativeFailed
        else {
            return .assessment
        }
        return .native
    }

    func performSetup(with appState: AppState) {
        self.appState = appState
        nativeIsAvailable = NativeAllowListConcealer27.isAvailable
        if !nativeIsAvailable {
            logger.notice("The native Allow in the Menu Bar switch cannot be read, so assessment mode is used")
        }
        guard nativeIsAvailable || MenuBarAssessmentAssertion27.isAvailable else {
            logger.error("Neither the native switch nor MenuBarClientCore assertions are available, so items will not be hidden")
            return
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            })
        }
        // Plugging a display in lays both bars out again, and whatever does not fit beside the
        // notch is folded away — the state the check below watches for. Nothing else here notices
        // a display arriving, so without this the check waits for the next concealment change,
        // which on a quiet machine is a long way off.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
            }
        })
        // `didLaunchApplicationNotification` arrives only once an application has finished
        // launching, and by then it has usually created its status item. The running
        // applications list changes as soon as the process checks in, which is earlier:
        // measured on macOS 27.0.1, AlDente created its item 400 ms after this fired.
        runningApplicationsObservation = NSWorkspace.shared.observe(
            \.runningApplications,
            options: [.new]
        ) { [weak self] _, change in
            guard change.kind == .insertion else {
                return
            }
            let launched = (change.newValue ?? []).compactMap { application -> (String, pid_t)? in
                guard let bundleID = application.bundleIdentifier else {
                    return nil
                }
                return (bundleID, application.processIdentifier)
            }
            Task { @MainActor in
                for (bundleID, pid) in launched {
                    if self?.backend == .native {
                        self?.reapplyWhileLaunching(bundleID: bundleID)
                    } else {
                        self?.showWhileLaunching(bundleID: bundleID, pid: pid)
                    }
                }
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller.releaseAll()
            }
        })
        // Entering or leaving fullscreen swaps the menu bar the items are drawn in, and nothing
        // else here notices: the concealment was left exactly as the previous bar had it, so
        // Ice's own item was missing from the bar that slides down over a fullscreen window and
        // there was nothing to click. `HIDEventManager` watches the same publisher, for the same
        // reason, on earlier versions of macOS.
        appState.$activeSpace
            .map(\.isFullscreen)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            }
            .store(in: &cancellables)
        let navigation = appState.navigationState
        navigation.$isSettingsPresented
            .combineLatest(navigation.$settingsNavigationIdentifier)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            }
            .store(in: &cancellables)
        appState.captureIndicatorPanel27.performSetup(watcher: appState.captureWatcher27, concealer: self)
        appState.focusIndicatorPanel27.performSetup(
            watcher: appState.focusWatcher27,
            concealer: self,
            captureIndicator: appState.captureIndicatorPanel27
        )
        // Turning the Focus indicator off stops the watching at once, rather than at the next
        // concealment change; turning it on starts it if anything is hidden.
        appState.settings.advanced.$showFocusIndicator
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] show in
                MainActor.assumeIsolated {
                    guard let self, let appState else {
                        return
                    }
                    appState.focusWatcher27.setWatching(self.isConcealing && self.needsClickLift && show)
                }
            }
            .store(in: &cancellables)
        // Changing the method releases the old one in full before the new one is applied (see
        // `update`). Received on the main queue, so the setting already holds the new value.
        appState.settings.advanced.$macOS27HidingMethod
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] method in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.logger.notice("Hiding method changed to \(method.rawValue, privacy: .public)")
                    // A lift in progress belongs to assessment mode; the new method starts clean.
                    self.suspendedUntil = nil
                    self.update()
                }
            }
            .store(in: &cancellables)
        update()
    }

    /// Derives what to conceal from Ice's sections and applies it.
    func update() {
        guard let appState else {
            return
        }
        let backend = resolvedBackend(appState)
        guard backend == .native || MenuBarAssessmentAssertion27.isAvailable else {
            return
        }
        self.backend = backend
        if let suspendedUntil, ContinuousClock.now < suspendedUntil {
            return
        }
        let applications = NSWorkspace.shared.runningApplications
        let running = Set(applications.compactMap(\.bundleIdentifier))
        let layout = SectionLayout27.effectiveLayout(observed: [:], saved: savedLayout, running: running)
        let target = ConcealmentPlanner27.concealedSets(
            layout: layout,
            state: heldRevealState.map { Self.moreRevealed($0, revealState(appState)) } ?? revealState(appState),
            temporarilyShown: Set(temporarilyShown.keys)
        )
        let concealed = ConcealmentPlanner27.effectivelyConcealed(sets: target)
        isConcealing = !target.isEmpty
        // The devices are only worth asking about while something is hidden: macOS draws its own
        // camera and microphone indicator the rest of the time — and all the time with the native
        // switch, which leaves Control Centre's modules alone.
        let drawsOwnIndicators = isConcealing && backend == .assessment
        appState.captureWatcher27.setWatching(drawsOwnIndicators && appState.settings.advanced.showCaptureIndicator)
        // Likewise the Focus: macOS draws its own Focus item whenever nothing is hidden.
        appState.focusWatcher27.setWatching(drawsOwnIndicators && appState.settings.advanced.showFocusIndicator)
        defer { MenuBarItemProvider27.setConcealedPIDs(concealedPIDs) }
        concealedPIDs = Set(applications.compactMap { application in
            guard let bundleID = application.bundleIdentifier, concealed.contains(bundleID) else {
                return nil
            }
            return application.processIdentifier
        })
        lastChangeAt = .now
        let previous = applyTask
        // Each method releases whatever the other holds before applying its own, so a change of
        // method never leaves both hiding at once, nor anything hidden by the one given up.
        let task = Task { [weak self, controller, native, logger] in
            await previous?.value
            switch backend {
            case .native:
                if controller.isActive {
                    controller.releaseAll()
                }
                self?.requestNativeApply(concealed: concealed)
            case .assessment:
                self?.cancelNativePacing()
                native.releaseAll()
                do {
                    try await controller.apply(target: target, running: running)
                } catch {
                    logger.error("Could not apply concealment: \(error, privacy: .public)")
                }
            }
        }
        applyTask = task
        // Concealing moves the remaining items, and hover hit-testing uses their cached
        // frames. The refresh stays out of `applyTask`, so a slow read never holds up the
        // next change. The bar animates for about 250 ms (measured).
        Task { [weak self] in
            await task.value
            try? await Task.sleep(for: .milliseconds(400))
            await self?.appState?.itemManager.cacheItemsIfNeeded()
            await self?.checkStuckOverflow()
        }
    }

    /// Applies a concealed set through the native switch, now or once the spacing allows.
    private func requestNativeApply(concealed: Set<String>) {
        let now = ProcessInfo.processInfo.systemUptime
        switch nativePacer.request(concealed, at: now) {
        case .writeNow:
            applyNative(concealed: concealed, at: now)
        case .dropped:
            logger.debug("Native write dropped: the bar already shows what was asked")
        case .deferred(let until):
            logger.debug("Native write held for \((until - now) * 1000, privacy: .public) ms")
            guard nativeTrailingWrite == nil else {
                return
            }
            nativeTrailingWrite = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(until - now, 0)))
                guard let self, !Task.isCancelled else {
                    return
                }
                nativeTrailingWrite = nil
                let now = ProcessInfo.processInfo.systemUptime
                guard backend == .native, let due = nativePacer.takeDue(at: now) else {
                    return
                }
                applyNative(concealed: due, at: now)
                // The bar moves now rather than when the request came, so heavy work waits for
                // this movement too, and the cached frames are read again once it has settled.
                lastChangeAt = .now
                try? await Task.sleep(for: Self.settleAfterChange)
                await appState?.itemManager.cacheItemsIfNeeded()
            }
        }
    }

    /// Writes a concealed set through the native switch and notes it with the pacer.
    private func applyNative(concealed: Set<String>, at now: Double) {
        do {
            let result = try native.apply(concealed: concealed)
            untrackedConcealed = result.untracked
            nativePacer.didApply(concealed, wrote: result.wrote, at: now)
        } catch {
            logger.error("Could not apply concealment through the native switch: \(error, privacy: .public)")
            // A switch that cannot be found or read now will not be in a moment either, so
            // assessment mode takes over for the rest of the run. A write that did not
            // synchronize is tried again at the next change.
            switch error as? NativeAllowListConcealer27.Failure {
            case .unavailable, .unreadable:
                nativeFailed = true
                update()
            default:
                break
            }
        }
    }

    /// Forgets any held native write, as assessment mode takes over and hands the switch back.
    private func cancelNativePacing() {
        nativeTrailingWrite?.cancel()
        nativeTrailingWrite = nil
        nativePacer.reset()
    }

    /// Applies the native switch again while a hidden application launches.
    ///
    /// MenuBarAgent consults the switch when an item is created, so an application that is
    /// already tracked needs nothing here: it is simply not drawn. One it has never seen has no
    /// switch until its first item exists, and is turned off once it does.
    private func reapplyWhileLaunching(bundleID: String) {
        guard let section = savedLayout[bundleID], section != .visible else {
            return
        }
        Task { [weak self] in
            for delay in [1, 3, 8] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, backend == .native, untrackedConcealed.contains(bundleID) else {
                    return
                }
                update()
            }
        }
    }

    /// How many checks in a row have disagreed with ``isOverflowStuck``.
    ///
    /// A single read can catch the bar mid-animation and count wrongly, and the notice flickered
    /// on and off every few seconds because of it. Two in agreement are needed to change it.
    private var stuckDisagreements = 0

    /// Whether a notched bar looks stuck with items folded away and no way to reach them.
    ///
    /// Settings shows this, with the applications that could be the ones missing from it.
    @Published private(set) var isOverflowStuck = false

    /// The applications whose items belong on every bar while the hiding is in force.
    ///
    /// Which of them a notched bar has folded away cannot be told from the bar: the items it
    /// draws carry no owner, and Accessibility keeps reporting frames for items drawn nowhere.
    /// So they are offered to the user as the candidates to relaunch, rather than acted on.
    @Published private(set) var visibleApplications = [(bundleID: String, name: String)]()

    /// Notes whether concealment has left a notched bar's items folded with no overflow button.
    ///
    /// Seen three times here — 2026-09-29, 10-01 and 10-02 — and the third time with the trigger
    /// in hand: plugging the second display in. macOS lays both bars out again, folds what does
    /// not fit beside the notch, and never reconsiders once Ice frees the room; the "«" goes away
    /// with the items still behind it.
    ///
    /// A bar that is not the active one is read by counting: its own window lists what it draws,
    /// and the items folded away are simply absent from it while the other display draws them.
    /// That is the case that matters — the display being worked on is usually the other one, and
    /// with only the active bar's geometry to go by this watched the wrong display for two days.
    private func checkStuckOverflow() async {
        guard backend == .assessment else {
            // Folded items with no way back were an artefact of assessment mode: the native
            // switch gives the room back as MenuBarAgent lays the bar out, so there is nothing
            // to watch for, and a notice left over from the other method goes with it.
            stuckDisagreements = 0
            if isOverflowStuck {
                isOverflowStuck = false
            }
            return
        }
        guard isConcealing else {
            // With nothing concealed every item is on the bar, so a notched one folds what does
            // not fit and there is nothing to tell. This is also when the user is most likely to
            // be looking: opening the Menu Bar Layout window reveals everything, and the notice
            // that brought them there would otherwise disappear as they arrived.
            return
        }
        let items = await MenuBarItemProvider27.items()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let agentBundleID = MenuBarItemProvider27.menuBarAgentBundleID
        let applicationItems = items.filter { item in
            item.ownerPID != ownPID
                && !concealedPIDs.contains(item.ownerPID)
                && item.sourceApplication?.bundleIdentifier != agentBundleID
        }
        // What each bar lists, by MenuBarAgent's own account of it. Both displays list every
        // item that belongs to the bar — the one it is drawn on with a frame, the other without
        // geometry — so a bar listing fewer than another is a bar missing items. The items the
        // applications report are no use here: a folded item keeps the frame it last had, so it
        // still reads as drawn (measured 2026-10-02, with four of five items gone from the
        // built-in bar and all five still reporting frames on it).
        let counts = NSScreen.screens.reduce(into: [CGDirectDisplayID: Int]()) { counts, screen in
            counts[screen.displayID] = MenuBarItemProvider27.applicationEntryCount(for: screen.displayID)
        }
        let described = NSScreen.screens.map { screen in
            let button = MenuBarItemProvider27.overflowButtonFrame(for: screen.displayID) == nil ? "" : " and «"
            return "\(screen.displayID)\(screen.hasNotch ? " notched" : "") lists \(counts[screen.displayID].map(String.init) ?? "nothing")\(button)"
        }.joined(separator: ", ")
        logger.debug("Stuck check: \(applicationItems.count, privacy: .public) items to draw; \(described, privacy: .public)")
        let chevron = MenuBarItemProvider27.overflowButtonFrame()
        let stuck = NSScreen.screens.contains { screen in
            guard screen.hasNotch, let listed = counts[screen.displayID] else {
                return false
            }
            let displayBounds = CGDisplayBounds(screen.displayID)
            // A bar with a "«" on it has folded its items away but left them a click away, which
            // is macOS behaving as it means to. Measured on 2026-10-02, the counts do not trip on
            // that anyway — a bar with the button listed 20 against the other display's 19, since
            // the button is one of its entries — but the state is worth distinguishing all the
            // same (raised by @jasonsmithio on jordanbaird/Ice#995). The bar's own window is asked
            // first: the button under `AXExtrasMenuBar` is the active bar's alone.
            let ownChevron = MenuBarItemProvider27.overflowButtonFrame(for: screen.displayID)
            let activeChevron = chevron.flatMap { displayBounds.intersects($0) ? $0 : nil }
            return StuckOverflow27.isNotchedBarStuck(
                listsOverflowButton: ownChevron != nil || activeChevron != nil,
                listedApplicationItems: listed,
                mostListedElsewhere: counts.filter { $0.key != screen.displayID }.values.max()
            ) {
                // The only bar there is. With nothing to compare it against, the geometry is all
                // that is left: an item under the notch, or one stacked on its neighbour, with no
                // button to reach either. It cannot see a bar that lost its items outright, but it
                // is what the check had before counting, and a MacBook on its own would otherwise
                // go unwatched.
                StuckOverflow27.isStuck(
                    visibleItemFrames: applicationItems.filter { displayBounds.intersects($0.bounds) }.map(\.bounds),
                    chevronFrame: chevron,
                    notchSpan: StuckOverflow27.notchSpan(
                        displayBounds: displayBounds,
                        leftAreaWidth: screen.auxiliaryTopLeftArea?.width,
                        rightAreaWidth: screen.auxiliaryTopRightArea?.width
                    )
                )
            }
        }
        var applications = [String: String]()
        for item in applicationItems {
            guard let application = item.sourceApplication, let bundleID = application.bundleIdentifier else {
                continue
            }
            applications[bundleID] = application.localizedName ?? bundleID
        }
        let candidates = applications
            .map { (bundleID: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // A read that caught the bar mid-change can come back with one item or none; keeping the
        // last full answer is better than offering the user a list that empties as they look at it.
        if !candidates.isEmpty, candidates.map(\.bundleID) != visibleApplications.map(\.bundleID) {
            visibleApplications = candidates
        }
        guard stuck != isOverflowStuck else {
            stuckDisagreements = 0
            return
        }
        stuckDisagreements += 1
        guard stuckDisagreements >= 2 else {
            return
        }
        stuckDisagreements = 0
        isOverflowStuck = stuck
        if stuck {
            logger.notice("A notched bar looks stuck: items folded away with no overflow button")
        } else {
            logger.notice("The notched bar lays its items out again")
        }
    }

    /// Quits an application and starts it again, which is what lays its items out afresh.
    ///
    /// Asked for from Settings, for the application the user can see is missing. Ice does not do
    /// it by itself: an item created while an assertion is live is laid out alone and leaves the
    /// folded ones where they are (measured 2026-10-02, restarting TextInputMenuAgent brought
    /// back its own item and nothing else), so only the owner can bring an item back — and the
    /// owner is the user's application, not Ice's to close unasked.
    func relaunch(bundleID: String) {
        guard
            let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
            let url = application.bundleURL
        else {
            logger.warning("Cannot relaunch \(bundleID, privacy: .public): it is not running")
            return
        }
        logger.notice("Relaunching \(bundleID, privacy: .public) to lay its menu bar items out again")
        application.terminate()
        Task { [logger] in
            for _ in 0..<40 where !application.isTerminated {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // An agent launchd keeps alive is back on its own by now, and opening it again does
            // nothing; an application that refused to quit is left exactly as it was.
            guard application.isTerminated else {
                logger.warning("\(bundleID, privacy: .public) did not quit, so it was left alone")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } catch {
                logger.error("Could not start \(bundleID, privacy: .public) again: \(error, privacy: .public)")
            }
        }
    }

    /// Releases every assertion for a moment, so a click can reach a system item.
    ///
    /// Does nothing with the native switch, where clicks reach system items anyway.
    func suspend(for duration: Duration) {
        guard needsClickLift else {
            return
        }
        lastChangeAt = .now
        suspendedUntil = .now + duration
        isConcealing = false
        concealedPIDs.removeAll()
        let previous = applyTask
        applyTask = Task { [controller] in
            await previous?.value
            controller.releaseAll()
        }
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.suspendedUntil = nil
            self?.update()
        }
    }

    /// Ends a suspension before its time, so the items are hidden again as soon as whatever
    /// needed them shown is done. The flash of revealed items is all the user sees of a lift, so
    /// the less of it there is, the better.
    func resumeConcealing() {
        guard suspendedUntil != nil else {
            return
        }
        suspendedUntil = nil
        update()
    }

    /// Releases every assertion and returns once that has actually happened.
    ///
    /// Releasing goes through MenuBarAgent and queues behind whatever concealment change came
    /// before it. A click replayed on a timer could therefore arrive while the assertion was
    /// still live, and MenuBarAgent ignores those — which is why a click on the clock sometimes
    /// did nothing and worked on the second try.
    func suspendReleased(for duration: Duration) async {
        guard needsClickLift else {
            return
        }
        lastChangeAt = .now
        suspendedUntil = .now + duration
        isConcealing = false
        concealedPIDs.removeAll()
        let previous = applyTask
        let release = Task { [controller] in
            await previous?.value
            controller.releaseAll()
        }
        applyTask = release
        await release.value
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.suspendedUntil = nil
            self?.update()
        }
    }

    /// Puts concealment back before the suspension would have run out.
    func endSuspension() {
        guard suspendedUntil != nil else {
            return
        }
        suspendedUntil = nil
        update()
    }

    /// How much of the bar's movement is still to come after the last concealment change.
    ///
    /// Work that runs while MenuBarAgent animates the bar lands on top of that animation:
    /// revealing the hidden items set off four overlapping display captures of 260–290 ms
    /// each and six Accessibility sweeps in little over a second (measured 2026-09-16), and
    /// the animation stuttered. Heavy work waits this out.
    func timeUntilSettled() -> Duration? {
        let settleAt = lastChangeAt + Self.settleAfterChange
        let now = ContinuousClock.now
        return now < settleAt ? settleAt - now : nil
    }

    /// Shows applications for a moment, to click or photograph their items.
    /// Every call must be balanced by ``endTemporaryShow(bundleIDs:)``.
    ///
    /// The whole set is shown in one change. Shown one at a time, each call re-applied
    /// concealment and MenuBarAgent animated the bar again, so photographing ten items meant
    /// ten reflows in a row and the capture caught the items in mid-fade: a faint glyph in a
    /// wide haze of bar that the background removal could not account for (measured
    /// 2026-09-17: those tiles held 1.6–2.3 % opaque pixels against 21–26 % faint ones, where
    /// an item photographed while it stood still holds 5–20 % against 3–9 %).
    func showTemporarily(bundleIDs: some Collection<String>) {
        guard !bundleIDs.isEmpty else {
            return
        }
        for bundleID in bundleIDs {
            temporarilyShown[bundleID, default: 0] += 1
        }
        update()
    }

    /// Ends one ``showTemporarily(bundleIDs:)``.
    func endTemporaryShow(bundleIDs: some Collection<String>) {
        guard !bundleIDs.isEmpty else {
            return
        }
        for bundleID in bundleIDs {
            guard let count = temporarilyShown[bundleID] else {
                continue
            }
            temporarilyShown[bundleID] = count > 1 ? count - 1 : nil
        }
        update()
    }

    /// Shows an application for a moment, to click or photograph its item.
    /// Every call must be balanced by ``endTemporaryShow(bundleID:)``.
    func showTemporarily(bundleID: String) {
        showTemporarily(bundleIDs: CollectionOfOne(bundleID))
    }

    /// Ends one ``showTemporarily(bundleID:)``.
    func endTemporaryShow(bundleID: String) {
        endTemporaryShow(bundleIDs: CollectionOfOne(bundleID))
    }

    /// The longest a launching application is shown while Ice waits for its item.
    private static let launchGrace = Duration.seconds(8)

    /// Applications shown while they create their status items, with when each gives up.
    private var launching = [String: (pid: pid_t, deadline: ContinuousClock.Instant)]()

    /// The one task that watches for their items, however many are launching at once.
    private var launchWatcher: Task<Void, Never>?

    /// Shows a concealed application while it creates its status item.
    ///
    /// An item created while its application is concealed is offered no room, and an item
    /// that sizes itself to that room — AlDente's, for one — settles at about 3 pt and never
    /// grows back, not even after Ice quits; only relaunching the application without Ice fixes
    /// it. Items of a fixed length, Amphetamine's for one, are not affected (measured on
    /// macOS 27.0.1, 2026-10-01). Reported as jordanbaird/Ice#1007.
    ///
    /// Assessment mode only: the native switch is consulted as the item is created, so an
    /// application launched while hidden is not drawn at all rather than squashed (measured on
    /// macOS 27.0.1, 2026-10-22).
    private func showWhileLaunching(bundleID: String, pid: pid_t) {
        guard
            let section = savedLayout[bundleID],
            section != .visible,
            launching[bundleID] == nil
        else {
            return
        }
        logger.notice("Showing launching \(bundleID, privacy: .public) until its item exists")
        launching[bundleID] = (pid, .now + Self.launchGrace)
        showTemporarily(bundleID: bundleID)
        startLaunchWatcher()
    }

    /// Watches for the items of every application being shown while it launches.
    ///
    /// One watcher for all of them, rather than one each: a login starts the hidden applications
    /// together, and a read of every process's items for each of them, three times a second, is a
    /// load worth not creating (raised by @jasonsmithio on jordanbaird/Ice#995).
    private func startLaunchWatcher() {
        guard launchWatcher == nil else {
            return
        }
        launchWatcher = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !launching.isEmpty else {
                    break
                }
                let items = await MenuBarItemProvider27.items()
                let now = ContinuousClock.now
                for (bundleID, entry) in launching {
                    if let item = items.first(where: { $0.ownerPID == entry.pid && $0.bounds.width > 4 }) {
                        endLaunchGrace(bundleID: bundleID, width: item.bounds.width)
                    } else if now > entry.deadline {
                        endLaunchGrace(bundleID: bundleID, width: 0)
                    }
                }
            }
            self?.launchWatcher = nil
        }
    }

    /// Conceals an application again once its item exists, or once the grace has run out.
    private func endLaunchGrace(bundleID: String, width: CGFloat) {
        guard launching.removeValue(forKey: bundleID) != nil else {
            return
        }
        logger.notice("Concealing \(bundleID, privacy: .public) again, item width \(width, privacy: .public)")
        Task { [weak self] in
            // Let the item finish laying out before it is concealed again.
            try? await Task.sleep(for: Self.settleAfterChange)
            self?.endTemporaryShow(bundleID: bundleID)
        }
    }

    /// Moves an application to a section of the saved layout and applies it.
    func setSection(_ section: MacOS27Section, for bundleID: String) {
        let updated = SectionLayout27.settingSection(section, for: bundleID, in: savedLayout)
        Defaults.set(updated.mapValues(\.rawValue), forKey: .macOS27Layout)
        update()
        Task { [weak self] in
            await self?.appState?.itemManager.cacheItemsRegardless()
        }
    }

    /// Writes the sections Ice held before macOS 27 into the saved layout, once.
    ///
    /// Nothing recorded them before: an item's section was where it sat between Ice's dividers.
    /// On 27 that order no longer means anything, and an application missing from the layout is
    /// visible, so without this an upgrade left Ice hiding nothing until the whole layout was
    /// rebuilt by hand (jordanbaird/Ice#1006). The positions AppKit saved for each item survive
    /// the upgrade (see ``layoutFromPreferredPositions()``); a user who has arranged a layout of
    /// their own keeps it.
    func seedLayoutIfNeeded() {
        guard
            !Defaults.bool(forKey: .macOS27LayoutSeeded),
            savedLayout.isEmpty,
            !isConcealing,
            let seeded = layoutFromPreferredPositions()
        else {
            return
        }
        Defaults.set(true, forKey: .macOS27LayoutSeeded)
        Defaults.set(seeded.mapValues(\.rawValue), forKey: .macOS27Layout)
        let described = seeded
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.rawValue)" }
            .joined(separator: " ")
        logger.notice("Took the macOS 27 layout from the positions saved before macOS 27: \(described, privacy: .public)")
        update()
    }

    /// Applications whose saved positions are not theirs to give: the system items they host
    /// cannot be hidden on macOS 27, and concealing the process would take the rest with it.
    /// Control Centre keeps positions for every module it ever showed, its keyboard brightness
    /// at 5673 here, which would have put it in Always Hidden.
    private static let unseededBundleIDs: Set<String> = [
        Constants.bundleIdentifier,
        MenuBarItemProvider27.menuBarAgentBundleID,
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
    ]

    /// The layout the positions AppKit saved before macOS 27 describe, or `nil` without them.
    ///
    /// Ice's hidden divider must have a position of its own: one that never left the 1 Ice
    /// writes before creating it (see `ControlItemDefaults`) was never placed, and would put
    /// every other application behind it.
    private func layoutFromPreferredPositions() -> [String: MacOS27Section]? {
        guard
            let hiddenDivider = ControlItemDefaults[.preferredPosition, ControlItem.Identifier.hidden.rawValue],
            hiddenDivider > 1
        else {
            return nil
        }
        let alwaysHiddenEnabled = appState?.menuBarManager.section(withName: .alwaysHidden)?.isEnabled ?? false
        let alwaysHiddenDivider = alwaysHiddenEnabled
            ? ControlItemDefaults[.preferredPosition, ControlItem.Identifier.alwaysHidden.rawValue]
            : nil
        var positions = [String: [CGFloat]]()
        for application in NSWorkspace.shared.runningApplications {
            guard
                let bundleID = application.bundleIdentifier,
                !Self.unseededBundleIDs.contains(bundleID),
                positions[bundleID] == nil
            else {
                continue
            }
            let saved = Self.preferredPositions(bundleID: bundleID)
            if !saved.isEmpty {
                positions[bundleID] = saved
            }
        }
        guard !positions.isEmpty else {
            return nil
        }
        return SectionLayout27.seededLayout(
            preferredPositions: positions,
            hiddenDivider: hiddenDivider,
            alwaysHiddenDivider: alwaysHiddenDivider
        )
    }

    /// The status item positions AppKit saved in an application's preferences.
    ///
    /// Only the application's own domain is read. A sandboxed application keeps its preferences
    /// in its container, which this does not look in: reading another application's container
    /// asks the user for access to other applications' data, and a prompt at first launch is
    /// worse than a sandboxed application left visible until the user moves it.
    private static func preferredPositions(bundleID: String) -> [CGFloat] {
        let prefix = "NSStatusItem Preferred Position "
        let domain = bundleID as CFString
        let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        return keys.filter { $0.hasPrefix(prefix) }.compactMap { key in
            (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber).map { CGFloat($0.doubleValue) }
        }
    }

    /// Builds the item cache from the saved layout rather than the order on the bar.
    func cacheFromSavedLayout(items: [MenuBarItem], displayID: CGDirectDisplayID?) -> MenuBarItemManager.ItemCache {
        var cache = MenuBarItemManager.ItemCache(displayID: displayID)
        let layout = savedLayout
        for item in items.sorted(by: { $0.bounds.minX < $1.bounds.minX }) where item.canBeHidden && !item.isSystemClone {
            if item.isControlItem {
                if item.tag == .visibleControlItem {
                    cache[.visible].append(item)
                }
                continue
            }
            switch layout[item.sourceApplication?.bundleIdentifier ?? ""] ?? .visible {
            case .visible: cache[.visible].append(item)
            case .hidden: cache[.hidden].append(item)
            case .alwaysHidden: cache[.alwaysHidden].append(item)
            }
        }
        return cache
    }

    // MARK: Reveal Hold

    /// The reveal state held while a drop on the bar is read, if one is.
    private var heldRevealState: RevealState27?
    private var revealHolds = 0

    /// How much of Ice's hidden content the bar draws right now.
    var currentRevealState: RevealState27 {
        guard let appState else {
            return .allHidden
        }
        let state = revealState(appState)
        return heldRevealState.map { Self.moreRevealed($0, state) } ?? state
    }

    /// Keeps the bar at least as revealed as it is now until ``releaseRevealHold()``.
    ///
    /// A Command-drag on the bar is read once MenuBarAgent has settled it (see
    /// `HIDEventManager.resolveMenuBarItemDrop27`), and the sections can be told to hide in the
    /// meantime — by the rehide timer, or a click elsewhere. Hiding then would take the run the
    /// item was dropped into off the bar before it was read, and conceal the old layout before the
    /// new section is saved; held, the rehide lands after the section change and hides the new one.
    /// Holds nest: the bar follows Ice's sections again when the last one is released.
    func holdReveal() {
        if revealHolds == 0 {
            heldRevealState = currentRevealState
        }
        revealHolds += 1
    }

    /// Lets the bar follow Ice's sections again after ``holdReveal()``, and applies them.
    func releaseRevealHold() {
        guard revealHolds > 0 else {
            return
        }
        revealHolds -= 1
        guard revealHolds == 0 else {
            return
        }
        heldRevealState = nil
        update()
    }

    private static func moreRevealed(_ lhs: RevealState27, _ rhs: RevealState27) -> RevealState27 {
        func rank(_ state: RevealState27) -> Int {
            switch state {
            case .allHidden: 0
            case .hiddenRevealed: 1
            case .allRevealed: 2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    // MARK: Private

    private func revealState(_ appState: AppState) -> RevealState27 {
        let navigation = appState.navigationState
        if navigation.isSettingsPresented, navigation.settingsNavigationIdentifier == .menuBarLayout {
            // Everything is drawn while the layout window is open, so every item can be photographed.
            return .allRevealed
        }
        if appState.settings.general.useIceBar {
            // The Ice Bar shows hidden items in its own panel, so the bar stays concealed.
            return .allHidden
        }
        let manager = appState.menuBarManager
        if let alwaysHidden = manager.section(withName: .alwaysHidden), alwaysHidden.isEnabled, !alwaysHidden.isHidden {
            return .allRevealed
        }
        if let hidden = manager.section(withName: .hidden), !hidden.isHidden {
            return .hiddenRevealed
        }
        return .allHidden
    }
}

extension MacOS27Section {
    init(_ name: MenuBarSection.Name) {
        switch name {
        case .visible: self = .visible
        case .hidden: self = .hidden
        case .alwaysHidden: self = .alwaysHidden
        }
    }
}
