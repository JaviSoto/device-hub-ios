import Foundation

public extension DiagnosticPersistenceClient {
    /// Creates a persistence client that writes complete, immutable snapshots
    /// with first-unlock protection and backup exclusion, then removes the
    /// oldest files after each successful write.
    static func rotatingFiles(
        directory: URL,
        maximumSnapshotCount: Int
    ) throws(DiagnosticPersistenceFailure) -> Self {
        try rotatingFiles(
            directory: directory,
            maximumSnapshotCount: maximumSnapshotCount,
            fileSecurity: .live
        )
    }
}

extension DiagnosticPersistenceClient {
    static func rotatingFiles(
        directory: URL,
        maximumSnapshotCount: Int,
        fileSecurity: DiagnosticFileSecurity
    ) throws(DiagnosticPersistenceFailure) -> Self {
        guard maximumSnapshotCount > 0 else {
            throw .invalidFileRetentionPolicy
        }

        let store = RotatingDiagnosticFileStore(
            directory: directory,
            maximumSnapshotCount: maximumSnapshotCount,
            fileSecurity: fileSecurity
        )
        return Self(
            load: { () async throws(DiagnosticPersistenceFailure) in
                try await store.load()
            },
            save: { data async throws(DiagnosticPersistenceFailure) in
                try await store.save(data)
            },
            clear: { () async throws(DiagnosticPersistenceFailure) in
                try await store.clear()
            }
        )
    }
}

/// Applies the distinct filesystem security policies for a diagnostics
/// directory and its immutable snapshot files.
struct DiagnosticFileSecurity: Sendable {
    var excludeFromBackup:
        @Sendable (URL) throws(DiagnosticPersistenceFailure) -> Void
    var hardenSnapshot:
        @Sendable (URL) throws(DiagnosticPersistenceFailure) -> Void

    static let live = Self(
        excludeFromBackup: { url throws(DiagnosticPersistenceFailure) in
            try Self.excludeFromBackup(url)
        },
        hardenSnapshot: { url throws(DiagnosticPersistenceFailure) in
            try Self.excludeFromBackup(url)
            do {
                try FileManager.default.setAttributes(
                    [
                        .protectionKey:
                            FileProtectionType
                            .completeUntilFirstUserAuthentication
                    ],
                    ofItemAtPath: url.path()
                )
            } catch {
                throw DiagnosticPersistenceFailure
                    .fileSecurityConfigurationFailed
            }
        }
    )

    private static func excludeFromBackup(
        _ url: URL
    ) throws(DiagnosticPersistenceFailure) {
        var securedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try securedURL.setResourceValues(values)
        } catch {
            throw .fileSecurityConfigurationFailed
        }
    }
}

private actor RotatingDiagnosticFileStore {
    private struct SnapshotFile {
        var sequence: UInt64
        var url: URL
    }

    private let directory: URL
    private let fileSecurity: DiagnosticFileSecurity
    private let maximumSnapshotCount: Int

    init(
        directory: URL,
        maximumSnapshotCount: Int,
        fileSecurity: DiagnosticFileSecurity
    ) {
        self.directory = directory
        self.fileSecurity = fileSecurity
        self.maximumSnapshotCount = maximumSnapshotCount
    }

    func load() throws(DiagnosticPersistenceFailure) -> Data? {
        guard directoryExists else {
            return nil
        }

        let files = try snapshotFiles(failure: .loadingFailed)
        try fileSecurity.excludeFromBackup(directory)
        for file in files {
            try fileSecurity.hardenSnapshot(file.url)
        }
        guard let latest = files.last else {
            return nil
        }

        do {
            return try Data(contentsOf: latest.url)
        } catch {
            throw .loadingFailed
        }
    }

    func save(_ data: Data) throws(DiagnosticPersistenceFailure) {
        try createDirectoryIfNeeded()
        let existingFiles = try snapshotFiles(failure: .rotationFailed)
        for file in existingFiles {
            try fileSecurity.hardenSnapshot(file.url)
        }
        let previousSequence = existingFiles.last?.sequence ?? 0
        guard previousSequence < .max else {
            throw .rotationFailed
        }

        let nextSequence = previousSequence + 1
        let filename = String(
            format: "diagnostics-%020llu.json",
            nextSequence
        )
        let destination = directory.appending(
            path: filename,
            directoryHint: .notDirectory
        )

        do {
            try data.write(
                to: destination,
                options: .atomic
            )
        } catch {
            throw .writingFailed
        }
        try fileSecurity.hardenSnapshot(destination)

        let filesAfterWrite = try snapshotFiles(failure: .rotationFailed)
        let removalCount = max(
            0,
            filesAfterWrite.count - maximumSnapshotCount
        )
        for file in filesAfterWrite.prefix(removalCount) {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                throw .rotationFailed
            }
        }
    }

    func clear() throws(DiagnosticPersistenceFailure) {
        guard directoryExists else {
            return
        }

        let files = try snapshotFiles(failure: .clearingFailed)
        for file in files {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                throw .clearingFailed
            }
        }
    }

    private var directoryExists: Bool {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: directory.path(),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    private func createDirectoryIfNeeded() throws(DiagnosticPersistenceFailure) {
        guard !directoryExists else {
            try fileSecurity.excludeFromBackup(directory)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw .directoryCreationFailed
        }
        try fileSecurity.excludeFromBackup(directory)
    }

    private func snapshotFiles(
        failure: DiagnosticPersistenceFailure
    ) throws(DiagnosticPersistenceFailure) -> [SnapshotFile] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw failure
        }

        return urls.compactMap { url in
            let filename = url.lastPathComponent
            let prefix = "diagnostics-"
            let suffix = ".json"
            guard
                filename.hasPrefix(prefix),
                filename.hasSuffix(suffix)
            else {
                return nil
            }

            let sequenceStart = filename.index(
                filename.startIndex,
                offsetBy: prefix.count
            )
            let sequenceEnd = filename.index(
                filename.endIndex,
                offsetBy: -suffix.count
            )
            guard let sequence = UInt64(filename[sequenceStart ..< sequenceEnd]) else {
                return nil
            }
            return SnapshotFile(sequence: sequence, url: url)
        }
        .sorted { $0.sequence < $1.sequence }
    }
}
