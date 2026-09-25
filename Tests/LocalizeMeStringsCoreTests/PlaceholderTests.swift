import Testing
@testable import LocalizeMeStringsCore

struct PlaceholderTests {
    typealias Kind = Placeholders.Kind

    @Test func plainTextHasNoPlaceholdersEvenWithAPercentSign() {
        for text in ["Home", "20% off", "100% free", "Save 20%", "100%% sure", "50%!", ""] {
            #expect(Placeholders.scan(text, strict: true) == [:], "\(text)")
        }
    }

    @Test func formattingReadsWhatStringFormatReads() {
        // What String(format:) makes of the space flag, which is why a string
        // that also has real placeholders has to write a literal % as %%.
        #expect(Placeholders.scan("20% off", strict: false) == [1: .int])
        #expect(Placeholders.scan("Hello %@", strict: false) == [1: .object])
        #expect(Placeholders.scan("%1$@ has %2$lld files", strict: false) == [1: .object, 2: .int])
        #expect(Placeholders.scan("%2$@ before %1$@", strict: false) == [1: .object, 2: .object])
        #expect(Placeholders.scan("%.*f", strict: false) == [1: .int, 2: .double])
        #expect(Placeholders.scan("%-5.2f%%", strict: false) == [1: .double])
        #expect(Placeholders.scan("%s %c %C %p %S", strict: false) == [1: .cString, 2: .char, 3: .unichar, 4: .pointer, 5: .wideString])
    }

    @Test func unsafeStringsAreRefused() {
        for text in ["%n", "%1$@ %1$d", "%y"] {
            #expect(Placeholders.scan(text, strict: false) == nil, "\(text)")
        }
        #expect(Placeholders.scan("%n", strict: true) == nil)
        // An unknown conversion is text when reading strictly.
        #expect(Placeholders.scan("%y", strict: true) == [:])
    }

    @Test func ruleVariablesTakeTheirCatalogPosition() {
        #expect(Placeholders.scan("%#@items@", strict: false) == [1: .variable("items")])
        let swapped = Placeholders.scan(
            "%#@folders@ hold %#@files@", strict: false, variablePositions: ["files": 1, "folders": 2]
        )
        #expect(swapped == [1: .variable("files"), 2: .variable("folders")])
    }

    @Test func swiftTypes() {
        #expect(Placeholders.swiftType(for: .int, specifiers: [:]) == "Int")
        #expect(Placeholders.swiftType(for: .object, specifiers: [:]) == "String")
        #expect(Placeholders.swiftType(for: .variable("n"), specifiers: ["n": "lld"]) == "Int")
        #expect(Placeholders.swiftType(for: .variable("n"), specifiers: ["n": "@"]) == "String")
        #expect(Placeholders.swiftType(for: .variable("n"), specifiers: ["n": "f"]) == "Double")
        #expect(Placeholders.swiftType(for: .variable("n"), specifiers: [:]) == "Int")
    }
}
