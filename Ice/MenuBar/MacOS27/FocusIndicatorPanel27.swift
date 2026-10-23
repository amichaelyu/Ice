//
//  FocusIndicatorPanel27.swift
//  Ice
//

// `AXUIElement` is not marked Sendable, but the press below hands it to another queue and
// does nothing else with it.
@preconcurrency import ApplicationServices
import Cocoa
import Combine
import OSLog
import SwiftUI

/// Draws Ice's own Focus indicator on the menu bar.
///
/// macOS has one of its own, the system item `com.apple.menuextra.focusmode` — the moon for Do
/// Not Disturb — but it belongs to Control Centre, and Control Centre's modules are gone from the
/// bar while any assessment assertion is live, which is to say whenever Ice hides anything.
/// Measured on macOS 27.0.1: the Focus item vanishes while an assertion is live, with every system
/// item number to 127 allowed, and macOS leaves only a small coloured dot at the far right of the
/// bar. So Ice draws the mode's own symbol the way macOS draws its item: in the menu bar's
/// foreground colour, like every other item. The mode's tint is only used inside Control Centre
/// (measured on macOS 27.0.1 against screenshots of the native item at 2x).
///
/// Clicking it opens the Focus menu, the one the system item opens.
@available(macOS 27.0, *)
@MainActor
final class FocusIndicatorPanel27: NSPanel {
    private let logger = Logger(category: "FocusIndicatorPanel27")
    private weak var appState: AppState?
    private weak var watcher: FocusWatcher27?
    private var cancellables = Set<AnyCancellable>()
    private var hostingView: NSHostingView<FocusIndicatorView>?

    /// Whether the items were read for this placement, rather than remembered from before.
    private var hasFreshItems = false

    /// Counts the placements asked for, so one overtaken by a later one is dropped.
    private var placementGeneration = 0

    /// Whether the concealment is lifted for a click on the indicator, which keeps it off the bar.
    private var isLifting = false

    /// How wide the indicator is drawn: the pitch of the native Focus item, which is 22 pt wide
    /// like the sound and Wi-Fi items (measured on macOS 27.0.1).
    private static let width: CGFloat = 22

    /// How much room is left between the indicator and the item beside it.
    ///
    /// The items' Accessibility frames start at their padding, not their glyphs, so a panel set
    /// flush against the leftmost frame put the moon 6 pt from the next glyph, where the native
    /// Focus item keeps 23 pt (measured on macOS 27.0.1 at 2x: 47 px between the moon and the
    /// sound glyph with Ice quit, 12 px with the panel flush). With the glyph centred in the
    /// 22 pt panel, 14 pt here gives the native spacing against an item with the usual 5 pt of
    /// padding.
    private static let gap: CGFloat = 14

    nonisolated private static let frameLock = NSLock()
    nonisolated(unsafe) private static var shownFrame: CGRect?

    /// Where the indicator is drawn right now, for the hit tests that decide whether the pointer
    /// is over an empty stretch of the bar. Without this, hovering the indicator would reveal the
    /// hidden items and clicking it would do whatever a click on the bare bar does.
    nonisolated static func indicatorFrame() -> CGRect? {
        frameLock.withLock { shownFrame }
    }

    private static func setIndicatorFrame(_ frame: CGRect?) {
        frameLock.withLock { shownFrame = frame }
    }

    init(appState: AppState) {
        self.appState = appState
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .canJoinAllSpaces]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
    }

    /// Starts following which Focus is on, and where the bar and the capture indicator are.
    ///
    /// The watcher republishes on every reading, changed or not, so the indicator follows the
    /// items along the bar without a timer of its own. The capture indicator is followed as well:
    /// this one stands immediately left of it, and has to move the moment it appears or goes.
    func performSetup(watcher: FocusWatcher27, concealer: Concealer27, captureIndicator: CaptureIndicatorPanel27) {
        self.watcher = watcher
        watcher.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                MainActor.assumeIsolated {
                    self?.update(mode: mode)
                }
            }
            .store(in: &cancellables)
        // An item shown for a moment appears where the indicators stand, and a lift reflows the
        // bar under them, so this one leaves at once rather than on the watcher's next reading,
        // and comes back as soon as either is over.
        concealer.$isShowingTemporarily
            .combineLatest(concealer.$isSuspended)
            .removeDuplicates { $0 == $1 }
            .map { _ in () }
            .merge(with: captureIndicator.frameChanges.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.update(mode: self?.watcher?.mode)
                }
            }
            .store(in: &cancellables)
        // The glyph is drawn in the bar's foreground colour, so it follows a switch between light
        // and dark at once rather than on the watcher's next reading.
        NSApp.publisher(for: \.effectiveAppearance)
            .map { $0.name }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update(mode: self?.watcher?.mode)
                }
            }
            .store(in: &cancellables)
    }

    /// The appearance the menu bar draws its items in.
    ///
    /// The same test Ice uses for the flat macOS 27 bar behind the Ice Bar
    /// (`IceBarColorManager.flatColor27()`, `ItemImageStore27`): the system's own light or dark.
    /// The panel takes the matching vibrant appearance, so `.primary` comes out white on a dark bar
    /// and black on a light one, as the native items do.
    private static func menuBarAppearance() -> NSAppearance? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }

    /// Shows, moves or hides the indicator.
    private func update(mode: FocusIndicator27.Mode?) {
        guard
            let mode,
            !isLifting,
            let appState,
            // Off the bar while concealment is lifted, for this indicator's click or any other:
            // the items revealed reflow the bar under it.
            !appState.concealer27.isSuspended,
            appState.settings.advanced.showFocusIndicator,
            appState.concealer27.isConcealing,
            // Out of the way while an item is shown for a moment: that item is drawn at the left
            // end of the run, and a click meant for it would land on the indicator instead.
            !appState.concealer27.isShowingTemporarily,
            let screen = NSScreen.screenWithActiveMenuBar,
            let menuBarHeight = screen.getMenuBarHeight()
        else {
            if isVisible {
                orderOut(nil)
            }
            Self.setIndicatorFrame(nil)
            return
        }
        if let remaining = appState.concealer27.timeUntilSettled() {
            // The bar is still moving: where the items are now is not where they will be.
            Task { [weak self] in
                try? await Task.sleep(for: remaining + .milliseconds(50))
                self?.update(mode: self?.watcher?.mode)
            }
            return
        }
        if !hasFreshItems {
            // Where the items begin is remembered from the last read of the bar, which may be
            // from before the bar last moved. Ask for the items first, as the capture indicator
            // does, and appear in the right spot.
            placementGeneration += 1
            let generation = placementGeneration
            Task { [weak self] in
                _ = await MenuBarItemProvider27.items()
                guard let self, generation == placementGeneration else {
                    return
                }
                hasFreshItems = true
                defer { hasFreshItems = false }
                update(mode: watcher?.mode)
            }
            return
        }
        let barFrame = CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight
        )
        let frame = FocusIndicator27.frame(
            barFrame: barFrame,
            leftEdgeOfItems: MenuBarItemProvider27.leftEdge(for: screen.displayID),
            captureIndicatorFrame: CaptureIndicatorPanel27.indicatorFrame(),
            width: Self.width,
            gap: Self.gap
        )
        appearance = Self.menuBarAppearance()
        let view = FocusIndicatorView(mode: mode) { [weak self] in
            self?.openFocusMenu()
        }
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            contentView = hostingView
            self.hostingView = hostingView
        }
        if self.frame != frame {
            setFrame(frame, display: true)
        }
        Self.setIndicatorFrame(frame)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    /// Opens the Focus menu, the one the system's own Focus item opens.
    ///
    /// That item is not drawn while anything is concealed, so there is nothing to press until the
    /// concealment is lifted — the same lift the capture indicator needs for the camera controls,
    /// and the same cost: the hidden items flash into view for a moment. With nothing concealed
    /// the item is the system item `com.apple.menuextra.focusmode`, pressed through
    /// Accessibility.
    ///
    /// If it does not appear, Control Centre is opened instead: the Focus controls are in it, and
    /// it opens with the concealment still in force.
    private func openFocusMenu() {
        guard let appState else {
            return
        }
        logger.notice("Opening the Focus menu from the indicator")
        // Off the bar before the lift begins. The revealed items push the run leftwards, and the
        // indicator left where it stood was drawn over one of them for a frame or two (seen on
        // macOS 27.0.1 in a 4 fps screenshot burst). It comes back once concealment is restored
        // and the bar has settled, through the same wait-and-read path as any placement.
        withdrawForLift()
        Task { [weak self] in
            defer { self?.endLift() }
            await appState.concealer27.suspendReleased(for: .milliseconds(900))
            for _ in 0..<14 {
                _ = await MenuBarItemProvider27.items()
                if let element = MenuBarItemProvider27.systemItem(withIdentifier: Self.focusItem) {
                    await Self.press(element)
                    // Hide the items again as soon as the menu is open, rather than letting the
                    // lift run its course: what the user sees of it is the whole cost.
                    try? await Task.sleep(for: .milliseconds(150))
                    appState.concealer27.resumeConcealing()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.logger.warning("The Focus item never appeared, so Control Centre was opened instead")
            if let element = MenuBarItemProvider27.systemItem(withIdentifier: Self.controlCentreItem) {
                await Self.press(element)
            }
            appState.concealer27.resumeConcealing()
        }
    }

    /// Takes the indicator off the bar for a lift, dropping any placement still on its way.
    private func withdrawForLift() {
        isLifting = true
        placementGeneration += 1
        if isVisible {
            orderOut(nil)
        }
        Self.setIndicatorFrame(nil)
    }

    /// Lets the indicator back once the lift is over. The placement waits out the bar's movement
    /// and reads the items afresh before it shows anything.
    private func endLift() {
        isLifting = false
        update(mode: watcher?.mode)
    }

    /// The system item the Focus menu belongs to.
    private static let focusItem = "com.apple.menuextra.focusmode"

    /// Control Centre's own item, which holds the Focus controls too.
    private static let controlCentreItem = "com.apple.menuextra.controlcenter"

    /// Presses an Accessibility element off the main thread, which the call can block.
    private static func press(_ element: AXUIElement) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
                continuation.resume()
            }
        }
    }
}

// MARK: - The indicator itself

/// The Focus's own symbol, in the menu bar's foreground colour, at the size of a menu bar glyph:
/// 14 pt medium matches the native moon's 28 x 28 px box at 2x (measured on macOS 27.0.1).
@available(macOS 27.0, *)
private struct FocusIndicatorView: View {
    let mode: FocusIndicator27.Mode
    let press: () -> Void

    /// The mode's symbol, or the moon if this system has no symbol by that name.
    private var symbolName: String {
        NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil) != nil
            ? mode.symbolName
            : FocusIndicator27.fallbackSymbolName
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: press)
            .help("\(mode.name) is on")
            .accessibilityLabel(Text("\(mode.name) is on"))
    }
}
