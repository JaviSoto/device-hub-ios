@testable import DeviceHubPreviewRenderer
import Foundation
import ImageIO
import Testing

@Suite("Preview catalog", .serialized)
struct PreviewCatalogTests {
    @Test("The required matrix covers every product state and layout")
    func requiredMatrix() {
        let scenarios = PreviewScenario.required

        #expect(scenarios.count == 9)
        #expect(Set(scenarios.map(\.id)).count == scenarios.count)
        #expect(Set(scenarios.map(\.filename)).count == scenarios.count)
        #expect(Set(scenarios.map(\.state)) == Set(PreviewState.allCases))
        #expect(Set(scenarios.map(\.theme)) == Set(PreviewTheme.allCases))
        #expect(
            scenarios.contains {
                $0.deviceClass == .iPad
                    && $0.orientation == .landscape
                    && $0.layout == .twoColumn
            }
        )
        #expect(
            scenarios.contains {
                $0.deviceClass == .iPhone
                    && $0.orientation == .landscape
                    && $0.remoteScreen == .tabletLandscape
            }
        )
        #expect(
            scenarios.contains {
                $0.dynamicType == .accessibility3
            }
        )
    }

    @Test("Fixtures use generic device identities")
    func fixtureTargetIdentity() throws {
        let devices = try PreviewScenario.required.flatMap {
            try PreviewFixture.state(for: $0).roster.devices
        }

        #expect(devices.contains { $0.name == "Test iPhone" })
        #expect(devices.contains { $0.name == "Test iPad" })
        #expect(devices.contains { $0.id.rawValue == "test-phone" })
        #expect(devices.contains { $0.id.rawValue == "test-ipad" })
    }

    @Test("Fixture states preserve the product presentation semantics")
    func fixtureStateSemantics() throws {
        let states = try Dictionary(
            PreviewScenario.required.map {
                try ($0.state, PreviewFixture.state(for: $0))
            },
            uniquingKeysWith: { first, _ in first }
        )

        let pairing = try #require(states[.pairing])
        #expect(pairing.selectedDevice?.pairingState == .requiresPairing)
        #expect(pairing.session == nil)

        let availableIdle = try #require(states[.availableIdle])
        #expect(availableIdle.isViewingStopped)
        #expect(availableIdle.sessionPresentation == nil)

        let connecting = try #require(states[.connecting])
        #expect(connecting.sessionPresentation == .connecting(.locating))

        let live = try #require(states[.liveFreshFrame])
        #expect(live.sessionPresentation == .live)
        #expect(live.acceptsInput)

        let failure = try #require(states[.actionableFailure])
        #expect(failure.remediation != nil)
        #expect(failure.session == nil)
    }

    @Test("Catalog metadata is derived from the exact PNG bytes")
    func artifactMetadata() throws {
        let scenario = try #require(PreviewScenario.required.first)
        let bytes = Data("fixture".utf8)

        let entries = try PreviewCatalog.entries(
            scenarios: [scenario]
        ) { filename in
            #expect(filename == scenario.filename)
            return bytes
        }
        let entry = try #require(entries.first)

        #expect(entry.path == scenario.filename)
        #expect(entry.viewportWidth == scenario.viewport.width)
        #expect(entry.viewportHeight == scenario.viewport.height)
        #expect(entry.pixelWidth == scenario.viewport.pixelWidth)
        #expect(entry.pixelHeight == scenario.viewport.pixelHeight)
        #expect(entry.byteCount == bytes.count)
        #expect(
            entry.pngSHA256
                == "f16d05ec6b29248d2c61adb1e9263f78"
                + "e4f7bace1b955014a2d17872cfe4064d"
        )

        let json = try PreviewCatalog.encoded(entries)
        #expect(json.last == Character("\n").asciiValue)
        let jsonString = try #require(
            String(data: json, encoding: .utf8)
        )
        #expect(
            jsonString.contains("\"png_sha256\"")
        )
    }

    @MainActor
    @Test("Rendering produces a nonempty PNG at the catalog dimensions")
    func rendersExactPNGDimensions() throws {
        let scenario = try #require(
            PreviewScenario.required.first {
                $0.state == .availableIdle
            }
        )

        let png = try PreviewRenderer.render(scenario)
        let source = try #require(
            CGImageSourceCreateWithData(png as CFData, nil)
        )
        let image = try #require(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )

        #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        #expect(image.width == scenario.viewport.pixelWidth)
        #expect(image.height == scenario.viewport.pixelHeight)
    }

    @MainActor
    @Test("Distinct connection states render distinct product surfaces")
    func rendersDistinctConnectionStates() throws {
        let connecting = try #require(
            PreviewScenario.required.first {
                $0.state == .connecting
            }
        )
        let live = try #require(
            PreviewScenario.required.first {
                $0.state == .liveFreshFrame
            }
        )

        #expect(
            try PreviewRenderer.render(connecting)
                != PreviewRenderer.render(live)
        )
    }

    @MainActor
    @Test("A file-backed catalog requires the exact PNG membership")
    func fileBackedCatalogRequiresExactMembership() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "device-hub-preview-membership-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                Issue.record(
                    "Could not remove preview fixture directory: \(error)"
                )
            }
        }

        #expect(throws: PreviewOutputError.self) {
            try PreviewOutput.catalog(reading: directory)
        }

        try Data().write(
            to: directory.appendingPathComponent("unexpected.png")
        )
        #expect(throws: PreviewOutputError.self) {
            try PreviewOutput.catalog(reading: directory)
        }
    }
}
