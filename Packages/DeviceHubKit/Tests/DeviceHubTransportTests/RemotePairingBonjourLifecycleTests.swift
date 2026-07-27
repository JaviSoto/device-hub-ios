import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Remote-pairing Bonjour lifecycle")
struct RemotePairingBonjourLifecycleTests {
    @Test("browsing emits only authenticated known-device availability")
    func authenticatedAvailability() async throws {
        let browser = BrowserProbe()
        let observations = ObservationProbe()
        let transport = makeTransport(
            browser: browser,
            observations: observations
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()

        let initialAvailability = try await iterator.next()
        expectNoDifference(
            initialAvailability,
            [
                RemotePairingAvailability(
                    deviceID: DeviceID(rawValue: "test-phone"),
                    reachability: .unavailable
                )
            ]
        )
        try await browser.emit(.resolved(resolvedService()))
        let reachableAvailability = try await iterator.next()
        expectNoDifference(
            reachableAvailability,
            [
                RemotePairingAvailability(
                    deviceID: DeviceID(rawValue: "test-phone"),
                    reachability: .reachable
                )
            ]
        )
        let recordedObservations = await observations.values
        expectNoDifference(recordedObservations, [])
    }

    @Test("an auth-tag miss never reaches Pair Verify")
    func authTagMissSkipsPairVerify() async throws {
        let browser = BrowserProbe()
        let observations = ObservationProbe()
        let verifier = CandidateVerificationProbe(
            authenticatedDeviceIDs: []
        )
        let transport = makeTransport(
            browser: browser,
            observations: observations,
            verifyCandidate: verifier.verify
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        try await browser.emit(.resolved(resolvedService(
            authTag: "AQIDBAUG"
        )))
        await observations.wait(forCount: 1)

        #expect(await verifier.callCount == 0)
        #expect(await observations.values == [.unknownAnnouncement])
        let service = await transport.resolvedService(
            for: DeviceID(rawValue: "test-phone")
        )
        #expect(service == nil)
    }

    @Test("malformed and unknown announcements never reach availability")
    func malformedAndUnknownServicesAreRejected() async throws {
        let browser = BrowserProbe()
        let observations = ObservationProbe()
        let transport = makeTransport(
            browser: browser,
            observations: observations
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        try await browser.emit(.resolved(resolvedService(
            authTag: "AQIDBAUG"
        )))
        try await browser.emit(.resolved(BonjourResolvedServiceSnapshot(
            serviceName: identifier,
            hostName: "test-iphone.local.",
            port: 49155,
            resolvedEndpoints: [testEndpoint()],
            txtRecord: Data([20, 0x61])
        )))

        await observations.wait(forCount: 2)
        let recordedObservations = await observations.values
        #expect(recordedObservations.count == 2)
        #expect(recordedObservations.contains(.unknownAnnouncement))
        #expect(recordedObservations.contains(.malformedAnnouncement))
        await transport.stopAvailability()
        #expect(try await iterator.next() == nil)
    }

    @Test("consumer cancellation stops browsing exactly once")
    func cancellationStopsBrowsingOnce() async {
        let browser = BrowserProbe()
        let transport = makeTransport(browser: browser)
        let stream = await transport.availability()
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                Issue.record("Unexpected stream error: \(error)")
            }
        }
        await browser.waitUntilStarted()

        consumer.cancel()
        await browser.waitUntilStopped()
        await transport.stopAvailability()

        let startCount = await browser.startCount
        let stopCount = await browser.stopCount
        #expect(startCount == 1)
        #expect(stopCount == 1)
    }

    @Test("callbacks after stop cannot revive a finished stream")
    func callbacksAfterStopAreIgnored() async throws {
        let browser = BrowserProbe()
        let transport = makeTransport(browser: browser)
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        await transport.stopAvailability()
        await transport.stopAvailability()
        try await browser.emit(.resolved(resolvedService()))

        #expect(try await iterator.next() == nil)
        let stopCount = await browser.stopCount
        #expect(stopCount == 1)
    }

    @Test("browser startup failure terminates before availability")
    func browserStartupFailure() async {
        let startFailure = BonjourNativeFailure(
            operation: .browseStart,
            code: -65563
        )
        let failingBrowser = BrowserProbe(startFailure: startFailure)
        let startTransport = makeTransport(browser: failingBrowser)
        let failingStream = await startTransport.availability()
        await expectStreamFailure(
            .browserStartFailed(code: -65563),
            from: failingStream
        )
        let startFailureStopCount = await failingBrowser.stopCount
        #expect(startFailureStopCount == 1)
    }

    @Test("browser runtime failure terminates after initial availability")
    func browserRuntimeFailure() async {
        let runtimeBrowser = BrowserProbe()
        let runtimeTransport = makeTransport(browser: runtimeBrowser)
        let stream = await runtimeTransport.availability()
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
        } catch {
            Issue.record("Unexpected stream error: \(error)")
        }
        await runtimeBrowser.emit(.failed(BonjourNativeFailure(
            operation: .browseRuntime,
            code: -72000
        )))
        await expectIteratorFailure(
            .browserFailed(code: -72000),
            iterator: iterator
        )
        let runtimeFailureStopCount = await runtimeBrowser.stopCount
        #expect(runtimeFailureStopCount == 1)
    }

    @Test("advertising uses an already-bound port and cancels exactly once")
    func advertisementLifecycle() async throws {
        let publisher = PublisherProbe()
        let transport = makeTransport(publisher: publisher)
        let stream = await transport.pairingAdvertisement(
            listenerPort: 49155,
            displayName: "Device Hub",
            model: "Mac17,7"
        )
        var iterator = stream.makeAsyncIterator()
        await publisher.waitUntilStarted()

        let pendingAdvertisement = await publisher.advertisement
        let advertisement = try #require(pendingAdvertisement)
        #expect(advertisement.listenerPort == 49155)
        #expect(
            advertisement.serviceType
                == "_remotepairing-pairable-host._tcp."
        )
        await publisher.emit(.published)
        let publicationEvent = try await iterator.next()
        expectNoDifference(
            publicationEvent,
            PairingAdvertisementEvent.published
        )

        await transport.stopPairingAdvertisement()
        await transport.stopPairingAdvertisement()
        await publisher.emit(.published)
        #expect(try await iterator.next() == nil)
        let stopCount = await publisher.stopCount
        #expect(stopCount == 1)
    }

    @Test("publisher failures terminate without leaking advertisement data")
    func publisherFailure() async {
        let publisher = PublisherProbe()
        let transport = makeTransport(publisher: publisher)
        let stream = await transport.pairingAdvertisement(
            listenerPort: 49155,
            displayName: "Device Hub",
            model: "Mac17,7"
        )
        let iterator = stream.makeAsyncIterator()
        await publisher.waitUntilStarted()

        await publisher.emit(.failed(BonjourNativeFailure(
            operation: .publishRuntime,
            code: -72001
        )))

        await expectIteratorFailure(
            .publisherFailed(code: -72001),
            iterator: iterator
        )
        let stopCount = await publisher.stopCount
        #expect(stopCount == 1)
    }

    @Test("per-service resolution failures are observed without a denial of service")
    func resolveFailureIsObserved() async throws {
        let browser = BrowserProbe()
        let observations = ObservationProbe()
        let transport = makeTransport(
            browser: browser,
            observations: observations
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        await browser.emit(.resolutionFailed(BonjourNativeFailure(
            operation: .resolve,
            code: -72007
        )))
        await observations.wait(forCount: 1)
        let recordedObservations = await observations.values
        expectNoDifference(
            recordedObservations,
            [.resolutionFailed]
        )

        try await browser.emit(.resolved(resolvedService()))
        let availability = try await iterator.next()
        #expect(availability?.first?.reachability == .reachable)
    }

    @Test("diagnostic sink failure cannot stop authenticated availability")
    func diagnosticSinkFailureDoesNotStopAvailability() async throws {
        let browser = BrowserProbe()
        let failingObservations = FailingObservationProbe()
        let failureReports = DiagnosticsFailureReportProbe()
        let transport = makeTransport(
            browser: browser,
            observe: failingObservations.record,
            reportDiagnosticsFailure: failureReports.record
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        try await browser.emit(.resolved(resolvedService(
            authTag: "AQIDBAUG"
        )))
        await failingObservations.wait(forCount: 1)
        try await browser.emit(.resolved(resolvedService()))

        let availability = try await iterator.next()
        #expect(availability?.first?.reachability == .reachable)
        #expect(await browser.stopCount == 0)
        #expect(failureReports.count == 1)
    }
}

func makeTransport(
    browser: BrowserProbe = BrowserProbe(),
    publisher: PublisherProbe = PublisherProbe(),
    observations: ObservationProbe = ObservationProbe(),
    observe: (
        @Sendable (BonjourTransportObservation) async throws -> Void
    )? = nil,
    reportDiagnosticsFailure: @escaping @Sendable () -> Void = {},
    verifyCandidate:
    @escaping @Sendable (
        DeviceID,
        ValidatedRemotePairingService
    ) async -> Bool = { _, service in
        service.authTags.contains {
            $0.base64EncodedString() == "kXjlTr2l"
        }
    },
    loadKnownDevices:
    @escaping @Sendable () async throws -> [KnownRemotePairingDevice] = {
        try [
            KnownRemotePairingDevice(
                deviceID: DeviceID(rawValue: "test-phone"),
                alternateIRK: #require(Data(
                    base64Encoded: "Mgp6ZGPzXM2ku9br46vsiw=="
                ))
            )
        ]
    }
) -> RemotePairingBonjourTransport {
    RemotePairingBonjourTransport(
        loadKnownDevices: loadKnownDevices,
        loadPairableHostIdentity: {
            try PairableHostIdentity(
                identifier: #require(UUID(uuidString: identifier)),
                alternateIRK: #require(Data(
                    base64Encoded: "Mgp6ZGPzXM2ku9br46vsiw=="
                ))
            )
        },
        browser: browser.client,
        publisher: publisher.client,
        verifyCandidate: verifyCandidate,
        observe: observe ?? observations.record,
        reportDiagnosticsFailure: reportDiagnosticsFailure
    )
}

func resolvedService(
    authTag: String = "kXjlTr2l",
    port: Int = 49155
) throws -> BonjourResolvedServiceSnapshot {
    let endpoint = try NativeResolvedEndpoint(
        family: .ipv4,
        address: Data([192, 168, 1, 44]),
        scopeID: 0,
        port: #require(UInt16(exactly: port))
    )
    return try BonjourResolvedServiceSnapshot(
        serviceName: identifier,
        hostName: "test-iphone.local.",
        port: port,
        resolvedEndpoints: [endpoint],
        txtRecord: makeTXT([
            ("identifier", identifier),
            ("authTag", authTag),
            ("flags", "0"),
            ("ver", "26"),
            ("minVer", "8")
        ])
    )
}

actor BrowserProbe {
    private var handler: (@Sendable (BonjourBrowserEvent) -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private let startFailure: BonjourNativeFailure?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(startFailure: BonjourNativeFailure? = nil) {
        self.startFailure = startFailure
    }

    nonisolated var client: BonjourBrowserClient {
        BonjourBrowserClient(
            start: { handler async throws(BonjourNativeFailure) in
                do {
                    try await self.start(handler: handler)
                } catch let failure as BonjourNativeFailure {
                    throw failure
                } catch {
                    throw BonjourNativeFailure(
                        operation: .browseStart,
                        code: -1
                    )
                }
            },
            stop: {
                await self.stop()
            }
        )
    }

    func emit(_ event: BonjourBrowserEvent) {
        handler?(event)
    }

    func waitUntilStarted() async {
        guard startCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilStopped() async {
        guard stopCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    private func start(
        handler: @escaping @Sendable (BonjourBrowserEvent) -> Void
    ) throws(BonjourNativeFailure) {
        startCount += 1
        self.handler = handler
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if let startFailure {
            throw startFailure
        }
    }

    private func stop() {
        stopCount += 1
        stopWaiters.forEach { $0.resume() }
        stopWaiters.removeAll()
    }
}

actor PublisherProbe {
    private var handler: (@Sendable (BonjourPublisherEvent) -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var advertisement: PairableHostAdvertisement?
    private(set) var stopCount = 0

    nonisolated var client: BonjourPublisherClient {
        BonjourPublisherClient(
            start: { advertisement, handler in
                await self.start(
                    advertisement: advertisement,
                    handler: handler
                )
            },
            stop: {
                await self.stop()
            }
        )
    }

    func emit(_ event: BonjourPublisherEvent) {
        handler?(event)
    }

    func waitUntilStarted() async {
        guard advertisement == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func start(
        advertisement: PairableHostAdvertisement,
        handler: @escaping @Sendable (BonjourPublisherEvent) -> Void
    ) {
        self.advertisement = advertisement
        self.handler = handler
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    private func stop() {
        stopCount += 1
    }
}

actor ObservationProbe {
    private var waiters: [
        (
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []
    private(set) var values: [BonjourTransportObservation] = []

    nonisolated var record:
        @Sendable (BonjourTransportObservation) async throws -> Void
    {
        { observation in
            await self.append(observation)
        }
    }

    func wait(forCount count: Int) async {
        guard values.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func append(_ observation: BonjourTransportObservation) {
        values.append(observation)
        let ready = waiters.filter { values.count >= $0.count }
        waiters.removeAll { values.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor FailingObservationProbe {
    private enum Failure: Error {
        case unavailable
    }

    private var attempts = 0
    private var waiters: [
        (
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []

    nonisolated var record:
        @Sendable (BonjourTransportObservation) async throws -> Void
    {
        { _ in
            try await self.fail()
        }
    }

    func wait(forCount count: Int) async {
        guard attempts < count else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func fail() throws {
        attempts += 1
        let ready = waiters.filter { attempts >= $0.count }
        waiters.removeAll { attempts >= $0.count }
        ready.forEach { $0.continuation.resume() }
        throw Failure.unavailable
    }
}

private final class DiagnosticsFailureReportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reportCount = 0

    var count: Int {
        lock.withLock { reportCount }
    }

    func record() {
        lock.withLock {
            reportCount += 1
        }
    }
}

private func expectStreamFailure(
    _ expected: RemotePairingBonjourError,
    from stream: AsyncThrowingStream<
        [RemotePairingAvailability],
        Error
    >
) async {
    let iterator = stream.makeAsyncIterator()
    await expectIteratorFailure(expected, iterator: iterator)
}

private func expectIteratorFailure(
    _ expected: RemotePairingBonjourError,
    iterator: AsyncThrowingStream<some Any, Error>.Iterator
) async {
    var iterator = iterator
    do {
        _ = try await iterator.next()
        Issue.record("Expected \(expected)")
    } catch let error as RemotePairingBonjourError {
        expectNoDifference(error, expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
