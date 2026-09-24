import Foundation

/// Reads the `printf`-style placeholders in a string, so an OTA value can be
/// checked against the shipped string before the app formats arguments into it.
enum FormatSpecifiers {
    /// Argument position → the kind of argument the placeholder there consumes:
    /// "i" (integers), "f" (floating point), "@" (objects), "s" (C strings),
    /// "c" (characters), "p" (pointers) or "#@" (a `.stringsdict` rule). A `*`
    /// width or precision takes an integer argument of its own. Length
    /// modifiers are ignored: `%d` and `%ld` read the same slot. Positions
    /// come from `n$` when given and count up otherwise.
    ///
    /// `nil` when the string cannot be trusted: a `%n`, a conversion this
    /// scanner does not know, or one position asked for two kinds. A `%`
    /// that ends the string is plain text.
    static func signature(_ string: String) -> [Int: String]? {
        let bytes = Array(string.utf8)
        var result: [Int: String] = [:]
        var implicit = 1
        var i = 0

        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

        /// Reads `n$` at `i` when present, moving past it.
        func explicitPosition() -> Int? {
            var j = i
            var n = 0
            while j < bytes.count, isDigit(bytes[j]) {
                n = n * 10 + Int(bytes[j] - 0x30)
                j += 1
            }
            guard j > i, j < bytes.count, bytes[j] == 0x24 /* $ */, n > 0 else { return nil }
            i = j + 1
            return n
        }

        func skipDigits() {
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
        }

        /// Records what the slot at `position` (or the next implicit one) takes.
        func record(_ position: Int?, _ kind: String) -> Bool {
            let slot: Int
            if let position {
                slot = position
            } else {
                slot = implicit
                implicit += 1
            }
            if let existing = result[slot], existing != kind { return false }
            result[slot] = kind
            return true
        }

        /// A `*` at `i` (width or precision from an argument) with its own
        /// optional `n$`. True when nothing is wrong.
        func star() -> Bool {
            guard i < bytes.count, bytes[i] == 0x2A /* * */ else {
                skipDigits()
                return true
            }
            i += 1
            return record(explicitPosition(), "i")
        }

        while i < bytes.count {
            guard bytes[i] == 0x25 /* % */ else {
                i += 1
                continue
            }
            i += 1
            // A `%` that ends the string ("Save 20%") is text, not a placeholder:
            // nothing can follow it, so nothing can be formatted into it.
            guard i < bytes.count else { break }
            if bytes[i] == 0x25 {
                i += 1
                continue
            }
            let position = explicitPosition()
            var alternate = false
            flags: while i < bytes.count {
                switch bytes[i] {
                case 0x23 /* # */: alternate = true
                case 0x2D, 0x2B, 0x20, 0x30, 0x27 /* - + space 0 ' */: break
                default: break flags
                }
                i += 1
            }
            guard star() else { return nil }
            if i < bytes.count, bytes[i] == 0x2E /* . */ {
                i += 1
                guard star() else { return nil }
            }
            lengths: while i < bytes.count {
                switch bytes[i] {
                case 0x68, 0x6C, 0x71, 0x4C, 0x7A, 0x74, 0x6A /* h l q L z t j */: i += 1
                default: break lengths
                }
            }
            guard i < bytes.count else { return nil }
            let kind: String
            switch bytes[i] {
            case 0x64, 0x69, 0x75, 0x78, 0x58, 0x6F, 0x4F, 0x44, 0x55 /* d i u x X o O D U */:
                kind = "i"
            case 0x66, 0x46, 0x65, 0x45, 0x67, 0x47, 0x61, 0x41 /* f F e E g G a A */:
                kind = "f"
            case 0x40 /* @ */:
                if alternate {
                    // %#@name@: a plural rule from a .stringsdict, closed by the next @.
                    guard let close = bytes[(i + 1)...].firstIndex(of: 0x40) else { return nil }
                    i = close
                    kind = "#@"
                } else {
                    kind = "@"
                }
            case 0x73, 0x53 /* s S */:
                kind = "s"
            case 0x63, 0x43 /* c C */:
                kind = "c"
            case 0x70 /* p */:
                kind = "p"
            default:
                return nil
            }
            i += 1
            guard record(position, kind) else { return nil }
        }
        return result
    }

    /// Whether `ota` takes exactly the arguments `shipped` takes. Translators
    /// may reorder positional arguments, not change their type or count, and
    /// neither string may be one the scanner cannot read.
    static func compatible(_ ota: String, _ shipped: String) -> Bool {
        guard let a = signature(ota), let b = signature(shipped) else { return false }
        return a == b
    }

    /// Whether a key looks like an identifier rather than a sentence: 1 to 128
    /// bytes of `A-Z a-z 0-9 _ . -`. A byte scan, since it runs on every miss.
    static func looksLikeIdentifier(_ key: String) -> Bool {
        var count = 0
        for byte in key.utf8 {
            count += 1
            guard count <= 128 else { return false }
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2E, 0x2D:
                continue
            default:
                return false
            }
        }
        return count > 0
    }
}
