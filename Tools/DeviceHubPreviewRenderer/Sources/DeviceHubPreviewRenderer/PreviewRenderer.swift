import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum PreviewRendererError: LocalizedError {
    case couldNotCreateBitmap(String)
    case couldNotCreateDestination(String)
    case couldNotEncode(String)
    case couldNotRender(String)
    case invalidPNG(String)
    case incorrectDimensions(
        name: String,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )

    var errorDescription: String? {
        switch self {
        case let .couldNotCreateBitmap(name):
            "Could not create the backing bitmap for \(name)."
        case let .couldNotCreateDestination(name):
            "Could not create the PNG destination for \(name)."
        case let .couldNotEncode(name):
            "Could not encode \(name) as PNG."
        case let .couldNotRender(name):
            "The offscreen AppKit host could not render \(name)."
        case let .invalidPNG(name):
            "\(name) is not a single-image PNG."
        case let .incorrectDimensions(
            name,
            expectedWidth,
            expectedHeight,
            actualWidth,
            actualHeight
        ):
            "\(name) rendered at \(actualWidth)x\(actualHeight), expected "
                + "\(expectedWidth)x\(expectedHeight)."
        }
    }
}

/// Serial offscreen AppKit renderer with every ambient input pinned.
///
/// `ImageRenderer` intentionally substitutes a prohibited placeholder for
/// navigation and other AppKit-backed SwiftUI content. Hosting the real view
/// tree in an unordered window exercises the same navigation hierarchy while
/// keeping rendering local, synchronous, and noninteractive.
@MainActor
enum PreviewRenderer {
    static func render(_ scenario: PreviewScenario) throws -> Data {
        let content = try PreviewFixtureView(scenario: scenario)
        let size = NSSize(
            width: scenario.viewport.width,
            height: scenario.viewport.height
        )
        let appearanceName: NSAppearance.Name = scenario.theme == .dark
            ? .darkAqua
            : .aqua
        guard let appearance = NSAppearance(named: appearanceName) else {
            throw PreviewRendererError.couldNotRender(scenario.id)
        }

        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.sizingOptions = []
        hostingView.appearance = appearance

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = scenario.theme == .dark
            ? .black
            : .white
        window.contentView = hostingView
        window.setContentSize(size)
        defer {
            window.contentView = nil
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: scenario.viewport.pixelWidth,
            pixelsHigh: scenario.viewport.pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw PreviewRendererError.couldNotCreateBitmap(scenario.id)
        }
        bitmap.size = size
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: bitmap
        )
        guard let image = bitmap.cgImage else {
            throw PreviewRendererError.couldNotRender(scenario.id)
        }

        try validateDimensions(
            width: image.width,
            height: image.height,
            for: scenario
        )

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PreviewRendererError.couldNotCreateDestination(
                scenario.id
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewRendererError.couldNotEncode(scenario.id)
        }
        let png = data as Data
        try validatePNG(png, for: scenario)
        return png
    }

    static func validatePNG(
        _ data: Data,
        for scenario: PreviewScenario
    ) throws {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  nil
              ),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  nil
              )
        else {
            throw PreviewRendererError.invalidPNG(scenario.id)
        }
        try validateDimensions(
            width: image.width,
            height: image.height,
            for: scenario
        )
    }

    private static func validateDimensions(
        width: Int,
        height: Int,
        for scenario: PreviewScenario
    ) throws {
        guard width == scenario.viewport.pixelWidth,
              height == scenario.viewport.pixelHeight
        else {
            throw PreviewRendererError.incorrectDimensions(
                name: scenario.id,
                expectedWidth: scenario.viewport.pixelWidth,
                expectedHeight: scenario.viewport.pixelHeight,
                actualWidth: width,
                actualHeight: height
            )
        }
    }
}
