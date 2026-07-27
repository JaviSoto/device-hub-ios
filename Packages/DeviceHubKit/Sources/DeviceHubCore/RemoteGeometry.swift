/// A two-dimensional point in view-space points.
public struct Point2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A two-dimensional size in view-space points.
public struct Size2D: Codable, Equatable, Sendable {
    public var height: Double
    public var width: Double

    public init(width: Double, height: Double) {
        self.height = height
        self.width = width
    }
}

/// Bounds occupied by the remote-screen stage in view-space points.
public struct Viewport: Codable, Equatable, Sendable {
    public var origin: Point2D
    public var size: Size2D

    public init(origin: Point2D, size: Size2D) {
        self.origin = origin
        self.size = size
    }
}

/// Native portrait pixel dimensions reported by the target.
public struct PixelSize: Codable, Equatable, Sendable {
    public var height: Int
    public var width: Int

    public init(width: Int, height: Int) {
        self.height = height
        self.width = width
    }
}

/// Native-portrait target point suitable for semantic touch commands.
///
/// The command boundary normalizes these digitizer coordinates across
/// UniversalHID's complete `UInt16` range.
public struct TargetPixelPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Rotation of displayed pixels relative to native portrait target coordinates.
public enum ScreenOrientation: Codable, CaseIterable, Equatable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    public func orientedSize(for pixelSize: PixelSize) -> PixelSize {
        switch self {
        case .portrait, .portraitUpsideDown:
            pixelSize
        case .landscapeLeft, .landscapeRight:
            PixelSize(width: pixelSize.height, height: pixelSize.width)
        }
    }
}

/// Result of mapping a view-space gesture to the target's native pixels.
public struct CoordinateMapping: Equatable, Sendable {
    public var point: TargetPixelPoint
    public var wasClamped: Bool

    public init(point: TargetPixelPoint, wasClamped: Bool) {
        self.point = point
        self.wasClamped = wasClamped
    }
}

/// Pure aspect-fit transform used by every pointer and touch interaction.
public enum RemoteCoordinateMapper {
    /// Maps the first touch only when it begins inside rendered screen content.
    ///
    /// Letterbox taps are rejected rather than clamped onto a device edge. Once
    /// a contact has begun, use ``map(_:in:targetPixels:orientation:)`` for
    /// moved touches so dragging outside the screen remains well behaved.
    public static func mapInitialTouch(
        _ point: Point2D,
        in viewport: Viewport,
        targetPixels: PixelSize,
        orientation: ScreenOrientation
    ) -> TargetPixelPoint? {
        guard let mapping = map(
            point,
            in: viewport,
            targetPixels: targetPixels,
            orientation: orientation
        ),
            !mapping.wasClamped
        else {
            return nil
        }
        return mapping.point
    }

    /// Maps a gesture through letterboxing and display rotation.
    ///
    /// Points outside the rendered screen clamp to its nearest edge. Invalid or
    /// non-finite geometry returns `nil` instead of emitting unsafe coordinates.
    /// The stream dimensions are already oriented for display, while the
    /// touchscreen digitizer remains in native portrait coordinates.
    public static func map(
        _ point: Point2D,
        in viewport: Viewport,
        targetPixels: PixelSize,
        orientation: ScreenOrientation
    ) -> CoordinateMapping? {
        guard point.x.isFinite,
              point.y.isFinite,
              viewport.origin.x.isFinite,
              viewport.origin.y.isFinite,
              viewport.size.width.isFinite,
              viewport.size.height.isFinite,
              viewport.size.width > 0,
              viewport.size.height > 0,
              targetPixels.width > 0,
              targetPixels.height > 0
        else {
            return nil
        }

        let orientedPixels = orientation.orientedSize(for: targetPixels)
        let scale = min(
            viewport.size.width / Double(orientedPixels.width),
            viewport.size.height / Double(orientedPixels.height)
        )
        guard scale.isFinite, scale > 0 else {
            return nil
        }

        let contentSize = Size2D(
            width: Double(orientedPixels.width) * scale,
            height: Double(orientedPixels.height) * scale
        )
        let contentOrigin = Point2D(
            x: viewport.origin.x
                + (viewport.size.width - contentSize.width) / 2,
            y: viewport.origin.y
                + (viewport.size.height - contentSize.height) / 2
        )
        let clampedPoint = Point2D(
            x: min(
                max(point.x, contentOrigin.x),
                contentOrigin.x + contentSize.width
            ),
            y: min(
                max(point.y, contentOrigin.y),
                contentOrigin.y + contentSize.height
            )
        )
        let displayedX = (clampedPoint.x - contentOrigin.x) / contentSize.width
        let displayedY = (clampedPoint.y - contentOrigin.y) / contentSize.height
        let nativePoint = nativeNormalizedPoint(
            displayedX: displayedX,
            displayedY: displayedY,
            orientation: orientation
        )

        return CoordinateMapping(
            point: TargetPixelPoint(
                x: nativePoint.x * Double(max(targetPixels.width - 1, 0)),
                y: nativePoint.y * Double(max(targetPixels.height - 1, 0))
            ),
            wasClamped: clampedPoint != point
        )
    }

    private static func nativeNormalizedPoint(
        displayedX: Double,
        displayedY: Double,
        orientation: ScreenOrientation
    ) -> Point2D {
        switch orientation {
        case .portrait:
            Point2D(x: displayedX, y: displayedY)
        case .portraitUpsideDown:
            Point2D(x: 1 - displayedX, y: 1 - displayedY)
        case .landscapeLeft:
            Point2D(x: 1 - displayedY, y: displayedX)
        case .landscapeRight:
            Point2D(x: displayedY, y: 1 - displayedX)
        }
    }
}
