import Darwin
import Foundation
import UIKit

/// Resolves the controller's user-assigned iPhone or iPad name.
///
/// iOS may redact `UIDevice.name` without a restricted entitlement. This
/// private-use app therefore asks MobileGestalt first and retains UIKit's name
/// as a nonfatal fallback.
public enum DeviceHubCurrentDeviceName {
    private static let userProvidedNameKey =
        "DeviceHub.userProvidedControllerName"
    private typealias MobileGestaltCopyAnswer =
        @convention(c) (CFString) -> Unmanaged<CFTypeRef>?

    /// Returns the best available device name for nearby-pairing UI.
    @MainActor
    public static func load() -> String {
        resolve(
            privateName: privateUIKitName() ?? mobileGestaltName(),
            publicName: UIDevice.current.name,
            modelName: UIDevice.current.model
        )
    }

    /// Returns the normalized name explicitly chosen inside Device Hub.
    public static func userProvidedName(
        userDefaults: UserDefaults = .standard
    ) -> String? {
        normalized(userDefaults.string(forKey: userProvidedNameKey))
    }

    /// Persists the controller name used by future pairing advertisements.
    public static func saveUserProvidedName(
        _ name: String,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(normalized(name), forKey: userProvidedNameKey)
    }

    /// Detects Apple's privacy-redacted device labels.
    public static func requiresUserProvidedName(_ name: String) -> Bool {
        ["iPhone", "iPad", "iPod touch"].contains(name)
    }

    /// Selects the first meaningful name without leaking lookup mechanics into
    /// production composition.
    static func resolve(
        privateName: String?,
        publicName: String?,
        modelName: String
    ) -> String {
        normalized(privateName)
            ?? normalized(publicName)
            ?? modelName
    }

    @MainActor
    private static func privateUIKitName() -> String? {
        let selector = NSSelectorFromString("_deviceInfoForKey:")
        guard UIDevice.current.responds(to: selector) else {
            return nil
        }
        return UIDevice.current
            .perform(selector, with: "DeviceName")?
            .takeUnretainedValue() as? String
    }

    private static func mobileGestaltName() -> String? {
        let paths = [
            "/usr/lib/libMobileGestalt.dylib",
            "/System/Library/PrivateFrameworks/MobileGestalt.framework/"
                + "MobileGestalt"
        ]

        for path in paths {
            guard let handle = dlopen(path, RTLD_NOW) else {
                continue
            }
            defer {
                dlclose(handle)
            }
            guard let symbol = dlsym(handle, "MGCopyAnswer") else {
                continue
            }
            let copyAnswer = unsafeBitCast(
                symbol,
                to: MobileGestaltCopyAnswer.self
            )
            guard
                let value = copyAnswer(
                    "UserAssignedDeviceName" as CFString
                )?.takeRetainedValue() as? String
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
