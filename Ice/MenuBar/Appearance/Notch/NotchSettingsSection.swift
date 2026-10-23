//
//  NotchSettingsSection.swift
//  Ice
//

import SwiftUI

/// The settings for hiding the notch, shown only on Macs with a notched screen.
struct NotchSettingsSection: View {
    @ObservedObject var settings: NotchSettings
    @State private var hasNotchedScreen = NotchHidingManager.hasNotchedScreen

    var body: some View {
        Group {
            if hasNotchedScreen {
                IceSection("Notch") {
                    hideNotch
                    mainDisplayOnly
                        .disabled(!settings.hideNotch)
                    roundedCorners
                        .disabled(!settings.hideNotch)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotchedScreen = NotchHidingManager.hasNotchedScreen
        }
    }

    @ViewBuilder
    private var hideNotch: some View {
        Toggle(isOn: $settings.hideNotch) {
            Text("Hide the notch")
            Text("Paints the strip under the menu bar black by rewriting the desktop wallpaper. Your original wallpaper is restored when this is turned off.")
        }
    }

    @ViewBuilder
    private var mainDisplayOnly: some View {
        Toggle(isOn: $settings.notchMainDisplayOnly) {
            Text("Notched display only")
            Text("Turn off to paint the strip under the menu bar black on every display.")
        }
    }

    @ViewBuilder
    private var roundedCorners: some View {
        Toggle(isOn: $settings.notchRoundedCorners) {
            Text("Rounded corners")
            Text("Rounds the top corners of the wallpaper below the strip, matching the screen corners of the built-in display.")
        }
    }
}
