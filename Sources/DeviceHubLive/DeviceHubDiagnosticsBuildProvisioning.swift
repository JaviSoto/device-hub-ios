import DeviceHubDiagnostics
import Foundation

/// Resolves optional diagnostics settings embedded in the application bundle.
///
/// Public builds omit both keys and remain local-only. A distributor may
/// provide both values through local build configuration, but upload still
/// remains disabled until the user explicitly opts in.
public enum DeviceHubDiagnosticsBuildProvisioning {
    private static let endpointKey = "DeviceHubDiagnosticsEndpoint"
    private static let tokenKey = "DeviceHubDiagnosticsBearerToken"

    /// Returns validated optional provisioning from `bundle`.
    public static func uploadProvisioning(
        from bundle: Bundle = .main
    ) throws
        -> DeviceHubDiagnosticsUploadProvisioning?
    {
        try uploadProvisioning(
            infoDictionary: bundle.infoDictionary ?? [:]
        )
    }

    static func uploadProvisioning(
        infoDictionary: [String: Any]
    ) throws -> DeviceHubDiagnosticsUploadProvisioning? {
        let endpointValue = normalizedString(
            infoDictionary[endpointKey]
        )
        let tokenValue = normalizedString(
            infoDictionary[tokenKey]
        )

        if endpointValue == nil, tokenValue == nil {
            return nil
        }
        guard
            let endpointValue,
            let endpoint = URL(string: endpointValue),
            let tokenValue
        else {
            throw DiagnosticUploadFailure.invalidConfiguration
        }
        return try DeviceHubDiagnosticsUploadProvisioning(
            endpoint: endpoint,
            bearerToken: tokenValue
        )
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }
}
