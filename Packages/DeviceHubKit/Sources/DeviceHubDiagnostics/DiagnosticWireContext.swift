import Foundation

/// Stable, composition-owned identifiers and version metadata attached to
/// every diagnostics upload. Both UUIDs must be independently generated v4
/// values and must never be derived from a device.
public struct DiagnosticWireContext: Codable, Equatable, Sendable {
    public let installationID: UUID
    public let sessionID: UUID
    public let appVersion: String
    public let buildNumber: String

    public init(
        installationID: UUID,
        sessionID: UUID,
        appVersion: String,
        buildNumber: String
    ) throws(DiagnosticUploadFailure) {
        guard
            Self.isRandomVersion4(installationID),
            Self.isRandomVersion4(sessionID),
            installationID != sessionID,
            Self.isValidAppVersion(appVersion),
            Self.isValidBuildNumber(buildNumber)
        else {
            throw .invalidConfiguration
        }

        self.installationID = installationID
        self.sessionID = sessionID
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    private enum CodingKeys: String, CodingKey {
        case appVersion
        case buildNumber
        case installationID
        case sessionID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                installationID: container.decode(
                    UUID.self,
                    forKey: .installationID
                ),
                sessionID: container.decode(
                    UUID.self,
                    forKey: .sessionID
                ),
                appVersion: container.decode(
                    String.self,
                    forKey: .appVersion
                ),
                buildNumber: container.decode(
                    String.self,
                    forKey: .buildNumber
                )
            )
        } catch is DiagnosticUploadFailure {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: container,
                debugDescription: "Invalid diagnostics capture context."
            )
        }
    }

    private static func isRandomVersion4(_ identifier: UUID) -> Bool {
        var bytes = identifier.uuid
        return withUnsafeBytes(of: &bytes) { rawBytes in
            rawBytes[6] >> 4 == 4 && rawBytes[8] >> 6 == 2
        }
    }

    private static func isValidAppVersion(_ value: String) -> Bool {
        guard (3 ... 32).contains(value.count) else {
            return false
        }
        let pattern = #"^[0-9]+(?:\.[0-9]+){1,2}(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?(?:\+[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?$"#
        return value.range(
            of: pattern,
            options: [.regularExpression]
        ) != nil
    }

    private static func isValidBuildNumber(_ value: String) -> Bool {
        guard (1 ... 20).contains(value.count) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value)
        }
    }
}
