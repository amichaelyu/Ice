//
//  DropSection27.swift
//  Ice
//

import CoreGraphics

/// Reads the section an application was dropped into from a Command-drag on the bar on macOS 27.
///
/// Before macOS 27 dragging an item past one of Ice's dividers was how it was hidden, and users
/// still reach for it. On 27 the order is MenuBarAgent's own: Command-drags reorder items on the
/// bar and MenuBarAgent persists the order itself (measured on macOS 27.0.1, 2026-10-23), and Ice's
/// dividers are collapsed to nothing. So Ice leaves the order alone and reads the drop only to learn
/// the section: where the dragged item came to rest, against the runs of items the saved layout puts
/// in each section, says which section the user meant.
enum DropSection27 {
    /// The frames of the items drawn for each section, the dragged application's own left out.
    struct Runs: Equatable {
        var visible: [CGRect] = []
        var hidden: [CGRect] = []
        var alwaysHidden: [CGRect] = []
    }

    /// How far, in points, an item can come to rest from where it was picked up and still count
    /// as put back. Neighbours are at least an item's width apart, so a real move goes further.
    static let putBackTolerance: CGFloat = 4

    /// The section the dropped application now belongs to, or `nil` if it stays where it is.
    ///
    /// The runs are read left to right as always-hidden, hidden, visible — the order Ice's
    /// dividers kept before macOS 27 — and a drop is judged by the centre of the item:
    ///
    /// - within or left of the always-hidden run: always hidden;
    /// - within the hidden run, or between its left edge and the visible run: hidden;
    /// - right of the hidden run and not left of the visible run: visible.
    ///
    /// A run with nothing drawn gives way to its neighbour's edge: with no hidden items on the
    /// bar, left of the visible run is hidden. With no always-hidden items there is no edge to
    /// cross, so nothing becomes always hidden; that section is reached through the layout editor.
    ///
    /// - Parameters:
    ///   - dropped: The dragged item's frame once the bar settled, or `nil` if it was not found.
    ///   - runs: The frames of the other items drawn for each section.
    ///   - current: The dragged application's section in the saved layout.
    static func section(dropped: CGRect?, runs: Runs, current: MacOS27Section) -> MacOS27Section? {
        guard let dropped, !dropped.isNull, dropped.width > 0 else {
            return nil
        }
        let x = dropped.midX
        let alwaysHidden = span(runs.alwaysHidden)
        let hidden = span(runs.hidden)
        let visible = span(runs.visible)
        let result: MacOS27Section
        if let alwaysHidden, x <= alwaysHidden.maxX {
            result = .alwaysHidden
        } else if let hidden {
            if x <= hidden.maxX {
                result = .hidden
            } else if let visible, x < visible.minX {
                result = .hidden
            } else {
                result = .visible
            }
        } else if let visible {
            result = x < visible.minX ? .hidden : .visible
        } else if alwaysHidden != nil {
            // Only always-hidden items drawn, and the drop right of them.
            result = .hidden
        } else {
            return nil
        }
        return result == current ? nil : result
    }

    /// The section for a drop, guarded for how the drag went.
    ///
    /// An item put back where it was picked up says nothing. And when the hidden section was not
    /// revealed during the drag there was no run to drop into, so the drop only reorders: Ice's
    /// dividers are invisible on 27, and the leftmost visible place looks just like the place left
    /// of the hidden divider, so reading it as hiding made reordered items vanish.
    ///
    /// - Parameters:
    ///   - picked: The dragged item's frame when the drag began, if it was read.
    ///   - hiddenRevealed: Whether the hidden section was drawn on the bar during the drag.
    static func section(
        dropped: CGRect?,
        picked: CGRect?,
        runs: Runs,
        current: MacOS27Section,
        hiddenRevealed: Bool
    ) -> MacOS27Section? {
        guard let dropped else {
            return nil
        }
        if let picked, abs(dropped.midX - picked.midX) < putBackTolerance {
            return nil
        }
        guard hiddenRevealed else {
            return nil
        }
        return section(dropped: dropped, runs: runs, current: current)
    }

    /// The frame in a list nearest the given point along the bar, for an application with several items.
    static func nearest(to point: CGPoint, in frames: [CGRect]) -> CGRect? {
        frames.min { abs($0.midX - point.x) < abs($1.midX - point.x) }
    }

    /// The horizontal span from the leftmost frame's left edge to the rightmost's right edge.
    private static func span(_ frames: [CGRect]) -> (minX: CGFloat, maxX: CGFloat)? {
        let frames = frames.filter { !$0.isNull && $0.width > 0 }
        guard let minX = frames.map(\.minX).min(), let maxX = frames.map(\.maxX).max() else {
            return nil
        }
        return (minX, maxX)
    }
}
