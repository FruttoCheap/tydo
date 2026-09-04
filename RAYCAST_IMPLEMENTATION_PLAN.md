# Tydo Raycast Implementation Plan

This plan starts from `SYSTEM_OVERVIEW.md` and targets domain parity with the
macOS UI through a Store-ready Raycast extension. Raycast remains a thin client
of the `tydo` JSON CLI. It does not access SwiftData, UserDefaults, Keychain, or
AI providers directly.

## Decisions

- Ship the standalone CLI through a dedicated Homebrew tap.
- Make the extension usable without the Tydo macOS app.
- Start with a new explicit data store; do not migrate the existing implicit
  SwiftData store.
- Keep Tydo configuration canonical in the CLI, including its Keychain secret.
- Put the extension in this repository and prepare it for the Raycast Store.
- License the whole repository under MIT.
- Expose four user-facing commands plus one scheduled no-view command.
- Run AI processing after capture/import as a separate background step.
- Confirm destructive actions.
- Poll for new grouping clarifications every 10 minutes, show a HUD once, and
  keep the pending count in the checker command subtitle.
- Add a real unassign operation that returns a todo to AI grouping.

Publishing placeholders that must be resolved before release:

- Raycast author: `<raycast-username>`
- GitHub and Homebrew tap owner: `<github-owner>`

## Scope

### Included

- Capture one todo and process it.
- Browse, search, filter, inspect, complete, reopen, rename, move, unassign, and
  delete todos.
- Display active, completed, grouped, and still-processing todos.
- Create, rename, delete, and inspect groups.
- Resolve grouping clarifications.
- Extract actions from supported documents, review the results, bulk-add the
  selected actions, and process them.
- Run Mastermind for one group or the whole list, inspect proposals, accept a
  proposal once, and dismiss it locally.
- Read and atomically update provider, model, API-key, and retention settings.
- Manually run maintenance after confirmation.
- Surface newly created grouping clarifications through a background HUD and
  command subtitle.

### Deliberately Not Replicated

- Floating-panel placement, click-away behavior, Spaces behavior, and custom
  window geometry. Raycast owns its window.
- Tydo's app-level global shortcuts. Users assign Raycast command hotkeys.
- The macOS "Send to Tydo" Service. `Import Document` is the Raycast entry point.
- Carousel rendering and app-only active-group/list-style preferences. Raycast's
  searchable list replaces both Carousel and Classic presentation.
- The timed clarification popup. Raycast shows a background HUD and pending
  command subtitle instead.
- Automatic maintenance scheduling. The app may keep its schedule; Raycast only
  exposes a confirmed manual action.
- Editing todo body, raw text, stage, or timestamps; the current UI does not edit
  them.
- Export, event-history browsing, backup UI, and live processing progress; none
  exists in the current UI contract.

## Target Architecture

```text
Raycast commands (TypeScript/React)
              |
              v
       src/lib/tydo.ts
   spawn tydo, JSON stdin/stdout
              |
              v
  Homebrew-installed Swift CLI
       /opt/homebrew/bin/tydo
       or /usr/local/bin/tydo
              |
       +------+------+
       |             |
       v             v
 explicit store   providers/Keychain
```

Use one CLI adapter and one TypeScript types file. Do not create repositories,
service interfaces, dependency injection, generated clients, or a second domain
model.

## Phase 1: Stabilize the CLI

This phase is a release gate. The extension must not compensate for these
defects independently.

### 1.1 Explicit Store and Lock Location

Change `makeTydoModelContainer()` so normal app and CLI invocations use:

```text
~/Library/Application Support/Tydo/default.store
```

Keep `TYDO_DATA_DIR` as the test/development override. Put both lock files beside
the selected store. The new location intentionally starts empty; do not add
legacy-store detection or migration. Establish this public store as a versioned
SwiftData schema before release so later schema changes have a migration path.

Acceptance:

- Homebrew CLI and bundled app helper see the same todos.
- Two invocations with the same `TYDO_DATA_DIR` see the same isolated store.
- Locks and store always share a directory.
- The initial public schema has an explicit version.

### 1.2 Command-Wide Interprocess Lock

Use one coarse lock for every store command. Mutations take an exclusive lock;
snapshot/list/show commands take a shared lock if the existing lock primitive
supports it, otherwise all commands take the same exclusive lock initially.
Lock acquisition has a bounded deadline and returns `busy` on timeout.

Do not design record-level or per-command locking. The coarse lock is sufficient
until measured contention proves otherwise.

Acceptance:

- Concurrent CLI mutation smoke tests do not lose writes or corrupt snapshots.
- A contended command fails within the documented deadline.
- Snapshot's todos, groups, and clarifications are read under one lock.

### 1.3 Stable Error Envelope

Extend protocol v1 failures without changing the successful envelope:

```json
{
  "version": 1,
  "code": "invalid_request",
  "error": "Localized explanation"
}
```

Required codes:

- `invalid_request`
- `not_found`
- `conflict`
- `busy`
- `timeout`
- `internal`

Also reject trailing arguments to `version` and make response-encoding failure
exit nonzero with an error envelope when possible.

Acceptance:

- Raycast branches only on `code`, never localized text.
- Every nonzero tested command returns a decodable error envelope.
- Unknown protocol versions fail before data decoding.

### 1.4 Safe Atomic Configuration

Replace Raycast's need for sequential `config set` calls with:

```text
tydo config update
```

The command reads one JSON object from stdin, validates every supplied value,
then applies the update. Supported fields match `ConfigOutput`; an omitted API
key leaves it unchanged, a non-empty key replaces it, and an explicit `null`
clears it. Keychain operations must throw on OSStatus failure. Secrets never
appear in argv or command output.

The existing `config get` remains. Existing single-key `config set` may remain
for shell compatibility but the app and Raycast must stop using it for secrets.

Acceptance:

- Invalid input changes no setting.
- Keychain failure returns `internal` and is not reported as success.
- Process inspection cannot reveal the submitted key.
- `config get` reports only whether a non-default key is configured.

### 1.5 Required Data Fixes

Make the following changes at the shared repository/service layer:

- Maintenance deletes only completed todos, using `completedAt` and
  `retentionDays`; it never deletes active todos.
- Manual move sets stage to `grouped` and records a grouped event.
- Pipeline and organizer skip completed todos.
- Todo deletion removes matching clarifications in the same locked operation.
- Whole-list Mastermind fetches todos directly so ungrouped todos are included.
- Group create/rename rejects case-insensitive duplicate names.
- General cannot be renamed or deleted.
- Clarification resolution rejects stale/unknown choices instead of silently
  falling back to General.
- Failed Mastermind acceptance embedding leaves the todo eligible for embedding
  retry instead of permanently marking unusable state.
- Mastermind proposal acceptance is idempotent by proposal UUID under the store
  lock and returns the originally created todo on repetition.

Acceptance: one black-box regression check per item through the CLI.

### 1.6 Unassign Command

Add:

```text
tydo todo unassign <todo-id>
```

The repository operation clears the group and any stale clarification for the
todo. If an embedding exists, set stage to `enriched`; otherwise set the latest
valid earlier stage represented by the stored fields. Record an edited/grouping
event only if an existing event type accurately describes the operation; do not
add an event type solely for Raycast. A later `process` performs grouping again.

Acceptance:

- Unassigning a grouped todo makes it appear as processing/ungrouped.
- The next process can group it again or create one clarification.
- Repeated unassign is harmless and does not duplicate clarifications.

### 1.7 Time and Input Bounds

- Set explicit connect/request/resource timeouts for provider calls.
- Limit document byte size or maximum chunks before sending provider requests.
- Document the CLI's whole-command expectations for clients.
- Treat `process` failures as potentially partial progress.

The Raycast adapter also enforces a child-process deadline, terminates the child
on timeout/cancellation, waits for exit, and never automatically retries a
mutation.

### 1.8 Focused Black-Box Tests

Add one Swift test target that invokes the built CLI with isolated
`TYDO_DATA_DIR`. Cover only the public contract consumed by the app/Raycast:

- version and protocol mismatch handling
- snapshot
- todo CRUD, move, unassign, and add-many via stdin
- group CRUD and protected General behavior
- clarification listing, presentation, and resolution
- config get/update, including key clear without logging the key
- document extraction argument/input validation without requiring a live model
- process/maintenance locking and completed-only cleanup
- Mastermind argument/proposal decoding and duplicate acceptance guard
- concurrent writes and bounded lock timeout
- stdout/stderr envelopes and exit status

Provider-backed happy paths can use a tiny local HTTP stub. Do not introduce a
general mocking framework.

## Phase 2: Publish the Standalone CLI

### 2.1 Release Artifact

Produce a signed/notarized universal macOS executable from the same Swift source
as the app helper. A release includes:

- `tydo` archive
- SHA-256 checksum
- source tag matching the CLI version
- release notes calling out protocol or store-schema requirements

Keep CLI and protocol versions separate. Raycast requires protocol `1` and may
require a minimum CLI version once new commands land.

### 2.2 Homebrew Tap

Create `<github-owner>/homebrew-tap` with a `tydo` formula that downloads the
immutable tagged release, verifies SHA-256, installs `bin/tydo`, and has a
`version` test.

Document:

```sh
brew install <github-owner>/tap/tydo
```

Do not make the extension run Homebrew automatically. On a missing/incompatible
CLI, show install/upgrade instructions and provide a copy action.

### 2.3 App Alignment

Keep the app's bundled helper for app distribution, but build it from the same
source and make it use the explicit store. Update the app client to use atomic
`config update` and refresh the Options snapshot whenever the retained Options
window is shown.

The app and Homebrew binary may coexist because protocol and store locking are
defined. Do not make the app depend on Homebrew.

## Phase 3: Raycast Extension Skeleton

Create `raycast/` with the standard current Raycast TypeScript template and npm
lockfile. Use only:

- `@raycast/api`
- `@raycast/utils` when its existing hooks remove code
- Node standard library (`child_process`, `fs`, `path`)

Do not add an HTTP client, state manager, schema validator, subprocess package,
date library, or test framework unless a concrete failure cannot be covered by
the platform and standard library.

Minimum layout:

```text
raycast/
  assets/icon.png
  src/capture-todo.tsx
  src/browse-todos.tsx
  src/import-document.tsx
  src/manage-tydo.tsx
  src/check-grouping-questions.ts
  src/lib/tydo.ts
  src/lib/types.ts
  package.json
  package-lock.json
  README.md
  CHANGELOG.md
```

Do not create one file per action or model. Split a command only after it becomes
materially hard to read.

### CLI Discovery

On first call, search in this order:

1. Optional extension preference override for development.
2. `/opt/homebrew/bin/tydo`.
3. `/usr/local/bin/tydo`.
4. `tydo` resolved from the child process environment.

Run `tydo version`, require protocol `1` and the documented minimum CLI version,
and cache only for the lifetime of the command. Spawn directly with argument
arrays and `shell: false`.

### CLI Adapter Contract

`src/lib/tydo.ts` owns:

- executable discovery/version check
- JSON stdin encoding
- stdout success-envelope decoding
- stderr error-envelope decoding
- per-command deadline and child termination
- mapping CLI errors to concise Raycast errors

It does not cache snapshots, retry mutations, know UI state, or duplicate domain
rules.

Mutation policy:

- Never retry `add`, `add-many`, `accept`, or any other mutation automatically.
- On `process` failure, report partial progress and let the next view fetch a new
  snapshot.
- Serialize mutations within one command invocation; rely on the CLI lock across
  processes.

## Phase 4: Commands

### 4.1 Capture Todo

Manifest mode: `view`.

Use one draft-enabled form with a required text area. Submission behavior:

1. Trim input.
2. If it contains no newline, call `todo add`.
3. If it contains newlines, call document extraction through a temporary UTF-8
   file and push the same review screen used by `Import Document`.
4. After successful persistence, close the form/show success immediately.
5. Start `process` separately and surface completion/failure through a HUD or
   toast. Never retry the creation if processing fails.

This preserves capture semantics without copying the custom floating panel.

Acceptance:

- Empty input cannot submit.
- A successful add remains successful if processing later fails.
- Multiline input is reviewed before any todos are created.

### 4.2 Browse Todos

Manifest mode: `view`.

Use one `List` loaded from `snapshot`:

- search by title, raw text, body, and group name
- dropdown filter: Active, Completed, All
- sections by group, with `Processing` for nil group
- newest-first rows
- accessories for status, group, and processing stage
- detail view for title, body, original text when different, group, status,
  stage, creation date, and completion date

Actions:

- complete or reopen
- rename through a pushed form
- move through a group submenu
- unassign and then start processing separately
- delete after `confirmAlert`
- refresh snapshot
- run Mastermind for the selected group or everything

After a mutation, fetch a fresh snapshot. Disable only the action currently in
flight; no optimistic state layer.

### 4.3 Import Document

Manifest mode: `view`.

Use `Form.FilePicker` with the app-supported extensions: PDF, TXT, Markdown,
DOC/DOCX, RTF/RTFD, and HTML. Allow multiple files.

Flow:

1. Extract each selected file sequentially to avoid multiplying provider load.
2. Stop and show the first error, naming the file.
3. Deduplicate the combined strings case-insensitively.
4. Push one review form with all actions selected by default.
5. Add checked actions through `todo add-many` JSON on stdin.
6. Start processing separately and report its eventual result.

Set the CLI document-size limit before starting extraction and explain empty
results as "No actionable items found."

### 4.4 Manage Tydo

Manifest mode: `view`.

Use one root `List` with sections, pushing native Raycast screens:

- Pending grouping questions, with candidate group actions.
- Groups, with create, rename, confirmed delete, and group planning.
- Plan Everything.
- Provider/settings form loaded from `config get` and saved once through
  `config update` on stdin.
- Confirmed Run Maintenance action.

Settings form fields:

- primary base URL
- primary chat model
- embedding model
- reasoning base URL
- reasoning chat model
- replacement API key plus an explicit clear-key checkbox/action
- completed-todo retention days, constrained to 1...365

The password field starts empty; never display or store the existing key in
Raycast preferences/local storage.

Mastermind screen:

- explicit Analyze action with one in-flight guard
- summary detail and 2-5 proposal rows
- title, optional body, rationale, and target group
- Accept disabled while that proposal is being accepted
- accepted proposal removed after success
- Dismiss removes it only from the current screen

The CLI should make acceptance by proposal UUID idempotent under the store lock;
the UI guard remains the immediate duplicate-click defense.

### 4.5 Check Grouping Questions

Manifest mode: `no-view`; interval: `10m`.

On each launch:

1. Verify the CLI and fetch `snapshot`.
2. Select unpresented clarifications oldest first.
3. Update the command subtitle with the total unresolved count.
4. Show one HUD summarizing newly created questions.
5. After the HUD succeeds, mark those questions presented sequentially.
6. Stop on mutation failure so unmarked questions are retried later.

When launched manually, show a HUD with the unresolved count. Do not show another
background HUD for presented but unresolved questions; they remain counted in
the subtitle and visible in `Manage Tydo`.

## Phase 5: Verification

### CLI Gate

- `swift test`
- `swift build -c release`
- existing Xcode app build with signing disabled
- isolated concurrent CLI smoke test
- universal binary architecture check
- clean-account test of store and Keychain behavior

### Raycast Gate

- `npm run lint`
- `npm run build`
- exercise every command against isolated test data
- test missing CLI, old CLI, malformed output, `busy`, provider timeout, and
  child termination
- verify add/process partial-failure messaging and no duplicate mutation retry
- verify all destructive actions require confirmation
- verify keyboard-only navigation and Raycast loading/empty/error states
- verify light/dark icon and required Store screenshots
- verify background clarification HUD, subtitle, and presented-state transition

### Parity Checklist

Release only when each included item in Scope has a manual acceptance result and
every visible macOS UI domain action maps either to a Raycast action or to an
explicit non-goal above.

## Phase 6: Store and Release

1. Add the root MIT `LICENSE` after owner approval.
2. Fill `<raycast-username>` and `<github-owner>`.
3. Publish signed CLI release and update the Homebrew formula/checksum.
4. Install from Homebrew on a clean Apple Silicon Mac and, if supported, Intel
   Mac.
5. Include setup, privacy, provider-data disclosure, CLI installation, and
   troubleshooting in `raycast/README.md`.
6. Add a 512x512 icon, at least three consistent screenshots, and changelog.
7. Confirm current Raycast Store guidelines immediately before submission.
8. Submit the extension with source-visible binary provenance and Homebrew
   dependency documentation.

## Release Gates

The extension implementation may start after Phase 1's CLI command shapes are
fixed, but Store submission is blocked until all are true:

- explicit shared store and coarse interprocess locking
- completed-only retention
- stable coded errors and black-box protocol tests
- safe atomic stdin configuration
- provider/document/child-process bounds
- unassign and corrected data workflows
- signed universal CLI release and working dedicated tap
- MIT license and resolved publisher identities
- Raycast lint/build and parity checklist pass

## Deferred Until Measured Need

- Generic capability discovery or generated JSON Schema.
- Generic idempotency keys for all creates; guarded human actions and no retries
  are enough initially. Mastermind acceptance alone needs persisted idempotency
  because its proposal already has an ID and duplicate clicks are confirmed.
- Fine-grained locks or a daemon. Use the coarse CLI lock until contention is
  observed.
- Store-change notifications. Each Raycast command reads a fresh snapshot; the
  app refreshes when its views open.
- A shared Swift/TypeScript library. JSON protocol tests are the boundary.
- Automatic CLI installation from Raycast. Homebrew plus actionable onboarding
  is smaller and easier to audit.
- Legacy store migration, by explicit product decision.
