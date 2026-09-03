# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository. `CLAUDE.md` is a symlink to this file. See also [CONTRIBUTING.md](CONTRIBUTING.md).

## Project Overview

Actuali is a native iOS companion app for [Actual Budget](https://actualbudget.org/), a local-first personal finance tool. It implements Actual's CRDT sync engine natively in Swift for offline-first operation with automatic synchronization.

Repo layout:

- `Actuali/` — the Xcode project: app (`Actuali/`), unit tests (`ActualiTests/`), UI tests (`ActualiUITests/`)
- `website/` — Astro marketing/support site, including the changelog
- `dev/` — development scripts and fixtures
- `actual/` — (optional, gitignored) local clone of [actualbudget/actual](https://github.com/actualbudget/actual) used as the reference implementation

## Build and Test

```bash
# Build
xcodebuild -project Actuali/Actuali.xcodeproj -scheme Actuali -sdk iphonesimulator build

# Unit tests (what CI runs; UI tests are excluded from CI)
xcodebuild test \
  -project Actuali/Actuali.xcodeproj \
  -scheme Actuali \
  -destination 'platform=iOS Simulator,name=<any installed iPhone simulator>' \
  -skip-testing:ActualiUITests

# Regenerate protobuf (only if sync.proto changes — never hand-edit Generated/)
protoc --swift_out=Actuali/Actuali/Generated/ Actuali/Actuali/Resources/sync.proto
```

Requirements: Xcode with the iOS 26.1+ SDK. Swift Package Manager resolves dependencies (GRDB, SwiftProtobuf, ZIPFoundation) on first build.

`SWIFT_VERSION = 5.0` on the Xcode 26 toolchain — Swift 6 strict concurrency migration is a separate tracked effort; don't flip it as a side effect of other work.

## Architecture

```text
UI (SwiftUI Views)
    ↓
BudgetStore (@MainActor, ObservableObject)   — single source of truth for app state
    ↓
Services layer
    ├── BudgetDatabase (GRDB) → SQLite
    ├── SyncClient (actor) → CRDT sync engine
    └── ActualServerClient (actor) → network
```

Key files (under `Actuali/Actuali/`):

- `Services/BudgetStore.swift` — main app state
- `Services/Sync/SyncClient.swift` — sync orchestration (actor)
- `Services/Database/BudgetDatabase.swift` — GRDB SQLite wrapper
- `Services/Network/ActualServerClient.swift` — API client (actor)

### CRDT Sync Engine (`Services/Sync/`)

- `HybridLogicalClock.swift` / `HLCTimestamp.swift` — causality ordering (`2019-06-03T16:40:53.876Z-0000-9f66d38cba0ef956` format)
- `MerkleTree.swift` — sync diffing (ternary trie, minute-resolution buckets)
- `MessageGenerator.swift` — field-level CRDT message creation
- `SyncEncoder.swift` — protobuf encoding/decoding

Write flow: local SQLite → generate CRDT messages → store in `messages_crdt` → update Merkle tree → sync to server (1s debounce). Reads are plain SQLite queries with no CRDT overhead.

The sync engine must stay byte-for-byte compatible with upstream Actual. For any sync-engine change, check the corresponding behavior in the upstream repo (`packages/crdt`, `packages/loot-core`) and reference it in your PR so it can be verified.

### Data Format Quirks

- Dates: `YYYYMMDD` integers (e.g. `20251209`)
- Amounts: integer cents (e.g. `1050` = $10.50)
- Booleans: `0`/`1` integers
- Monthly budgets live in either `zero_budgets` or `reflect_budgets` depending on budget type — check both

## Coding Standards

- Match the style, naming, and idioms of the surrounding code. Read neighboring files before writing new ones.
- Keep it simple (KISS): prefer the smallest change that solves the problem. No speculative abstractions, feature flags, or configuration for needs that don't exist yet.
- Don't repeat yourself (DRY): before writing a helper, search for an existing one — this codebase already has utilities for amounts, dates, and database access. But don't force abstractions to unify code that is only coincidentally similar.
- Respect the concurrency model: UI state on `@MainActor` via `BudgetStore`; I/O and sync in `actor` services. Don't introduce ad-hoc `DispatchQueue`/`Task.detached` hops around it.
- No dead code: don't leave commented-out blocks, unused parameters, or "just in case" branches.
- Comments explain *why* (constraints, upstream parity, non-obvious invariants), not *what* the next line does.
- Keep changes scoped: don't reformat, rename, or refactor code unrelated to the task at hand.

## Testing

- Every behavior change needs test coverage. Unit tests use Swift Testing (`@Test` / `#expect`); UI tests (`ActualiUITests/`) use XCTest.
- `ActualiTests/` mirrors the app source tree: put a test in the folder matching where the primary type under test lives (e.g. tests for `Services/Sync/*` go in `ActualiTests/Services/Sync/`). Exceptions: `BudgetStore` tests get their own `Services/BudgetStore/`, and notification tests live in `Services/Notifications/` even though those sources sit loose in `Services/`.
- Run the unit test suite locally before opening a PR. CI runs it on every PR that touches `Actuali/**` and the check is required.
- The sync fixture tests (`SyncEngineFixtureTests.swift` and friends) verify CRDT behavior against fixtures derived from upstream Actual Budget. They must keep passing — never regenerate fixtures or loosen assertions to make a failure go away; a failure there usually means the change breaks sync compatibility.
- Never weaken, skip, or delete an existing test to get a green build. If a test genuinely no longer describes desired behavior, say so explicitly in the PR.
- Test behavior through the public surface (e.g. `BudgetStore` / `BudgetDatabase` APIs) rather than reaching into internals.

## Pull Requests

- One concern per PR; keep diffs focused and reviewable.
- Brief, casual PR titles and descriptions — say what changed and why, skip boilerplate sections.
- Build and tests must pass before opening the PR, and say in the PR what you ran.
- **Never bump version or build numbers** (`CURRENT_PROJECT_VERSION`, `MARKETING_VERSION`) — releases handle both.

## Local Overrides

Machine- or person-specific instructions belong in `CLAUDE.local.md` (gitignored), not in this file.
