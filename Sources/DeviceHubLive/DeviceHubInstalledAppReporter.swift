import CryptoKit
import Foundation
import UIKit

/// The opaque device identity shared by Javi's cooperating iOS apps.
///
/// The raw `identifierForVendor` value never leaves the device. A
/// domain-separated SHA-256 digest gives each app the same stable key while
/// keeping the vendor identifier out of the Builds.lan service.
public enum DeviceHubInstalledDeviceIdentity {
    private static let digestPrefix = "builds.lan/device/v1:"

    /// Returns the current device key, or `nil` when iOS has not supplied an
    /// identifier for this installation.
    @MainActor
    public static var current: String? {
        guard let identifier = UIDevice.current.identifierForVendor else {
            return nil
        }
        return key(for: identifier)
    }

    /// Derives the stable service key from a vendor identifier.
    public static func key(for identifier: UUID) -> String {
        let input = Data(
            "\(digestPrefix)\(identifier.uuidString.lowercased())".utf8
        )
        let digest = SHA256.hash(data: input)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The exact app metadata sent to the Builds.lan installed-app registry.
public struct DeviceHubInstalledAppReport: Encodable, Equatable, Sendable {
    public let deviceID: String
    public let bundleIdentifier: String
    public let version: String
    public let buildNumber: String
    public let reportedAt: Date
    public let sourceRevision: String?

    public init(
        deviceID: String,
        bundleIdentifier: String,
        version: String,
        buildNumber: String,
        reportedAt: Date,
        sourceRevision: String? = nil
    ) {
        self.deviceID = deviceID
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildNumber = buildNumber
        self.reportedAt = reportedAt
        self.sourceRevision = sourceRevision
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case bundleIdentifier = "bundle_id"
        case version
        case buildNumber = "build_number"
        case reportedAt = "reported_at"
        case sourceRevision = "source_revision"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(version, forKey: .version)
        try container.encode(buildNumber, forKey: .buildNumber)
        try container.encode(reportedAt.ISO8601Format(), forKey: .reportedAt)
        try container.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
    }
}

/// Best-effort registration of the app's exact version with Builds.lan.
///
/// The request is observational. A network failure never changes Device Hub
/// startup or control behavior. Every cooperating app reports on launch and
/// whenever it returns to the foreground so the Builds app can show exact
/// installed versions without relying on restricted LaunchServices records.
public enum DeviceHubInstalledAppReporter {
    public static let endpoint = URL(
        string: "https://api.builds.lan/v1/installed-apps/report"
    )!

    @MainActor
    public static func currentReport(
        bundle: Bundle = .main,
        now: Date = Date()
    ) -> DeviceHubInstalledAppReport? {
        guard
            let deviceID = DeviceHubInstalledDeviceIdentity.current,
            let bundleIdentifier = bundle.bundleIdentifier,
            let version = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            let buildNumber = bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            !bundleIdentifier.isEmpty,
            !version.isEmpty,
            !buildNumber.isEmpty
        else {
            return nil
        }

        return DeviceHubInstalledAppReport(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier,
            version: version,
            buildNumber: buildNumber,
            reportedAt: now,
            sourceRevision: sourceRevision(from: bundle)
        )
    }

    /// Sends the current bundle metadata. This method deliberately has no
    /// failure result because reporting is not part of the app's control path.
    @MainActor
    public static func reportCurrentInstallation(
        bundle: Bundle = .main,
        session: URLSession = .shared,
        now: Date = Date()
    ) async {
        guard let report = currentReport(bundle: bundle, now: now) else {
            return
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 8
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        do {
            request.httpBody = try JSONEncoder().encode(report)
            let (_, response) = try await session.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200 ..< 300).contains(httpResponse.statusCode)
            else {
                return
            }
        } catch {
            // Inventory reporting must never prevent Device Hub from opening.
        }
    }

    private static func sourceRevision(from bundle: Bundle) -> String? {
        guard
            let value = bundle.object(
                forInfoDictionaryKey: "CFBundleSourceRevision"
            ) as? String,
            value.count == 40,
            value.allSatisfy(\.isHexDigit),
            value == value.lowercased()
        else {
            return nil
        }
        return value
    }
}
