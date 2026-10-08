import CoreGraphics
import Testing
@testable import IceMacOS27Core

@Suite("ApplicationMenuArea27")
struct ApplicationMenuArea27Tests {
    // The displays this was measured on: an external one at the origin, a notched built-in one
    // to its left, at negative coordinates.
    let external = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let builtIn = CGRect(x: -1512, y: 0, width: 1512, height: 982)

    @Test("On the display the menus are drawn on, the area runs from its left edge to their end")
    func ownDisplay() {
        // Safari's menus, measured on the external bar: 10 to 572.
        let area = ApplicationMenuArea27.area(
            menuFrame: CGRect(x: 10, y: 0, width: 562, height: 30),
            ownerDisplay: external,
            display: external
        )
        #expect(area == CGRect(x: 0, y: 0, width: 572, height: 30))
    }

    @Test("The same reach is taken from the other display's own left edge")
    func otherDisplay() {
        let area = ApplicationMenuArea27.area(
            menuFrame: CGRect(x: 10, y: 0, width: 562, height: 30),
            ownerDisplay: external,
            display: builtIn
        )
        #expect(area == CGRect(x: -1512, y: 0, width: 572, height: 30))
    }

    @Test("Menus owned by the display at negative coordinates still reach from the other's left edge")
    func ownerToTheLeft() {
        // The case that revealed the hidden items: the built-in bar is the active one, so the
        // menus are measured at negative coordinates, and the old arithmetic made the external
        // display's area a rect of negative width, which contains nothing.
        let area = ApplicationMenuArea27.area(
            menuFrame: CGRect(x: -1502, y: 0, width: 562, height: 30),
            ownerDisplay: builtIn,
            display: external
        )
        #expect(area == CGRect(x: 0, y: 0, width: 572, height: 30))
    }

    @Test("A notch the other display does not have comes off the reach")
    func notchGap() {
        let area = ApplicationMenuArea27.area(
            menuFrame: CGRect(x: -1502, y: 0, width: 900, height: 30),
            ownerDisplay: builtIn,
            display: external,
            notchGap: 160
        )
        #expect(area.width == 750)
    }

    @Test("The area never leaves the display it is asked about")
    func staysOnTheDisplay() {
        let area = ApplicationMenuArea27.area(
            menuFrame: CGRect(x: -1502, y: 0, width: 4000, height: 30),
            ownerDisplay: builtIn,
            display: external
        )
        #expect(area.width == external.width)
        #expect(area.minX == external.minX)
    }

    @Test("Menus that measure as nothing take up nothing")
    func nothing() {
        let area = ApplicationMenuArea27.area(
            menuFrame: CGRect(x: -1512, y: 0, width: 0, height: 30),
            ownerDisplay: builtIn,
            display: external
        )
        #expect(area.width == 0)
    }
}
