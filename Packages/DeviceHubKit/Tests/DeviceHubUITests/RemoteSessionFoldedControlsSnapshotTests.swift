#if os(iOS)
    @testable import DeviceHubUI
    import SnapshotTesting
    import SwiftUI
    import Testing
    import UIKit

    #if DEVICE_HUB_RECORD_SNAPSHOTS
        private let foldedSnapshotRecordMode: SnapshotTestingConfiguration.Record = .all
    #else
        private let foldedSnapshotRecordMode: SnapshotTestingConfiguration.Record = .never
    #endif

    @MainActor
    @Suite("Folded remote controls", .serialized, .snapshots(record: foldedSnapshotRecordMode))
    struct RemoteSessionFoldedControlsSnapshotTests {
        @Test("Controls fit their dedicated area in both appearances")
        func foldedControls() {
            for appearance in [ColorScheme.light, .dark] {
                for acceptsInput in [true, false] {
                    let view = RemoteSessionFoldedControls(
                        acceptsInput: acceptsInput,
                        isKeyboardPresented: false,
                        home: {},
                        lock: {},
                        keyboard: {},
                        rotate: {}
                    )
                    .preferredColorScheme(appearance)
                    assertSnapshot(
                        of: view,
                        as: .image(
                            layout: .fixed(width: 680, height: 300),
                            traits: UITraitCollection(userInterfaceStyle: appearance == .dark ? .dark : .light)
                        ),
                        named: "\(appearance)-\(acceptsInput ? "enabled" : "disabled")"
                    )
                }
            }
        }
    }
#endif
