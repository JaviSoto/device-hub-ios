import Foundation

enum RemotePairingTXTKey: String, CaseIterable, Equatable, Sendable {
    case authTag
    case flags
    case identifier
    case minimumVersion = "minVer"
    case model
    case name
    case version = "ver"
}

struct RemotePairingTXTEntry: Equatable, Sendable {
    let key: RemotePairingTXTKey
    let value: String
}

enum RemotePairingTXTError: Error, Equatable, Sendable {
    case duplicateAuthTag
    case duplicateField(RemotePairingTXTKey)
    case emptyKey
    case entryTooLong
    case invalidAuthTag
    case invalidField(RemotePairingTXTKey)
    case invalidHostName
    case invalidIdentifier
    case invalidPort
    case invalidUTF8
    case missingField(RemotePairingTXTKey)
    case missingResolvedEndpoint
    case endpointPortMismatch
    case serviceNameMismatch
    case truncatedEntry
    case unknownField
    case unsupportedProtocolVersion
}

enum RemotePairingTXTCodec {
    /// Decodes raw DNS-SD TXT framing without collapsing duplicate keys.
    ///
    /// `NetService.dictionary(fromTXTRecord:)` collapses repeated keys. Parsing
    /// the wire representation here keeps validation fail-closed instead of
    /// silently selecting one value.
    static func entries(from data: Data) throws -> [RemotePairingTXTEntry] {
        var entries: [RemotePairingTXTEntry] = []
        var offset = data.startIndex

        while offset < data.endIndex {
            let length = Int(data[offset])
            offset = data.index(after: offset)
            guard length > 0 else {
                throw RemotePairingTXTError.emptyKey
            }
            guard data.distance(from: offset, to: data.endIndex) >= length else {
                throw RemotePairingTXTError.truncatedEntry
            }

            let end = data.index(offset, offsetBy: length)
            let bytes = data[offset ..< end]
            offset = end
            guard let separator = bytes.firstIndex(of: UInt8(ascii: "=")) else {
                throw RemotePairingTXTError.emptyKey
            }
            let keyBytes = bytes[..<separator]
            guard !keyBytes.isEmpty else {
                throw RemotePairingTXTError.emptyKey
            }
            let valueStart = bytes.index(after: separator)
            guard
                let rawKey = String(bytes: keyBytes, encoding: .utf8),
                let value = String(
                    bytes: bytes[valueStart...],
                    encoding: .utf8
                )
            else {
                throw RemotePairingTXTError.invalidUTF8
            }
            guard let key = RemotePairingTXTKey(rawValue: rawKey) else {
                throw RemotePairingTXTError.unknownField
            }
            entries.append(RemotePairingTXTEntry(key: key, value: value))
        }
        return entries
    }

    static func encode(_ entries: [RemotePairingTXTEntry]) throws -> Data {
        var result = Data()
        for entry in entries {
            let payload = Data(
                "\(entry.key.rawValue)=\(entry.value)".utf8
            )
            guard let length = UInt8(exactly: payload.count) else {
                throw RemotePairingTXTError.entryTooLong
            }
            result.append(length)
            result.append(payload)
        }
        return result
    }
}

/// Fully validated advertisement for an already-bound pairing listener.
///
/// The value is internal so raw TXT data and identity-resolution tags cannot
/// escape the transport boundary.
struct PairableHostAdvertisement:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Sendable
{
    static let serviceType = "_remotepairing-pairable-host._tcp."

    let listenerPort: Int
    let serviceName: String
    let txtRecord: Data

    init(
        identifier: UUID,
        alternateIRK: Data,
        displayName: String,
        model: String,
        listenerPort: Int
    ) throws {
        guard
            alternateIRK.count == 16,
            alternateIRK.contains(where: { $0 != 0 })
        else {
            throw RemotePairingTXTError.invalidAuthTag
        }
        try RemotePairingTXTValidation.validatePort(listenerPort)
        try RemotePairingTXTValidation.validateText(
            displayName,
            key: .name,
            maximumUTF8Length: 128
        )
        try RemotePairingTXTValidation.validateText(
            model,
            key: .model,
            maximumUTF8Length: 64
        )

        let serviceName = identifier.uuidString
        let authTag = RemotePairingAuthTag.compute(
            alternateIRK: alternateIRK,
            serviceIdentifier: serviceName
        )
        self.listenerPort = listenerPort
        self.serviceName = serviceName
        txtRecord = try RemotePairingTXTCodec.encode([
            RemotePairingTXTEntry(key: .name, value: displayName),
            RemotePairingTXTEntry(
                key: .identifier,
                value: serviceName
            ),
            RemotePairingTXTEntry(
                key: .authTag,
                value: authTag.base64EncodedString()
            ),
            RemotePairingTXTEntry(key: .model, value: model),
            RemotePairingTXTEntry(key: .flags, value: "1"),
            RemotePairingTXTEntry(key: .version, value: "26"),
            RemotePairingTXTEntry(
                key: .minimumVersion,
                value: "17"
            )
        ])
    }

    var serviceType: String {
        Self.serviceType
    }

    var description: String {
        "<redacted-pairable-host-advertisement>"
    }

    var debugDescription: String {
        description
    }
}

/// Resolved `_remotepairing._tcp` input that is safe to hand to the native
/// session boundary.
///
/// Construction validates every TXT field and endpoint component. Network
/// identity remains internal and every textual representation is redacted.
struct ValidatedRemotePairingService:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    static let serviceType = "_remotepairing._tcp."

    let authTags: [Data]
    let identifier: String
    let resolvedEndpoints: [NativeResolvedEndpoint]

    init(
        serviceName: String,
        hostName: String,
        port: Int,
        resolvedEndpoints: [NativeResolvedEndpoint],
        txtRecord: Data
    ) throws {
        let parsedEntries = try RemotePairingTXTCodec.entries(from: txtRecord)
        let fields = try RemotePairingTXTFields(entries: parsedEntries)
        let identifier = try fields.required(.identifier)
        guard
            let identifierUUID = UUID(uuidString: identifier),
            identifier.caseInsensitiveCompare(identifierUUID.uuidString)
            == .orderedSame
        else {
            throw RemotePairingTXTError.invalidIdentifier
        }
        guard
            serviceName.caseInsensitiveCompare(identifier) == .orderedSame
        else {
            throw RemotePairingTXTError.serviceNameMismatch
        }
        guard try fields.required(.flags) == "0" else {
            throw RemotePairingTXTError.invalidField(.flags)
        }
        guard
            try fields.required(.version) == "26",
            try fields.required(.minimumVersion) == "8"
        else {
            throw RemotePairingTXTError.unsupportedProtocolVersion
        }

        let authTags = try fields.authTags()
        try RemotePairingTXTValidation.validateHostName(hostName)
        try RemotePairingTXTValidation.validatePort(port)
        guard !resolvedEndpoints.isEmpty else {
            throw RemotePairingTXTError.missingResolvedEndpoint
        }
        guard resolvedEndpoints.allSatisfy({ $0.port == UInt16(port) }) else {
            throw RemotePairingTXTError.endpointPortMismatch
        }
        self.authTags = authTags
        self.identifier = identifierUUID.uuidString
        self.resolvedEndpoints = resolvedEndpoints
            .reduce(into: []) { endpoints, endpoint in
                if !endpoints.contains(endpoint) {
                    endpoints.append(endpoint)
                }
            }
            .sorted(by: canonicalEndpointPrecedes)
    }

    var description: String {
        "<redacted-remote-pairing-service>"
    }

    var debugDescription: String {
        description
    }
}

private func canonicalEndpointPrecedes(
    _ lhs: NativeResolvedEndpoint,
    _ rhs: NativeResolvedEndpoint
) -> Bool {
    let lhsFamily = switch lhs.family {
    case .ipv4: 0
    case .ipv6: 1
    }
    let rhsFamily = switch rhs.family {
    case .ipv4: 0
    case .ipv6: 1
    }
    if lhsFamily != rhsFamily {
        return lhsFamily < rhsFamily
    }
    if lhs.address != rhs.address {
        return lhs.address.lexicographicallyPrecedes(rhs.address)
    }
    if lhs.scopeID != rhs.scopeID {
        return lhs.scopeID < rhs.scopeID
    }
    return lhs.port < rhs.port
}

private struct RemotePairingTXTFields {
    private var values: [RemotePairingTXTKey: [String]]

    init(entries: [RemotePairingTXTEntry]) throws {
        values = Dictionary(grouping: entries, by: \.key)
            .mapValues { $0.map(\.value) }
        for key in RemotePairingTXTKey.allCases where key != .authTag {
            if let count = values[key]?.count, count > 1 {
                throw RemotePairingTXTError.duplicateField(key)
            }
        }
    }

    func required(_ key: RemotePairingTXTKey) throws -> String {
        guard let value = values[key]?.first else {
            throw RemotePairingTXTError.missingField(key)
        }
        return value
    }

    func authTags() throws -> [Data] {
        guard let rawTags = values[.authTag], !rawTags.isEmpty else {
            throw RemotePairingTXTError.missingField(.authTag)
        }

        var tags: [Data] = []
        for rawTag in rawTags {
            guard
                rawTag.utf8.count == 8,
                let tag = Data(base64Encoded: rawTag),
                tag.count == 6,
                tag.base64EncodedString() == rawTag
            else {
                throw RemotePairingTXTError.invalidAuthTag
            }
            guard !tags.contains(tag) else {
                throw RemotePairingTXTError.duplicateAuthTag
            }
            tags.append(tag)
        }
        return tags
    }
}

private enum RemotePairingTXTValidation {
    static func validateText(
        _ value: String,
        key: RemotePairingTXTKey,
        maximumUTF8Length: Int
    ) throws {
        guard
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= maximumUTF8Length,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw RemotePairingTXTError.invalidField(key)
        }
    }

    static func validatePort(_ port: Int) throws {
        guard (1 ... Int(UInt16.max)).contains(port) else {
            throw RemotePairingTXTError.invalidPort
        }
    }

    static func validateHostName(_ hostName: String) throws {
        guard
            !hostName.isEmpty,
            hostName.utf8.count <= 253,
            hostName.hasSuffix(".")
        else {
            throw RemotePairingTXTError.invalidHostName
        }

        let labels = hostName.dropLast().split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard labels.count >= 2 else {
            throw RemotePairingTXTError.invalidHostName
        }
        for label in labels {
            guard
                !label.isEmpty,
                label.utf8.count <= 63,
                label.first != "-",
                label.last != "-",
                label.utf8.allSatisfy(isDNSLabelByte)
            else {
                throw RemotePairingTXTError.invalidHostName
            }
        }
    }

    private static func isDNSLabelByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-")
    }
}

enum RemotePairingAuthTag {
    static func compute(
        alternateIRK: Data,
        serviceIdentifier: String
    ) -> Data {
        precondition(alternateIRK.count == 16)
        let key0 = loadLittleEndianUInt64(Data(
            alternateIRK[alternateIRK.startIndex ..< alternateIRK.index(
                alternateIRK.startIndex,
                offsetBy: 8
            )]
        ))
        let key1 = loadLittleEndianUInt64(Data(
            alternateIRK[alternateIRK.index(
                alternateIRK.startIndex,
                offsetBy: 8
            )...]
        ))
        let output = SipHash24.hash(
            key0: key0,
            key1: key1,
            message: Data(serviceIdentifier.utf8)
        ).littleEndian
        let bytes = withUnsafeBytes(of: output) { Data($0) }
        return Data(bytes.prefix(6).reversed())
    }

    private static func loadLittleEndianUInt64(_ bytes: Data) -> UInt64 {
        bytes.enumerated().reduce(into: UInt64.zero) { result, element in
            result |= UInt64(element.element) << UInt64(element.offset * 8)
        }
    }
}

private enum SipHash24 {
    static func hash(
        key0: UInt64,
        key1: UInt64,
        message: Data
    ) -> UInt64 {
        var state = State(key0: key0, key1: key1)
        var index = message.startIndex

        while message.distance(from: index, to: message.endIndex) >= 8 {
            let end = message.index(index, offsetBy: 8)
            let word = message[index ..< end].enumerated().reduce(
                into: UInt64.zero
            ) { result, element in
                result |= UInt64(element.element)
                    << UInt64(element.offset * 8)
            }
            state.compress(word)
            index = end
        }

        let remainder = message[index...]
        var finalWord = UInt64(message.count) << 56
        for (offset, byte) in remainder.enumerated() {
            finalWord |= UInt64(byte) << UInt64(offset * 8)
        }
        state.compress(finalWord)
        return state.finalize()
    }

    private struct State {
        var value0: UInt64
        var value1: UInt64
        var value2: UInt64
        var value3: UInt64

        init(key0: UInt64, key1: UInt64) {
            value0 = 0x736F_6D65_7073_6575 ^ key0
            value1 = 0x646F_7261_6E64_6F6D ^ key1
            value2 = 0x6C79_6765_6E65_7261 ^ key0
            value3 = 0x7465_6462_7974_6573 ^ key1
        }

        mutating func compress(_ word: UInt64) {
            value3 ^= word
            round()
            round()
            value0 ^= word
        }

        mutating func finalize() -> UInt64 {
            value2 ^= 0xFF
            round()
            round()
            round()
            round()
            return value0 ^ value1 ^ value2 ^ value3
        }

        private mutating func round() {
            value0 &+= value1
            value1 = value1.rotatedLeft(by: 13)
            value1 ^= value0
            value0 = value0.rotatedLeft(by: 32)
            value2 &+= value3
            value3 = value3.rotatedLeft(by: 16)
            value3 ^= value2
            value0 &+= value3
            value3 = value3.rotatedLeft(by: 21)
            value3 ^= value0
            value2 &+= value1
            value1 = value1.rotatedLeft(by: 17)
            value1 ^= value2
            value2 = value2.rotatedLeft(by: 32)
        }
    }
}

private extension UInt64 {
    func rotatedLeft(by count: UInt64) -> UInt64 {
        (self << count) | (self >> (64 - count))
    }
}
