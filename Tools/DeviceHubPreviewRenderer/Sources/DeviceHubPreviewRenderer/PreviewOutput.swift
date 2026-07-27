import Foundation

enum PreviewOutputError: LocalizedError {
    case artifactMembership(
        directory: String,
        missing: [String],
        unexpected: [String]
    )

    var errorDescription: String? {
        switch self {
        case let .artifactMembership(directory, missing, unexpected):
            "\(directory) does not match the preview catalog; "
                + "missing=\(missing), unexpected=\(unexpected)."
        }
    }
}

/// Imperative filesystem shell around the pure catalog and image renderer.
@MainActor
enum PreviewOutput {
    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try validateMembership(
            at: directory,
            allowsMissingExpectedArtifacts: true
        )

        for scenario in PreviewScenario.required {
            let data = try autoreleasepool {
                try PreviewRenderer.render(scenario)
            }
            try data.write(
                to: directory.appendingPathComponent(
                    scenario.filename
                ),
                options: .atomic
            )
        }

        try validateMembership(
            at: directory,
            allowsMissingExpectedArtifacts: false
        )
    }

    static func catalog(
        reading directory: URL?
    ) throws -> Data {
        var rendered: [String: Data] = [:]
        if let directory {
            try validateMembership(
                at: directory,
                allowsMissingExpectedArtifacts: false
            )
            for scenario in PreviewScenario.required {
                let data = try Data(
                    contentsOf: directory.appendingPathComponent(
                        scenario.filename
                    )
                )
                try PreviewRenderer.validatePNG(
                    data,
                    for: scenario
                )
                rendered[scenario.filename] = data
            }
        } else {
            for scenario in PreviewScenario.required {
                let data = try autoreleasepool {
                    try PreviewRenderer.render(scenario)
                }
                rendered[scenario.filename] = data
            }
        }

        let entries = try PreviewCatalog.entries(
            scenarios: PreviewScenario.required
        ) { filename in
            guard let data = rendered[filename] else {
                preconditionFailure(
                    "Validated preview data is missing \(filename)."
                )
            }
            return data
        }
        return try PreviewCatalog.encoded(entries)
    }

    private static func validateMembership(
        at directory: URL,
        allowsMissingExpectedArtifacts: Bool
    ) throws {
        let expected = Set(
            PreviewScenario.required.map(\.filename)
        )
        let actual = try Set(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "png" }
            .map(\.lastPathComponent)
        )
        let missing = allowsMissingExpectedArtifacts
            ? []
            : expected.subtracting(actual).sorted()
        let unexpected = actual.subtracting(expected).sorted()
        guard missing.isEmpty, unexpected.isEmpty else {
            throw PreviewOutputError.artifactMembership(
                directory: directory.path,
                missing: missing,
                unexpected: unexpected
            )
        }
    }
}
