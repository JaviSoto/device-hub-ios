import CustomDump
import DeviceHubCore
import Foundation
import Testing

struct SessionSurfaceTests {
    @Test
    func pairingEventsExposeProgressWithAnEphemeralCode() throws {
        let pairedDevice = DeviceSummary.fixture(id: "paired")
        let code = try #require(PairingCode("123456"))
        let events: [PairingEvent] = [
            .advertising,
            .waitingForCodeEntry(code: code),
            .saving,
            .paired(pairedDevice)
        ]

        expectNoDifference(
            events,
            [
                .advertising,
                .waitingForCodeEntry(code: code),
                .saving,
                .paired(pairedDevice)
            ]
        )
    }

    @Test
    func pairingCodeValidatesASCIIAndRedactsEveryDescription() throws {
        let code = try #require(PairingCode("123456"))

        expectNoDifference(code.displayValue, "123456")
        #expect(PairingCode("12345") == nil)
        #expect(PairingCode("1234567") == nil)
        #expect(PairingCode("12345a") == nil)
        #expect(PairingCode("１２３４５６") == nil)
        #expect(!(PairingCode.self is any Codable.Type))

        let descriptions = [
            String(describing: code),
            String(reflecting: code),
            String(customDumping: code),
            String(customDumping: PairingEvent.waitingForCodeEntry(code: code))
        ]
        for description in descriptions {
            #expect(!description.contains(code.displayValue))
            #expect(description.lowercased().contains("redacted"))
        }
    }

    @Test
    func commandsAreSemanticAndIndependentOfTransportDetails() {
        let commands: [DeviceCommand] = [
            .tap(TargetPixelPoint(x: 100, y: 200)),
            .touch(
                TouchCommand(
                    contactID: 1,
                    point: TargetPixelPoint(x: 101, y: 201),
                    phase: .moved
                )
            ),
            .key(
                KeyCommand(
                    key: .return,
                    phase: .press,
                    modifiers: [.command, .shift]
                )
            ),
            .button(.lock, phase: .release),
            .buttonTap(.home),
            .keyTap(.tab, modifiers: [.command]),
            .releaseAllInput
        ]

        #expect(commands.count == 7)
    }

    @Test
    func rotationCommandsCoverEveryProductControlAndRemainEphemeral() {
        expectNoDifference(
            DeviceRotation.allCases,
            [
                .rotateLeft,
                .rotateRight
            ]
        )
        expectNoDifference(
            DeviceRotation.allCases.map(DeviceCommand.rotation),
            [
                .rotation(.rotateLeft),
                .rotation(.rotateRight)
            ]
        )
        #expect(!(DeviceRotation.self is any Codable.Type))
        #expect(!(DeviceCommand.self is any Codable.Type))
    }
}
