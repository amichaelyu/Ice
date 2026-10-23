import CoreGraphics
import Testing
@testable import IceMacOS27Core

@Suite("SectionLayout27")
struct SectionLayout27Tests {
    @Test("An app takes its most visible section")
    func appTakesMostVisibleSection() {
        let result = SectionLayout27.appSections(items: [
            (bundleID: "eu.exelban.Stats", section: .hidden),
            (bundleID: "eu.exelban.Stats", section: .visible),
            (bundleID: "ru.keepcoder.Telegram", section: .alwaysHidden),
        ])
        #expect(result == ["eu.exelban.Stats": .visible, "ru.keepcoder.Telegram": .alwaysHidden])
    }

    @Test("The saved layout places running apps")
    func savedPlacesRunningApps() {
        let result = SectionLayout27.effectiveLayout(
            saved: ["com.ethanbills.DockDoor": .hidden],
            running: ["com.ethanbills.DockDoor"]
        )
        #expect(result == ["com.ethanbills.DockDoor": .hidden])
    }

    @Test("Apps seen for the first time are visible")
    func newAppsAreVisible() {
        let result = SectionLayout27.effectiveLayout(saved: [:], running: ["com.example.New"])
        #expect(result == ["com.example.New": .visible])
    }

    @Test("Only running apps are part of the layout")
    func onlyRunningApps() {
        let result = SectionLayout27.effectiveLayout(saved: ["com.example.Quit": .hidden], running: [])
        #expect(result.isEmpty)
    }

    @Test("Bundles are collected by section")
    func bundlesBySection() {
        let layout: [String: MacOS27Section] = ["a": .visible, "b": .hidden, "c": .alwaysHidden]
        #expect(SectionLayout27.bundles(in: [.hidden, .alwaysHidden], layout: layout) == ["b", "c"])
        #expect(SectionLayout27.bundles(in: [.alwaysHidden], layout: layout) == ["c"])
    }
}

@Suite("Seeding the macOS 27 layout from saved positions")
struct SectionLayoutFromPositions27Tests {
    // Ice's dividers as saved on the Mac this was written on.
    let hidden: CGFloat = 704
    let alwaysHidden: CGFloat = 732

    @Test("Each divider places the items left of it")
    func dividers() {
        let result = SectionLayout27.seededLayout(
            preferredPositions: [
                "com.caldis.Mos": [320],
                "eu.exelban.Stats": [710],
                "ru.keepcoder.Telegram": [900],
            ],
            hiddenDivider: hidden,
            alwaysHiddenDivider: alwaysHidden
        )
        #expect(result == [
            "com.caldis.Mos": .visible,
            "eu.exelban.Stats": .hidden,
            "ru.keepcoder.Telegram": .alwaysHidden,
        ])
    }

    @Test("An application with several items takes the most hidden one")
    func mostHidden() {
        let result = SectionLayout27.seededLayout(
            preferredPositions: ["eu.exelban.Stats": [120, 760, 715]],
            hiddenDivider: hidden,
            alwaysHiddenDivider: alwaysHidden
        )
        #expect(result == ["eu.exelban.Stats": .alwaysHidden])
    }

    @Test("Without an always-hidden divider nothing is always hidden")
    func noAlwaysHidden() {
        let result = SectionLayout27.seededLayout(
            preferredPositions: ["ru.keepcoder.Telegram": [900], "com.caldis.Mos": [10]],
            hiddenDivider: hidden,
            alwaysHiddenDivider: nil
        )
        #expect(result == ["ru.keepcoder.Telegram": .hidden, "com.caldis.Mos": .visible])
    }

    @Test("An always-hidden divider right of the hidden one is ignored")
    func misplacedAlwaysHidden() {
        let result = SectionLayout27.seededLayout(
            preferredPositions: ["ru.keepcoder.Telegram": [900], "eu.exelban.Stats": [650]],
            hiddenDivider: hidden,
            alwaysHiddenDivider: 600
        )
        #expect(result == ["ru.keepcoder.Telegram": .hidden, "eu.exelban.Stats": .visible])
    }

    @Test("An item exactly at a divider stays on its right")
    func atDivider() {
        let result = SectionLayout27.seededLayout(
            preferredPositions: ["eu.exelban.Stats": [704], "ru.keepcoder.Telegram": [732]],
            hiddenDivider: hidden,
            alwaysHiddenDivider: alwaysHidden
        )
        #expect(result == ["eu.exelban.Stats": .visible, "ru.keepcoder.Telegram": .hidden])
    }

    @Test("Applications with no saved position are left out")
    func noPosition() {
        let result = SectionLayout27.seededLayout(
            preferredPositions: ["com.caldis.Mos": []],
            hiddenDivider: hidden,
            alwaysHiddenDivider: alwaysHidden
        )
        #expect(result.isEmpty)
    }
}
