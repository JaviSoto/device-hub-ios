import CustomDump
import DeviceHubCore
import Testing

struct RemoteCoordinateMapperTests {
    private let portraitPixels = PixelSize(width: 100, height: 200)
    private let squareViewport = Viewport(
        origin: Point2D(x: 0, y: 0),
        size: Size2D(width: 400, height: 400)
    )

    @Test
    func portraitMappingAccountsForHorizontalLetterboxing() throws {
        let topLeft = try #require(
            RemoteCoordinateMapper.map(
                Point2D(x: 100, y: 0),
                in: squareViewport,
                targetPixels: portraitPixels,
                orientation: .portrait
            )
        )
        let bottomRight = try #require(
            RemoteCoordinateMapper.map(
                Point2D(x: 300, y: 400),
                in: squareViewport,
                targetPixels: portraitPixels,
                orientation: .portrait
            )
        )

        expectNoDifference(
            topLeft,
            CoordinateMapping(
                point: TargetPixelPoint(x: 0, y: 0),
                wasClamped: false
            )
        )
        expectNoDifference(
            bottomRight,
            CoordinateMapping(
                point: TargetPixelPoint(x: 99, y: 199),
                wasClamped: false
            )
        )
    }

    @Test
    func pointsInLetterboxAndBeyondTheViewportClampToScreenEdges() throws {
        let mapping = try #require(
            RemoteCoordinateMapper.map(
                Point2D(x: -40, y: 500),
                in: squareViewport,
                targetPixels: portraitPixels,
                orientation: .portrait
            )
        )

        expectNoDifference(
            mapping,
            CoordinateMapping(
                point: TargetPixelPoint(x: 0, y: 199),
                wasClamped: true
            )
        )
    }

    @Test
    func initialTouchesRejectLetterboxingInsteadOfLandingOnAnEdge() throws {
        #expect(
            RemoteCoordinateMapper.mapInitialTouch(
                Point2D(x: 50, y: 200),
                in: squareViewport,
                targetPixels: portraitPixels,
                orientation: .portrait
            ) == nil
        )

        let mapped = try #require(
            RemoteCoordinateMapper.mapInitialTouch(
                Point2D(x: 200, y: 200),
                in: squareViewport,
                targetPixels: portraitPixels,
                orientation: .portrait
            )
        )
        expectNoDifference(
            mapped,
            TargetPixelPoint(x: 49.5, y: 99.5)
        )
    }

    @Test(
        arguments: [
            (
                ScreenOrientation.portraitUpsideDown,
                TargetPixelPoint(x: 99, y: 199),
                TargetPixelPoint(x: 0, y: 0)
            ),
            (
                ScreenOrientation.landscapeLeft,
                TargetPixelPoint(x: 99, y: 0),
                TargetPixelPoint(x: 0, y: 199)
            ),
            (
                ScreenOrientation.landscapeRight,
                TargetPixelPoint(x: 0, y: 199),
                TargetPixelPoint(x: 99, y: 0)
            )
        ]
    )
    func mappingConvertsDisplayCoordinatesIntoNativePortraitDigitizerSpace(
        orientation: ScreenOrientation,
        expectedTopLeft: TargetPixelPoint,
        expectedBottomRight: TargetPixelPoint
    ) throws {
        let renderedSize = orientation.orientedSize(for: portraitPixels)
        let viewport = Viewport(
            origin: Point2D(x: 0, y: 0),
            size: Size2D(
                width: Double(renderedSize.width) * 2,
                height: Double(renderedSize.height) * 2
            )
        )
        let topLeft = try #require(
            RemoteCoordinateMapper.map(
                viewport.origin,
                in: viewport,
                targetPixels: portraitPixels,
                orientation: orientation
            )
        )
        let bottomRight = try #require(
            RemoteCoordinateMapper.map(
                Point2D(
                    x: viewport.origin.x + viewport.size.width,
                    y: viewport.origin.y + viewport.size.height
                ),
                in: viewport,
                targetPixels: portraitPixels,
                orientation: orientation
            )
        )

        expectNoDifference(topLeft.point, expectedTopLeft)
        expectNoDifference(bottomRight.point, expectedBottomRight)
    }

    @Test
    func mappingRejectsInvalidOrNonFiniteGeometry() {
        #expect(
            RemoteCoordinateMapper.map(
                Point2D(x: 10, y: 10),
                in: Viewport(
                    origin: Point2D(x: 0, y: 0),
                    size: Size2D(width: 0, height: 100)
                ),
                targetPixels: portraitPixels,
                orientation: .portrait
            ) == nil
        )
        #expect(
            RemoteCoordinateMapper.map(
                Point2D(x: .infinity, y: 10),
                in: squareViewport,
                targetPixels: portraitPixels,
                orientation: .portrait
            ) == nil
        )
    }
}
