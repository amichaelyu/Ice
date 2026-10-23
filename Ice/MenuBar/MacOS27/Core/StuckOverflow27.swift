//
//  StuckOverflow27.swift
//  Ice
//

import CoreGraphics

/// Recognises the notched bar's stuck overflow on macOS 27.
///
/// On the MacBook's built-in display macOS 27 folds items that do not fit beside the notch.
/// Concealing hidden applications frees room, but the visible items it folded are not laid out
/// again: the "<<" button disappears and they are left unreachable (seen on macOS 27.0, see
/// `Scripts/macos27/reflow-probe.swift`). With no overflow button, an item that is laid out
/// never sits under the notch nor on top of another one, so either is a sign of that state.
/// Accessibility keeps the frames of items that are no longer drawn, so the sign is not proof.
enum StuckOverflow27 {
    /// The horizontal span the notch covers on a display, from the widths of the unobscured
    /// areas beside it, or `nil` for a display without a notch.
    static func notchSpan(displayBounds: CGRect, leftAreaWidth: CGFloat?, rightAreaWidth: CGFloat?) -> ClosedRange<CGFloat>? {
        guard let leftAreaWidth, let rightAreaWidth else {
            return nil
        }
        let minX = displayBounds.minX + leftAreaWidth
        let maxX = displayBounds.maxX - rightAreaWidth
        return minX < maxX ? minX...maxX : nil
    }

    /// Whether the visible items on a notched bar look folded with no way to reach them.
    ///
    /// - Parameters:
    ///   - visibleItemFrames: Frames of the items meant to be shown on that bar.
    ///   - chevronFrame: The frame of the overflow button, if there is one.
    ///   - notchSpan: The span the notch covers, see ``notchSpan(displayBounds:leftAreaWidth:rightAreaWidth:)``.
    static func isStuck(visibleItemFrames: [CGRect], chevronFrame: CGRect?, notchSpan: ClosedRange<CGFloat>?) -> Bool {
        guard chevronFrame == nil, let notchSpan else {
            return false
        }
        // Items laid out side by side overlap by 2 points (measured on macOS 27.0); folded
        // items are stacked on one another.
        let tolerance: CGFloat = 6
        let frames = visibleItemFrames.filter { $0.width > 4 }
        let underNotch = frames.contains { frame in
            frame.maxX - tolerance > notchSpan.lowerBound && frame.minX + tolerance < notchSpan.upperBound
        }
        let sorted = frames.sorted { $0.minX < $1.minX }
        let stacked = zip(sorted, sorted.dropFirst()).contains { left, right in
            left.maxX - right.minX > tolerance
        }
        return underNotch || stacked
    }

    /// How many of each bar's entries belong to applications rather than to the system group.
    ///
    /// MenuBarAgent lists an application's item on the bar it is drawn on with its frame, and on
    /// the other display's bar as an entry with no geometry at all (measured on macOS 27.0). Both
    /// count: what matters is that the bar lists the item, not where it says it is.
    ///
    /// The system group — battery, Wi-Fi, Control Centre, clock — is not told apart by geometry on
    /// every bar, though. On the bar that is not active some of its items come back without a
    /// frame too: measured on macOS 27.0.1 on 2026-10-22, the external display's bar listed the
    /// same ten entries as the active one, but only four system items with geometry and six
    /// entries without, Wi-Fi and battery among them. Counting every entry with no geometry as an
    /// application's read that bar as six application items against the active bar's four, and
    /// the notched bar was declared stuck while it was not. So the system group's size is taken
    /// from the bar that has geometry for all of it — the most system items any bar shows — and
    /// subtracted from every bar's total.
    ///
    /// An item folded away beside the notch is listed by neither bar, which is what makes a bar
    /// missing items recognisable at all.
    ///
    /// - Parameter bars: For each bar, how many entries its window lists, and how many of them
    ///   have the frame of a system item.
    /// - Returns: The application items each bar lists, or nothing when no bar shows a system
    ///   group to measure by.
    static func applicationEntryCounts<Bar: Hashable>(
        bars: [Bar: (entries: Int, systemItemsWithGeometry: Int)]
    ) -> [Bar: Int] {
        guard let systemItems = bars.values.map(\.systemItemsWithGeometry).max(), systemItems > 0 else {
            return [:]
        }
        return bars.mapValues { max($0.entries - systemItems, 0) }
    }

    /// Whether a bar draws fewer application items than there are to draw.
    ///
    /// This is the state on a notched bar that is not the active one, where the geometry
    /// ``isStuck(visibleItemFrames:chevronFrame:notchSpan:)`` reads cannot be had: the items
    /// folded away are simply absent from the bar's window, while the other display draws them.
    static func isStuck(drawnApplicationItems: Int, expectedApplicationItems: Int) -> Bool {
        expectedApplicationItems > 0 && drawnApplicationItems < expectedApplicationItems
    }

    /// Whether a notched bar is stuck, from everything read about it.
    ///
    /// A bar that lists an overflow button of its own has folded its items away but left them a
    /// click away, which is macOS behaving as it means to, so it is never stuck whatever the
    /// counts say. The button used to be looked for only on the active bar, and the notched
    /// display's « went unseen while it was the other one: Settings asked for relaunches on a bar
    /// overflowing normally (seen on macOS 27.0.1, built-in display as the main one, with an
    /// external one beside it). Otherwise the bar is compared with the fullest other bar, and
    /// with no other bar the geometry is all there is.
    ///
    /// - Parameters:
    ///   - listsOverflowButton: Whether the bar's own window lists an overflow button.
    ///   - listedApplicationItems: How many application items the bar lists.
    ///   - mostListedElsewhere: The most any other display's bar lists, or `nil` with no other bar.
    ///   - geometryLooksStuck: The single-display test, see
    ///     ``isStuck(visibleItemFrames:chevronFrame:notchSpan:)``. Only asked when it decides.
    static func isNotchedBarStuck(
        listsOverflowButton: Bool,
        listedApplicationItems: Int,
        mostListedElsewhere: Int?,
        geometryLooksStuck: () -> Bool
    ) -> Bool {
        if listsOverflowButton {
            return false
        }
        if let mostListedElsewhere {
            return isStuck(drawnApplicationItems: listedApplicationItems, expectedApplicationItems: mostListedElsewhere)
        }
        return geometryLooksStuck()
    }
}
