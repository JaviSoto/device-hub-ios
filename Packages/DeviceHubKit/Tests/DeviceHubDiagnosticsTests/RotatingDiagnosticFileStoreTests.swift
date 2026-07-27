import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

struct RotatingDiagnosticFileStoreTests {
    @Test func retainingOnlyNewestSnapshotFilesStillLoadsTheLatest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            do {
                if FileManager.default.fileExists(atPath: directory.path()) {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch {
                Issue.record("Could not remove test directory: \(error)")
            }
        }
        let persistence = try DiagnosticPersistenceClient.rotatingFiles(
            directory: directory,
            maximumSnapshotCount: 2
        )

        try await persistence.save(Data([1]))
        try await persistence.save(Data([2]))
        try await persistence.save(Data([3]))

        let loaded = try await persistence.load()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .fileProtectionKey,
                .isExcludedFromBackupKey
            ],
            options: [.skipsHiddenFiles]
        )
        expectNoDifference(loaded, Data([3]))
        expectNoDifference(files.count, 2)
        try expectBackupExcluded(directory)
        for file in files {
            try expectHardenedSnapshot(file)
        }

        try await persistence.clear()
        let filesAfterClear = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        expectNoDifference(filesAfterClear, [])
    }

    @Test
    func loadingExcludesExistingDirectoryFromBackupAndHardensEveryRetainedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let firstSnapshot = directory.appending(
            path: "diagnostics-00000000000000000001.json",
            directoryHint: .notDirectory
        )
        let secondSnapshot = directory.appending(
            path: "diagnostics-00000000000000000002.json",
            directoryHint: .notDirectory
        )
        try Data([1]).write(to: firstSnapshot)
        try Data([2]).write(to: secondSnapshot)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove test directory: \(error)")
            }
        }
        let persistence = try DiagnosticPersistenceClient.rotatingFiles(
            directory: directory,
            maximumSnapshotCount: 2
        )

        let loaded = try await persistence.load()

        expectNoDifference(loaded, Data([2]))
        try expectBackupExcluded(directory)
        try expectHardenedSnapshot(firstSnapshot)
        try expectHardenedSnapshot(secondSnapshot)
    }

    @Test(arguments: [false, true])
    func savingDoesNotRequireDirectoryFileProtection(
        directoryAlreadyExists: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        if directoryAlreadyExists {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        defer {
            do {
                if FileManager.default.fileExists(atPath: directory.path()) {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch {
                Issue.record("Could not remove test directory: \(error)")
            }
        }
        let persistence = try DiagnosticPersistenceClient.rotatingFiles(
            directory: directory,
            maximumSnapshotCount: 2,
            fileSecurity: directoryRejectingFileSecurity(directory)
        )

        try await persistence.save(Data([42]))

        let snapshotName = "diagnostics-00000000000000000001.json"
        let snapshot = directory.appending(
            path: snapshotName,
            directoryHint: .notDirectory
        )
        try expectBackupExcluded(directory)
        try expectHardenedSnapshot(snapshot)
    }

    @Test func loadingDoesNotRequireDirectoryFileProtection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let snapshotName = "diagnostics-00000000000000000001.json"
        let snapshot = directory.appending(
            path: snapshotName,
            directoryHint: .notDirectory
        )
        try Data([42]).write(to: snapshot)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove test directory: \(error)")
            }
        }
        let persistence = try DiagnosticPersistenceClient.rotatingFiles(
            directory: directory,
            maximumSnapshotCount: 2,
            fileSecurity: directoryRejectingFileSecurity(directory)
        )

        let loaded = try await persistence.load()

        expectNoDifference(loaded, Data([42]))
        try expectBackupExcluded(directory)
        try expectHardenedSnapshot(snapshot)
    }

    @Test func persistenceSurfacesAnUnusableDirectory() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        try Data([1]).write(to: fileURL)
        defer {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Issue.record("Could not remove test file: \(error)")
            }
        }
        let persistence = try DiagnosticPersistenceClient.rotatingFiles(
            directory: fileURL,
            maximumSnapshotCount: 2
        )

        await #expect(
            throws: DiagnosticPersistenceFailure.directoryCreationFailed
        ) {
            try await persistence.save(Data([2]))
        }
    }

    @Test func fileRetentionCountMustBePositive() {
        #expect(
            throws: DiagnosticPersistenceFailure.invalidFileRetentionPolicy
        ) {
            _ = try DiagnosticPersistenceClient.rotatingFiles(
                directory: FileManager.default.temporaryDirectory,
                maximumSnapshotCount: 0
            )
        }
    }

    private func expectBackupExcluded(
        _ url: URL
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        expectNoDifference(
            values.isExcludedFromBackup,
            true
        )
    }

    private func expectHardenedSnapshot(
        _ url: URL
    ) throws {
        try expectBackupExcluded(url)
        let values = try url.resourceValues(
            forKeys: [.fileProtectionKey]
        )
        expectNoDifference(
            values.fileProtection,
            .completeUntilFirstUserAuthentication
        )
    }
}

private func directoryRejectingFileSecurity(
    _ directory: URL
) -> DiagnosticFileSecurity {
    let directoryPath = directory.standardizedFileURL.path()
    return DiagnosticFileSecurity(
        excludeFromBackup: { url throws(DiagnosticPersistenceFailure) in
            try DiagnosticFileSecurity.live.excludeFromBackup(url)
        },
        hardenSnapshot: { url throws(DiagnosticPersistenceFailure) in
            guard url.standardizedFileURL.path() != directoryPath else {
                throw DiagnosticPersistenceFailure
                    .fileSecurityConfigurationFailed
            }
            try DiagnosticFileSecurity.live.hardenSnapshot(url)
        }
    )
}
