import DeviceHubCore
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

@Suite("Native command encoding")
struct DeviceHubNativeCommandEncoderTests {
    private let pixelSize = PixelSize(width: 101, height: 201)

    @Test("target pixels map across the complete normalized touch range")
    func touchNormalization() throws {
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .tap(TargetPixelPoint(x: 0, y: 0)),
                pixelSize: pixelSize
            ) == .touch(phase: .tap, x: 0, y: 0)
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .tap(TargetPixelPoint(x: 50, y: 100)),
                pixelSize: pixelSize
            ) == .touch(phase: .tap, x: 32767, y: 32767)
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .tap(TargetPixelPoint(x: 100, y: 200)),
                pixelSize: pixelSize
            ) == .touch(
                phase: .tap,
                x: UInt16.max,
                y: UInt16.max
            )
        )
    }

    @Test("touch cancellation carries zero coordinates")
    func touchCancellation() throws {
        let encoded = try DeviceHubNativeCommandEncoder.encode(
            .touch(
                TouchCommand(
                    contactID: 0,
                    point: TargetPixelPoint(x: 42, y: 84),
                    phase: .cancelled
                )
            ),
            pixelSize: pixelSize
        )

        #expect(encoded == .touch(phase: .cancel, x: 0, y: 0))
    }

    @Test("the single-contact ABI rejects extra contacts")
    func extraContact() {
        #expect(throws: DeviceHubNativeCommandEncodingError.unsupportedContact) {
            try DeviceHubNativeCommandEncoder.encode(
                .touch(
                    TouchCommand(
                        contactID: 1,
                        point: TargetPixelPoint(x: 0, y: 0),
                        phase: .began
                    )
                ),
                pixelSize: pixelSize
            )
        }
    }

    @Test(
        "non-finite and out-of-bounds target pixels fail before integer conversion",
        arguments: [
            TargetPixelPoint(x: .nan, y: 0),
            TargetPixelPoint(x: 0, y: .infinity),
            TargetPixelPoint(x: -0.1, y: 0),
            TargetPixelPoint(x: 101, y: 0),
            TargetPixelPoint(x: 0, y: 201)
        ]
    )
    func invalidCoordinates(point: TargetPixelPoint) {
        #expect(throws: DeviceHubNativeCommandEncodingError.invalidCoordinate) {
            try DeviceHubNativeCommandEncoder.encode(
                .tap(point),
                pixelSize: pixelSize
            )
        }
    }

    @Test("fractional coordinates beyond the final pixel fail closed")
    func beyondFinalPixel() {
        #expect(
            throws: DeviceHubNativeCommandEncodingError.invalidCoordinate
        ) {
            try DeviceHubNativeCommandEncoder.encode(
                .tap(TargetPixelPoint(x: 100.001, y: 200)),
                pixelSize: pixelSize
            )
        }
    }

    @Test("touch input requires valid geometry")
    func invalidGeometry() {
        #expect(
            throws: DeviceHubNativeCommandEncodingError.missingGeometry
        ) {
            try DeviceHubNativeCommandEncoder.encode(
                .tap(TargetPixelPoint(x: 0, y: 0)),
                pixelSize: nil
            )
        }
        #expect(
            throws: DeviceHubNativeCommandEncodingError.invalidGeometry
        ) {
            try DeviceHubNativeCommandEncoder.encode(
                .tap(TargetPixelPoint(x: 0, y: 0)),
                pixelSize: PixelSize(width: 0, height: 1)
            )
        }
    }

    @Test("single-pixel geometry maps only its sole pixel to zero")
    func singlePixelGeometry() throws {
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .tap(TargetPixelPoint(x: 0, y: 0)),
                pixelSize: PixelSize(width: 1, height: 1)
            ) == .touch(phase: .tap, x: 0, y: 0)
        )
    }

    @Test("every touch edge preserves its native phase")
    func touchPhases() throws {
        let point = TargetPixelPoint(x: 0, y: 0)

        #expect(
            try encodeTouch(point: point, phase: .began)
                == .touch(phase: .down, x: 0, y: 0)
        )
        #expect(
            try encodeTouch(point: point, phase: .moved)
                == .touch(phase: .move, x: 0, y: 0)
        )
        #expect(
            try encodeTouch(point: point, phase: .ended)
                == .touch(phase: .up, x: 0, y: 0)
        )
    }

    @Test("keyboard edges preserve translated complete modifiers")
    func keyboard() throws {
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .key(
                    KeyCommand(
                        key: .character("A"),
                        phase: .press,
                        modifiers: .option
                    )
                ),
                pixelSize: pixelSize
            ) == .keyboard(
                phase: .down,
                usage: 0x04,
                modifiers: 0x06
            )
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .keyTap(.character("a"), modifiers: .command),
                pixelSize: pixelSize
            ) == .keyboard(
                phase: .tap,
                usage: 0x04,
                modifiers: 0x08
            )
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .key(
                    KeyCommand(
                        key: .return,
                        phase: .release
                    )
                ),
                pixelSize: nil
            ) == .keyboard(
                phase: .up,
                usage: 0x28,
                modifiers: 0
            )
        )
    }

    @Test("unsupported keyboard values fail without retaining input")
    func unsupportedKeyboard() {
        #expect(
            throws: DeviceHubNativeCommandEncodingError.unsupportedKeyboard
        ) {
            try DeviceHubNativeCommandEncoder.encode(
                .keyTap(.character("é"), modifiers: []),
                pixelSize: nil
            )
        }
    }

    @Test("hardware controls, rotation, and cleanup preserve semantics")
    func semanticControls() throws {
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .button(.home, phase: .press),
                pixelSize: pixelSize
            ) == .button(button: .home, phase: .down)
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .buttonTap(.siri),
                pixelSize: pixelSize
            ) == .button(button: .siri, phase: .tap)
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .rotation(.rotateRight),
                pixelSize: pixelSize
            ) == .rotation(.right)
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .releaseAllInput,
                pixelSize: nil
            ) == .releaseAll
        )
    }

    @Test("every button and both rotations map without geometry")
    func everyButtonAndRotation() throws {
        let buttons: [
            (DeviceButton, DeviceHubEncodedButton)
        ] = [
            (.home, .home),
            (.lock, .lock),
            (.mute, .mute),
            (.siri, .siri),
            (.volumeDown, .volumeDown),
            (.volumeUp, .volumeUp)
        ]

        for (button, expected) in buttons {
            #expect(
                try DeviceHubNativeCommandEncoder.encode(
                    .button(button, phase: .release),
                    pixelSize: nil
                ) == .button(button: expected, phase: .up)
            )
        }
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .rotation(.rotateLeft),
                pixelSize: nil
            ) == .rotation(.left)
        )
        #expect(
            try DeviceHubNativeCommandEncoder.encode(
                .rotation(.rotateRight),
                pixelSize: nil
            ) == .rotation(.right)
        )
    }

    @Test("encoded input and failures redact their descriptions")
    func redaction() {
        let command = DeviceHubEncodedCommand.keyboard(
            phase: .down,
            usage: 0x14,
            modifiers: 0x08
        )
        let failure =
            DeviceHubNativeCommandEncodingError.invalidCoordinate

        for description in [
            String(describing: command),
            String(reflecting: command),
            String(describing: failure),
            String(reflecting: failure)
        ] {
            #expect(description.lowercased().contains("redacted"))
            #expect(!description.contains("20"))
            #expect(!description.contains("8"))
        }
    }

    private func encodeTouch(
        point: TargetPixelPoint,
        phase: TouchPhase
    ) throws -> DeviceHubEncodedCommand {
        try DeviceHubNativeCommandEncoder.encode(
            .touch(
                TouchCommand(
                    contactID: 0,
                    point: point,
                    phase: phase
                )
            ),
            pixelSize: pixelSize
        )
    }
}
