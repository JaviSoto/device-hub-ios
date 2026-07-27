import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

@Suite(.serialized)
struct DiagnosticUploaderTests {
    private let now = Date(timeIntervalSince1970: 1_753_207_200)

    @Test func postsCanonicalBatchesWithPrivateEphemeralHeaders() async throws {
        let requests = LockedRequests()
        DiagnosticURLProtocolStub.install { request in
            requests.append(request)
            return (.fixture(url: request.url, statusCode: 201), Data("ignored".utf8))
        }
        let client = try makeClient()

        try await client.upload(snapshot(eventCount: 1).encoded())

        let request = try #require(requests.values.first)
        expectNoDifference(request.url?.absoluteString, "https://diagnostics.example.test/v1/diagnostics")
        expectNoDifference(request.httpMethod, "POST")
        expectNoDifference(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(Self.tokenValue)"
        )
        expectNoDifference(request.value(forHTTPHeaderField: "Accept"), "application/json")
        expectNoDifference(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        expectNoDifference(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        expectNoDifference(object["schema_version"] as? Int, 1)
        expectNoDifference(
            object["installation_id"] as? String,
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )
    }

    @Test func chunksAtOneHundredAndRetriesWithIdenticalBatchIDs() async throws {
        let requests = LockedRequests()
        DiagnosticURLProtocolStub.install { request in
            requests.append(request)
            return (.fixture(url: request.url, statusCode: 200), Data())
        }
        let client = try makeClient()
        let payload = try snapshot(eventCount: 201).encoded()

        try await client.upload(payload)
        try await client.upload(payload)

        let bodies = try requests.values.map { try #require($0.httpBody) }
        expectNoDifference(bodies.count, 6)
        try expectNoDifference(
            eventCounts(in: Array(bodies.prefix(3))),
            [100, 100, 1]
        )
        try expectNoDifference(
            batchIDs(in: Array(bodies.prefix(3))),
            batchIDs(in: Array(bodies.suffix(3)))
        )
        expectNoDifference(
            Array(bodies.prefix(3)),
            Array(bodies.suffix(3))
        )
    }

    @Test(arguments: [200, 201])
    func acceptsOnlyDocumentedSuccessStatuses(statusCode: Int) async throws {
        DiagnosticURLProtocolStub.install { request in
            (
                .fixture(url: request.url, statusCode: statusCode),
                Data("response body is deliberately ignored".utf8)
            )
        }
        let client = try makeClient()

        try await client.upload(snapshot(eventCount: 1).encoded())
    }

    @Test(arguments: [199, 202, 204, 400, 401, 409, 413, 422, 500])
    func rejectsEveryOtherStatus(statusCode: Int) async throws {
        DiagnosticURLProtocolStub.install { request in
            (
                .fixture(url: request.url, statusCode: statusCode),
                Data("must not enter an error or log".utf8)
            )
        }
        let client = try makeClient()
        let payload = try snapshot(eventCount: 1).encoded()

        do {
            try await client.upload(payload)
            Issue.record("The undocumented status unexpectedly succeeded.")
        } catch {
            expectNoDifference(
                error,
                DiagnosticUploadFailure.rejected(statusCode: statusCode)
            )
        }
    }

    @Test func mapsTransportTimeoutAndCancellationWithoutUnderlyingDetails() async throws {
        let payload = try snapshot(eventCount: 1).encoded()
        for (error, expectedFailure) in [
            (URLError(.cannotConnectToHost), DiagnosticUploadFailure.transportFailed),
            (URLError(.timedOut), .timedOut),
            (URLError(.cancelled), .cancelled)
        ] {
            DiagnosticURLProtocolStub.install { _ in throw error }
            let client = try makeClient()
            do {
                try await client.upload(payload)
                Issue.record("The transport failure unexpectedly succeeded.")
            } catch {
                expectNoDifference(error, expectedFailure)
            }
        }
    }

    @Test func mapsTaskCancellationBeforeStartingTransport() async throws {
        let requests = LockedRequests()
        DiagnosticURLProtocolStub.install { request in
            requests.append(request)
            return (.fixture(url: request.url, statusCode: 201), Data())
        }
        let client = try makeClient()
        let payload = try snapshot(eventCount: 1).encoded()

        let task = Task { () -> DiagnosticUploadFailure? in
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            do {
                try await client.upload(payload)
                return nil
            } catch let failure as DiagnosticUploadFailure {
                return failure
            } catch {
                Issue.record("The uploader returned an unexpected error type.")
                return nil
            }
        }

        let failure = await task.value
        expectNoDifference(
            failure,
            DiagnosticUploadFailure.cancelled
        )
        expectNoDifference(requests.values, [])
    }

    @Test func validatesEndpointTokenTimeoutAndBodyLimits() throws {
        let context = try Self.context()
        let token = try DiagnosticBearerToken(validating: Self.tokenValue)

        #expect(throws: DiagnosticUploadFailure.insecureEndpoint) {
            try DiagnosticHTTPUploadConfiguration(
                endpoint: #require(URL(string: "http://diagnostics.example.test/v1/diagnostics")),
                bearerToken: token,
                context: context
            )
        }
        #expect(throws: DiagnosticUploadFailure.invalidConfiguration) {
            try DiagnosticBearerToken(validating: "too-short")
        }
        #expect(throws: DiagnosticUploadFailure.invalidConfiguration) {
            try DiagnosticHTTPUploadConfiguration(
                endpoint: #require(URL(string: "https://diagnostics.example.test/v1/diagnostics")),
                bearerToken: token,
                context: context,
                requestTimeout: 0
            )
        }
        #expect(throws: DiagnosticUploadFailure.invalidConfiguration) {
            try DiagnosticHTTPUploadConfiguration(
                endpoint: #require(URL(string: "https://diagnostics.example.test/v1/diagnostics")),
                bearerToken: token,
                context: context,
                maximumRequestBodyByteCount: 1
            )
        }
    }

    @Test(
        "shared endpoint validation rejects every unsafe URL shape",
        arguments: [
            "http://diagnostics.example.test/v1/diagnostics",
            "https://user@diagnostics.example.test/v1/diagnostics",
            "https://user:password@diagnostics.example.test/v1/diagnostics",
            "https://diagnostics.example.test/v1/diagnostics?device=1",
            "https://diagnostics.example.test/v1/diagnostics#device",
            "https:///v1/diagnostics"
        ]
    )
    func rejectsUnsafeEndpointShapes(urlString: String) throws {
        let endpoint = try #require(URL(string: urlString))

        #expect(throws: DiagnosticUploadFailure.insecureEndpoint) {
            try DiagnosticHTTPUploadConfiguration.validate(
                endpoint: endpoint
            )
        }
    }

    @Test func bearerTokenIsRedactedFromEveryRepresentation() throws {
        let token = try DiagnosticBearerToken(validating: Self.tokenValue)

        expectNoDifference(token.description, "<redacted>")
        expectNoDifference(token.debugDescription, "<redacted>")
        #expect(!String(reflecting: token).contains(Self.tokenValue))
        #expect(!String(describing: token.customMirror).contains(Self.tokenValue))
    }

    @Test func rejectsMalformedLocalSnapshotsAndOversizedResponses() async throws {
        DiagnosticURLProtocolStub.install { request in
            (
                .fixture(url: request.url, statusCode: 201),
                Data(repeating: 0, count: 65)
            )
        }
        let client = try makeClient(maximumResponseBodyByteCount: 64)

        await #expect(throws: DiagnosticUploadFailure.invalidPayload) {
            try await client.upload(Data("{}".utf8))
        }
        await #expect(throws: DiagnosticUploadFailure.responseTooLarge) {
            try await client.upload(snapshot(eventCount: 1).encoded())
        }
    }

    @Test func rejectsAnOversizedRequestBeforeStartingTransport() async throws {
        let requests = LockedRequests()
        DiagnosticURLProtocolStub.install { request in
            requests.append(request)
            return (.fixture(url: request.url, statusCode: 201), Data())
        }
        let client = try makeClient(maximumRequestBodyByteCount: 1024)

        await #expect(throws: DiagnosticUploadFailure.bodyTooLarge) {
            try await client.upload(snapshot(eventCount: 100).encoded())
        }
        expectNoDifference(requests.values, [])
    }

    @Test func anExpiredRestoredOutboxCompletesWithoutStartingTransport() async throws {
        let requests = LockedRequests()
        DiagnosticURLProtocolStub.install { request in
            requests.append(request)
            return (.fixture(url: request.url, statusCode: 201), Data())
        }
        let client = try makeClient()
        let expired = try DiagnosticSnapshot(
            context: Self.context(),
            events: [
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                )
            ]
        )

        try await client.upload(expired.encoded())

        expectNoDifference(requests.values, [])
    }

    private func makeClient(
        maximumRequestBodyByteCount: Int = 128 * 1024,
        maximumResponseBodyByteCount: Int = 16 * 1024
    ) throws -> DiagnosticUploadClient {
        let configuration = try DiagnosticHTTPUploadConfiguration(
            endpoint: #require(
                URL(string: "https://diagnostics.example.test/v1/diagnostics")
            ),
            bearerToken: DiagnosticBearerToken(validating: Self.tokenValue),
            context: Self.context(),
            maximumRequestBodyByteCount:
            maximumRequestBodyByteCount,
            maximumResponseBodyByteCount: maximumResponseBodyByteCount
        )
        return DiagnosticUploadClient.urlSession(
            configuration: configuration,
            protocolClasses: [DiagnosticURLProtocolStub.self],
            now: { now }
        )
    }

    private func snapshot(eventCount: Int) -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            events: (1 ... eventCount).map { sequence in
                DiagnosticEvent(
                    sequence: UInt64(sequence),
                    timestamp: now.addingTimeInterval(TimeInterval(sequence) / 1000),
                    level: .info,
                    category: .connection,
                    stage: .openingTunnel,
                    kind: .operationSucceeded,
                    fields: DiagnosticFields(
                        attempt: 1,
                        outcome: .succeeded
                    )
                )
            }
        )
    }

    private func eventCounts(in bodies: [Data]) throws -> [Int] {
        try bodies.map { body in
            let object = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            return try #require((object["events"] as? [Any])?.count)
        }
    }

    private func batchIDs(in bodies: [Data]) throws -> [String] {
        try bodies.map { body in
            let object = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            return try #require(object["batch_id"] as? String)
        }
    }

    private static let tokenValue =
        "test-only-diagnostics-token-value-0001"

    private static func context() throws -> DiagnosticWireContext {
        try DiagnosticWireContext(
            installationID: #require(
                UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            ),
            sessionID: #require(
                UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
            ),
            appVersion: "1.0.0",
            buildNumber: "42"
        )
    }
}

private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var values: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock {
            storage.append(request)
        }
    }
}

private final class DiagnosticURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler =
        @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var installedHandler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            installedHandler = handler
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.installedHandler }
        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unknown)
            )
            return
        }

        do {
            let materializedRequest = try Self.materializeBody(in: request)
            let (response, data) = try handler(materializedRequest)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func materializeBody(
        in request: URLRequest
    ) throws -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = stream.read(
                &buffer,
                maxLength: buffer.count
            )
            if readCount < 0 {
                throw stream.streamError
                    ?? URLError(.cannotDecodeContentData)
            }
            guard readCount > 0 else {
                break
            }
            body.append(contentsOf: buffer.prefix(readCount))
        }

        var materializedRequest = request
        materializedRequest.httpBody = body
        return materializedRequest
    }
}

private extension HTTPURLResponse {
    static func fixture(url: URL?, statusCode: Int) -> HTTPURLResponse {
        guard
            let url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            preconditionFailure("The test response must be constructible.")
        }
        return response
    }
}
