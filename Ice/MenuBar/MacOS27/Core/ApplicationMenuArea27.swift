//
//  ApplicationMenuArea27.swift
//  Ice
//

import CoreGraphics

/// The stretch of a menu bar the application's own menus occupy.
///
/// Before macOS 27 the menus were read from the display they were asked about, so their frame and
/// that display shared an origin, and widening the frame to the display's left edge was arithmetic
/// on one coordinate space. On 27 they are read from the application that owns the menu bar,
/// wherever it is, so the same frame comes back for every display — in the owning display's
/// coordinates. Widening it against another display's left edge then produces nonsense: a rect
/// stretched across both displays when the owner is to the right, and one of negative width,
/// which contains nothing at all, when the owner is to the left. The second is what reveals the
/// hidden items when the pointer is over the menus of the display that is not active.
///
/// What carries across displays is how far the menus reach from their own display's left edge.
enum ApplicationMenuArea27 {
    /// The menus' stretch of the given display's bar.
    ///
    /// - Parameters:
    ///   - menuFrame: The union of the application's menus, as Accessibility reports it.
    ///   - ownerDisplay: The bounds of the display the menus are drawn on.
    ///   - display: The bounds of the display being asked about.
    ///   - notchGap: How much of the measurement is the owning display's notch rather than menus.
    ///     A long menu bar carries on past a notch and the gap goes into the measurement with it;
    ///     no other display has that gap, so the caller passes it when asking about another one.
    static func area(
        menuFrame: CGRect,
        ownerDisplay: CGRect,
        display: CGRect,
        notchGap: CGFloat = 0
    ) -> CGRect {
        let reach = menuFrame.maxX - ownerDisplay.minX - notchGap
        let width = min(max(reach, 0), display.width)
        return CGRect(x: display.minX, y: menuFrame.minY, width: width, height: menuFrame.height)
    }
}
