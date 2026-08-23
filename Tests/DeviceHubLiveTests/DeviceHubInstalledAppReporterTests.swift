import DeviceHubLive
import Foundation
import Testing

@Suite("Builds.lan installed-app reporting")
struct DeviceHubInstalledAppReporterTests {
    @Test("vendor identity is a domain-separated lowercase SHA-256 key")
    func vendorIdentity() throws {
        let identifier = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))

        #expect(
            DeviceHubInstalledDeviceIdentity.key(for: identifier)
                == "ec23ddbbfc7fa73ff967144818571cdf2f35f3bae02e1bc44f1cbc2d16b4ff04"
        )
    }

    @Test("report encoding matches the installed-app API schema")
    func reportEncoding() throws {
        let report = DeviceHubInstalledAppReport(
            deviceID: "ec23ddbbfc7fa73ff967144818571cdf2f35f3bae02e1bc44f1cbc2d16b4ff04",
            bundleIdentifier: "es.javisoto.DeviceHub",
            version: "1.0.0",
            buildNumber: "20260823123456",
            reportedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let data = try JSONEncoder().encode(report)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        #expect(object["device_id"] == report.deviceID)
        #expect(object["bundle_id"] == report.bundleIdentifier)
        #expect(object["version"] == report.version)
        #expect(object["build_number"] == report.buildNumber)
        #expect(object["reported_at"] != nil)
        #expect(object["source_revision"] == nil)
    }
}
