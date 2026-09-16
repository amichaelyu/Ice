//
//  MenuBarMaskPanel27.swift
//  Ice
//

import Cocoa

/// Covers part of the menu bar with the pixels it had a moment ago.
///
/// On macOS 27 a click on the clock, the battery or Wi-Fi only reaches MenuBarAgent while no
/// assessment assertion is live, so Ice lifts the concealment for a moment — and every hidden
/// item appears and disappears again. MenuBarAgent lays items out from the right, so the ones
/// that reappear sit left of the items that stay drawn, and nothing else moves. Showing the
/// last capture of that stretch of bar over it therefore hides the whole flicker. The panel
/// lets clicks through, and the item being clicked is to the right of what it covers.
@available(macOS 27.0, *)
@MainActor
final class MenuBarMaskPanel27: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .moveToActiveSpace]
        self.imageView.imageScaling = .scaleAxesIndependently
        self.contentView = imageView
    }

    /// AppKit pushes a window below the menu bar unless it says otherwise, which is how the
    /// cover ended up drawn as a second bar underneath the real one.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Covers the bar between `from` and `edge`, on the given screen.
    func cover(strip: CGImage, stripFrame: CGRect, scale: CGFloat, from: CGFloat, upTo edge: CGFloat, screen: NSScreen) {
        let left = max(from, stripFrame.minX)
        let width = edge - left
        guard
            width > 1,
            let slice = strip.cropping(to: CGRect(
                x: (left - stripFrame.minX) * scale,
                y: 0,
                width: width * scale,
                height: CGFloat(strip.height)
            ))
        else {
            hide()
            return
        }
        imageView.image = NSImage(cgImage: slice, size: CGSize(width: width, height: stripFrame.height))
        setFrame(
            CGRect(x: left, y: screen.frame.maxY - stripFrame.height, width: width, height: stripFrame.height),
            display: false
        )
        orderFrontRegardless()
    }

    /// Takes the cover away.
    func hide() {
        orderOut(nil)
        imageView.image = nil
    }
}
