import Foundation

/// A validated diagnostics credential whose textual and reflected
/// representations never reveal the underlying token.
public struct DiagnosticBearerToken:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Sendable
{
    public let description = "<redacted>"
    public let debugDescription = "<redacted>"

    let authorizationHeader: String

    public init(
        validating value: String
    ) throws(DiagnosticUploadFailure) {
        guard
            (32 ... 256).contains(value.utf8.count),
            value.unicodeScalars.allSatisfy({
                (33 ... 126).contains($0.value)
            })
        else {
            throw .invalidConfiguration
        }
        authorizationHeader = "Bearer \(value)"
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["authorizationHeader": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Validated, log-free HTTP settings for the schema-v1 diagnostics endpoint.
public struct DiagnosticHTTPUploadConfiguration: Sendable {
    public let endpoint: URL
    public let bearerToken: DiagnosticBearerToken
    public let context: DiagnosticWireContext
    public let requestTimeout: TimeInterval
    public let maximumRequestBodyByteCount: Int
    public let maximumResponseBodyByteCount: Int

    public init(
        endpoint: URL,
        bearerToken: DiagnosticBearerToken,
        context: DiagnosticWireContext,
        requestTimeout: TimeInterval = 15,
        maximumRequestBodyByteCount: Int = 128 * 1024,
        maximumResponseBodyByteCount: Int = 16 * 1024
    ) throws(DiagnosticUploadFailure) {
        try Self.validate(endpoint: endpoint)
        guard
            requestTimeout.isFinite,
            (1 ... 60).contains(requestTimeout),
            (1024 ... 8 * 1024 * 1024).contains(
                maximumRequestBodyByteCount
            ),
            (1 ... 64 * 1024).contains(maximumResponseBodyByteCount)
        else {
            throw .invalidConfiguration
        }

        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.context = context
        self.requestTimeout = requestTimeout
        self.maximumRequestBodyByteCount =
            maximumRequestBodyByteCount
        self.maximumResponseBodyByteCount =
            maximumResponseBodyByteCount
    }

    /// Validates the shared security boundary for diagnostics destinations.
    ///
    /// Callers that provision an endpoint before constructing a complete
    /// upload configuration use this function so every layer enforces the
    /// exact same URL policy.
    public static func validate(
        endpoint: URL
    ) throws(DiagnosticUploadFailure) {
        guard
            endpoint.absoluteString.utf8.count <= 2048,
            let components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw .insecureEndpoint
        }
    }
}

public extension DiagnosticUploadClient {
    /// Creates a private ephemeral uploader. The session disables caches,
    /// cookies, credential storage, and connectivity waits, and the
    /// implementation never reads or logs a response body.
    static func urlSession(
        configuration: DiagnosticHTTPUploadConfiguration
    ) -> Self {
        makeURLSession(
            configuration: configuration,
            protocolClasses: nil,
            now: Date.init
        )
    }

    internal static func urlSession(
        configuration: DiagnosticHTTPUploadConfiguration,
        protocolClasses: [AnyClass],
        now: @escaping @Sendable () -> Date
    ) -> Self {
        makeURLSession(
            configuration: configuration,
            protocolClasses: protocolClasses,
            now: now
        )
    }

    private static func makeURLSession(
        configuration: DiagnosticHTTPUploadConfiguration,
        protocolClasses: [AnyClass]?,
        now: @escaping @Sendable () -> Date
    ) -> Self {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy =
            .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest =
            configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource =
            configuration.requestTimeout
        sessionConfiguration.httpMaximumConnectionsPerHost = 1
        if let protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }

        let session = URLSession(configuration: sessionConfiguration)
        let batchEncoder = DiagnosticWireBatchEncoder(
            context: configuration.context
        )
        return Self { payload async throws(DiagnosticUploadFailure) in
            guard !Task.isCancelled else {
                throw .cancelled
            }

            let snapshot: DiagnosticSnapshot
            do {
                snapshot = try DiagnosticSnapshot.decode(payload)
            } catch {
                throw .invalidPayload
            }

            let envelopes = try batchEncoder.envelopes(
                from: snapshot,
                now: now()
            )
            for envelope in envelopes {
                guard !Task.isCancelled else {
                    throw .cancelled
                }
                let body = try envelope.canonicalJSON()
                guard
                    body.count <= configuration
                    .maximumRequestBodyByteCount
                else {
                    throw .bodyTooLarge
                }

                var request = URLRequest(url: configuration.endpoint)
                request.httpMethod = "POST"
                request.httpBody = body
                request.timeoutInterval = configuration.requestTimeout
                request.cachePolicy =
                    .reloadIgnoringLocalAndRemoteCacheData
                request.httpShouldHandleCookies = false
                request.setValue(
                    configuration.bearerToken.authorizationHeader,
                    forHTTPHeaderField: "Authorization"
                )
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Accept"
                )
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Content-Type"
                )
                request.setValue(
                    "no-store",
                    forHTTPHeaderField: "Cache-Control"
                )

                try await send(
                    request,
                    using: session,
                    maximumResponseBodyByteCount:
                    configuration.maximumResponseBodyByteCount
                )
            }
        }
    }

    private static func send(
        _ request: URLRequest,
        using session: URLSession,
        maximumResponseBodyByteCount: Int
    ) async throws(DiagnosticUploadFailure) {
        do {
            let (responseBytes, response) = try await session.bytes(
                for: request
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DiagnosticUploadFailure.transportFailed
            }
            guard
                httpResponse.statusCode == 200
                || httpResponse.statusCode == 201
            else {
                throw DiagnosticUploadFailure.rejected(
                    statusCode: httpResponse.statusCode
                )
            }

            var receivedByteCount = 0
            for try await _ in responseBytes {
                receivedByteCount += 1
                guard
                    receivedByteCount <= maximumResponseBodyByteCount
                else {
                    throw DiagnosticUploadFailure.responseTooLarge
                }
            }
        } catch let failure as DiagnosticUploadFailure {
            throw failure
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw .cancelled
            case .timedOut:
                throw .timedOut
            default:
                throw .transportFailed
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .transportFailed
        }
    }
}
