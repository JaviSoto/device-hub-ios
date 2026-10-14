import CoreGraphics
import SwiftUI

/// Controls float over the canvas; no layout reserves remote-screen space.
enum RemoteSessionChromeLayout: Equatable {
    case floatingTrailingRail
    case floatingBottomDock

    init(
        containerSize: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass? = nil
    ) {
        let usesCompactChrome =
            horizontalSizeClass == .compact
                || verticalSizeClass == .compact
        self = usesCompactChrome && containerSize.width > containerSize.height
            ? .floatingTrailingRail
            : .floatingBottomDock
    }
}
