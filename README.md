# LocalizeMe for iOS

Over-the-air translations. Approved strings in the LocalizeMe dashboard reach
the app on its next launch, without an App Store release.

- iOS 15+, tvOS 15+, watchOS 8+, macOS 12+. Swift Package Manager.
- No dependencies. About 1,500 lines.
- One conditional request per launch; the usual answer is a 304 with no body.

## Install

Xcode → File → Add Package Dependencies →
`https://github.com/localizeme-app/localizeme-ios-sdk`, product `LocalizeMe`.
While the SDK is in beta, choose **Exact Version** `0.1.0-beta.1`: Swift
Package Manager never picks a pre-release on its own.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/localizeme-app/localizeme-ios-sdk", exact: "0.1.0-beta.1"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "LocalizeMe", package: "localizeme-ios-sdk"),
    ]),
]
```

## Use

```swift
import LocalizeMe

@main
struct MyApp: App {
    init() {
        LocalizeMe.start(sdkKey: "lzs_…")   // from the project's Mobile SDK tab
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

That is all for most apps. Lookups on `Bundle.main` now return the newest
approved string for the language the app is showing, and fall back to the
app's own `.strings` / `.xcstrings` when the dashboard has nothing.

Keys in the dashboard must match the keys in your string catalog.

### What is intercepted

The SDK exchanges the two public lookup methods of `Bundle` and touches
nothing else, so it only sees what goes through them.

Intercepted automatically:

- `NSLocalizedString`
- `Bundle.main.localizedString(forKey:value:table:)`
- `Bundle.main.localizedAttributedString(forKey:value:table:)`
- SwiftUI views that take a `LocalizedStringKey`: `Text("key")`,
  `Text("key \(n)")`, `Button("key")`, `Label`, `.navigationTitle("key")`
  and so on, unless the view sets `.environment(\.locale, …)`

Not intercepted, use `LocalizeMe.localizedString(forKey:)` or
`LocalizeMe.text(_:)` instead:

- `String(localized:)`
- `LocalizedStringResource` and `Text(LocalizedStringResource)`
- `AttributedString(localized:)`
- `Text` with an explicit locale (`.environment(\.locale, …)`)
- strings in other bundles, including `Bundle.module`
- `.stringsdict` plural rules

These use private Foundation entry points. Swizzling those would be an App
Store rejection risk and could break with any OS update, so the SDK stays on
public API and gives you helpers for the rest:

```swift
LocalizeMe.localizedString(forKey: "home.title")                       // String
LocalizeMe.localizedString(forKey: "items %lld", arguments: count)     // formatted
LocalizeMe.text("home.title")                                          // SwiftUI Text
```

Both return the approved OTA value when there is one, otherwise exactly what
`NSLocalizedString` would have returned.

### Safety

An OTA value whose placeholders differ from the shipped string's (`%@` where
the app passes a number, a missing `%lld`, two arguments instead of one) is
never shown; the shipped string is used and the dashboard gets a
`format_mismatch` report naming the key. Translators may reorder positional
arguments (`%2$@ … %1$d`), not change their type or count.

Reporting missing keys is off by default. When `reportMissingKeys` is on, the
SDK reports only keys that look like identifiers (up to 128 characters of
letters, digits, `_`, `.` and `-`) and only while an OTA language is live, so
a sentence a view passed as its own text never leaves the device.

### Options

```swift
var config = LocalizeMeConfiguration(sdkKey: "lzs_…")
config.applyImmediately = true        // swap strings in as they arrive (default: next launch)
config.language = "lt"                // ignore the language the app is showing
config.languageScope = .all           // download every language, not just the device's
config.checkOnForeground = false      // only check on cold launch
config.minimumCheckInterval = 300     // seconds between automatic checks
config.interceptBundleLookups = false // don't touch Bundle; use the helpers above
config.reportMissingKeys = true       // tell the dashboard about unknown keys
config.debugLogging = true            // DEBUG builds only
LocalizeMe.start(config)
```

### Which language

The SDK matches the localization the app is actually rendering
(`Bundle.main.preferredLocalizations`), then the device's language list,
against the languages the project publishes and every code they answer to
(`no` is also `nb` and `nb-NO`), with Apple's own matcher. So an app that only
ships French shows French OTA strings on a German device too, and `zh-Hant-TW`
finds `zh-Hant`.

### Applying an update without a relaunch

By default a new version is downloaded and staged, and goes live on the next
launch so nothing changes under the user's finger. To apply it now:

```swift
LocalizeMe.onUpdate = { version in
    LocalizeMe.applyNow()
    // re-render: e.g. bump an @Published id on your root view
}
```

`applyNow()` is synchronous: when it returns the new strings are live, so the
re-render right after it sees them. It returns `true` when something changed
and does not call `onUpdate` again.

### Manual lookups

```swift
LocalizeMe.string("home.title")                      // String? — the raw OTA value, nil when the app should use its own
LocalizeMe.string("home.title", fallback: "Home")    // String — the fallback also wins on a placeholder mismatch
LocalizeMe.check { result in … }                     // force a check now
LocalizeMe.setLanguage("lt")                         // in-app language switch
LocalizeMe.version                                   // 0 until something has been downloaded
```

## How it works

1. On launch the SDK loads the last bundle from `Library/Caches/LocalizeMe/` and
   swaps it in synchronously, then asks `GET /ota/v1/manifest?platform=ios` with
   `If-None-Match`.
2. A 304 means done, unless the device now wants a language that is not on
   disk yet; the manifest kept from the last 200 says where to get it. A 200
   lists a content-addressed bundle per language; the SDK downloads the
   device's language, verifies its SHA-256, and writes it atomically.
3. The new snapshot is staged (or applied, see above). Old bundle files are
   pruned.

The SDK also sends an install id it made up (a random UUID kept in
UserDefaults), the app, SDK and OS versions, and any errors it hit. Nothing
that identifies a person or a device.

## Building and testing

`swift build` works with the Xcode command line tools alone. `swift test` needs
the toolchain's Swift Testing framework on the search path when Xcode itself is
not installed:

```bash
./test.sh                              # everything except the SwiftUI rendering test
LOCALIZEME_UI_TESTS=1 ./test.sh        # also render SwiftUI Text through the swizzle (needs a window server)
./test.sh --sanitize=thread            # the re-start race test under the thread sanitizer
```
