import Darwin
import Foundation

@main
enum DeviceHubPreviewRenderer {
    @MainActor
    static func main() {
        do {
            switch try PreviewCommand.parse(CommandLine.arguments) {
            case let .catalog(directory):
                let data = try PreviewOutput.catalog(
                    reading: directory
                )
                FileHandle.standardOutput.write(data)

            case let .render(directory):
                try PreviewOutput.renderAll(to: directory)
            }
        } catch {
            let message = "DeviceHubPreviewRenderer: "
                + "\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
