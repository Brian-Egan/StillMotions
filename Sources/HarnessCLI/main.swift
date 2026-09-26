import Foundation

// stillmotions-harness — see docs/PRD.md R-22, R-23 and docs/ARCHITECTURE.md §9 for the
// full interface this CLI grows into across phase 1. Today it only knows
// `generate-fixtures`; later issues add the default metrics run and `benchmark-estimators`.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments

guard arguments.count > 1 else {
    fail("usage: stillmotions-harness <generate-fixtures> [options]")
}

switch arguments[1] {
case "generate-fixtures":
    do {
        try FixtureGenerator.run(arguments: Array(arguments.dropFirst(2)))
    } catch {
        fail("generate-fixtures failed: \(error)")
    }
default:
    fail("unknown subcommand: \(arguments[1])")
}
