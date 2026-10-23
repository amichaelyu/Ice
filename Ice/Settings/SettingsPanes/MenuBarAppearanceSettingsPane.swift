//
//  MenuBarAppearanceSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarAppearanceSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var appearanceManager: MenuBarAppearanceManager

    var body: some View {
        // The editor is a scrolling form of its own, so the notch section
        // goes inside it rather than below it.
        MenuBarAppearanceEditor(
            appearanceManager: appearanceManager,
            location: .settings,
            additionalContent: AnyView(NotchSettingsSection(settings: appState.settings.notch))
        )
    }
}
