@testable import DeviceHubPreviewRenderer
import Foundation
import Testing

@Suite("Preview renderer command")
struct PreviewCommandTests {
    @Test("The CLI accepts rendering and standalone or file-backed catalogs")
    func parsesSupportedCommands() throws {
        let directory = URL(fileURLWithPath: "/tmp/device-hub-previews")

        #expect(
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--output",
                directory.path
            ]) == .render(directory)
        )
        #expect(
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--list-json"
            ]) == .catalog(nil)
        )
        #expect(
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--list-json",
                "--output",
                directory.path
            ]) == .catalog(directory)
        )
    }

    @Test("The CLI rejects incomplete, repeated, and unknown arguments")
    func rejectsInvalidCommands() {
        #expect(throws: PreviewCommandError.missingCommand) {
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer"
            ])
        }
        #expect(throws: PreviewCommandError.missingOutputDirectory) {
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--output"
            ])
        }
        #expect(throws: PreviewCommandError.missingOutputDirectory) {
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--output",
                "--list-json"
            ])
        }
        #expect(throws: PreviewCommandError.repeatedFlag("--output")) {
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--output",
                "/tmp/first",
                "--output",
                "/tmp/second"
            ])
        }
        #expect(throws: PreviewCommandError.repeatedFlag("--list-json")) {
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--list-json",
                "--list-json"
            ])
        }
        #expect(throws: PreviewCommandError.unknownArgument("--unknown")) {
            try PreviewCommand.parse([
                "DeviceHubPreviewRenderer",
                "--unknown"
            ])
        }
    }
}
