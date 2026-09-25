import Foundation
import PackagePlugin

/// Generates typed accessors (`L10n.homeTitle`) for a target's string tables
/// on every build: `.xcstrings`, `.strings` and `.stringsdict`, except
/// `InfoPlist` and `AppShortcuts`. Each accessor returns the newest
/// over-the-air string, or the shipped one.
@main
struct LocalizeMeStrings: BuildToolPlugin {
    /// A Swift package target.
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let files = target.sourceFiles.map(\.path)
        // A package target's strings live in `Bundle.module`, which exists
        // only when the target declares resources.
        let hasResources = target.sourceFiles.contains { $0.type == .resource }
        return try Generation.commands(
            for: target.name,
            files: files,
            configuration: Generation.configuration(in: files, orNextTo: target.directory),
            bundle: hasResources ? "module" : "main",
            workDirectory: context.pluginWorkDirectory,
            tool: context.tool(named: "LocalizeMeStringsGenerator").path
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension LocalizeMeStrings: XcodeBuildToolPlugin {
    /// An Xcode app or framework target.
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let files = target.inputFiles.map(\.path)
        return try Generation.commands(
            for: target.displayName,
            files: files,
            configuration: Generation.configuration(in: files, orNextTo: context.xcodeProject.directory),
            // The bundle that holds the generated code: the app's, or a framework's.
            bundle: "token",
            workDirectory: context.pluginWorkDirectory,
            tool: context.tool(named: "LocalizeMeStringsGenerator").path
        )
    }
}
#endif

enum Generation {
    static let configurationName = "localizeme-strings.json"
    static let tableExtensions: Set<String> = ["xcstrings", "strings", "stringsdict"]
    static let skippedTables: Set<String> = ["InfoPlist", "AppShortcuts"]

    /// The configuration file: one among the target's files, else one in `directory`.
    static func configuration(in files: [Path], orNextTo directory: Path) -> Path? {
        if let file = files.first(where: { $0.lastComponent == configurationName }) { return file }
        let candidate = directory.appending(configurationName)
        return FileManager.default.fileExists(atPath: candidate.string) ? candidate : nil
    }

    static func commands(
        for target: String, files: [Path], configuration: Path?, bundle: String, workDirectory: Path, tool: Path
    ) -> [Command] {
        let tables = files.filter {
            tableExtensions.contains($0.extension ?? "") && !skippedTables.contains($0.stem)
        }
        guard !tables.isEmpty else { return [] }
        let output = workDirectory.appending("LocalizeMeStrings.swift")
        var arguments = ["--output", output.string, "--bundle", bundle]
        if let configuration { arguments += ["--config", configuration.string] }
        arguments += tables.map(\.string)
        return [
            .buildCommand(
                displayName: "Generating LocalizeMe string accessors for \(target)",
                executable: tool,
                arguments: arguments,
                inputFiles: tables + (configuration.map { [$0] } ?? []),
                outputFiles: [output]
            ),
        ]
    }
}
