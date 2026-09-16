//
//  ItemImages27.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Pure rules for menu bar item images on macOS 27.
enum ItemImages27 {
    /// The pixel rectangle of an item inside a capture of its display's menu bar strip,
    /// or `nil` if the item is not on that strip. Frames are in global points with the
    /// origin at the top left, like the capture.
    static func cropRect(itemFrame: CGRect, stripFrame: CGRect, scale: CGFloat) -> CGRect? {
        let clipped = itemFrame.intersection(stripFrame)
        guard !clipped.isNull, clipped.width >= itemFrame.width * 0.9 else {
            return nil
        }
        return CGRect(
            x: ((clipped.minX - stripFrame.minX) * scale).rounded(.down),
            y: ((clipped.minY - stripFrame.minY) * scale).rounded(.down),
            width: (clipped.width * scale).rounded(.up),
            height: (clipped.height * scale).rounded(.up)
        )
    }

    /// Below this share of the glyph's own contrast, a pixel is taken for bar, not glyph.
    private static let noiseFloor = 0.06
    /// A tile whose pixels all sit this close to the background holds no glyph.
    private static let emptyTileDistance = 8.0
    /// Further than this from the tile's own colour, a column's edge is glyph, not bar.
    private static let maximumColumnDrift = 40.0

    /// The background colour of a captured item, taken from the pixels along its edges.
    ///
    /// A capture of the menu bar carries the bar behind the glyph. The edges of an item's
    /// rectangle are background almost everywhere, so the most common colour among them is
    /// the background. Pixels are `RGBA`, eight bits each, row by row.
    static func backgroundColor(pixels: [UInt8], width: Int, height: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var counts = [UInt32: Int]()
        func count(x: Int, y: Int) {
            let offset = (y * width + x) * 4
            guard offset + 2 < pixels.count else {
                return
            }
            let key = UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2])
            counts[key, default: 0] += 1
        }
        for x in 0..<width {
            count(x: x, y: 0)
            count(x: x, y: height - 1)
        }
        for y in 0..<height {
            count(x: 0, y: y)
            count(x: width - 1, y: y)
        }
        guard let common = counts.max(by: { $0.value < $1.value })?.key else {
            return (0, 0, 0)
        }
        return (UInt8((common >> 16) & 0xff), UInt8((common >> 8) & 0xff), UInt8(common & 0xff))
    }

    /// The same pixels with the background made transparent, so the glyph can be drawn on
    /// any colour.
    ///
    /// The capture holds the glyph already blended into the bar, so a pixel's opacity is
    /// how far it moved from the bar towards the glyph's own colour, not how far it lies
    /// from the bar in absolute terms. Measuring absolutely washes out a glyph that is
    /// close in colour to the bar; measuring as a share keeps it whole and still softens
    /// the glyph's edges. The glyph's colour is taken to be that of the pixel furthest
    /// from the background, and each pixel's colour is unblended from the background.
    static func removingBackground(
        pixels: [UInt8],
        width: Int,
        height: Int,
        background: (r: UInt8, g: UInt8, b: UInt8)
    ) -> [UInt8] {
        let count = min(pixels.count, width * height * 4)
        let backgroundChannels = [Double(background.r), Double(background.g), Double(background.b)]

        // The bar is translucent, so the wallpaper behind it drifts its colour from one
        // side of an item to the other, and the bar also shades from its top row to its
        // bottom (measured on macOS 27.0: 11 to 18 between them). One colour for the whole
        // tile leaves a haze, which shows as a pale box behind the glyph. So each column
        // takes a colour from above the glyph and one from below it, and every pixel is
        // measured against the blend of the two at its own row. A column the glyph covers
        // edge to edge keeps the tile's colour instead of erasing itself.
        func edgeBackground(column: Int, rows: [Int]) -> (colour: [Double], row: Int) {
            var closest = backgroundChannels
            var closestRow = rows.first ?? 0
            var closestDrift = Double.infinity
            for y in rows {
                let index = (y * width + column) * 4
                guard index + 2 < count else {
                    continue
                }
                let candidate = (0..<3).map { Double(pixels[index + $0]) }
                let drift = (0..<3).reduce(0.0) { max($0, abs(candidate[$1] - backgroundChannels[$1])) }
                if drift < closestDrift {
                    closestDrift = drift
                    closest = candidate
                    closestRow = y
                }
            }
            return closestDrift <= maximumColumnDrift ? (closest, closestRow) : (backgroundChannels, closestRow)
        }

        let topRows = [0, 1].filter { $0 < height }
        let bottomRows = [height - 2, height - 1].filter { $0 >= 0 }
        var topBackgrounds = [(colour: [Double], row: Int)]()
        var bottomBackgrounds = [(colour: [Double], row: Int)]()
        for x in 0..<width {
            topBackgrounds.append(edgeBackground(column: x, rows: topRows))
            bottomBackgrounds.append(edgeBackground(column: x, rows: bottomRows))
        }

        func blendedBackground(at index: Int) -> [Double] {
            let pixel = index / 4
            let top = topBackgrounds[pixel % width]
            let bottom = bottomBackgrounds[pixel % width]
            let span = Double(bottom.row - top.row)
            let share = span > 0 ? min(1, max(0, Double(pixel / width - top.row) / span)) : 0
            return (0..<3).map { top.colour[$0] + (bottom.colour[$0] - top.colour[$0]) * share }
        }

        func distance(at index: Int) -> Double {
            let local = blendedBackground(at: index)
            return (0..<3).reduce(0) { furthest, channel in
                max(furthest, abs(Double(pixels[index + channel]) - local[channel]))
            }
        }

        var glyphDistance = 0.0
        for index in stride(from: 0, to: count, by: 4) {
            glyphDistance = max(glyphDistance, distance(at: index))
        }

        var result = pixels
        guard glyphDistance > emptyTileDistance else {
            for index in stride(from: 0, to: count, by: 4) {
                result[index + 3] = 0
            }
            return result
        }

        for index in stride(from: 0, to: count, by: 4) {
            let opacity = min(1, distance(at: index) / glyphDistance)
            guard opacity > noiseFloor else {
                result[index + 3] = 0
                continue
            }
            result[index + 3] = UInt8((opacity * 255).rounded())
            let local = blendedBackground(at: index)
            for channel in 0..<3 {
                let unblended = (Double(pixels[index + channel]) - local[channel] * (1 - opacity)) / opacity
                result[index + channel] = UInt8(min(255, max(0, unblended.rounded())))
            }
        }
        return result
    }

    /// The tags whose frames are the same in both reads, give or take a point.
    ///
    /// The bar re-lays out whenever an item is shown or hidden, or when Ice's own item
    /// leaves it, and a capture taken across that re-layout cuts between icons: the stored
    /// images then hold slivers of two neighbours or plain bar (measured on macOS 27.0,
    /// after the Ice icon was switched off while items were being photographed). Reading
    /// the frames again after the capture and keeping only what stayed put throws those
    /// away, so the next capture can store them properly.
    static func settledTags(before: [String: CGRect], after: [String: CGRect], tolerance: CGFloat = 1) -> Set<String> {
        var settled = Set<String>()
        for (tag, frame) in before {
            guard let later = after[tag] else {
                continue
            }
            let moved = max(
                abs(later.minX - frame.minX),
                abs(later.minY - frame.minY),
                abs(later.width - frame.width),
                abs(later.height - frame.height)
            )
            if moved <= tolerance {
                settled.insert(tag)
            }
        }
        return settled
    }

    /// Anything fainter than this is a trace of a neighbouring item, not the glyph.
    private static let visibleAlpha: UInt8 = 16

    /// The columns the glyph itself covers, or `nil` when the tile holds nothing.
    ///
    /// MenuBarAgent pads items unevenly, so a captured tile has anywhere from no margin to
    /// a dozen points of it (measured on macOS 27.0). Drawing the tiles side by side then
    /// spaces the glyphs unevenly, which is why the Ice Bar and the layout window trim each
    /// tile to its glyph and add a margin of their own.
    static func glyphColumns(pixels: [UInt8], width: Int, height: Int) -> ClosedRange<Int>? {
        var first: Int?
        var last: Int?
        for x in 0..<width {
            let covered = (0..<height).contains { y in
                let index = (y * width + x) * 4 + 3
                return index < pixels.count && pixels[index] > visibleAlpha
            }
            guard covered else {
                continue
            }
            if first == nil {
                first = x
            }
            last = x
        }
        guard let first, let last else {
            return nil
        }
        return first...last
    }

    /// The same pixels in one colour, keeping every pixel's opacity.
    ///
    /// MenuBarAgent draws a glyph light or dark to suit whatever sits behind the menu bar,
    /// so a captured glyph can be the wrong colour for the Ice Bar's own flat background.
    /// Recolouring gives the panel one readable look, the way a template image behaves.
    static func tinted(pixels: [UInt8], colour: (r: UInt8, g: UInt8, b: UInt8)) -> [UInt8] {
        var result = pixels
        for index in stride(from: 0, to: pixels.count, by: 4) {
            result[index] = colour.r
            result[index + 1] = colour.g
            result[index + 2] = colour.b
        }
        return result
    }

    /// A stable file name for an item's image, safe to use on disk.
    static func fileName(forTag tag: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in tag.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx.png", hash)
    }
}

/// Decides when an application may be shown for a moment to photograph its item.
struct PhotoSchedule27 {
    static let minimumInterval: TimeInterval = 600

    private var lastAttempts = [String: TimeInterval]()

    func mayPhotograph(bundleID: String, now: TimeInterval) -> Bool {
        guard let last = lastAttempts[bundleID] else {
            return true
        }
        return now - last >= Self.minimumInterval
    }

    mutating func recordAttempt(bundleID: String, now: TimeInterval) {
        lastAttempts[bundleID] = now
    }
}
