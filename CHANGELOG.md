# Changelog

## 1.1.0

- Plurals over the air. Approved plural forms (`<key>_one`, `<key>_other`…)
  now reach `NSLocalizedString`, SwiftUI's `Text("key \(n)")`, the typed
  accessors and `LocalizeMe.localizedString(forKey:arguments:)`, with
  Foundation still choosing the form. A plural with a missing form, other
  placeholders or several variables keeps its shipped strings. See "Plurals"
  in the README.

## 1.0.0

- The first stable release. From here on, only a new major version breaks
  source compatibility.
- Consent levels for apps that ask the user first (Usercentrics, OneTrust,
  Didomi…): full, strings only, and off, set in the configuration and with
  `LocalizeMe.setConsent`. See "Consent" in the README.
- **Source-breaking:** a new error kind, `LocalizeMeError.Kind.consentOff`, for checks skipped while
  consent is off. A `switch`/`when` that lists every kind needs a branch for it.
