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

## Localization

All user-facing text must use the String Catalog through `String(localized:)` or a localized SwiftUI initializer. Do not add hard-coded English text to views, accessibility labels, errors, notifications, AppIntents, or services.

When adding a string, add translations for all supported locales in `Actuali/Actuali/Localizable.xcstrings`, preserve every format placeholder, and run `python3 dev/scripts/validate-localization.py`. For a new language, update the Xcode project regions and the validator's supported locale list together.

## Issues

Bug reports and feature requests are welcome — please open a GitHub issue.

## Pull requests

- Keep changes focused; one concern per PR
- Make sure the project builds and tests pass before opening a PR
- For sync-engine changes, reference the corresponding upstream behavior (`packages/crdt` / `packages/loot-core` in [actualbudget/actual](https://github.com/actualbudget/actual)) so it can be verified
- Don't bump the build number; that happens at release time
