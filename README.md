# LocalizeMe for iOS

Over-the-air translations. Approved strings in the LocalizeMe dashboard reach
the app on its next launch, without an App Store release.

- iOS 15+, tvOS 15+, watchOS 8+, macOS 12+. Swift Package Manager.
- No dependencies. About 1,500 lines.
- One conditional request per launch; the usual answer is a 304 with no body.
- Optional typed accessors (`L10n.homeTitle`) generated from your string tables.

## Install

Xcode → File → Add Package Dependencies →
`https://github.com/localizeme-app/localizeme-ios-sdk`, product `LocalizeMe`.
While the SDK is in beta, choose **Exact Version** `0.1.0-beta.2`: Swift
Package Manager never picks a pre-release on its own.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/localizeme-app/localizeme-ios-sdk", exact: "0.1.0-beta.2"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "LocalizeMe", package: "localizeme-ios-sdk"),
    ]),
]
```

## Use

Start the SDK once, as early as possible, before any screen reads its strings.

SwiftUI:

```swift
import LocalizeMe
import SwiftUI

@main
struct MyApp: App {
    init() {
        LocalizeMe.start(sdkKey: "lzs_…")   // from the project's Mobile SDK tab
    }
    var body: some Scene { WindowGroup { RootView() } }
}
```

UIKit:

```swift
import LocalizeMe
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        LocalizeMe.start(sdkKey: "lzs_…")   // from the project's Mobile SDK tab
        return true
    }
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
The typed accessors below do the same without spelling out keys.

### Typed accessors

The `LocalizeMeStrings` build plugin reads the target's string tables on every
build and generates `L10n`, one accessor per key, so the compiler checks every
key you use:

```swift
Text(L10n.homeTitle)                        // "home.title"
Button(L10n.save) { save() }                // "save"
Text(L10n.itemsCount(count))                // "items.count" = "%lld items"
titleLabel.text = L10n.Onboarding.welcome   // "welcome" in Onboarding.xcstrings
```

Each accessor returns the newest approved OTA value, otherwise the shipped
string, and works from any thread. Before `LocalizeMe.start` it returns the
shipped string.

Turn it on in Xcode: select the app target, then Build Phases → Run Build Tool
Plug-ins → + → `LocalizeMeStrings`. Xcode asks you to trust the plugin on the
first build. In a Swift package, add it to the target that has the strings:

```swift
.target(
    name: "MyFeature",
    dependencies: [.product(name: "LocalizeMe", package: "localizeme-ios-sdk")],
    resources: [.process("Resources")],
    plugins: [.plugin(name: "LocalizeMeStrings", package: "localizeme-ios-sdk")]
)
```

The examples below use these keys from `Localizable.xcstrings`:

| Key | English | Accessor |
| --- | --- | --- |
| `cart.title` | Cart | `L10n.cartTitle` |
| `cart.items` | %lld items, with a plural variant for one | `L10n.cartItems(_:)` |
| `cart.total` | Total: %@ | `L10n.cartTotal(_:)` |
| `cart.checkout` | Check out | `L10n.cartCheckout` |
| `cart.promo.placeholder` | Promo code | `L10n.cartPromoPlaceholder` |
| `cart.clear` | Clear cart | `L10n.cartClear` |
| `cart.clear.confirm` | Remove all %lld items? | `L10n.cartClearConfirm(_:)` |
| `cart.empty` | Your cart is empty | `L10n.cartEmpty` |
| `item.remove` | Remove %@ | `L10n.itemRemove(_:)` |
| `common.delete`, `common.cancel` | Delete, Cancel | `L10n.commonDelete`, `L10n.commonCancel` |
| `tab.cart` | Cart | `L10n.tabCart` |
| `settings.title`, `settings.notifications` | Settings, Notifications | `L10n.settingsTitle`, `L10n.settingsNotifications` |
| `promo.banner` | \*\*20% off\*\* everything this week | `L10n.promoBanner` |

#### SwiftUI

Every view that takes a title takes a `String` too, so an accessor goes
wherever a literal would:

```swift
import SwiftUI

struct CartView: View {
    let items: [CartItem]
    let total: String
    @State private var promoCode = ""
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Button(role: .destructive) { remove(item) } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(L10n.itemRemove(item.name))     // "Remove %@"
                    }
                }
            } header: {
                Text(L10n.cartItems(items.count))    // "3 items", "1 item": the catalog's plural rules
            } footer: {
                Text(L10n.cartTotal(total))          // "Total: €24.90"
            }

            TextField(L10n.cartPromoPlaceholder, text: $promoCode)

            Button(L10n.cartClear, role: .destructive) { confirmingClear = true }
        }
        .overlay {
            if items.isEmpty {
                Text(L10n.cartEmpty).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.cartTitle)
        .toolbar {
            Button(L10n.cartCheckout) { checkout() }
        }
        .confirmationDialog(
            L10n.cartClearConfirm(items.count), isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button(L10n.commonDelete, role: .destructive) { clear() }
            Button(L10n.commonCancel, role: .cancel) {}
        }
    }
}

struct SettingsView: View {
    @AppStorage("notifications") private var notifications = true

    var body: some View {
        Form {
            Toggle(L10n.settingsNotifications, isOn: $notifications)
        }
        .navigationTitle(L10n.settingsTitle)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationView { CartView(items: [], total: "€0.00") }
                .tabItem { Label(L10n.tabCart, systemImage: "cart") }
            NavigationView { SettingsView() }
                .tabItem { Label(L10n.settingsTitle, systemImage: "gear") }
        }
    }
}
```

A `String` is shown exactly as written: SwiftUI does not look it up again and
does not render Markdown in it. For a value that uses Markdown, parse it:

```swift
struct PromoBanner: View {
    var body: some View {
        Text((try? AttributedString(markdown: L10n.promoBanner)) ?? AttributedString(L10n.promoBanner))
    }
}
```

#### UIKit

Keep the strings a screen shows in one method, so it can run again when an
update is applied (see [Applying an update without a relaunch](#applying-an-update-without-a-relaunch)):

```swift
import UIKit

final class CartViewController: UITableViewController {
    var items: [CartItem] = []
    private let promoField = UITextField(frame: CGRect(x: 0, y: 0, width: 320, height: 44))

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "item")
        tableView.tableHeaderView = promoField
        applyStrings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stringsDidChange), name: .localizeMeStringsDidChange, object: nil
        )
    }

    /// Every string on the screen, in one place.
    func applyStrings() {
        title = L10n.cartTitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.cartCheckout, style: .done, target: self, action: #selector(checkout)
        )
        promoField.placeholder = L10n.cartPromoPlaceholder
        tableView.reloadData()
    }

    @objc private func stringsDidChange() {
        applyStrings()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        L10n.cartItems(items.count)                      // "3 items", "1 item"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = items[indexPath.row].name
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let item = items[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: L10n.itemRemove(item.name)) { [weak self] _, _, done in
            self?.remove(item)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    @objc private func confirmClear() {
        let sheet = UIAlertController(title: L10n.cartClearConfirm(items.count), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L10n.commonDelete, style: .destructive) { [weak self] _ in self?.clear() })
        sheet.addAction(UIAlertAction(title: L10n.commonCancel, style: .cancel))
        present(sheet, animated: true)
    }
}
```

Labels, button configurations, menus, tab bar items and accessibility labels
work the same way:

```swift
final class CheckoutBarViewController: UIViewController {
    private let emptyLabel = UILabel()
    private let bannerLabel = UILabel()
    private let checkoutButton = UIButton(configuration: .filled())
    private let moreButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        applyStrings()
    }

    func applyStrings() {
        emptyLabel.text = L10n.cartEmpty
        bannerLabel.attributedText = try? NSAttributedString(markdown: L10n.promoBanner)
        checkoutButton.configuration?.title = L10n.cartCheckout
        moreButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        moreButton.accessibilityLabel = L10n.cartClear
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIAction(title: L10n.cartClear, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.clearCart()
            },
        ])
        tabBarItem = UITabBarItem(title: L10n.tabCart, image: UIImage(systemName: "cart"), tag: 0)
    }
}
```

#### How keys become accessors

- **Names** split the key into words at dots, underscores, spaces and other
  punctuation and join them in lower camel case: `home.title`, `home_title`
  and `HOME_TITLE` all become `homeTitle`, and `Hello, %@!` becomes `hello`.
  When two keys would get the same name, the later one gets a number
  (`homeTitle2`) and the build shows a warning.
- **Plain text** becomes a property and is shown as written, so `"20% off"`
  needs no `%%`.
- **Placeholders** turn the accessor into a function that takes them in order,
  typed from the source-language value: `%d` and `%lld` take an `Int`, `%f` a
  `Double`, `%@` a `String`. Positional placeholders (`%2$@`) keep their
  positions. A plural rule, from a `.stringsdict` or a catalog's plural
  variations, takes its count as an `Int`. In a string with placeholders a
  literal percent sign has to be `%%`, as with `String(format:)`.
- **Tables:** `Localizable` fills `L10n` itself and every other table gets its
  own nested enum, such as `L10n.Onboarding`. `InfoPlist` and `AppShortcuts`
  are skipped.
- **Quick Help** shows the source-language text and the catalog's comment.

It reads `.xcstrings`, `.strings` and `.stringsdict` files. For `.strings` and
`.stringsdict` the values come from the `sourceLanguage` below if set, otherwise
from `Base`, then `en`, then the first other language.

#### Configuration

An optional `localizeme-strings.json` in the target, or next to the
`.xcodeproj`, changes the defaults:

```json
{ "typeName": "Strings", "accessLevel": "public", "sourceLanguage": "de" }
```

`accessLevel` is `internal` (the default), `public` or `package`; use `public`
for a strings module other modules import. In a Swift package, list the file
under the target's `exclude:`.

#### Notes for string catalogs

Keys that Xcode extracted from your code show as Stale in the catalog once only
`L10n` refers to them. Set them to manually managed in the Attributes inspector.
Catalogs exported from LocalizeMe already mark every key as manual.

Xcode 26 can generate its own symbols from a string catalog (`Text(.homeTitle)`),
but they resolve through `LocalizedStringResource`, which the SDK does not
intercept, so they always show the shipped text. Use `L10n` for strings you
update over the air.

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

SwiftUI: give the root view a new identity once the strings are live, and it
is rebuilt with them.

```swift
@main
struct MyApp: App {
    @State private var stringsVersion = 0

    init() {
        LocalizeMe.start(sdkKey: "lzs_…")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(stringsVersion)
                .onAppear {
                    LocalizeMe.onUpdate = { version in
                        LocalizeMe.applyNow()
                        stringsVersion = version
                    }
                }
        }
    }
}
```

A new identity also resets view state, such as scroll positions and text being
typed, which is why the default waits for the next launch.

UIKit: post a notification once the strings are live, and let each screen run
its `applyStrings()` again, as `CartViewController` above does.

```swift
extension Notification.Name {
    static let localizeMeStringsDidChange = Notification.Name("LocalizeMeStringsDidChange")
}

// In application(_:didFinishLaunchingWithOptions:), after LocalizeMe.start:
LocalizeMe.onUpdate = { _ in
    LocalizeMe.applyNow()
    NotificationCenter.default.post(name: .localizeMeStringsDidChange, object: nil)
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

The `LocalizeMeStringsGenerator` tool the plugin runs is a thin wrapper around
the `LocalizeMeStringsCore` library, which its tests link directly. The
`LocalizeMeTests` target runs the plugin on its own fixtures and tests the
`L10n` it gets.

```bash
./test.sh                              # everything except the SwiftUI rendering test
LOCALIZEME_UI_TESTS=1 ./test.sh        # also render SwiftUI Text through the swizzle (needs a window server)
./test.sh --sanitize=thread            # the re-start race test under the thread sanitizer
```

## License

Source-available under the [PolyForm Shield License 1.0.0](LICENSE). Put
it in any app, commercial or not, and read, change and ship it with your
app as you need. What it does not allow is using the SDK, or anything made
from it, to provide a product that competes with the SDK or with
LocalizeMe. Keep the `LICENSE` file, or its link and the `Required Notice`
line, with any copy you pass on.

Versions up to and including 0.1.0-beta.2 were released under the MIT License,
and stay available under it.
