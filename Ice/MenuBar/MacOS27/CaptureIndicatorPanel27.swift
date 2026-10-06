//
//  CaptureIndicatorPanel27.swift
//  Ice
//

import Cocoa
import Combine
import OSLog
import SwiftUI

/// Draws Ice's own camera and microphone indicator on the menu bar.
///
/// macOS has one of its own, but it belongs to Control Centre, and Control Centre's modules are
/// gone from the bar while any assessment assertion is live — which is to say, whenever Ice hides
/// anything. Nothing in the assertion can spare them (measured on macOS 27.0 against every system
/// item number up to 127, Control Centre's bundle identifier and the capturing application's), so
/// the only way to leave the user that indicator is to draw it.
///
/// Clicking it opens Control Centre, where the camera's own controls — Video Effects, Mic Mode —
/// live during a call. Control Centre is the one system item that opens from an Accessibility
/// press while items are concealed, so the click costs no reveal.
@available(macOS 27.0, *)
@MainActor
final class CaptureIndicatorPanel27: NSPanel {
    private let logger = Logger(category: "CaptureIndicatorPanel27")
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var hostingView: NSHostingView<CaptureIndicatorView>?

    /// How wide the indicator is drawn.
    private static let width: CGFloat = 36

    /// How much room is left between it and the items beside it.
    private static let gap: CGFloat = 6

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

    /// Starts following what is in use and where the bar is.
    ///
    /// The watcher reads the devices every couple of seconds and republishes either way, so the
    /// indicator follows the items along the bar as they come and go without a timer of its own.
    func performSetup(watcher: CaptureWatcher27) {
        watcher.$kind
            .receive(on: DispatchQueue.main)
            .sink { [weak self] kind in
                MainActor.assumeIsolated {
                    self?.update(kind: kind)
                }
            }
            .store(in: &cancellables)
    }

    /// Shows, moves or hides the indicator.
    private func update(kind: CaptureIndicator27.Kind?) {
        guard
            let kind,
            let appState,
            appState.settings.advanced.showCaptureIndicator,
            appState.concealer27.isConcealing,
            let screen = NSScreen.screenWithActiveMenuBar,
            let menuBarHeight = screen.getMenuBarHeight()
        else {
            if isVisible {
                orderOut(nil)
            }
            return
        }
        let barFrame = CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight
        )
        let frame = CaptureIndicator27.frame(
            barFrame: barFrame,
            leftEdgeOfItems: MenuBarItemProvider27.leftEdge(for: screen.displayID),
            width: Self.width,
            gap: Self.gap
        )
        let view = CaptureIndicatorView(kind: kind) { [weak self] in
            self?.openControlCenter()
        }
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            contentView = hostingView
            self.hostingView = hostingView
        }
        setFrame(frame, display: true)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    /// Opens Control Centre, which holds the camera's own controls during a call.
    private func openControlCenter() {
        guard let element = MenuBarItemProvider27.systemItem(withIdentifier: "com.apple.menuextra.controlcenter") else {
            logger.warning("Control Centre's item was not found, so the indicator has nothing to open")
            return
        }
        logger.notice("Opening Control Centre from the capture indicator")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }
}

// MARK: - The indicator itself

/// A green camera, or an orange microphone, drawn the way macOS draws its own.
@available(macOS 27.0, *)
private struct CaptureIndicatorView: View {
    let kind: CaptureIndicator27.Kind
    let press: () -> Void

    private var colour: Color {
        switch kind {
        case .camera: Color(red: 0.16, green: 0.78, blue: 0.3)
        case .microphone: Color(red: 0.98, green: 0.58, blue: 0.09)
        }
    }

    private var symbol: String {
        switch kind {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        }
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(colour)
                .frame(width: 30, height: 20)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: press)
        .help(kind == .camera ? "The camera is in use" : "The microphone is in use")
    }
}
