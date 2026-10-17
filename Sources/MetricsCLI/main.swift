import Foundation
import FitbitMetrics

struct CommandError: Encodable {
    let error: String
    let message: String
    let path: String?
}

func fail(_ error: CommandError) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(error) {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data([10]))
    }
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1 else {
    fail(CommandError(error: "usage", message: "Usage: metrics-cli INPUT.json (or - for stdin)", path: nil))
}

do {
    let input: Data
    if args[0] == "-" { input = FileHandle.standardInput.readDataToEndOfFile() }
    else { input = try Data(contentsOf: URL(fileURLWithPath: args[0])) }
    let output = try MetricsEngine.evaluate(json: input)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data([10]))
} catch let error as InputValidationError {
    fail(CommandError(error: error.code, message: error.message, path: error.path))
} catch is DecodingError {
    // Do not echo an input document or a health value in command diagnostics.
    fail(CommandError(error: "invalidJSON", message: "Input does not match the canonical JSON schema.", path: nil))
} catch {
    fail(CommandError(error: "processingFailed", message: "Could not read or process the input file.", path: nil))
}
