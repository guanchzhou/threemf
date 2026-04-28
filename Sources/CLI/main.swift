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
    case "thumbnail":
        guard cliArgs.count >= 4 else {
            CLI.printUsage()
            exit(2)
        }
        let size = CLI.parseSize(from: cliArgs) ?? 512
        try CLI.thumbnail(
            input: URL(fileURLWithPath: cliArgs[2]),
            output: URL(fileURLWithPath: cliArgs[3]),
            size: size
        )
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
