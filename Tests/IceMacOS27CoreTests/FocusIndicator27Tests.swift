import CoreGraphics
import Foundation
import Testing
@testable import IceMacOS27Core

@Suite("FocusIndicator27")
struct FocusIndicator27Tests {
    let bar = CGRect(x: 0, y: 1050, width: 1920, height: 30)

    /// `ModeConfigurations.json`, cut down to two modes as written on macOS 27.0.1.
    let configurations = Data("""
    {
      "data": [{
        "modeConfigurations": {
          "com.apple.donotdisturb.mode.default": {
            "mode": {
              "name": "Do Not Disturb",
              "symbolImageName": "moon.fill",
              "tintColorName": "systemIndigoColor",
              "modeIdentifier": "com.apple.donotdisturb.mode.default"
            }
          },
          "com.apple.focus.work": {
            "mode": {
              "name": "Work",
              "symbolImageName": "person.lanyardcard.fill",
              "tintColorName": "systemTealColor",
              "modeIdentifier": "com.apple.focus.work"
            }
          }
        }
      }],
      "header": {}
    }
    """.utf8)

    /// `Assertions.json` holding one assertion per mode, with the given start times.
    func assertions(_ modes: [(identifier: String, start: Double)]) -> Data {
        let records = modes.map { mode in
            """
            {
              "assertionUUID": "E6959565-C556-4995-B1E4-66E9031ED27A",
              "assertionSource": { "assertionClientIdentifier": "com.apple.controlcenter.dnd" },
              "assertionStartDateTimestamp": \(mode.start),
              "assertionDetails": {
                "assertionDetailsIdentifier": "com.apple.controlcenter.dnd",
                "assertionDetailsModeIdentifier": "\(mode.identifier)",
                "assertionDetailsReason": "user-action"
              }
            }
            """
        }
        return Data("""
        {
          "data": [{
            "storeInvalidationRecords": [],
            "storeAssertionRecords": [\(records.joined(separator: ","))]
          }],
          "header": {}
        }
        """.utf8)
    }

    @Test("An active Focus is read with its name, symbol and tint")
    func activeMode() {
        let mode = FocusIndicator27.activeMode(
            assertions: assertions([("com.apple.donotdisturb.mode.default", 814425027.08)]),
            modeConfigurations: configurations
        )
        #expect(mode == FocusIndicator27.Mode(
            identifier: "com.apple.donotdisturb.mode.default",
            name: "Do Not Disturb",
            symbolName: "moon.fill",
            tintName: "systemIndigoColor"
        ))
    }

    @Test("No assertions, no Focus")
    func noAssertions() {
        #expect(FocusIndicator27.activeMode(assertions: assertions([]), modeConfigurations: configurations) == nil)
    }

    @Test("The newest assertion wins")
    func newestWins() {
        let mode = FocusIndicator27.activeMode(
            assertions: assertions([
                ("com.apple.donotdisturb.mode.default", 100),
                ("com.apple.focus.work", 200),
            ]),
            modeConfigurations: configurations
        )
        #expect(mode?.identifier == "com.apple.focus.work")
        #expect(mode?.symbolName == "person.lanyardcard.fill")
        #expect(mode?.tintName == "systemTealColor")
    }

    @Test("A mode the configurations do not list is still shown, as the moon")
    func unknownMode() {
        let mode = FocusIndicator27.activeMode(
            assertions: assertions([("com.example.focus.unknown", 1)]),
            modeConfigurations: configurations
        )
        #expect(mode == FocusIndicator27.Mode(
            identifier: "com.example.focus.unknown",
            name: FocusIndicator27.fallbackName,
            symbolName: FocusIndicator27.fallbackSymbolName,
            tintName: nil
        ))
    }

    @Test("Unreadable configurations still show that a Focus is on")
    func malformedConfigurations() {
        let assertions = assertions([("com.apple.donotdisturb.mode.default", 1)])
        for configurations in [Data("{ not json".utf8), nil] {
            let mode = FocusIndicator27.activeMode(assertions: assertions, modeConfigurations: configurations)
            #expect(mode?.identifier == "com.apple.donotdisturb.mode.default")
            #expect(mode?.symbolName == FocusIndicator27.fallbackSymbolName)
        }
    }

    @Test("Unreadable assertions say nothing")
    func malformedAssertions() {
        for data in [Data(), Data("{ \"data\": [".utf8), Data("{ \"data\": [] }".utf8), Data("[1, 2]".utf8)] {
            #expect(FocusIndicator27.activeMode(assertions: data, modeConfigurations: configurations) == nil)
        }
    }

    @Test("Without the capture indicator it sits left of the items")
    func besideTheItems() {
        let frame = FocusIndicator27.frame(
            barFrame: bar, leftEdgeOfItems: 1400, captureIndicatorFrame: nil, width: 30, gap: 6
        )
        #expect(frame == CGRect(x: 1364, y: 1050, width: 30, height: 30))
    }

    @Test("With the capture indicator it sits left of that")
    func besideTheCaptureIndicator() {
        let capture = CGRect(x: 1358, y: 1050, width: 36, height: 30)
        let frame = FocusIndicator27.frame(
            barFrame: bar, leftEdgeOfItems: 1400, captureIndicatorFrame: capture, width: 30, gap: 6
        )
        #expect(frame == CGRect(x: 1322, y: 1050, width: 30, height: 30))
        #expect(!frame.intersects(capture))
    }

    @Test("A capture indicator on another display is ignored")
    func captureIndicatorElsewhere() {
        let capture = CGRect(x: -400, y: 950, width: 36, height: 33)
        let frame = FocusIndicator27.frame(
            barFrame: bar, leftEdgeOfItems: 1400, captureIndicatorFrame: capture, width: 30, gap: 6
        )
        #expect(frame.maxX == 1394)
    }

    @Test("A bar with no items keeps it at the right end")
    func noItems() {
        let frame = FocusIndicator27.frame(
            barFrame: bar, leftEdgeOfItems: nil, captureIndicatorFrame: nil, width: 30, gap: 6
        )
        #expect(frame.maxX == bar.maxX - 6)
    }
}
