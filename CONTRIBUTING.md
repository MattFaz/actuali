# Contributing

Thanks for your interest in Actuali.

## Building

- Xcode with the iOS 26.1+ SDK
- Open `Actuali/Actuali.xcodeproj`; Swift Package Manager resolves dependencies on first build

```bash
xcodebuild -project Actuali/Actuali.xcodeproj -scheme Actuali -sdk iphonesimulator build
```

## Tests

```bash
xcodebuild -project Actuali/Actuali.xcodeproj -scheme Actuali \
  -destination 'platform=iOS Simulator,name=<any installed simulator>' test
```

The sync engine tests (`Actuali/ActualiTests/SyncEngineFixtureTests.swift` and friends) verify CRDT behavior against fixtures derived from upstream Actual Budget — please keep them passing.

## Issues

Bug reports and feature requests are welcome — please open a GitHub issue.

## Pull requests

- Keep changes focused; one concern per PR
- Make sure the project builds and tests pass before opening a PR
- For sync-engine changes, reference the corresponding upstream behavior (`packages/crdt` / `packages/loot-core` in [actualbudget/actual](https://github.com/actualbudget/actual)) so it can be verified
- Don't bump the build number; that happens at release time

## Localization

The app ships a String Catalog at `Actuali/Actuali/Localizable.xcstrings` (JSON, Xcode 15+). English (`en`) is the development language; French (`fr`), Spanish (`es`), Brazilian Portuguese (`pt-BR`), German (`de`), Italian (`it`), and Dutch (`nl`) are supported translations.

**SwiftUI strings** — `Text("…")` literals are auto-extracted by Xcode into the catalog; no extra code needed.

**Non-SwiftUI strings** — notification bodies, AppIntent error descriptions, and Siri/Shortcuts dialog text must be wrapped explicitly:

```swift
// one-off strings — String Catalog key = the English value
String(localized: "Couldn't log transaction")

// shared/reused strings — semantic key, English lives in the catalog
String(localized: "common.cancel")

// with runtime values — %@ placeholders are generated automatically
String(localized: "…and \(count) more")
```

Keep translations in the same placeholder order as English — the app never uses positional specifiers (`%1$@`), so a reordered translation silently swaps its arguments.

Run `python3 dev/scripts/validate-localization.py` before opening a PR; it checks that every explicit key exists in the catalog, every entry covers all supported locales, and placeholders match across languages.

### Adding a new language

1. Open `Actuali/Actuali.xcodeproj` in Xcode.
2. Select the project root → **Info** → **Localizations** → **+** → choose the language.
3. Xcode adds the new locale to `knownRegions` in `project.pbxproj` and creates empty entries in `Localizable.xcstrings`.
4. Fill in the `"value"` fields for the new locale in `Localizable.xcstrings` (or use **Editor › Export Localizations…** for an XLIFF-based workflow).
5. Set every translated entry's `"state"` to `"translated"`.

### Adding new strings

- **SwiftUI**: just use `Text("My new string")` — Xcode extracts it automatically on the next build.
- **Non-SwiftUI** (notifications, intents, errors): wrap with `String(localized: "…")` and add a matching entry in `Localizable.xcstrings` with translations for each supported locale. Include a `"comment"` that describes the context so translators know where the string appears.
