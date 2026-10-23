//
//  FocusIndicator27.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Which Focus is on, and where Ice's own Focus indicator goes.
///
/// macOS shows the active Focus — the moon for Do Not Disturb — as a system item,
/// `com.apple.menuextra.focusmode`, but it is Control Centre's, and like the camera and
/// microphone indicator it is not drawn while any assessment assertion is live. Measured on
/// macOS 27.0.1: the Focus item vanishes while an assertion is live, with every system item
/// number to 127 allowed, leaving only a small coloured dot at the far right of the bar. So while
/// Ice hides anything, the user loses the one sign that notifications are being held back. Ice
/// draws it back.
///
/// What is on comes from the Do Not Disturb database in `~/Library/DoNotDisturb/DB`, which is
/// plain JSON and readable without any permission:
///
/// - `Assertions.json` holds `data[0].storeAssertionRecords`, one record per live Focus
///   assertion, each naming its mode in `assertionDetails.assertionDetailsModeIdentifier`. An
///   empty array means no Focus is on.
/// - `ModeConfigurations.json` holds `data[0].modeConfigurations[<identifier>].mode`, with the
///   mode's `name`, `symbolImageName` (an SF Symbol) and `tintColorName`.
enum FocusIndicator27 {
    /// The Focus that is on.
    struct Mode: Equatable {
        /// The mode's identifier, such as `com.apple.donotdisturb.mode.default`.
        var identifier: String
        /// What the user calls it, such as "Do Not Disturb".
        var name: String
        /// The SF Symbol it is drawn with, such as `moon.fill`.
        var symbolName: String
        /// The name of its tint, such as `systemIndigoColor`, if the configuration gives one.
        var tintName: String?
    }

    /// The symbol drawn for a mode whose configuration cannot be read: Do Not Disturb's moon,
    /// which is what macOS falls back to for Focus in general.
    static let fallbackSymbolName = "moon.fill"

    /// The name shown for a mode whose configuration cannot be read.
    static let fallbackName = "Focus"

    /// The Focus that is on, or `nil` when none is.
    ///
    /// The newest assertion wins: only one Focus is on at a time, and a later one replaces the
    /// earlier. An assertion for a mode the configurations do not list — or configurations that
    /// cannot be read at all — still means a Focus is on, so it is shown with the moon rather
    /// than not at all. Assertions that cannot be read mean nothing can be said, and nothing is
    /// shown.
    ///
    /// - Parameters:
    ///   - assertions: The contents of `Assertions.json`.
    ///   - modeConfigurations: The contents of `ModeConfigurations.json`.
    static func activeMode(assertions: Data, modeConfigurations: Data?) -> Mode? {
        guard
            let root = try? JSONSerialization.jsonObject(with: assertions) as? [String: Any],
            let store = (root["data"] as? [Any])?.first as? [String: Any],
            let records = store["storeAssertionRecords"] as? [[String: Any]]
        else {
            return nil
        }
        let newest = records
            .compactMap { record -> (identifier: String, start: Double)? in
                guard
                    let details = record["assertionDetails"] as? [String: Any],
                    let identifier = details["assertionDetailsModeIdentifier"] as? String,
                    !identifier.isEmpty
                else {
                    return nil
                }
                let start = (record["assertionStartDateTimestamp"] as? NSNumber)?.doubleValue ?? 0
                return (identifier, start)
            }
            .max { $0.start < $1.start }
        guard let identifier = newest?.identifier else {
            return nil
        }
        let configuration = modeConfigurations.flatMap { mode(identifier, in: $0) }
        return Mode(
            identifier: identifier,
            name: nonEmpty(configuration?["name"]) ?? fallbackName,
            symbolName: nonEmpty(configuration?["symbolImageName"]) ?? fallbackSymbolName,
            tintName: nonEmpty(configuration?["tintColorName"])
        )
    }

    /// The `mode` dictionary of the given mode in `ModeConfigurations.json`.
    private static func mode(_ identifier: String, in data: Data) -> [String: Any]? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let store = (root["data"] as? [Any])?.first as? [String: Any],
            let configurations = store["modeConfigurations"] as? [String: Any],
            let configuration = configurations[identifier] as? [String: Any]
        else {
            return nil
        }
        return configuration["mode"] as? [String: Any]
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    /// Where to draw the indicator on a menu bar.
    ///
    /// Just left of whatever Ice already draws at the left end of the items: the camera and
    /// microphone indicator when it is on this bar, the leftmost drawn item otherwise. Going by
    /// the capture indicator's own frame rather than working out where it would be means the two
    /// can never overlap, whichever of them was placed last.
    ///
    /// - Parameters:
    ///   - barFrame: The menu bar's own frame, in screen coordinates.
    ///   - leftEdgeOfItems: The left edge of the leftmost item drawn on that bar.
    ///   - captureIndicatorFrame: Where the capture indicator is drawn, if it is.
    ///   - width: How wide to draw the indicator.
    ///   - gap: How much room to leave between it and what is to its right.
    static func frame(
        barFrame: CGRect,
        leftEdgeOfItems: CGFloat?,
        captureIndicatorFrame: CGRect?,
        width: CGFloat,
        gap: CGFloat
    ) -> CGRect {
        var edges = [CGFloat]()
        if let leftEdgeOfItems {
            edges.append(leftEdgeOfItems)
        }
        // A capture indicator on another display says nothing about this bar.
        if let captureIndicatorFrame, barFrame.minX...barFrame.maxX ~= captureIndicatorFrame.midX {
            edges.append(captureIndicatorFrame.minX)
        }
        return CaptureIndicator27.frame(barFrame: barFrame, leftEdgeOfItems: edges.min(), width: width, gap: gap)
    }
}
