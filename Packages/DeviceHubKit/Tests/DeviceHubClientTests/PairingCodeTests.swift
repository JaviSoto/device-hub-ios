import CustomDump
import DeviceHubCore
import Testing

struct PairingCodeTests {
    @Test
    func acceptsExactlySixASCIIDigits() throws {
        let code = try #require(PairingCode("012345"))

        expectNoDifference(code.displayValue, "012345")
    }

    @Test(
        arguments: [
            "",
            "12345",
            "1234567",
            "12 456",
            "abcdef",
            "１２３４５６",
            "12💻456"
        ]
    )
    func rejectsMalformedValues(value: String) {
        #expect(PairingCode(value) == nil)
    }
}
