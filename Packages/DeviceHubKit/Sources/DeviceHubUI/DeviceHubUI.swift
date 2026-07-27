import ComposableArchitecture
import DeviceHubCore
import DeviceHubFeature
import SwiftUI

/// The complete screen-first Device Hub interface.
///
/// The view owns presentation-only state such as split-view visibility and
/// keyboard focus. Discovery, pairing, session lifecycle, and every remote
/// command remain owned by ``RemoteSessionFeature``.
public struct DeviceHubView: View {
    @Bindable private var store: StoreOf<RemoteSessionFeature>
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var detailsDevice: DeviceSummary?
    @State private var externalRemediation: ExternalRemediationRequest?
    @State private var isAboutPresented = false
    @State private var isKeyboardPresented = false
    @State private var preferredCompactColumn = NavigationSplitViewColumn.detail

    private let aboutContent: DeviceHubAboutContent
    private let remoteDiagnostics: DeviceHubRemoteDiagnosticsSettings
    private let startsFeatureTask: Bool

    @MainActor
    public init(store: StoreOf<RemoteSessionFeature>) {
        self.init(
            store: store,
            aboutContent: .load(),
            remoteDiagnostics: DeviceHubRemoteDiagnosticsSettings(
                destinationHost: nil,
                isEnabled: false,
                setEnabled: { _ in }
            ),
            startsFeatureTask: true
        )
    }

    /// Creates the live interface with its remote-diagnostics disclosure and
    /// consent control.
    @MainActor
    public init(
        store: StoreOf<RemoteSessionFeature>,
        remoteDiagnostics: DeviceHubRemoteDiagnosticsSettings
    ) {
        self.init(
            store: store,
            aboutContent: .load(),
            remoteDiagnostics: remoteDiagnostics,
            startsFeatureTask: true
        )
    }

    /// Creates the interface with explicitly supplied attribution content.
    ///
    /// This initializer keeps bundle loading at the application boundary and
    /// makes previews, tests, and alternate signed bundles deterministic.
    public init(
        store: StoreOf<RemoteSessionFeature>,
        aboutContent: DeviceHubAboutContent
    ) {
        self.init(
            store: store,
            aboutContent: aboutContent,
            remoteDiagnostics: DeviceHubRemoteDiagnosticsSettings(
                destinationHost: nil,
                isEnabled: false,
                setEnabled: { _ in }
            ),
            startsFeatureTask: true
        )
    }

    init(
        store: StoreOf<RemoteSessionFeature>,
        aboutContent: DeviceHubAboutContent = .load(),
        remoteDiagnostics: DeviceHubRemoteDiagnosticsSettings? = nil,
        startsFeatureTask: Bool
    ) {
        self.store = store
        self.aboutContent = aboutContent
        self.remoteDiagnostics = remoteDiagnostics
            ?? DeviceHubRemoteDiagnosticsSettings(
                destinationHost: nil,
                isEnabled: false,
                setEnabled: { _ in }
            )
        self.startsFeatureTask = startsFeatureTask
    }

    public var body: some View {
        navigationRoot
            .tint(.indigo)
            .sheet(item: $detailsDevice, onDismiss: detailsDismissed) { device in
                DeviceDetailsView(
                    device: device,
                    aboutContent: aboutContent
                )
            }
            .sheet(isPresented: $isAboutPresented) {
                AboutDeviceHubView(
                    content: aboutContent,
                    remoteDiagnostics: remoteDiagnostics
                )
            }
            .sheet(
                item: $externalRemediation,
                onDismiss: externalRemediationDismissed
            ) { request in
                ExternalRemediationView(remedy: request.remedy)
            }
            .sheet(
                item: $store.scope(
                    state: \.pairing,
                    action: \.pairing
                )
            ) { pairingStore in
                PairDeviceView(store: pairingStore)
            }
            .onChange(of: scenePhase, scenePhaseChanged)
            .onChange(of: store.detailsDeviceID, detailsDeviceIDChanged)
            .onChange(
                of: store.externalRemediation,
                externalRemediationChanged
            )
            .modifier(
                PairingScreenIdleTimerModifier(
                    isDisabled: pairingScreenIdleTimerDisabled
                )
            )
            .task {
                guard startsFeatureTask else {
                    return
                }
                await store.send(.task).finish()
            }
    }

    @ViewBuilder
    private var navigationRoot: some View {
        switch DeviceHubNavigationLayout(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        ) {
        case .remoteSessionOnly:
            NavigationStack {
                remoteSession
            }

        case .sidebarAndSession:
            NavigationSplitView(
                preferredCompactColumn: $preferredCompactColumn
            ) {
                DeviceSidebar(
                    devices: store.roster.devices,
                    isLoading: store.isLoadingRoster,
                    selectedDeviceID: store.selectedDeviceID,
                    detailsButtonTapped: detailsButtonTapped,
                    deviceSelected: deviceSelected,
                    pairButtonTapped: pairButtonTapped
                )
                .navigationSplitViewColumnWidth(
                    min: 280,
                    ideal: 300,
                    max: 320
                )
            } detail: {
                remoteSession
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var remoteSession: some View {
        RemoteSessionView(
            store: store,
            isKeyboardPresented: $isKeyboardPresented,
            aboutButtonTapped: aboutButtonTapped,
            detailsButtonTapped: selectedDetailsButtonTapped,
            pairButtonTapped: pairButtonTapped
        )
    }

    private var pairingScreenIdleTimerDisabled: Bool {
        PairingScreenIdlePolicy.isDisabled(
            isPairingPresented: store.pairing != nil,
            hasRemediation: store.pairing?.remediation != nil,
            scenePhase: scenePhase
        )
    }

    private func aboutButtonTapped() {
        isKeyboardPresented = false
        isAboutPresented = true
    }

    private func detailsButtonTapped(_ device: DeviceSummary) {
        detailsDevice = device
        if device.id == store.selectedDeviceID {
            store.send(.detailsButtonTapped)
        }
    }

    private func detailsDeviceIDChanged(
        _ oldValue: DeviceID?,
        _ newValue: DeviceID?
    ) {
        guard newValue != oldValue,
              let newValue,
              let device = store.roster.devices.first(
                  where: { $0.id == newValue }
              )
        else {
            return
        }
        detailsDevice = device
    }

    private func detailsDismissed() {
        store.send(.detailsDismissed)
    }

    private func externalRemediationChanged(
        _ oldValue: ExternalRemediationRequest?,
        _ newValue: ExternalRemediationRequest?
    ) {
        guard newValue?.id != oldValue?.id, let request = newValue else {
            return
        }

        if request.remedy == .grantLocalNetworkAccess {
            #if os(iOS)
                guard let settingsURL = URL(
                    string: UIApplication.openSettingsURLString
                ) else {
                    preconditionFailure("UIKit supplied an invalid Settings URL.")
                }
                openURL(settingsURL)
                store.send(.externalRemediationHandled(request.id))
            #else
                externalRemediation = request
            #endif
        } else {
            externalRemediation = request
        }
    }

    private func externalRemediationDismissed() {
        guard let request = store.externalRemediation else {
            return
        }
        store.send(.externalRemediationHandled(request.id))
    }

    private func deviceSelected(_ deviceID: DeviceID) {
        store.send(.deviceSelected(deviceID))
        preferredCompactColumn = .detail
    }

    private func pairButtonTapped() {
        isKeyboardPresented = false
        store.send(.pairDeviceButtonTapped)
    }

    private func scenePhaseChanged(
        _ oldValue: ScenePhase,
        _ newValue: ScenePhase
    ) {
        guard newValue != oldValue else {
            return
        }
        store.send(.appLifecycleChanged(newValue.deviceHubLifecycle))
    }

    private func selectedDetailsButtonTapped() {
        guard let selectedDevice = store.selectedDevice else {
            return
        }
        detailsDevice = selectedDevice
        store.send(.detailsButtonTapped)
    }
}

/// Decides when an explicit pairing attempt must outlive normal Auto-Lock.
///
/// Error recovery and non-active scenes release the lease so an abandoned
/// sheet cannot keep the controller awake indefinitely.
enum PairingScreenIdlePolicy {
    static func isDisabled(
        isPairingPresented: Bool,
        hasRemediation: Bool,
        scenePhase: ScenePhase
    ) -> Bool {
        isPairingPresented
            && !hasRemediation
            && scenePhase == .active
    }
}

/// Applies the pairing-specific idle-timer lease at the UIKit shell boundary.
private struct PairingScreenIdleTimerModifier: ViewModifier {
    let isDisabled: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .onChange(of: isDisabled, initial: true) { _, isDisabled in
                    UIApplication.shared.isIdleTimerDisabled = isDisabled
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        #else
            content
        #endif
    }
}

/// Chooses the platform navigation shape without coupling feature state to
/// transient window geometry.
enum DeviceHubNavigationLayout: Equatable {
    case remoteSessionOnly
    case sidebarAndSession

    init(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass? = nil
    ) {
        self = horizontalSizeClass == .compact
            || verticalSizeClass == .compact
            ? .remoteSessionOnly
            : .sidebarAndSession
    }
}

private extension ScenePhase {
    var deviceHubLifecycle: DeviceHubAppLifecycle {
        switch self {
        case .active:
            .active
        case .background:
            .background
        case .inactive:
            .inactive
        @unknown default:
            .inactive
        }
    }
}
