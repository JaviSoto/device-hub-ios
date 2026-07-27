#if DEBUG
    @testable import DeviceHubUI
    import Testing

    @MainActor
    @Suite("Device Hub simulator fixtures")
    struct DeviceHubPreviewFixtureTests {
        @Test("every launch fixture builds without live feature work")
        func allFixturesBuild() throws {
            for fixture in DeviceHubPreviewFixture.allCases {
                let state = try fixture.state()
                #expect(
                    state.roster.devices.allSatisfy {
                        ["Test iPhone", "Test iPad"].contains($0.name)
                    }
                )
                if fixture == .live || fixture == .liveLandscape {
                    #expect(state.acceptsInput)
                }
                if fixture == .liveLandscape {
                    #expect(
                        state.session?.frame?.metadata.orientation
                            == .landscapeRight
                    )
                    #expect(
                        state.selectedDevice?.name
                            == "Test iPad"
                    )
                }
                _ = try fixture.makeView()
            }
        }

        @Test("launch argument names remain stable")
        func stableNames() {
            #expect(
                DeviceHubPreviewFixture.allCases.map(\.rawValue)
                    == [
                        "connecting",
                        "empty",
                        "live",
                        "live-landscape",
                        "locked-error",
                        "pairing"
                    ]
            )
        }
    }
#endif
