import CoreGraphics
import SwiftUI

/// Chooses how remote-session chrome shares space with the screen canvas.
///
/// Compact layouts prioritize the remote image: portrait uses a bottom dock,
/// while landscape places floating chrome in the target's pillarboxes. The
/// regular-width iPad layout uses native navigation toolbar controls.
enum RemoteSessionChromeLayout: Equatable {
    case floatingTrailingRail
    case nativeToolbar
    case portraitBottomDock

    init(
        containerSize: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass? = nil
    ) {
        let usesCompactChrome =
            horizontalSizeClass == .compact
                || verticalSizeClass == .compact
        guard usesCompactChrome else {
            self = .nativeToolbar
            return
        }

        self = containerSize.width > containerSize.height
            ? .floatingTrailingRail
            : .portraitBottomDock
    }

    var screenInset: CGFloat {
        switch self {
        case .floatingTrailingRail:
            8
        case .nativeToolbar:
            12
        case .portraitBottomDock:
            0
        }
    }

    /// Breathing room above compact portrait chrome when no host safe-area
    /// inset is available, such as split-screen and snapshot containers.
    var topChromePadding: CGFloat {
        self == .portraitBottomDock ? 8 : 0
    }
}
