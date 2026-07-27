import Foundation
import SwiftUI

/// One human-readable notice embedded in the signed application bundle.
public struct DeviceHubLegalDocument: Equatable, Identifiable, Sendable {
    public let body: String
    public let id: String
    public let title: String

    public init(id: String, title: String, body: String) {
        self.body = body
        self.id = id
        self.title = title
    }
}

/// Version and open-source attribution content presented by Device Hub.
public struct DeviceHubAboutContent: Equatable, Sendable {
    public let applicationName: String
    public let build: String?
    public let legalDocuments: [DeviceHubLegalDocument]
    public let legalNoticeFailure: String?
    public let version: String?

    public init(
        applicationName: String,
        version: String?,
        build: String?,
        legalDocuments: [DeviceHubLegalDocument],
        legalNoticeFailure: String?
    ) {
        self.applicationName = applicationName
        self.build = build
        self.legalDocuments = legalDocuments
        self.legalNoticeFailure = legalNoticeFailure
        self.version = version
    }

    /// Loads signed resources without exposing filesystem paths or raw errors.
    ///
    /// Missing or unreadable resources produce visible user-facing failure
    /// content instead of silently omitting legal notices.
    public static func load(from bundle: Bundle = .main) -> Self {
        var documents: [DeviceHubLegalDocument] = []
        var failures: [String] = []

        if let noticesURL = bundle.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "md"
        ) {
            do {
                try documents.append(
                    DeviceHubLegalDocument(
                        id: "third-party-notices",
                        title: "Third-Party Notices",
                        body: String(
                            contentsOf: noticesURL,
                            encoding: .utf8
                        )
                    )
                )
            } catch {
                failures.append(
                    "The embedded third-party notices could not be read."
                )
            }
        } else {
            failures.append(
                "The embedded third-party notices are missing from this build."
            )
        }

        let licenseURLs = ["md", "txt"]
            .flatMap { fileExtension in
                bundle.urls(
                    forResourcesWithExtension: fileExtension,
                    subdirectory: "Licenses"
                ) ?? []
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }

        if licenseURLs.isEmpty {
            failures.append(
                "The embedded open-source licenses are missing from this build."
            )
        }

        for url in licenseURLs {
            do {
                let body = try String(contentsOf: url, encoding: .utf8)
                documents.append(
                    DeviceHubLegalDocument(
                        id: "license/\(url.lastPathComponent)",
                        title: legalTitle(for: url, body: body),
                        body: body
                    )
                )
            } catch {
                failures.append(
                    "An embedded open-source license could not be read."
                )
            }
        }

        return Self(
            applicationName: bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String
                ?? bundle.object(
                    forInfoDictionaryKey: "CFBundleName"
                ) as? String
                ?? "Device Hub",
            version: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            legalDocuments: documents,
            legalNoticeFailure: failures.isEmpty
                ? nil
                : failures.uniqued().joined(separator: " ")
        )
    }

    var versionLabel: String {
        switch (version, build) {
        case let (.some(version), .some(build)):
            "Version \(version) (\(build))"
        case let (.some(version), .none):
            "Version \(version)"
        case let (.none, .some(build)):
            "Build \(build)"
        case (.none, .none):
            "Private development build"
        }
    }

    private static func legalTitle(for url: URL, body: String) -> String {
        if url.pathExtension.localizedCaseInsensitiveCompare("md")
            == .orderedSame,
            let heading = body.split(separator: "\n").first(where: {
                $0.hasPrefix("# ")
            })
        {
            return String(heading.dropFirst(2))
        }

        return url.deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
    }
}

struct AboutDeviceHubView: View {
    @Environment(\.dismiss) private var dismiss

    let content: DeviceHubAboutContent
    let remoteDiagnostics: DeviceHubRemoteDiagnosticsSettings?

    init(
        content: DeviceHubAboutContent,
        remoteDiagnostics: DeviceHubRemoteDiagnosticsSettings? = nil
    ) {
        self.content = content
        self.remoteDiagnostics = remoteDiagnostics
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(
                            systemName:
                            "iphone.gen3.radiowaves.left.and.right"
                        )
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                        Text(content.applicationName)
                            .font(.title2.weight(.semibold))
                        Text(content.versionLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .accessibilityElement(children: .combine)
                }

                Section("Open Source") {
                    NavigationLink {
                        OpenSourceNoticesView(content: content)
                    } label: {
                        Label(
                            "Open Source Notices",
                            systemImage: "doc.text"
                        )
                    }

                    if content.legalNoticeFailure != nil {
                        Label(
                            "Some notices are unavailable",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Diagnostics & Privacy") {
                    if
                        let remoteDiagnostics,
                        let destinationHost =
                        remoteDiagnostics.destinationHost
                    {
                        Toggle(
                            "Share Remote Diagnostics",
                            isOn: Binding(
                                get: {
                                    remoteDiagnostics.isEnabled
                                },
                                set: {
                                    remoteDiagnostics.setEnabled($0)
                                }
                            )
                        )
                        .accessibilityHint(
                            "Shares redacted connection diagnostics with "
                                + destinationHost
                        )

                        LabeledContent(
                            "Destination",
                            value: destinationHost
                        )

                        Text(
                            "When enabled, redacted connection diagnostics "
                                + "are sent to \(destinationHost)."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        LabeledContent(
                            "Remote Diagnostics",
                            value: "Off"
                        )

                        Text(
                            "Diagnostics are stored only on this device."
                        )
                        .foregroundStyle(.secondary)
                    }

                    Text(
                        "Pairing codes, keys, and remote screen contents "
                            + "are never included in diagnostics."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
            .deviceHubInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct OpenSourceNoticesView: View {
    let content: DeviceHubAboutContent

    var body: some View {
        List {
            if let failure = content.legalNoticeFailure {
                Section {
                    Label {
                        Text(failure)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if content.legalDocuments.isEmpty {
                ContentUnavailableView(
                    "Notices Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        "This build does not contain readable notice files."
                    )
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Documents") {
                    ForEach(content.legalDocuments) { document in
                        NavigationLink(document.title) {
                            LegalDocumentView(document: document)
                        }
                    }
                }
            }
        }
        .navigationTitle("Open Source Notices")
        .deviceHubInlineNavigationTitle()
    }
}

private struct LegalDocumentView: View {
    let document: DeviceHubLegalDocument

    var body: some View {
        ScrollView {
            Text(document.body)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(document.title)
        .deviceHubInlineNavigationTitle()
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
