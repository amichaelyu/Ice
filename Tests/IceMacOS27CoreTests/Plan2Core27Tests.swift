import CoreGraphics
import Foundation
import Testing
@testable import IceMacOS27Core

@Suite("Temporary allowances")
struct TemporaryAllowance27Tests {
    let layout: [String: MacOS27Section] = [
        "ru.keepcoder.Telegram": .hidden,
        "com.caldis.Mos": .alwaysHidden,
    ]

    @Test("A temporarily shown application leaves the concealed set")
    func removed() {
        let sets = ConcealmentPlanner27.concealedSets(layout: layout, state: .allHidden, temporarilyShown: ["ru.keepcoder.Telegram"])
        #expect(sets == [["com.caldis.Mos"]])
    }

    @Test("Showing the only concealed application needs no assertion")
    func nothingLeft() {
        let sets = ConcealmentPlanner27.concealedSets(layout: layout, state: .hiddenRevealed, temporarilyShown: ["com.caldis.Mos"])
        #expect(sets.isEmpty)
    }

    @Test("Without temporary allowances the sets are unchanged")
    func unchanged() {
        let plain = ConcealmentPlanner27.concealedSets(layout: layout, state: .allHidden)
        #expect(ConcealmentPlanner27.concealedSets(layout: layout, state: .allHidden, temporarilyShown: []) == plain)
    }
}

@Suite("ItemImages27")
struct ItemImages27Tests {
    @Test("An item on a 1x display crops to its own frame")
    func externalCrop() {
        let rect = ItemImages27.cropRect(
            itemFrame: CGRect(x: 1478, y: 2, width: 33, height: 24),
            stripFrame: CGRect(x: 0, y: 0, width: 1920, height: 30),
            scale: 1
        )
        #expect(rect == CGRect(x: 1478, y: 2, width: 33, height: 24))
    }

    @Test("An item on a 2x display left of the primary one crops in pixels")
    func builtInCrop() {
        let rect = ItemImages27.cropRect(
            itemFrame: CGRect(x: -442, y: 102.5, width: 33, height: 24),
            stripFrame: CGRect(x: -1512, y: 98, width: 1512, height: 33),
            scale: 2
        )
        #expect(rect == CGRect(x: 2140, y: 9, width: 66, height: 48))
    }

    @Test("An item on another display has no crop")
    func otherDisplay() {
        let rect = ItemImages27.cropRect(
            itemFrame: CGRect(x: 1478, y: 2, width: 33, height: 24),
            stripFrame: CGRect(x: -1512, y: 98, width: 1512, height: 33),
            scale: 2
        )
        #expect(rect == nil)
    }

    @Test("File names are stable, distinct and safe")
    func fileNames() {
        let name = ItemImages27.fileName(forTag: "eu.exelban.Stats:Item-0")
        #expect(name == ItemImages27.fileName(forTag: "eu.exelban.Stats:Item-0"))
        #expect(name != ItemImages27.fileName(forTag: "eu.exelban.Stats:Item-1"))
        #expect(name.hasSuffix(".png"))
        #expect(!name.contains("/") && !name.contains(":"))
    }
}

@Suite("PhotoSchedule27")
struct PhotoSchedule27Tests {
    @Test("An application is photographed at most once every ten minutes")
    func interval() {
        var schedule = PhotoSchedule27()
        #expect(schedule.mayPhotograph(bundleID: "ru.keepcoder.Telegram", now: 0))
        schedule.recordAttempt(bundleID: "ru.keepcoder.Telegram", now: 0)
        #expect(!schedule.mayPhotograph(bundleID: "ru.keepcoder.Telegram", now: 599))
        #expect(schedule.mayPhotograph(bundleID: "ru.keepcoder.Telegram", now: 600))
    }

    @Test("Applications are scheduled independently")
    func independent() {
        var schedule = PhotoSchedule27()
        schedule.recordAttempt(bundleID: "ru.keepcoder.Telegram", now: 0)
        #expect(schedule.mayPhotograph(bundleID: "com.caldis.Mos", now: 1))
    }
}

@Suite("ItemClick27")
struct ItemClick27Tests {
    @Test("No activation when the Ice Bar is on the active menu bar's display")
    func sameDisplay() {
        #expect(!ItemClick27.needsMenuBarActivation(activeDisplayID: 3, iceBarDisplayID: 3))
    }

    @Test("Activation when the Ice Bar is on another display")
    func otherDisplay() {
        #expect(ItemClick27.needsMenuBarActivation(activeDisplayID: 3, iceBarDisplayID: 1))
    }

    @Test("No activation without a known Ice Bar display")
    func unknownDisplay() {
        #expect(!ItemClick27.needsMenuBarActivation(activeDisplayID: 3, iceBarDisplayID: nil))
    }

    @Test("A new window of the item's process means its interface is open")
    func interfaceOpen() {
        let windows = [(number: 10, ownerPID: Int32(100)), (number: 42, ownerPID: Int32(555))]
        #expect(ItemClick27.interfaceIsOpen(windowOwners: windows, ownerPID: 555, baseline: [10]))
    }

    @Test("Windows that were already there, or belong to others, do not count")
    func interfaceClosed() {
        let windows = [(number: 10, ownerPID: Int32(555)), (number: 42, ownerPID: Int32(100))]
        #expect(!ItemClick27.interfaceIsOpen(windowOwners: windows, ownerPID: 555, baseline: [10]))
    }
}

@Suite("Item image background")
struct ItemImageBackground27Tests {
    /// A 5×5 tile of `background` with `centre` in the middle and an optional second
    /// pixel at (1, 1), which stands for a soft edge of the glyph.
    func tile(
        background: (r: UInt8, g: UInt8, b: UInt8),
        centre: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255),
        edge: (r: UInt8, g: UInt8, b: UInt8)? = nil
    ) -> [UInt8] {
        var pixels = [UInt8]()
        for y in 0..<5 {
            for x in 0..<5 {
                var colour = background
                if x == 2, y == 2 {
                    colour = centre
                } else if x == 1, y == 1, let edge {
                    colour = edge
                }
                pixels += [colour.r, colour.g, colour.b, 255]
            }
        }
        return pixels
    }

    func alpha(_ pixels: [UInt8], x: Int, y: Int) -> UInt8 {
        pixels[(y * 5 + x) * 4 + 3]
    }

    @Test("The background colour is taken from the edges, not the glyph")
    func backgroundFromEdges() {
        let background = ItemImages27.backgroundColor(pixels: tile(background: (100, 140, 170)), width: 5, height: 5)
        #expect(background.r == 100 && background.g == 140 && background.b == 170)
    }

    @Test("Background pixels become transparent and the glyph stays opaque")
    func backgroundRemoved() {
        let pixels = ItemImages27.removingBackground(pixels: tile(background: (100, 140, 170)), width: 5, height: 5, background: (100, 140, 170))
        #expect(alpha(pixels, x: 0, y: 0) == 0)
        #expect(alpha(pixels, x: 2, y: 2) == 255)
    }

    @Test("The glyph keeps its own colour")
    func glyphColourKept() {
        let pixels = ItemImages27.removingBackground(pixels: tile(background: (100, 140, 170), centre: (40, 200, 90)), width: 5, height: 5, background: (100, 140, 170))
        let offset = (2 * 5 + 2) * 4
        #expect(pixels[offset] == 40 && pixels[offset + 1] == 200 && pixels[offset + 2] == 90)
    }

    @Test("A pixel halfway between the glyph and the background is half opaque")
    func halfBlendIsHalfOpaque() {
        // Glyph (20, 20, 20) on background (100, 140, 170); the edge pixel is their mix.
        let pixels = ItemImages27.removingBackground(
            pixels: tile(background: (100, 140, 170), centre: (20, 20, 20), edge: (60, 80, 95)),
            width: 5,
            height: 5,
            background: (100, 140, 170)
        )
        #expect(alpha(pixels, x: 2, y: 2) == 255)
        let edge = Int(alpha(pixels, x: 1, y: 1))
        #expect(edge > 112 && edge < 143)
    }

    @Test("A glyph the colour of the bar's text stays fully opaque")
    func faintGlyphStaysOpaque() {
        // A dark grey glyph on a light bar: far less contrast, still the glyph.
        let pixels = ItemImages27.removingBackground(
            pixels: tile(background: (157, 194, 218), centre: (120, 150, 170)),
            width: 5,
            height: 5,
            background: (157, 194, 218)
        )
        #expect(alpha(pixels, x: 2, y: 2) == 255)
    }

    @Test("Beside a strong glyph, a pixel close to the background stays faint")
    func edgesFade() {
        // Opacity is a share of the glyph's own contrast, so the same edge colour means
        // different opacity depending on how strong the glyph beside it is.
        let pixels = ItemImages27.removingBackground(
            pixels: tile(background: (100, 140, 170), centre: (255, 255, 255), edge: (130, 140, 170)),
            width: 5,
            height: 5,
            background: (100, 140, 170)
        )
        let a = Int(alpha(pixels, x: 1, y: 1))
        #expect(a > 0 && a < 80)
    }

    @Test("A bar whose colour drifts across the item still disappears completely")
    func driftingBackgroundRemoved() {
        // The menu bar is translucent, so the wallpaper behind it makes its colour drift
        // from one side of an item to the other. Subtracting a single colour leaves a
        // haze over the whole tile, which shows as a pale box behind the glyph.
        let width = 7
        let height = 6
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let drift = UInt8(5 * x)
                var colour: (r: UInt8, g: UInt8, b: UInt8) = (100 + drift, 140 + drift, 170 + drift)
                if x == 3, (2...3).contains(y) {
                    colour = (20, 20, 20)
                }
                pixels += [colour.r, colour.g, colour.b, 255]
            }
        }
        let background = ItemImages27.backgroundColor(pixels: pixels, width: width, height: height)
        let result = ItemImages27.removingBackground(pixels: pixels, width: width, height: height, background: background)
        for y in 0..<height {
            for x in 0..<width where !(x == 3 && (2...3).contains(y)) {
                #expect(result[(y * width + x) * 4 + 3] == 0)
            }
        }
        #expect(result[(2 * width + 3) * 4 + 3] == 255)
    }

    @Test("A bar that shades from its top to its bottom also disappears completely")
    func shadedBackgroundRemoved() {
        // Measured on macOS 27.0: the bar's colour drifts by 11–18 between its top and
        // bottom rows, so a background taken from one row leaves a haze on the other.
        let width = 6
        let height = 8
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let shade = UInt8(2 * y)
                var colour: (r: UInt8, g: UInt8, b: UInt8) = (100 + shade, 140 + shade, 170 + shade)
                if x == 3, (3...4).contains(y) {
                    colour = (20, 20, 20)
                }
                pixels += [colour.r, colour.g, colour.b, 255]
            }
        }
        let background = ItemImages27.backgroundColor(pixels: pixels, width: width, height: height)
        let result = ItemImages27.removingBackground(pixels: pixels, width: width, height: height, background: background)
        for y in 0..<height {
            for x in 0..<width where !(x == 3 && (3...4).contains(y)) {
                #expect(result[(y * width + x) * 4 + 3] == 0)
            }
        }
        // The shading makes the lower of the two glyph pixels the furthest from the bar, so
        // it is the one that sets full opacity; the other is a hair behind it.
        #expect(result[(4 * width + 3) * 4 + 3] == 255)
        #expect(result[(3 * width + 3) * 4 + 3] >= 250)
    }

    @Test("A recoloured glyph keeps its shape")
    func tintedKeepsShape() {
        let keyed = ItemImages27.removingBackground(
            pixels: tile(background: (100, 140, 170), centre: (255, 255, 255), edge: (178, 198, 213)),
            width: 5,
            height: 5,
            background: (100, 140, 170)
        )
        let tinted = ItemImages27.tinted(pixels: keyed, colour: (10, 10, 10))
        let centre = (2 * 5 + 2) * 4
        let edge = (1 * 5 + 1) * 4
        #expect(tinted[centre] == 10 && tinted[centre + 1] == 10 && tinted[centre + 2] == 10)
        #expect(tinted[centre + 3] == 255)
        #expect(tinted[edge + 3] == keyed[edge + 3])
        #expect(tinted[edge + 3] > 0 && tinted[edge + 3] < 255)
    }
}

@Suite("System item panel")
struct SystemPanel27Tests {
    // Measured on macOS 27.0: pressing Control Centre through Accessibility opens
    // "Control Center", layer 101, 656×964, after about 177 ms.
    let before: Set<Int> = [10, 11]

    @Test("A new tall window above the menu bar means the panel opened")
    func opened() {
        let after: [(number: Int, layer: Int, height: CGFloat)] = [(number: 10, layer: 20, height: 1080.0), (number: 42, layer: 101, height: 964.0)]
        #expect(ItemClick27.panelOpened(before: before, windows: after))
    }

    @Test("The windows that were already there do not count")
    func nothingNew() {
        let after: [(number: Int, layer: Int, height: CGFloat)] = [(number: 10, layer: 20, height: 1080.0), (number: 11, layer: 101, height: 964.0)]
        #expect(!ItemClick27.panelOpened(before: before, windows: after))
    }

    @Test("A small new window is not a panel")
    func tooSmall() {
        let after: [(number: Int, layer: Int, height: CGFloat)] = [(number: 43, layer: 101, height: 28.0)]
        #expect(!ItemClick27.panelOpened(before: before, windows: after))
    }

    @Test("An ordinary window opening at the same moment is not a panel")
    func ordinaryWindow() {
        let after: [(number: Int, layer: Int, height: CGFloat)] = [(number: 44, layer: 0, height: 700.0)]
        #expect(!ItemClick27.panelOpened(before: before, windows: after))
    }

    // Measured on macOS 27.0: the clock opens "Notification Center", layer 21, the size of
    // the display, about 166 ms after the click. It stands far below Control Centre's level.
    @Test("Notification Center counts, low as its window stands")
    func notificationCenter() {
        let after: [(number: Int, layer: Int, height: CGFloat)] = [(number: 45, layer: 21, height: 1080.0)]
        #expect(ItemClick27.panelWindow(before: before, windows: after) == 45)
    }

    @Test("A panel is open while its window is on screen, and closed once it goes")
    func staysOnScreen() {
        let open: [(number: Int, layer: Int, height: CGFloat)] = [(number: 45, layer: 21, height: 1080.0)]
        let closed: [(number: Int, layer: Int, height: CGFloat)] = [(number: 10, layer: 20, height: 1080.0)]
        #expect(ItemClick27.panelIsOnScreen(window: 45, windows: open))
        #expect(!ItemClick27.panelIsOnScreen(window: 45, windows: closed))
    }
}

@Suite("Items zone")
struct ItemsZone27Tests {
    let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let items = [
        ItemHitTest27.Item(frame: CGRect(x: 1400, y: 2, width: 30, height: 24), ownerPID: 11, isOnScreen: true),
        ItemHitTest27.Item(frame: CGRect(x: 1500, y: 2, width: 30, height: 24), ownerPID: 12, isOnScreen: true),
    ]
    let systemFrames = [CGRect(x: 1700, y: 4, width: 26, height: 22)]

    @Test("The gap between two items belongs to the items, not to empty space")
    func gapBelongsToItems() {
        #expect(ItemHitTest27.isInsideItemsArea(
            point: CGPoint(x: 1460, y: 12),
            displayBounds: bounds,
            items: items,
            concealedPIDs: [],
            systemFrames: systemFrames,
            rememberedLeftEdge: nil
        ))
    }

    @Test("The bar left of every item is still empty space")
    func leftOfItemsIsEmpty() {
        #expect(!ItemHitTest27.isInsideItemsArea(
            point: CGPoint(x: 900, y: 12),
            displayBounds: bounds,
            items: items,
            concealedPIDs: [],
            systemFrames: systemFrames,
            rememberedLeftEdge: nil
        ))
    }

    @Test("Frames left behind on the other display do not drag the edge across")
    func otherDisplayIgnored() {
        let stray = ItemHitTest27.Item(frame: CGRect(x: -500, y: 2, width: 30, height: 24), ownerPID: 13, isOnScreen: true)
        #expect(!ItemHitTest27.isInsideItemsArea(
            point: CGPoint(x: 900, y: 12),
            displayBounds: bounds,
            items: items + [stray],
            concealedPIDs: [],
            systemFrames: systemFrames,
            rememberedLeftEdge: nil
        ))
    }

    @Test("Where nothing is drawn, the edge remembered from that display is used")
    func rememberedEdge() {
        #expect(ItemHitTest27.isInsideItemsArea(
            point: CGPoint(x: 1450, y: 12),
            displayBounds: bounds,
            items: [],
            concealedPIDs: [],
            systemFrames: [],
            rememberedLeftEdge: 1400
        ))
    }

    @Test("The remembered edge counts even when items are drawn further right")
    func rememberedWithDrawn() {
        // Ice's cache holds only the items it manages, so the run of the bar can start
        // further left than anything in it.
        #expect(ItemHitTest27.isInsideItemsArea(
            point: CGPoint(x: 1250, y: 12),
            displayBounds: bounds,
            items: items,
            concealedPIDs: [],
            systemFrames: systemFrames,
            rememberedLeftEdge: 1200
        ))
    }

    @Test("With nothing known at all, hovering still works")
    func nothingKnown() {
        #expect(!ItemHitTest27.isInsideItemsArea(
            point: CGPoint(x: 1450, y: 12),
            displayBounds: bounds,
            items: [],
            concealedPIDs: [],
            systemFrames: [],
            rememberedLeftEdge: nil
        ))
    }
}

@Suite("Settled item frames")
struct SettledFrames27Tests {
    let a = CGRect(x: 100, y: 0, width: 30, height: 24)
    let b = CGRect(x: 140, y: 0, width: 30, height: 24)

    @Test("Items that stayed put through the capture are kept")
    func stayedPut() {
        let frames = ["a": a, "b": b]
        #expect(ItemImages27.settledTags(before: frames, after: frames) == ["a", "b"])
    }

    @Test("An item that moved during the capture is dropped")
    func moved() {
        // The bar re-lays out whenever an item is shown or hidden, and a capture taken
        // across that lands between icons, which is how garbled tiles were stored.
        let after = ["a": a.offsetBy(dx: 35, dy: 0), "b": b]
        #expect(ItemImages27.settledTags(before: ["a": a, "b": b], after: after) == ["b"])
    }

    @Test("An item that vanished during the capture is dropped")
    func vanished() {
        #expect(ItemImages27.settledTags(before: ["a": a, "b": b], after: ["b": b]) == ["b"])
    }

    @Test("A sub-point jitter still counts as settled")
    func jitter() {
        let after = ["a": a.offsetBy(dx: 0.5, dy: 0)]
        #expect(ItemImages27.settledTags(before: ["a": a], after: after) == ["a"])
    }
}

@Suite("Item image trimming")
struct ItemImageTrimming27Tests {
    /// A tile `width` wide whose pixels are opaque only in the given columns.
    func tile(width: Int, opaque: Range<Int>) -> [UInt8] {
        var pixels = [UInt8]()
        for _ in 0..<4 {
            for x in 0..<width {
                pixels += [0, 0, 0, opaque.contains(x) ? 255 : 0]
            }
        }
        return pixels
    }

    @Test("The glyph's own columns are found, whatever the margins around it")
    func glyphColumns() {
        let columns = ItemImages27.glyphColumns(pixels: tile(width: 10, opaque: 3..<7), width: 10, height: 4)
        #expect(columns?.lowerBound == 3)
        #expect(columns?.upperBound == 6)
    }

    @Test("A tile with nothing drawn in it has no columns")
    func emptyTile() {
        #expect(ItemImages27.glyphColumns(pixels: tile(width: 10, opaque: 0..<0), width: 10, height: 4) == nil)
    }

    @Test("A nearly transparent edge does not count as the glyph")
    func faintEdgeIgnored() {
        var pixels = tile(width: 10, opaque: 4..<6)
        pixels[(0 * 10 + 1) * 4 + 3] = 8 // a trace of the neighbouring item
        let columns = ItemImages27.glyphColumns(pixels: pixels, width: 10, height: 4)
        #expect(columns?.lowerBound == 4)
    }
}

@Suite("SectionLayoutEditing27")
struct SectionLayoutEditing27Tests {
    let saved: [String: MacOS27Section] = ["ru.keepcoder.Telegram": .hidden, "com.caldis.Mos": .alwaysHidden]

    @Test("Moving an application to a hidden section stores it")
    func toHidden() {
        let updated = SectionLayout27.settingSection(.hidden, for: "com.electron.pritunl", in: saved)
        #expect(updated["com.electron.pritunl"] == .hidden)
        #expect(updated.count == 3)
    }

    @Test("Moving an application to Visible removes it, since missing means visible")
    func toVisible() {
        let updated = SectionLayout27.settingSection(.visible, for: "ru.keepcoder.Telegram", in: saved)
        #expect(updated["ru.keepcoder.Telegram"] == nil)
        #expect(updated["com.caldis.Mos"] == .alwaysHidden)
    }

    @Test("Moving between hidden sections replaces the entry")
    func between() {
        let updated = SectionLayout27.settingSection(.alwaysHidden, for: "ru.keepcoder.Telegram", in: saved)
        #expect(updated["ru.keepcoder.Telegram"] == .alwaysHidden)
    }
}
