import Foundation
import Testing
@testable import LocalizeMeStringsCore

struct CatalogTests {
    @Test func stringCatalogsGiveTheSourceValueOrTheKeyItself() throws {
        let json = #"""
        {
          "sourceLanguage" : "en",
          "strings" : {
            "home.title" : {
              "comment" : "Top of the home screen",
              "localizations" : {
                "de" : { "stringUnit" : { "state" : "translated", "value" : "Startseite" } },
                "en" : { "stringUnit" : { "state" : "translated", "value" : "Home" } }
              }
            },
            "Hello %@" : { },
            "items %lld" : {
              "localizations" : {
                "en" : {
                  "variations" : {
                    "plural" : {
                      "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld item" } },
                      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld items" } }
                    }
                  }
                }
              }
            },
            "Tap here" : {
              "localizations" : {
                "en" : {
                  "variations" : {
                    "device" : {
                      "mac" : { "stringUnit" : { "state" : "translated", "value" : "Click here" } },
                      "other" : { "stringUnit" : { "state" : "translated", "value" : "Tap here" } }
                    }
                  }
                }
              }
            },
            "files.in.folders" : {
              "localizations" : {
                "en" : {
                  "stringUnit" : { "state" : "translated", "value" : "%#@folders@ hold %#@files@" },
                  "substitutions" : {
                    "files" : {
                      "argNum" : 1, "formatSpecifier" : "lld",
                      "variations" : { "plural" : {
                        "one" : { "stringUnit" : { "state" : "translated", "value" : "%arg file" } },
                        "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg files" } }
                      } }
                    },
                    "folders" : {
                      "argNum" : 2, "formatSpecifier" : "lld",
                      "variations" : { "plural" : {
                        "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg folders" } }
                      } }
                    }
                  }
                }
              }
            }
          },
          "version" : "1.0"
        }
        """#
        let entries = Dictionary(uniqueKeysWithValues: try Catalog.xcstrings(Data(json.utf8)).map { ($0.key, $0) })
        #expect(entries["home.title"]?.format == "Home")
        #expect(entries["home.title"]?.comment == "Top of the home screen")
        #expect(entries["Hello %@"]?.format == "Hello %@")
        #expect(entries["items %lld"]?.format == "%lld items")
        #expect(entries["Tap here"]?.format == "Tap here")
        let files = try #require(entries["files.in.folders"])
        #expect(files.format == "%#@folders@ hold %#@files@")
        #expect(files.preview == "%lld folders hold %lld files")
        #expect(files.variables["files"] == .init(specifier: "lld", position: 1))
        #expect(files.variables["folders"] == .init(specifier: "lld", position: 2))
    }

    @Test func stringsFilesAndBlankOnes() throws {
        let text = """
        /* A comment */
        "home.title" = "Home";
        "quote" = "Say \\"hi\\"\\n";
        // Another comment
        "percent" = "20% off";
        """
        #expect(try Catalog.strings(Data(text.utf8)) == ["home.title": "Home", "quote": "Say \"hi\"\n", "percent": "20% off"])
        let utf16 = try #require(text.data(using: .utf16))
        #expect(try Catalog.strings(utf16)["home.title"] == "Home")
        #expect(try Catalog.strings(Data("/* nothing yet */\n// still nothing\n".utf8)) == [:])
    }

    @Test func stringsdictRules() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>items.count</key>
          <dict>
            <key>NSStringLocalizedFormatKey</key><string>%#@items@ in %@</string>
            <key>items</key>
            <dict>
              <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
              <key>NSStringFormatValueTypeKey</key><string>lld</string>
              <key>one</key><string>%lld item</string>
              <key>other</key><string>%lld items</string>
            </dict>
          </dict>
          <key>greeting</key>
          <dict>
            <key>NSStringVariableWidthRuleType</key>
            <dict><key>1</key><string>Hi</string><key>20</key><string>Hello there</string></dict>
          </dict>
        </dict></plist>
        """
        let entries = Dictionary(uniqueKeysWithValues: try Catalog.stringsdict(Data(plist.utf8)).map { ($0.key, $0) })
        let items = try #require(entries["items.count"])
        #expect(items.format == "%#@items@ in %@")
        #expect(items.preview == "%lld items in %@")
        #expect(items.variables["items"] == .init(specifier: "lld", position: nil))
        #expect(entries["greeting"]?.format == "Hello there")
    }

    @Test func tablesMergeLanguagesAndPreferTheSourceOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        let files = [
            try write("de.lproj/Localizable.strings", #""title" = "Titel"; "only.de" = "Nur hier";"#),
            try write("en.lproj/Localizable.strings", #""title" = "Title";"#),
            try write("en.lproj/InfoPlist.strings", #""CFBundleDisplayName" = "App";"#),
            try write("broken.lproj/Broken.strings", #""unterminated = "#),
        ]
        let (tables, warnings) = Catalog.read(files, sourceLanguage: nil)
        #expect(tables.map(\.name) == ["Broken", "Localizable"])
        let localizable = try #require(tables.first { $0.name == "Localizable" })
        #expect(localizable.entries["title"]?.format == "Title")
        #expect(localizable.entries["only.de"]?.format == "Nur hier")
        #expect(warnings.count == 1)
        #expect(warnings.first?.file?.hasSuffix("Broken.strings") == true)

        let german = Catalog.read(files, sourceLanguage: "de").tables.first { $0.name == "Localizable" }
        #expect(german?.entries["title"]?.format == "Titel")
    }
}
