//
//  GroupPreferences27.swift
//  Ice
//

import Foundation

/// One of MenuBarAgent's group-container preference domains, read and written through
/// CoreFoundation's container-aware calls.
///
/// Only these calls reach the observers MenuBarAgent keeps on its domains; a path-based write
/// changes the file and nothing else. The containers open to Ice only with Full Disk Access, and
/// without it a read comes back empty rather than failing. The calls are private, so they are
/// looked up at first use and their absence is an answer rather than a crash.
@available(macOS 27.0, *)
struct GroupPreferences27 {
    private typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
    private typealias SetValue = @convention(c) (CFString, CFPropertyList?, CFString, CFString, CFString, CFString) -> Void
    private typealias Synchronize = @convention(c) (CFString, CFString, CFString, CFString) -> Bool

    private struct Calls {
        let copy: Copy
        let set: SetValue
        let synchronize: Synchronize
    }

    private static let calls: Calls? = {
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
            let copy = dlsym(handle, "_CFPreferencesCopyValueWithContainer"),
            let set = dlsym(handle, "_CFPreferencesSetValueWithContainer"),
            let synchronize = dlsym(handle, "_CFPreferencesSynchronizeWithContainer")
        else {
            return nil
        }
        return Calls(
            copy: unsafeBitCast(copy, to: Copy.self),
            set: unsafeBitCast(set, to: SetValue.self),
            synchronize: unsafeBitCast(synchronize, to: Synchronize.self)
        )
    }()

    /// MenuBarAgent's per-application switches (see `NativeAllowListConcealer27`).
    static let controlCenter = GroupPreferences27(group: "group.com.apple.controlcenter")

    /// MenuBarAgent's item positions (see `ItemPositions27`).
    static let menuBar = GroupPreferences27(group: "com.apple.MenuBar")

    /// Whether the container-aware calls exist on this system.
    static var isAvailable: Bool {
        calls != nil
    }

    private let applicationID: CFString
    private let container: CFString

    private init(group: String) {
        self.applicationID = group as CFString
        self.container = (NSHomeDirectory() + "/Library/Group Containers/" + group) as CFString
    }

    /// The value stored for the given key, or `nil` if there is none or it cannot be read.
    func value(forKey key: String) -> Any? {
        Self.calls?.copy(key as CFString, applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)?
            .takeRetainedValue()
    }

    /// Stores a value for the given key and synchronizes, returning whether that succeeded.
    func set(_ value: Any, forKey key: String) -> Bool {
        guard let calls = Self.calls else {
            return false
        }
        calls.set(key as CFString, value as CFPropertyList, applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
        return calls.synchronize(applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
    }
}
