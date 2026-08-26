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
# List what's available with: xcrun simctl list devices available | grep iPhone

# Regenerate protobuf (only if sync.proto changes — never hand-edit Generated/)
protoc --swift_out=Actuali/Actuali/Generated/ Actuali/Actuali/Resources/sync.proto
```

Requirements: Xcode with the iOS 26.1+ SDK. Swift Package Manager resolves dependencies (GRDB, SwiftProtobuf, ZIPFoundation) on first build.

`IPHONEOS_DEPLOYMENT_TARGET` is 18.0, so the app ships to iOS 18 while still building against the iOS 26 SDK — the two are independent and both are needed. Code may use an iOS 26 API behind `@available` / `#available` (`.prominent` in `AddTransactionView`, `FoundationModels` in `TransactionTextParser`), which is why the newer SDK stays a hard requirement. Adding an iOS 26 API without a gate is a compile error, so the build itself guards the floor.

What the compiler can't guard is anything the OS resolves at runtime, so CI runs the unit suite twice: once on the newest runtime and once on iOS 18. Two known traps live in that gap — SF Symbols added after SF Symbols 6 render blank rather than failing, and SQLite in iOS 18 predates 3.46.0, so a numeric separator inside a SQL string (`500_000`) throws `unrecognized token` at runtime. Plain Swift numeric literals are fine; only digits inside a SQL string matter.

### Notes for agents

- **Always pass an explicit timeout** on `xcodebuild` (600000 ms is safe). A full `xcodebuild test` exceeds the default 2-minute shell limit and will be killed mid-run, which looks like a build failure but isn't.
- **Reuse the existing simulator; don't `simctl create`/`delete` per run.** Resolve the UDID once from `xcrun simctl list devices available` and reuse it. Booting a fresh device costs more than the test run.
- **Narrow the test run.** `-only-testing:ActualiTests/SomeTests` for a single suite; `-skip-testing:ActualiUITests` is the CI-equivalent full run. Don't run UI tests to validate a unit-level change.
- **Pipe to a filter, don't read raw output.** `xcodebuild ... 2>&1 | grep -E 'error:|warning:|\*\* (TEST|BUILD) (SUCCEEDED|FAILED) \*\*'` — full xcodebuild output is tens of thousands of lines.
- CI is GitHub Actions. `gh pr checks` exits **8** when checks are still pending — that is a state, not a failure, so don't retry on it. To wait, use `gh pr checks <pr> --watch` rather than polling in a loop.

### Concurrency (Swift 6)

`SWIFT_VERSION = 6.0` on every target, with `SWIFT_STRICT_CONCURRENCY = complete` on the app target and the `SWIFT_UPCOMING_FEATURE_*` flags set at project level. New code is checked for data races: keep UI state on `@MainActor` and I/O in actors rather than reaching for `@unchecked Sendable`. The three existing escape hatches each carry a comment justifying them — add a new one only with the same.

Three rules cover most of what the compiler will stop you on:

- **GRDB `Row` is not `Sendable`, so it can't leave a `read`/`write` closure.** Map rows into a `Sendable` type *inside* the closure and let only that cross the boundary — a domain type where one exists (`BudgetDatabase.nearbyPayees`), otherwise a small local projection or tuple (see `BudgetDatabaseSplitTests.SplitRow`). Don't widen the closure's return to `Any`.
- **`BudgetDatabase` keeps a strict async/sync split.** Async methods use `try await dbQueue.read`; the synchronous write path uses `try dbQueue.read` and must not suspend (`fetchNote` vs `notesTableExists`). Keep the two apart: under `NONISOLATED_NONSENDING_BY_DEFAULT` a `nonisolated async` body runs on the *caller's* actor, so a blocking DB call in an async method can now block the main thread.
- **Pure static helpers on `View` types need `nonisolated`.** They otherwise inherit `@MainActor` from the conformance, which forces `@MainActor` onto every test that calls them (`MonthPicker.title`, `ReportsTabView.resolvePageId`, `RuleIdMultiPicker.toggling`). Mark the helper, don't annotate the test. If a helper needs main-actor state it isn't pure — move it onto the model instead, as `BudgetTransferContext.rankedCategories` does.

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

## Coding Standards (Ponytail / Lazy Senior Dev)

Operate in "lazy senior dev" mode: lazy means efficient, not careless. The best code is the code never written.

Before writing code, stop at the first rung that holds:
1. Does this need to be built at all? (YAGNI)
2. Does the standard library already do this? Use it.
3. Does a native platform feature cover it? Use it.
4. Does an already-installed dependency solve it? Use it.
5. Can this be one line? Make it one line.
6. Only then: write the minimum code that works.

Rules:
- Match the style, naming, and idioms of the surrounding code. Read neighboring files before writing new ones.
- Keep it simple (KISS): prefer the smallest change that solves the problem. No abstractions that weren't explicitly requested, no speculative feature flags or configuration for needs that don't exist yet.
- No boilerplate nobody asked for. Deletion over addition. Boring over clever. Fewest files possible.
- Don't repeat yourself (DRY): before writing a helper, search for an existing one — this codebase already has utilities for amounts, dates, and database access. But don't force abstractions to unify code that is only coincidentally similar.
- Question complex requests: "Do you actually need X, or does Y cover it?"
- Pick the edge-case-correct option when two stdlib approaches are the same size (lazy means less code, not the flimsier algorithm).
- Mark intentional simplifications with a `ponytail:` comment. If the shortcut has a known ceiling (e.g. global lock, O(n²) scan, naive heuristic), name the ceiling and the upgrade path in the comment.
- Respect the concurrency model: UI state on `@MainActor` via `BudgetStore`; I/O and sync in `actor` services. Don't introduce ad-hoc `DispatchQueue`/`Task.detached` hops around it.
- No dead code: don't leave commented-out blocks, unused parameters, or "just in case" branches.
- Comments explain *why* (constraints, upstream parity, non-obvious invariants), not *what* the next line does.
- Keep changes scoped: don't reformat, rename, or refactor code unrelated to the task at hand.

Not lazy about:
- Input validation at trust boundaries, error handling that prevents data loss, security, accessibility, or anything explicitly requested.
- Lazy code without its check is unfinished: every behavior change needs test coverage (Swift Testing `@Test` / `#expect`), as the Testing section states. Do not skip the test because the change is small.

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
