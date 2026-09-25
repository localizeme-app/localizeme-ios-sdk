import Foundation

/// The arguments a format string takes, read the way `String(format:)`
/// reads them and the way the SDK's own placeholder check (`FormatSpecifiers`)
/// does, so a generated function takes exactly what formatting will consume.
enum Placeholders {
    enum Kind: Equatable {
        case int, double, object, cString, wideString, char, unichar, pointer
        /// `%#@name@`: a plural or other rule from a `.stringsdict` or a
        /// catalog's substitutions, whose own specifier decides the type.
        case variable(String)
    }

    /// Argument slot (1-based) → what it takes.
    ///
    /// `nil` when formatting could go wrong: a `%n`, a conversion
    /// `String(format:)` does not know, or one slot read as two types.
    ///
    /// `strict` reads a `%` that does not open a well-formed placeholder as
    /// plain text, and does not accept the space flag, so "20% off" reads as
    /// text where `String(format:)` would see `% o`. It answers "is this a
    /// format string at all"; the lenient reading answers "what does
    /// formatting it consume".
    static func scan(_ format: String, strict: Bool, variablePositions: [String: Int] = [:]) -> [Int: Kind]? {
        let bytes = Array(format.utf8)
        var result: [Int: Kind] = [:]
        var implicit = 1
        var i = 0

        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

        /// Reads `n$` at `j` when present, moving past it.
        func position(at j: inout Int) -> Int? {
            var k = j
            var n = 0
            while k < bytes.count, isDigit(bytes[k]) {
                n = n &* 10 &+ Int(bytes[k] - 0x30)
                k += 1
            }
            guard k > j, k < bytes.count, bytes[k] == 0x24 /* $ */, n > 0 else { return nil }
            j = k + 1
            return n
        }

        while i < bytes.count {
            guard bytes[i] == 0x25 /* % */ else {
                i += 1
                continue
            }
            let start = i
            var j = i + 1
            // A `%` that ends the string ("Save 20%") is text.
            guard j < bytes.count else { break }
            if bytes[j] == 0x25 {
                i = j + 1
                continue
            }

            var found: [(position: Int?, kind: Kind)] = []
            var malformed = false
            let explicit = position(at: &j)
            var alternate = false
            flags: while j < bytes.count {
                switch bytes[j] {
                case 0x23 /* # */: alternate = true
                case 0x2D, 0x2B, 0x30, 0x27 /* - + 0 ' */: break
                case 0x20 /* space */:
                    if strict { malformed = true; break flags }
                default: break flags
                }
                j += 1
            }
            // Width, then precision: digits, or `*` taking an int argument of its own.
            for part in 0..<2 where !malformed {
                if part == 1 {
                    guard j < bytes.count, bytes[j] == 0x2E /* . */ else { break }
                    j += 1
                }
                if j < bytes.count, bytes[j] == 0x2A /* * */ {
                    j += 1
                    found.append((position(at: &j), .int))
                } else {
                    while j < bytes.count, isDigit(bytes[j]) { j += 1 }
                }
            }
            lengths: while !malformed, j < bytes.count {
                switch bytes[j] {
                case 0x68, 0x6C, 0x71, 0x4C, 0x7A, 0x74, 0x6A /* h l q L z t j */: j += 1
                default: break lengths
                }
            }

            var kind: Kind?
            if !malformed, j < bytes.count {
                switch bytes[j] {
                case 0x64, 0x69, 0x75, 0x78, 0x58, 0x6F, 0x4F, 0x44, 0x55 /* d i u x X o O D U */: kind = .int
                case 0x66, 0x46, 0x65, 0x45, 0x67, 0x47, 0x61, 0x41 /* f F e E g G a A */: kind = .double
                case 0x40 /* @ */:
                    if alternate {
                        // %#@name@, closed by the next @.
                        if let close = bytes[(j + 1)...].firstIndex(of: 0x40) {
                            kind = .variable(String(decoding: bytes[(j + 1)..<close], as: UTF8.self))
                            j = close
                        }
                    } else {
                        kind = .object
                    }
                case 0x73 /* s */: kind = .cString
                case 0x53 /* S */: kind = .wideString
                case 0x63 /* c */: kind = .char
                case 0x43 /* C */: kind = .unichar
                case 0x70 /* p */: kind = .pointer
                case 0x6E /* n */: return nil
                default: break
                }
            }
            guard let kind else {
                if strict {
                    // Not a placeholder: the `%` is text.
                    i = start + 1
                    continue
                }
                return nil
            }
            var slot = explicit
            if slot == nil, case .variable(let name) = kind { slot = variablePositions[name] }
            found.append((slot, kind))

            for (position, kind) in found {
                let resolved: Int
                if let position {
                    resolved = position
                } else {
                    resolved = implicit
                    implicit += 1
                }
                if let existing = result[resolved], existing != kind { return nil }
                result[resolved] = kind
            }
            i = j + 1
        }
        return result
    }

    /// The Swift type a caller passes for `kind`. A rule variable takes the
    /// type of its own specifier (`lld` → `Int`), an integer when it has none.
    static func swiftType(for kind: Kind, specifiers: [String: String]) -> String {
        switch kind {
        case .int: return "Int"
        case .double: return "Double"
        case .object: return "String"
        case .cString: return "UnsafePointer<CChar>"
        case .wideString: return "UnsafePointer<UInt16>"
        case .char: return "CChar"
        case .unichar: return "UInt16"
        case .pointer: return "UnsafeRawPointer"
        case .variable(let name):
            guard let specifier = specifiers[name],
                  let resolved = scan("%" + specifier, strict: false)?[1],
                  resolved != kind
            else { return "Int" }
            if case .variable = resolved { return "Int" }
            return swiftType(for: resolved, specifiers: [:])
        }
    }
}
