import Foundation
import LocalizeMeStringsCore

// The generator lives in LocalizeMeStringsCore so the tests can link it.
exit(GeneratorCommand.main(Array(CommandLine.arguments.dropFirst())))
