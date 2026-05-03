import AppKit
import Foundation
import SceneKit
import simd

// MARK: - Entry point

let cliArgs = CommandLine.arguments

guard cliArgs.count >= 2 else {
    CLI.printUsage()
    exit(2)
}

do {
    switch cliArgs[1] {
    case "info":
        guard cliArgs.count >= 3 else {
            CLI.printUsage()
            exit(2)
        }
        try CLI.info(file: URL(fileURLWithPath: cliArgs[2]))
    case "validate":
        guard cliArgs.count >= 3 else {
            CLI.printUsage()
            exit(2)
        }
        try CLI.validate(file: URL(fileURLWithPath: cliArgs[2]))
    case "thumbnail":
        guard cliArgs.count >= 4 else {
            CLI.printUsage()
            exit(2)
        }
        let size = CLI.parseSize(from: cliArgs) ?? 512
        let useCache = cliArgs.contains("--cache")
        try CLI.thumbnail(
            input: URL(fileURLWithPath: cliArgs[2]),
            output: URL(fileURLWithPath: cliArgs[3]),
            size: size,
            useCache: useCache
        )
    case "batch":
        guard cliArgs.count >= 4 else {
            CLI.printUsage()
            exit(2)
        }
        let action = cliArgs[2]
        let files = cliArgs[3...].map { URL(fileURLWithPath: $0) }
        // Drive the async batch runner from the synchronous CLI entry point.
        let semaphore = DispatchSemaphore(value: 0)
        var batchError: Error?
        Task {
            do { try await CLI.batch(action: action, files: files) }
            catch { batchError = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let batchError { throw batchError }
    case "-h", "--help", "help":
        CLI.printUsage()
        exit(0)
    default:
        CLI.printUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
