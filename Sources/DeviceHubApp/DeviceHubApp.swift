import ComposableArchitecture
import DeviceHubClient
import DeviceHubFeature
import DeviceHubLive
import DeviceHubPersistence
import DeviceHubTransport
import DeviceHubUI
import SwiftUI

/// The iOS and iPadOS application shell.
///
/// The app target owns only process composition. Device discovery, pairing,
/// session lifetime, and remote-control behavior remain in reusable package
/// modules.
@main
struct DeviceHubApp: App {
    private let content: AnyView

    @MainActor
    init() {
        #if DEBUG
            switch DeviceHubDebugLaunchSelection(
                arguments: ProcessInfo.processInfo.arguments
            ) {
            case let .fixture(fixture):
                do {
                    content = try AnyView(
                        fixture.makeView()
                    )
                } catch {
                    content = AnyView(
                        DeviceHubDebugConfigurationErrorView(
                            message: "Could not construct fixture "
                                + "\(fixture.rawValue)."
                        )
                    )
                }
                return

            case let .invalid(message):
                content = AnyView(
                    DeviceHubDebugConfigurationErrorView(message: message)
                )
                return

            case .live:
                break
            }
        #endif

        content = AnyView(
            DeviceHubLiveBootstrapView()
        )
    }

    var body: some Scene {
        WindowGroup {
            content
        }
    }
}

/// Restores local diagnostics before exposing the production feature store.
///
/// Native construction validates the linked ABI but does not access a device,
/// signing state, pairing records, or controller credentials.
@MainActor
private struct DeviceHubLiveBootstrapView: View {
    private enum StartupState {
        case loading
        case needsAdvertisedName
        case ready(
            StoreOf<RemoteSessionFeature>,
            DeviceHubDiagnosticsRuntime
        )
        case unavailable
    }

    @State private var startupState = StartupState.loading
    @State private var advertisedNameDraft = ""

    var body: some View {
        Group {
            switch startupState {
            case .loading:
                ProgressView("Device Hub")

            case .needsAdvertisedName:
                DeviceHubAdvertisedNameSetupView(
                    name: $advertisedNameDraft,
                    save: saveAdvertisedName
                )

            case let .ready(store, diagnostics):
                DeviceHubLiveContentView(
                    store: store,
                    diagnostics: diagnostics
                )

            case .unavailable:
                ContentUnavailableView(
                    "Device Hub Couldn't Start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "This build couldn't load the required local runtime. "
                            + "Install a verified Device Hub build and try again."
                    )
                )
            }
        }
        .task {
            await prepareBootstrap()
        }
    }

    private func prepareBootstrap() async {
        DeviceHubBootstrapTrace.emit("prepare_started")
        guard case .loading = startupState else {
            DeviceHubBootstrapTrace.emit("prepare_skipped")
            return
        }

        if let userProvidedName =
            DeviceHubCurrentDeviceName.userProvidedName()
        {
            DeviceHubBootstrapTrace.emit("name_loaded")
            await bootstrap(controllerDeviceName: userProvidedName)
            return
        }

        let automaticName = DeviceHubCurrentDeviceName.load()
        guard
            DeviceHubCurrentDeviceName.requiresUserProvidedName(automaticName)
        else {
            DeviceHubBootstrapTrace.emit("automatic_name_loaded")
            await bootstrap(controllerDeviceName: automaticName)
            return
        }
        DeviceHubBootstrapTrace.emit("name_required")
        startupState = .needsAdvertisedName
    }

    private func saveAdvertisedName() {
        let name = advertisedNameDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            return
        }
        DeviceHubCurrentDeviceName.saveUserProvidedName(name)
        startupState = .loading
        Task {
            await bootstrap(controllerDeviceName: name)
        }
    }

    private func bootstrap(controllerDeviceName: String) async {
        do {
            DeviceHubBootstrapTrace.emit("runtime_creating")
            let runtime = try DeviceHubDiagnosticsRuntime.live(
                applicationSupportDirectory:
                FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                ),
                upload:
                DeviceHubDiagnosticsBuildProvisioning
                    .uploadProvisioning()
            )
            DeviceHubBootstrapTrace.emit("runtime_created")
            await runtime.restoreBestEffort()
            DeviceHubBootstrapTrace.emit("diagnostics_restored")
            await runtime.recordLifecycle(.launched)
            DeviceHubBootstrapTrace.emit("launch_recorded")
            guard !Task.isCancelled else {
                DeviceHubBootstrapTrace.emit("bootstrap_cancelled")
                return
            }

            DeviceHubBootstrapTrace.emit("native_sessions_creating")
            let nativeSessions = try NativeSessionClient.deviceHubLive()
            DeviceHubBootstrapTrace.emit("native_sessions_created")
            let configuration =
                try DeviceHubProductionComposition
                    .makeTransportConfiguration(
                        controllerDeviceName: controllerDeviceName
                    )
            DeviceHubBootstrapTrace.emit("transport_configuration_created")
            let pairingPersistence = try PairingPersistenceClient.live(
                descriptor: .pairingVault(
                    service:
                    DeviceHubPairingPersistenceProvisioning
                        .keychainService()
                )
            )
            let deviceHub = DeviceHubClient.live(
                nativeSessions: nativeSessions,
                configuration: configuration,
                diagnostics: runtime.recorder,
                requestDiagnosticsUpload: {
                    await runtime.schedulePromptUploadBestEffort()
                },
                pairingPersistence: pairingPersistence
            )
            DeviceHubBootstrapTrace.emit("client_created")
            startupState = .ready(
                DeviceHubAppComposition.makeStore(deviceHub: deviceHub),
                runtime
            )
            DeviceHubBootstrapTrace.emit("bootstrap_ready")
        } catch {
            guard !Task.isCancelled else {
                DeviceHubBootstrapTrace.emit("bootstrap_cancelled")
                return
            }
            DeviceHubBootstrapTrace.emit("bootstrap_failed")
            startupState = .unavailable
        }
    }
}

/// Emits opt-in, closed-vocabulary bootstrap milestones to an attached device
/// console without including identifiers, configuration, or error strings.
private enum DeviceHubBootstrapTrace {
    static func emit(_ milestone: String) {
        guard
            ProcessInfo.processInfo.environment[
                "DEVICE_HUB_BOOTSTRAP_TRACE"
            ] == "1"
        else {
            return
        }
        FileHandle.standardOutput.write(
            Data("devicehub.bootstrap \(milestone)\n".utf8)
        )
    }
}

/// Collects a stable, human-readable controller name when iOS redacts the
/// system device name.
private struct DeviceHubAdvertisedNameSetupView: View {
    @Binding var name: String
    let save: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "For example, Test iPhone",
                        text: $name
                    )
                    .accessibilityIdentifier(
                        "advertised-device-name-field"
                    )
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit(save)
                } header: {
                    Text("Advertised Device Name")
                } footer: {
                    Text(
                        "Other devices will see “Device Hub App in "
                            + "<this name>” while pairing."
                    )
                }

                Button("Continue", action: save)
                    .disabled(
                        name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
            }
            .navigationTitle("Name This Device Hub")
        }
    }
}

/// Runs product and diagnostics lifecycle effects from one SwiftUI scene.
@MainActor
private struct DeviceHubLiveContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var remoteDiagnostics:
        DeviceHubRemoteDiagnosticsSettings

    let store: StoreOf<RemoteSessionFeature>
    let diagnostics: DeviceHubDiagnosticsRuntime

    init(
        store: StoreOf<RemoteSessionFeature>,
        diagnostics: DeviceHubDiagnosticsRuntime
    ) {
        self.store = store
        self.diagnostics = diagnostics
        _remoteDiagnostics = State(
            initialValue: DeviceHubRemoteDiagnosticsSettings(
                destinationHost:
                diagnostics.remoteDiagnosticsDestinationHost,
                isEnabled:
                diagnostics.isRemoteDiagnosticsSharingEnabled,
                setEnabled: {
                    diagnostics
                        .setRemoteDiagnosticsSharingEnabled($0)
                }
            )
        )
    }

    var body: some View {
        DeviceHubView(
            store: store,
            remoteDiagnostics: remoteDiagnostics
        )
        .task(id: scenePhase) {
            switch scenePhase {
            case .active:
                await diagnostics.recordLifecycle(.foreground)
                await diagnostics.flushOnForegroundBestEffort()

            case .background:
                await diagnostics.recordLifecycle(.background)

            case .inactive:
                break

            @unknown default:
                break
            }
        }
    }
}

#if DEBUG
    /// Parsed DEBUG-only simulator launch mode.
    ///
    /// Release builds do not compile this type or any fixture branch.
    private enum DeviceHubDebugLaunchSelection {
        case fixture(DeviceHubPreviewFixture)
        case invalid(String)
        case live

        init(arguments: [String]) {
            let flag = "--device-hub-fixture"
            let flagIndices = arguments.indices.filter {
                arguments[$0] == flag
            }
            guard !flagIndices.isEmpty else {
                self = .live
                return
            }
            guard flagIndices.count == 1, let flagIndex = flagIndices.first else {
                self = .invalid("\(flag) may be supplied only once.")
                return
            }

            let valueIndex = arguments.index(after: flagIndex)
            guard arguments.indices.contains(valueIndex) else {
                self = .invalid("\(flag) requires a fixture name.")
                return
            }

            let value = arguments[valueIndex]
            guard let fixture = DeviceHubPreviewFixture(rawValue: value) else {
                let validValues = DeviceHubPreviewFixture.allCases
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ", ")
                self = .invalid(
                    "Unknown fixture \(value). Valid fixtures: \(validValues)."
                )
                return
            }
            self = .fixture(fixture)
        }
    }

    /// Visible failure surface for malformed simulator fixture arguments.
    private struct DeviceHubDebugConfigurationErrorView: View {
        let message: String

        var body: some View {
            ContentUnavailableView(
                "Invalid Device Hub Fixture",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
#endif

/// Builds the root feature with its process-owned dependencies.
///
/// Accepting the client explicitly makes the composition boundary testable and
/// prevents transport details from leaking into the feature or SwiftUI layers.
@MainActor
enum DeviceHubAppComposition {
    static func makeStore(
        deviceHub: DeviceHubClient
    ) -> StoreOf<RemoteSessionFeature> {
        Store(initialState: RemoteSessionFeature.State()) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub = deviceHub
        }
    }
}
