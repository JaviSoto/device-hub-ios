import CustomDump
import Dependencies
import DependenciesTestSupport
import DeviceHubClient
import DeviceHubCore
import IssueReporting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DeviceHubClientTests {
    @Test
    func dependencyOverrideForwardsEveryOperation() async throws {
        let device = DeviceSummary.fixture()
        let pairingCode = try #require(PairingCode("123456"))
        let session = DeviceSession.fixture(device: device)
        let recorder = ClientOperationRecorder()

        try await withDependencies {
            $0.deviceHub = DeviceHubClient(
                pairedDevices: {
                    await recorder.record(.pairedDevices)
                    return [device]
                },
                availability: {
                    AsyncStream { continuation in
                        continuation.yield([device])
                        continuation.finish()
                    }
                },
                pair: { request in
                    AsyncThrowingStream { continuation in
                        Task {
                            await recorder.record(.pair(request))
                            continuation.yield(
                                .waitingForCodeEntry(code: pairingCode)
                            )
                            continuation.finish()
                        }
                    }
                },
                connect: { id in
                    await recorder.record(.connect(id))
                    return session
                },
                forget: { id in
                    await recorder.record(.forget(id))
                }
            )
        } operation: {
            @Dependency(\.deviceHub) var deviceHub

            let pairedDevices = try await deviceHub.pairedDevices()
            expectNoDifference(pairedDevices, [device])

            var availabilityIterator = deviceHub.availability().makeAsyncIterator()
            let availableDevices = await availabilityIterator.next()
            expectNoDifference(availableDevices, [device])
            let availabilityEnd = await availabilityIterator.next()
            expectNoDifference(availabilityEnd, nil)

            var pairingIterator = deviceHub.pair(PairingRequest()).makeAsyncIterator()
            let pairingEvent = try await pairingIterator.next()
            expectNoDifference(
                pairingEvent,
                .waitingForCodeEntry(code: pairingCode)
            )
            let pairingEnd = try await pairingIterator.next()
            expectNoDifference(pairingEnd, nil)

            let connectedSession = try await deviceHub.connect(device.id)
            expectNoDifference(connectedSession.id, session.id)

            try await deviceHub.forget(device.id)
        }

        let operations = await recorder.snapshot()
        expectNoDifference(
            operations,
            [
                .pairedDevices,
                .pair(PairingRequest()),
                .connect(device.id),
                .forget(device.id)
            ]
        )
    }

    @Test
    func unimplementedPairedDevicesFailsLoudly() async {
        await withExpectedIssue {
            _ = try await DeviceHubClient.testValue.pairedDevices()
        }
    }

    @Test
    func unimplementedAvailabilityFailsLoudlyAndTerminates() async {
        await withExpectedIssue {
            let stream = DeviceHubClient.testValue.availability()
            var iterator = stream.makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
    }

    @Test
    func unimplementedPairFailsLoudlyAndTerminates() async {
        await withExpectedIssue {
            let stream = DeviceHubClient.testValue.pair(PairingRequest())
            var iterator = stream.makeAsyncIterator()
            do {
                let event = try await iterator.next()
                #expect(event == nil)
            } catch {
                Issue.record("Unexpected unimplemented-pair error: \(error)")
            }
        }
    }

    @Test
    func unimplementedConnectFailsLoudly() async {
        await withExpectedIssue {
            _ = try await DeviceHubClient.testValue.connect(DeviceID(rawValue: "device"))
        }
    }

    @Test
    func unimplementedForgetFailsLoudly() async {
        await withExpectedIssue {
            try await DeviceHubClient.testValue.forget(DeviceID(rawValue: "device"))
        }
    }

    @Test
    func availabilityConsumerCancellationReachesTheLiveEndpoint() async {
        let termination = ClientTerminationRecorder<
            AsyncStream<[DeviceSummary]>.Continuation.Termination
        >()
        var client = DeviceHubClient.testValue
        client.availability = {
            AsyncStream { continuation in
                continuation.onTermination = { reason in
                    Task {
                        await termination.record(reason)
                    }
                }
            }
        }
        let consumer = Task {
            for await _ in client.availability() {}
        }
        await Task.yield()

        consumer.cancel()
        await consumer.value

        await termination.waitUntilRecorded()
        let terminationReason = await termination.snapshot()
        #expect(terminationReason != nil)
    }

    @Test
    func pairingConsumerCancellationReachesTheLiveEndpoint() async {
        let termination = ClientTerminationRecorder<
            AsyncThrowingStream<PairingEvent, Error>.Continuation.Termination
        >()
        var client = DeviceHubClient.testValue
        client.pair = { _ in
            AsyncThrowingStream { continuation in
                continuation.onTermination = { reason in
                    Task {
                        await termination.record(reason)
                    }
                }
            }
        }
        let consumer = Task {
            for try await _ in client.pair(PairingRequest()) {}
        }
        await Task.yield()

        consumer.cancel()
        do {
            try await consumer.value
        } catch is CancellationError {
            // Expected when cancellation reaches the endpoint.
        } catch {
            Issue.record("Unexpected pairing-consumer error: \(error)")
        }

        await termination.waitUntilRecorded()
        let terminationReason = await termination.snapshot()
        #expect(terminationReason != nil)
    }
}

private actor ClientOperationRecorder {
    enum Operation: Equatable, Sendable {
        case pairedDevices
        case pair(PairingRequest)
        case connect(DeviceID)
        case forget(DeviceID)
    }

    private(set) var operations: [Operation] = []

    func record(_ operation: Operation) {
        operations.append(operation)
    }

    func snapshot() -> [Operation] {
        operations
    }
}

private actor ClientTerminationRecorder<Value: Sendable> {
    private(set) var value: Value?

    func record(_ value: Value) {
        self.value = value
    }

    func waitUntilRecorded() async {
        while value == nil {
            await Task.yield()
        }
    }

    func snapshot() -> Value? {
        value
    }
}
