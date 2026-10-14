import CoreGraphics
import DeviceHubCore
@testable import DeviceHubUI
import Testing

@Suite("Remote touch ledger")
struct RemoteTouchLedgerTests {
    @Test("portrait controls float over an edge-to-edge canvas")
    func compactPhoneChromeUsesOrientationSpecificLayouts() {
        let portrait = RemoteSessionChromeLayout(
            containerSize: CGSize(width: 440, height: 956),
            horizontalSizeClass: .compact
        )
        #expect(portrait == .floatingBottomDock)
        #expect(
            RemoteSessionChromeLayout(
                containerSize: CGSize(width: 956, height: 440),
                horizontalSizeClass: .compact
            ) == .floatingTrailingRail
        )
    }

    @Test("regular iPad windows keep the entire canvas beneath floating controls")
    func regularWidthChromeUsesNativeToolbar() {
        #expect(
            RemoteSessionChromeLayout(
                containerSize: CGSize(width: 1180, height: 820),
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular
            ) == .floatingBottomDock
        )
    }

    @Test("landscape iPhone chrome follows compact height")
    func landscapeIPhoneChromeUsesTrailingRail() {
        #expect(
            RemoteSessionChromeLayout(
                containerSize: CGSize(width: 1280, height: 589),
                horizontalSizeClass: .regular,
                verticalSizeClass: .compact
            ) == .floatingTrailingRail
        )
    }

    @Test("phone control rail keeps native minimum hit targets")
    func phoneControlRailUsesNativeHitTargets() {
        #expect(RemoteControlBarMetrics.minimumTargetDimension >= 44)
    }

    @Test("rendered screen has explicit aspect-fit bounds")
    func renderedScreenUsesExplicitAspectFitBounds() {
        let size = RemoteScreenLayout.size(
            in: CGSize(width: 390, height: 760),
            targetPixels: PixelSize(width: 1504, height: 2272),
            orientation: .landscapeLeft,
            inset: 16
        )

        #expect(size.width == 358)
        #expect(abs(size.height - 236.985_915_492_957_76) < 0.000_000_001)
    }

    @Test("input coordinates are local to the rendered remote screen")
    func inputCoordinatesUseRenderedScreenBounds() throws {
        let viewport = RemoteInputSurfaceGeometry.viewport(
            for: CGSize(width: 1136, height: 752)
        )

        #expect(viewport.origin == Point2D(x: 0, y: 0))
        #expect(viewport.size == Size2D(width: 1136, height: 752))

        let mappedPoint = try #require(
            RemoteCoordinateMapper.mapInitialTouch(
                Point2D(x: 51, y: 23),
                in: viewport,
                targetPixels: PixelSize(width: 1504, height: 2272),
                orientation: .landscapeLeft
            )
        )
        #expect(
            abs(mappedPoint.x - 1457.030_585_106_383)
                < 0.000_000_001
        )
        #expect(
            abs(mappedPoint.y - 101.955_105_633_802_82)
                < 0.000_000_001
        )
    }

    @Test("reauthorization starts a fresh contact after mid-drag revocation")
    func reauthorizationStartsFreshContact() throws {
        let viewport = Viewport(
            origin: Point2D(x: 16, y: 16),
            size: Size2D(width: 358, height: 760)
        )
        var ledger = RemoteTouchLedger()

        let firstContact = ledger.beginIfNeeded(
            contactID: 0,
            at: Point2D(x: 40, y: 80),
            viewport: viewport
        )
        let requiredFirstContact = try #require(firstContact)
        ledger.updateLastPoint(Point2D(x: 120, y: 240))

        let cancelledContact = ledger.revokeInput(from: true, to: false)
        let requiredCancelledContact = try #require(cancelledContact)
        #expect(
            requiredCancelledContact.contactID
                == requiredFirstContact.contactID
        )
        #expect(
            requiredCancelledContact.lastPoint
                == Point2D(x: 120, y: 240)
        )
        #expect(ledger.activeTouch == nil)

        let reauthorizedContact = ledger.beginIfNeeded(
            contactID: 0,
            at: Point2D(x: 60, y: 100),
            viewport: viewport
        )
        let requiredReauthorizedContact = try #require(
            reauthorizedContact
        )
        #expect(
            requiredReauthorizedContact.lastPoint
                == Point2D(x: 60, y: 100)
        )
        #expect(ledger.activeTouch == requiredReauthorizedContact)
    }

    @Test("irrelevant authorization changes preserve the active contact")
    func irrelevantAuthorizationChanges() throws {
        let viewport = Viewport(
            origin: Point2D(x: 0, y: 0),
            size: Size2D(width: 390, height: 844)
        )
        var ledger = RemoteTouchLedger()
        let contact = ledger.beginIfNeeded(
            contactID: 0,
            at: Point2D(x: 20, y: 30),
            viewport: viewport
        )
        let requiredContact = try #require(contact)

        #expect(ledger.revokeInput(from: true, to: true) == nil)
        #expect(ledger.activeTouch == requiredContact)
        #expect(ledger.revokeInput(from: false, to: true) == nil)
        #expect(ledger.activeTouch == requiredContact)
    }
}
