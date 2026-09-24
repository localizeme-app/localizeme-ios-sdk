import Foundation

/// A random id for this install, made once and kept in UserDefaults.
///
/// It is not a device identifier and is not tied to the user; deleting the app
/// or its data makes a new one. The dashboard counts these to say how many
/// installs are alive.
enum InstallID {
    static let key = "app.localizeme.install_id"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
