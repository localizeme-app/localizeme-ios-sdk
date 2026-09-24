import Foundation

/// Which languages to keep up to date on this device.
public enum LocalizeMeLanguageScope {
    /// The language the app is showing. One small download per change.
    case device
    /// Every language the project publishes. Only worth it for apps that let
    /// the user switch language in-app without a restart.
    case all
}

public struct LocalizeMeConfiguration {
    /// A project SDK key (`lzs_…`) from the project's Mobile SDK tab.
    public var sdkKey: String
    /// The API host. Only the sandbox or a self-hosted API changes this.
    public var baseURL: URL = URL(string: "https://api.localizeme.app")!
    /// Swap a downloaded bundle in as soon as it arrives. Off by default: new
    /// strings apply on the next launch, so a screen never changes under the
    /// user's finger. `LocalizeMe.applyNow()` applies a staged bundle on demand.
    public var applyImmediately = false
    /// Force a language instead of following the one the app is showing.
    public var language: String?
    public var languageScope: LocalizeMeLanguageScope = .device
    /// Check again when the app returns to the foreground.
    public var checkOnForeground = true
    /// The shortest gap between two automatic checks.
    public var minimumCheckInterval: TimeInterval = 60
    /// Route `Bundle.main`'s lookups through the OTA strings. That covers
    /// `NSLocalizedString`, `Bundle.main.localizedString(forKey:value:table:)`,
    /// `Bundle.main.localizedAttributedString(forKey:value:table:)` and the
    /// SwiftUI views that take a `LocalizedStringKey` (`Text("key")`,
    /// `Text("key \(n)")`, `Button("key")`, `Label`, `.navigationTitle`) unless
    /// they set `.environment(\.locale, …)`. `String(localized:)`,
    /// `LocalizedStringResource`, `AttributedString(localized:)`, other bundles
    /// and `.stringsdict` plurals use private Foundation entry points and are
    /// left alone; call `LocalizeMe.localizedString(forKey:)` or
    /// `LocalizeMe.text(_:)` there. Turn off to use only those helpers.
    public var interceptBundleLookups = true
    /// Tell the dashboard about keys the app asked for that neither the OTA
    /// strings nor the shipped ones had. Off by default. When on, only keys
    /// that look like identifiers (up to 128 characters of letters, digits,
    /// `_`, `.` and `-`) are sent, never a sentence a view passed as its own
    /// text, and nothing is sent while no OTA language is live.
    public var reportMissingKeys = false
    /// Print what the SDK is doing. Leave off in release builds.
    public var debugLogging = false

    public init(sdkKey: String) {
        self.sdkKey = sdkKey
    }
}
