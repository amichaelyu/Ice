//
//  IceIconVisibility27.swift
//  Ice
//

import CoreGraphics

/// Decides whether Ice's own icon is on screen, from which Ice infers that the
/// menu bar is not hidden.
///
/// On macOS 27 the icon's window is 33 pt tall on every display and centred on
/// the bar, so on a 30 pt bar it overhangs the top edge by 2 pt (measured frame
/// {1394, 1049, 33, 33} on a display whose top is 1080). The window also stays
/// on the display it was created on, whichever menu bar is active. Comparing
/// its top edge with the hovered display, as earlier versions do, rejects every
/// hover in that case, so the icon's centre is judged against all displays.
enum IceIconVisibility27 {
    static func isOnScreen(iconFrame: CGRect, screenFrames: [CGRect]) -> Bool {
        let center = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        return screenFrames.contains { $0.contains(center) }
    }
}
