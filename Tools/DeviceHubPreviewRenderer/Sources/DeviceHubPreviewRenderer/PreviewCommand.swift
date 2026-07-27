import Foundation

enum PreviewCommand: Equatable {
    case catalog(URL?)
    case render(URL)

    static func parse(_ arguments: [String]) throws -> Self {
        var outputDirectory: URL?
        var requestsCatalog = false
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--list-json":
                guard !requestsCatalog else {
                    throw PreviewCommandError.repeatedFlag(
                        "--list-json"
                    )
                }
                requestsCatalog = true

            case "--output":
                guard outputDirectory == nil else {
                    throw PreviewCommandError.repeatedFlag("--output")
                }
                index += 1
                guard arguments.indices.contains(index),
                      !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("--")
                else {
                    throw PreviewCommandError.missingOutputDirectory
                }
                outputDirectory = URL(
                    fileURLWithPath: arguments[index]
                )

            default:
                throw PreviewCommandError.unknownArgument(
                    arguments[index]
                )
            }
            index += 1
        }

        if requestsCatalog {
            return .catalog(outputDirectory)
        }
        guard let outputDirectory else {
            throw PreviewCommandError.missingCommand
        }
        return .render(outputDirectory)
    }
}

enum PreviewCommandError: LocalizedError, Equatable {
    case missingCommand
    case missingOutputDirectory
    case repeatedFlag(String)
    case unknownArgument(String)

    var errorDescription: String? {
        let usage = "Usage: DeviceHubPreviewRenderer "
            + "--output <directory> | "
            + "--list-json [--output <directory>]"

        return switch self {
        case .missingCommand:
            usage
        case .missingOutputDirectory:
            "--output requires a directory.\n\(usage)"
        case let .repeatedFlag(flag):
            "\(flag) may be specified only once.\n\(usage)"
        case let .unknownArgument(argument):
            "Unknown argument: \(argument)\n\(usage)"
        }
    }
}
