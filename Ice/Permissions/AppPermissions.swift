//
//  AppPermissions.swift
//  Ice
//

import Combine
import Foundation
import OSLog

/// A type that manages the permissions of the app.
@MainActor
final class AppPermissions: ObservableObject {
    /// Keys to access individual permissions.
    enum PermissionKey {
        case accessibility
        case screenRecording
    }

    /// The state of the app's granted permissions.
    enum PermissionsState {
        case missing
        case hasAll
        case hasRequired
    }

    /// The manager's logger.
    let logger = Logger(category: "Permissions")

    /// The permission for Accessibility features.
    let accessibility = AccessibilityPermission()

    /// The permission for Screen Recording features.
    let screenRecording = ScreenRecordingPermission()

    /// Full Disk Access, for the native hiding method and the Focus indicator on macOS 27.
    ///
    /// Not part of ``allPermissions``: it is optional, and must not hold up the first-launch
    /// permissions window or ``permissionsState``. It is listed there all the same, through
    /// ``listedPermissions``.
    let fullDiskAccess = FullDiskAccessPermission()

    /// The state of the app's granted permissions.
    @Published private(set) var permissionsState: PermissionsState = .missing

    /// Storage for internal observers.
    private var cancellable: AnyCancellable?

    /// The permissions required for full app functionality.
    var allPermissions: [Permission] {
        [accessibility, screenRecording]
    }

    /// The permissions listed in the first-launch window and the Advanced settings pane: the
    /// ones in ``allPermissions``, plus Full Disk Access on macOS 27, where native hiding and the
    /// Focus indicator use it.
    var listedPermissions: [Permission] {
        if #available(macOS 27.0, *) {
            return allPermissions + [fullDiskAccess]
        }
        return allPermissions
    }

    /// The permissions required for basic app functionality.
    var requiredPermissions: [Permission] {
        allPermissions.filter { $0.isRequired }
    }

    /// Creates a new permissions manager.
    init() {
        self.updatePermissionsState()
        self.cancellable = Publishers.MergeMany(allPermissions.map { $0.$hasPermission })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePermissionsState()
            }
    }

    /// Updates the current permissions state.
    private func updatePermissionsState() {
        if allPermissions.allSatisfy({ $0.hasPermission }) {
            permissionsState = .hasAll
        } else if requiredPermissions.allSatisfy({ $0.hasPermission }) {
            permissionsState = .hasRequired
        } else {
            permissionsState = .missing
        }
    }

    /// Stops running all permissions checks.
    func stopAllChecks() {
        logger.info("Stopping all permissions checks")
        for permission in allPermissions + [fullDiskAccess] {
            permission.stopCheck()
        }
    }
}
