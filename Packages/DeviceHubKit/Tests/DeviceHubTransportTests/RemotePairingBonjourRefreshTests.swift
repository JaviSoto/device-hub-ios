import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

extension RemotePairingBonjourLifecycleTests {
    @Test(
        "a queued candidate that becomes ambiguous is observed and never verified"
    )
    func queuedCandidateAmbiguityIsObserved() async throws {
        let observations = ObservationProbe()
        let verifier = CandidateVerificationProbe(
            authenticatedDeviceIDs: []
        )
        let transport = makeTransport(
            observations: observations,
            verifyCandidate: verifier.verify
        )
        let fixture = try ambiguousCandidateFixture()
        let token = await transport.installCandidateVerificationState(
            service: fixture.service,
            knownDevices: fixture.knownDevices,
            queued: true
        )

        await transport.startCandidateVerificationIfNeeded(token: token)
        await transport.waitForCandidateVerificationForTesting()

        #expect(await verifier.callCount == 0)
        let recordedObservations = await observations.values
        expectNoDifference(
            recordedObservations,
            [.ambiguousAnnouncement]
        )
    }

    @Test("a synchronous candidate lookup reports ambiguity")
    func synchronousCandidateAmbiguityIsObserved() async throws {
        let observations = ObservationProbe()
        let transport = makeTransport(observations: observations)
        let fixture = try ambiguousCandidateFixture()
        _ = await transport.installCandidateVerificationState(
            service: fixture.service,
            knownDevices: fixture.knownDevices,
            queued: false
        )

        let resolvedDeviceID = await transport
            .resolveInstalledCandidateForTesting(
                serviceKey: fixture.service.identifier.lowercased()
            )
        for _ in 0 ..< 100 where await observations.values.isEmpty {
            await Task.yield()
        }

        #expect(resolvedDeviceID == nil)
        let recordedObservations = await observations.values
        expectNoDifference(
            recordedObservations,
            [.ambiguousAnnouncement]
        )
    }

    @Test("refreshing records reauthenticates retained announcements")
    func refreshKnownDevices() async throws {
        let browser = BrowserProbe()
        let knownDevices = KnownDevicesProbe()
        let transport = makeTransport(
            browser: browser,
            loadKnownDevices: knownDevices.load
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        var availability = try await iterator.next()
        expectNoDifference(availability, [])

        try await browser.emit(.resolved(resolvedService()))
        try await knownDevices.replace(with: [
            KnownRemotePairingDevice(
                deviceID: DeviceID(rawValue: "test-phone"),
                alternateIRK: #require(Data(
                    base64Encoded: "Mgp6ZGPzXM2ku9br46vsiw=="
                ))
            )
        ])
        try await transport.refreshKnownDevices()

        for _ in 0 ..< 2 {
            availability = try await iterator.next()
            if availability?.first?.reachability == .reachable {
                break
            }
        }
        expectNoDifference(
            availability,
            [
                RemotePairingAvailability(
                    deviceID: DeviceID(rawValue: "test-phone"),
                    reachability: .reachable
                )
            ]
        )
        let service = await transport.resolvedService(
            for: DeviceID(rawValue: "test-phone")
        )
        #expect(try service?.resolvedEndpoints == [testEndpoint()])
    }

    @Test(
        "an active control session suppresses competing Pair Verify probes"
    )
    func activeSessionSuppressesPairVerify() async throws {
        let browser = BrowserProbe()
        let verifier = CandidateVerificationProbe(
            authenticatedDeviceIDs: [
                DeviceID(rawValue: "test-phone")
            ]
        )
        let transport = makeTransport(
            browser: browser,
            verifyCandidate: verifier.verify
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        try await browser.emit(.resolved(resolvedService()))
        _ = try await iterator.next()
        #expect(await verifier.callCount == 1)

        let deviceID = DeviceID(rawValue: "test-phone")
        await transport.claimDevice(deviceID)
        let claimedAvailability = try await iterator.next()
        expectNoDifference(
            claimedAvailability,
            [
                RemotePairingAvailability(
                    deviceID: deviceID,
                    reachability: .reachable
                )
            ]
        )

        try await browser.emit(.resolved(resolvedService(port: 49156)))
        let refreshedAvailability = try await iterator.next()
        expectNoDifference(
            refreshedAvailability,
            [
                RemotePairingAvailability(
                    deviceID: deviceID,
                    reachability: .reachable
                )
            ]
        )
        #expect(await verifier.callCount == 1)

        await transport.releaseDevice(deviceID)
        let releasedAvailability = try await iterator.next()
        expectNoDifference(
            releasedAvailability,
            [
                RemotePairingAvailability(
                    deviceID: deviceID,
                    reachability: .unavailable
                )
            ]
        )
        let reauthenticatedAvailability = try await iterator.next()
        expectNoDifference(
            reauthenticatedAvailability,
            [
                RemotePairingAvailability(
                    deviceID: deviceID,
                    reachability: .reachable
                )
            ]
        )
        #expect(await verifier.callCount == 2)
    }
}

private extension RemotePairingBonjourTransport {
    func installCandidateVerificationState(
        service: ValidatedRemotePairingService,
        knownDevices: [KnownRemotePairingDevice],
        queued: Bool
    ) -> UUID {
        let (_, continuation) =
            AsyncThrowingStream<
                [RemotePairingAvailability],
                Error
            >.makeStream()
        let token = UUID()
        let serviceKey = service.identifier.lowercased()
        var state = BrowsingState(
            continuation: continuation,
            knownDevices: knownDevices,
            token: token
        )
        state.nextCandidateRevision = 1
        state.revisionsByServiceName[serviceKey] = 1
        state.servicesByName[serviceKey] = service
        if queued {
            state.pendingVerificationServiceNames = [serviceKey]
            state.queuedVerificationServiceNames = [serviceKey]
        }
        browsingState = state
        return token
    }

    func resolveInstalledCandidateForTesting(
        serviceKey: String
    ) -> DeviceID? {
        guard let state = browsingState else {
            return nil
        }
        return resolvedDeviceID(for: serviceKey, state: state)
    }

    func waitForCandidateVerificationForTesting() async {
        await candidateVerificationTask?.value
    }
}

actor CandidateVerificationProbe {
    private let authenticatedDeviceIDs: Set<DeviceID>
    private(set) var callCount = 0

    init(authenticatedDeviceIDs: Set<DeviceID>) {
        self.authenticatedDeviceIDs = authenticatedDeviceIDs
    }

    nonisolated var verify:
        @Sendable (
            DeviceID,
            ValidatedRemotePairingService
        ) async -> Bool
    {
        { deviceID, _ in
            await self.verify(deviceID)
        }
    }

    private func verify(_ deviceID: DeviceID) -> Bool {
        callCount += 1
        return authenticatedDeviceIDs.contains(deviceID)
    }
}

private func ambiguousCandidateFixture() throws -> (
    service: ValidatedRemotePairingService,
    knownDevices: [KnownRemotePairingDevice]
) {
    let first = try KnownRemotePairingDevice(
        deviceID: DeviceID(rawValue: "first"),
        alternateIRK: Data((1 ... 16).map(UInt8.init))
    )
    let second = try KnownRemotePairingDevice(
        deviceID: DeviceID(rawValue: "second"),
        alternateIRK: Data((17 ... 32).map(UInt8.init))
    )
    let service = try ValidatedRemotePairingService(
        serviceName: identifier,
        hostName: "test-iphone.local.",
        port: 49155,
        resolvedEndpoints: [testEndpoint()],
        txtRecord: makeTXT([
            ("identifier", identifier),
            ("authTag", first.authTag(for: identifier).base64EncodedString()),
            ("authTag", second.authTag(for: identifier).base64EncodedString()),
            ("flags", "0"),
            ("ver", "26"),
            ("minVer", "8")
        ])
    )
    return (service, [first, second])
}

private actor KnownDevicesProbe {
    private var devices: [KnownRemotePairingDevice] = []

    nonisolated var load:
        @Sendable () async throws -> [KnownRemotePairingDevice]
    {
        {
            await self.devices
        }
    }

    func replace(with devices: [KnownRemotePairingDevice]) {
        self.devices = devices
    }
}
