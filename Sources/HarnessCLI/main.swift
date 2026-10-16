import Foundation

// stillmotions-harness — see docs/PRD.md R-22, R-23 and docs/ARCHITECTURE.md §9.
//
//   stillmotions-harness --fixtures <dir> --out <dir> [...]   the metrics run (HarnessRunner)
//   stillmotions-harness generate-fixtures --out <dir>        regenerate the synthetic clips
//   stillmotions-harness benchmark-estimators ...             the decision 0001 measurement

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments

guard arguments.count > 1 else {
    fail(HarnessRunner.usage + "\n       stillmotions-harness <generate-fixtures|benchmark-estimators> [options]")
}

// No subcommand: the default metrics run, which is what scripts/verify.sh invokes.
if arguments[1].hasPrefix("--") {
    do {
        exit(try await HarnessRunner.run(arguments: Array(arguments.dropFirst(1))))
    } catch {
        fail("\(error)")
    }
}

switch arguments[1] {
case "generate-fixtures":
    do {
        try FixtureGenerator.run(arguments: Array(arguments.dropFirst(2)))
    } catch {
        fail("generate-fixtures failed: \(error)")
    }
case "benchmark-estimators":
    do {
        try await BenchmarkEstimators.run(arguments: Array(arguments.dropFirst(2)))
    } catch {
        fail("benchmark-estimators failed: \(error)")
    }
default:
    fail("unknown subcommand: \(arguments[1])")
}
