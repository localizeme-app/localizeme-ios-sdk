import Foundation

/// Which languages to keep up to date on this device.
public enum LocalizeMeLanguageScope {
    /// The language the app is showing. One small download per change.
    case device
    /// Every language the project publishes. Only worth it for apps that let
    /// the user switch language in-app without a restart.
    case all
}

/// How much of the SDK may run, for apps that ask the user first (a consent
/// banner or CMP such as Usercentrics, OneTrust or Didomi).
/// Declared from least to most, which is the order `<` compares in.
public enum LocalizeMeConsent: String, CaseIterable, Comparable {
    /// No network at all. Strings already downloaded keep showing, falling
    /// back to the shipped ones.
    case off
    /// Strings only. Nothing is stored on the device beyond the strings, and
    /// requests carry the SDK key and SDK version and nothing about the install.
    /// The install id is deleted and nothing is reported.
    case stringsOnly = "strings_only"
    /// Strings plus what the dashboard shows about installs: a random install
    /// id kept on the device, the app and OS version, the language, and error
    /// and missing-key reports.
    case full

    public static func < (lhs: LocalizeMeConsent, rhs: LocalizeMeConsent) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
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
    /// they set `.environment(\.locale, …)`, plurals included.
    /// `String(localized:)`, `LocalizedStringResource`,
    /// `AttributedString(localized:)` and other bundles use private Foundation
    /// entry points and are left alone; call `LocalizeMe.localizedString(forKey:)` or
    /// `LocalizeMe.text(_:)` there. Turn off to use only those helpers.
    public var interceptBundleLookups = true
    /// Tell the dashboard about keys the app asked for that neither the OTA
    /// strings nor the shipped ones had. Off by default. When on, only keys
    /// that look like identifiers (up to 128 characters of letters, digits,
    /// `_`, `.` and `-`) are sent, never a sentence a view passed as its own
    /// text, and nothing is sent while no OTA language is live.
    public var reportMissingKeys = false
    /// What the SDK may do until `LocalizeMe.setConsent(_:)` says otherwise.
    /// Not remembered between launches: the consent tool is the record, so
    /// start at the level it last gave, or at `.off` until it answers.
    public var consent: LocalizeMeConsent = .full
    /// Print what the SDK is doing. Leave off in release builds.
    public var debugLogging = false

    public init(sdkKey: String) {
        self.sdkKey = sdkKey
    }
}
