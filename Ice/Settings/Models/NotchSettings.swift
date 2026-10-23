//
//  NotchSettings.swift
//  Ice
//

import Combine
import SwiftUI

/// Model for the app's notch hiding settings.
@MainActor
final class NotchSettings: ObservableObject {
    /// A Boolean value that indicates whether to hide the notch by
    /// painting the strip under the menu bar black in the wallpaper.
    ///
    /// Off by default, so that updating Ice never changes anyone's
    /// wallpaper unasked.
    @Published var hideNotch = false

    /// A Boolean value that indicates whether to hide the notch only on
    /// the notched (built-in) display, rather than on every display.
    @Published var notchMainDisplayOnly = true

    /// A Boolean value that indicates whether to round the top corners
    /// of the wallpaper below the menu bar strip.
    @Published var notchRoundedCorners = true

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Performs the initial setup of the model.
    func performSetup(with appState: AppState) {
        self.appState = appState
        loadInitialState()
        configureCancellables()
    }

    /// Loads the model's initial state.
    ///
    /// For each setting Ice has never stored, the value from the standalone
    /// NotchHider app is adopted, if it has one. Ice took over NotchHider's
    /// job, and someone who ran NotchHider with hiding on has already opted
    /// into the wallpaper rewrite, so carrying their choices over keeps the
    /// switch seamless. Everyone else still starts with hiding off. Ice's own
    /// values always win once they exist, so this happens only once.
    private func loadInitialState() {
        let legacy = UserDefaults(suiteName: Self.legacySuiteName)

        loadValue(key: .hideNotch, legacyKey: "hideNotchEnabled", from: legacy, assign: &hideNotch)
        loadValue(key: .notchMainDisplayOnly, legacyKey: "mainDisplayOnly", from: legacy, assign: &notchMainDisplayOnly)
        loadValue(key: .notchRoundedCorners, legacyKey: "roundedCorners", from: legacy, assign: &notchRoundedCorners)
    }

    /// The defaults domain of the standalone NotchHider app.
    private static let legacySuiteName = "com.michaelyu.NotchHider"

    /// Assigns Ice's stored value for the given key, or, if Ice has none,
    /// the value stored by NotchHider under the legacy key.
    private func loadValue(
        key: Defaults.Key,
        legacyKey: String,
        from legacy: UserDefaults?,
        assign value: inout Bool
    ) {
        if Defaults.object(forKey: key) != nil {
            Defaults.ifPresent(key: key, assign: &value)
        } else if let legacyValue = legacy?.object(forKey: legacyKey) as? Bool {
            value = legacyValue
        }
    }

    /// Configures the internal observers for the model.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $hideNotch
            .receive(on: DispatchQueue.main)
            .sink { hide in
                Defaults.set(hide, forKey: .hideNotch)
            }
            .store(in: &c)

        $notchMainDisplayOnly
            .receive(on: DispatchQueue.main)
            .sink { mainOnly in
                Defaults.set(mainOnly, forKey: .notchMainDisplayOnly)
            }
            .store(in: &c)

        $notchRoundedCorners
            .receive(on: DispatchQueue.main)
            .sink { rounded in
                Defaults.set(rounded, forKey: .notchRoundedCorners)
            }
            .store(in: &c)

        cancellables = c
    }
}
