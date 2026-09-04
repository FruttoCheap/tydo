# Tydo System Overview

> Implementation status (2026-09-03): the Raycast plan is implemented in
> `raycast/`, and CLI 1.1.0 now includes the explicit versioned store, coarse
> locking, coded errors, atomic stdin configuration, data fixes, bounds,
> unassign, and black-box tests. The detailed audit below describes the
> pre-1.1.0 baseline and is retained as historical rationale.

The agreed Raycast architecture, scope, prerequisites, and delivery sequence are
defined in [`raycast-implementation-plan.md`](raycast-implementation-plan.md).

Audited against the source and local builds on 2026-09-03. This is the handoff
document for app, CLI, agent-skill, and Raycast work.

## Product Model

Tydo is a macOS 14 task manager with AI-assisted cleanup, enrichment, grouping,
document extraction, and planning.

The CLI is the source of truth. The macOS app is a subprocess client:

```text
macOS UI / future skill / future Raycast extension
                       |
                       v
                tydo CLI (JSON)
                       |
          +------------+-------------+
          |                          |
          v                          v
   SwiftData store          OpenAI-compatible APIs
                                  |
                       chat + embeddings + reasoning
```

- `Package.swift` builds the `tydo` executable from `tydo/`, excluding only
  the app and UI directories.
- The Xcode app target compiles the UI directories and embeds the SwiftPM
  executable at `Tydo.app/Contents/Helpers/tydo`.
- App code does not access SwiftData or AI services directly. Every active data
  operation goes through `TydoCLIClient`.
- The app locates the CLI from an injected URL, `TYDO_CLI_PATH`, or the bundled
  helper path, in that order.

Primary implementation files:

| Concern | Source |
|---|---|
| CLI protocol and commands | `tydo/CLI/TydoCLI.swift` |
| Persistent models and store | `tydo/Models/Models.swift` |
| CRUD and cleanup behavior | `tydo/Services/TodoRepository.swift` |
| Main AI pipeline | `tydo/Services/PipelineService.swift` |
| AI grouping | `tydo/Services/OrganizerService.swift` |
| Planning | `tydo/Services/MastermindService.swift` |
| Document extraction | `tydo/Services/DocumentImportService.swift` |
| Provider transport | `tydo/Services/LLMService.swift` |
| Settings and secrets | `tydo/Services/SettingsStore.swift` |
| App subprocess adapter | `tydo/App/TydoCLIClient.swift` |
| App lifecycle | `tydo/App/AppDelegate.swift` |
| Window coordination | `tydo/App/WindowManager.swift` |

## CLI Contract

The current CLI version is `1.2.0`; the protocol version is `1`.

Successful machine commands print one JSON value to stdout:

```json
{
  "version": 1,
  "data": {}
}
```

Failures print JSON to stderr and exit `1`:

```json
{
  "version": 1,
  "error": "Localized error text"
}
```

Dates are ISO 8601 and UUIDs are strings. Output is pretty-printed and keys are
sorted. There are no stable machine-readable error codes.

Exceptions to the JSON contract:

- No arguments, `help`, `--help`, and `-h` print plain text and exit `0`.
- `version` ignores trailing arguments.
- If response encoding itself fails, the CLI can emit no output without
  changing the exit status.

### Commands

| Command | Input | Result |
|---|---|---|
| `tydo version` | none | CLI and protocol versions |
| `tydo snapshot` | none | todos, groups, clarifications |
| `tydo todo add <text> [--process]` | text tokens | created todo |
| `tydo todo add-many [JSON] [--process]` | JSON array argument or stdin | created todos |
| `tydo todo list [all\|active\|completed] [group-id]` | optional filters | todos |
| `tydo todo show <id>` | todo UUID | todo |
| `tydo todo rename <id> <title>` | UUID and title | todo |
| `tydo todo complete <id>` | todo UUID | todo |
| `tydo todo reopen <id>` | todo UUID | todo |
| `tydo todo move <todo-id> <group-id>` | two UUIDs | todo |
| `tydo todo delete <id> --yes` | UUID and confirmation | deletion receipt |
| `tydo group list` | none | groups |
| `tydo group create <name>` | name | group |
| `tydo group rename <id> <name>` | UUID and name | group |
| `tydo group delete <id> --yes` | UUID and confirmation | deletion receipt |
| `tydo clarification list` | none | clarifications |
| `tydo clarification mark-presented <id>` | clarification UUID | clarification |
| `tydo clarification resolve <id> <group-name>` | UUID and name | resolution receipt |
| `tydo document extract <path>` | local file path | extracted action strings |
| `tydo process` | none | updated snapshot |
| `tydo mastermind analyze [group-id]` | optional group UUID | summary and proposals |
| `tydo mastermind accept [JSON]` | proposal argument or stdin | created todo |
| `tydo config get` | none | non-secret configuration |
| `tydo config set <key> <value>` | key and value | updated configuration |
| `tydo doctor` | none | per-slot provider and store diagnostics |
| `tydo maintenance` | none | updated snapshot |

`todo add-many` and `mastermind accept` are the only commands that read JSON
from stdin. There is no standard option parser or `--` terminator. In add
commands, every exact `--process` token is treated as an option and removed
from content.

### Output Types

Todo:

```text
id, rawText, title, body?, status, stage, createdAt, completedAt?,
groupID?, groupName?
```

- `status`: `active` or `completed`
- `stage`: `raw`, `grammar`, `enriched`, or `grouped`

Group:

```text
id, name, isGeneral, createdByAI, createdAt, activeCount, completedCount
```

Clarification:

```text
id, todoID, todoTitle, optionGroupNames, createdAt, wasPresented
```

Snapshot:

```text
todos, groups, clarifications
```

The snapshot omits embeddings and event history. Todos are newest first,
groups are name-sorted, and clarifications are oldest first.

Mastermind analysis:

```text
summary, proposals[]
proposal: id, title, body?, rationale, group
```

`mastermind accept` requires the complete proposal shape, including `id`, but
creates a new todo UUID and does not verify that the proposal came from an
earlier analysis.

### Integration Rules

External clients must currently assume all of the following:

1. Parse help as text, not JSON.
2. Check exit status before decoding stdout.
3. Treat a failed mutation as potentially partially committed.
4. Never blindly retry `todo add --process` or `todo add-many --process`;
   processing failure occurs after insertion and can duplicate tasks.
5. Prefer stdin for bulk JSON and mastermind proposals.
6. Serialize mutations in the client where practical; ordinary writes are not
   covered by the global processing lock.
7. Set `TYDO_DATA_DIR` for isolated development and automated testing.
8. Expect AI-backed commands to wait indefinitely; no timeout or cancellation
   contract exists.
9. Do not infer that an empty document or mastermind result means valid model
   output; malformed model output is often converted to an empty success.
10. Refresh with `snapshot` after changes made through another interface. The
    app does not observe external store changes.

`tydo doctor` covers health. The CLI still has no capability-discovery, schema, processing-status, export,
event-history, idempotency, or unassign command.

## Persistence

The SwiftData schema contains:

- `Todo`: task content, status, processing stage, embedding, optional group.
- `TodoGroup`: name, General/AI flags, and todo relationship.
- `TodoEvent`: denormalized task history retained independently of tasks.
- `ClarificationQuestion`: denormalized pending group choice.

Only UUID uniqueness is schema-enforced. Group names are not unique and the
single-General invariant is maintained in application code.

When `TYDO_DATA_DIR` is set, the store is:

```text
$TYDO_DATA_DIR/default.store
```

and lock files are:

```text
$TYDO_DATA_DIR/tydo-process.lock
$TYDO_DATA_DIR/tydo-store.lock
```

Without it, SwiftData chooses its default store location while locks use the
application-support directory. The production store location is not explicitly
documented or versioned in code, and there is no `VersionedSchema` or migration
plan.

`tydo-process.lock` serializes `process` and `maintenance`. The store lock only
protects creation of the General group. CRUD commands and snapshots do not hold
one transaction-wide interprocess lock.

### Lifecycle Semantics

- Adding a todo creates a `created` event.
- Completing, reopening, renaming, AI enrichment/grouping, and deletion create
  selected events; manual moves do not.
- Deleting a todo leaves its denormalized event history behind.
- Deleting a group moves its todos to General.
- Completing the last active todo in a non-General group prunes that group and
  moves its todos to General. This was confirmed by an isolated CLI smoke test.
- Reopening such a todo therefore reopens it in General, not its former group.
- Clarifications have no relationship cleanup and can outlive deleted todos.

## Configuration

Non-secret settings use the `it.clait.tydo` UserDefaults suite.

There are three independent provider slots — `chat`, `embedding`, `reasoning` —
each with its own base URL, model and Keychain key.

| CLI key | Stored setting | Default |
|---|---|---|
| `base-url` | chat base URL | `http://localhost:11434/v1` |
| `chat-model` | chat model | `llama3.2` |
| `embedding-model` | embedding model | `nomic-embed-text` |
| `embedding-base-url` | embedding base URL | `""`, meaning "same server as chat" |
| `reasoning-base-url` | reasoning base URL | chat URL |
| `reasoning-chat-model` | reasoning model | chat model |
| `retention-days` | cleanup age | `30` |

Keys are stored in Keychain under service `it.clait.tydo.reasoning` — the name
is historical, it now holds all three — with accounts `chat.apiKey`,
`embedding.apiKey` and `reasoning.apiKey`. Each falls back to the literal
`ollama`, which local servers ignore.

The slot split exists because OpenRouter and Groq serve chat but expose no
`/embeddings` endpoint at all. It also allows the useful default of a hosted
chat model with embeddings still on localhost.

Current constraints:

- API keys are writable only through `config update` on stdin. `config set`
  rejects `chat-api-key`, `embedding-api-key` and `reasoning-api-key`, because
  arguments are visible in `ps` and land in shell history.
- `config update` validates URLs and the 1...365 retention range; `config set`
  does not. Invalid URLs stored through `set` silently fall back to the local
  default when used.
- Changing the embedding model changes the vector width, which makes
  `cosineSimilarity` return 0 against every stored embedding and drops all
  grouping into General. `tydo doctor` is the only thing that reports it.

## AI Workflows

All network calls use an OpenAI-compatible API:

```text
POST <baseURL>/chat/completions
POST <baseURL>/embeddings
Authorization: Bearer <apiKey>
```

There are no explicit timeouts, retries, backoff, token limits, response-size
limits, streaming, or structured-output schemas. Non-2xx response bodies are
included verbatim in errors.

### Processing Pipeline

`tydo process` runs the pipeline and then the organizer under the processing
lock. Each successful substage is saved, so later invocations resume partial
work.

```text
raw
  -> grammar cleanup
grammar
  -> title/body enrichment using up to 40 active peer todos
enriched
  -> embedding
  -> organizer decision
grouped
```

The grammar prompt preserves language and rejects implausibly long output. The
enrichment parser extracts the outermost JSON object; malformed output silently
keeps the existing title and empty body.

Pending selection does not filter completed todos, so a task completed before
processing can still consume AI calls and be grouped.

### Organizer

The organizer processes ungrouped, embedded todos at the `enriched` stage:

1. Compute up to three group candidates from embedding centroids.
2. Find up to five nearby active todos currently in General.
3. Ask the chat model to assign, create, or use General.
4. Persist the group decision and mark the todo `grouped`.

Malformed decisions silently choose General. Name matching is exact and
case-sensitive despite duplicate names being allowed.

When two or more strong candidates are close, the organizer leaves the todo
ungrouped and creates a clarification. Resolving it uses a group name, not an
ID; stale or unknown names silently resolve to General.

### Document Extraction

Supported app picker formats are PDF, plain text, Markdown, Word, RTF/RTFD, and
HTML. The CLI attempts any supplied path.

Documents are read natively, split into 8,000-character chunks with 400
characters of overlap, sent sequentially to the chat model, then deduplicated
case-insensitively. Extraction returns strings only; the app presents a review
sheet and calls `todo add-many` after confirmation.

Malformed per-chunk model output becomes an empty list. There is no document or
input size limit. Multi-file app import aborts the whole batch on one error and
does not deduplicate across files.

### Mastermind

`mastermind analyze` uses the reasoning provider for planning and the primary
provider for embeddings. It returns a summary and 2-5 proposed next actions.

- Group analysis includes active tasks, up to 20 completed tasks, up to 100
  relevant events, and an overview of other groups.
- Whole-list analysis currently derives tasks by flattening groups, so
  ungrouped tasks are omitted.
- Missing groups and malformed model output return successful empty results.
- Accepting a proposal immediately creates a `grouped` todo and best-effort
  embedding. Failed embedding is suppressed and is never retried by the normal
  pipeline because the task is already grouped.

## Maintenance

Maintenance runs immediately at app launch and every six hours. It deletes
**completed** todos whose `completedAt` is older than `retentionDays`, then
prunes groups with no active todos. Active todos are never deleted by age.

There is no confirmation, trash, undo, backup, or export. Event records can
still retain deleted task titles, and clarifications are not cleaned up.

## macOS App

Tydo is an accessory/menu-bar app (`LSUIElement`) with no dock icon and these
default global shortcuts:

| Action | Shortcut |
|---|---|
| Capture | Option-Space |
| List | Option-L |
| Options | Option-O |

All are user-configurable with KeyboardShortcuts, the project's only direct
third-party dependency.

### Launch

At launch the app:

1. Registers as a macOS Services provider.
2. Starts `tydo process` in the background.
3. Runs `tydo maintenance`, then repeats it every six hours.
4. Registers global shortcut handlers.

Background failures are printed to stderr but not shown in the UI.

### Capture

- Single-line text capture adds a todo, closes, then starts processing.
- Shift-Enter/multiline content is routed through document extraction using a
  temporary text file, although the field is visually limited to one line.
- Files can be selected in the capture panel or sent through the macOS “Send to
  Tydo” service.
- Extracted actions are selected by default in a review sheet before bulk add.

### List

The floating list has two persisted modes:

- Carousel: groups, keyboard rotation, selection, complete, rename.
- Classic: active-only searchable list, complete, rename.

Neither mode supports reopen, move, delete, body/details, or completed-item
browsing. The app-only “active group” preference is not part of the CLI model.

### Options

Tabs expose:

- Todos: filter, complete/reopen, rename, move, delete.
- Groups: create, rename, delete, plan group, plan everything.
- Settings: clarifications, shortcuts, provider settings, retention.

Known mismatches:

- “Unassigned” appears in the move picker but cannot perform an operation.
- Todo/group delete supplies `--yes` without a GUI confirmation.
- General cannot be renamed in the app, but the CLI currently permits it.
- Settings save is seven sequential CLI calls and can partially succeed.
- The persistent Options window may show stale data when reopened.
- Todo bodies, timestamps, AI-created group status, and detailed stage are
  decoded but not displayed.

### Clarifications and Mastermind

- One unpresented clarification is shown after processing, marked presented
  before display, and closed after 60 seconds. Unresolved questions remain in
  Settings.
- Mastermind analysis is guarded against duplicate starts, but proposal Accept
  is not guarded; rapid clicks can create duplicates.
- Dismissing a proposal only hides it in the current sheet.

### App State

`TydoCLIClient` owns one in-memory snapshot. Mutations normally run one CLI
command and then a second `snapshot` command. Processing and maintenance return
snapshots directly.

There is no store observation, notification, activation refresh, or polling.
Changes from Raycast, an agent, or a terminal remain invisible until an app
action happens to refresh the snapshot.

Subprocess execution has no timeout and task cancellation does not terminate
the child. Temporary files are used for stdout/stderr to avoid pipe-buffer
deadlocks.

## Confirmed Defects and Risks

### Blockers Before External Clients

1. **Destructive retention:** active tasks are silently deleted by age.
2. **Secret exposure:** reasoning keys travel through argv.
3. **Unsafe retries:** add-with-process can insert successfully and exit with a
   processing error; retrying duplicates data.
4. **Incomplete locking:** concurrent app, Raycast, terminal, and agent writes
   can interleave.
5. **No stable install path:** the app has a private bundled helper, but no
   installer or documented public CLI location exists.
6. **No tested protocol specification:** behavior exists in code but has no
   JSON schema, stable error codes, contract tests, or compatibility policy.
7. **No timeout contract:** providers and child processes can hang clients
   indefinitely.

### Data and Workflow Defects

1. Manual `todo move` does not set the todo stage to `grouped`. A manually
   moved raw todo can later remain permanently `enriched`, causing the app to
   show it as still processing.
2. Whole-list Mastermind omits ungrouped todos.
3. Completed todos continue through pipeline and organizer work.
4. Deleted todos can leave orphan clarification records.
5. Embeddings have no model/version/dimension metadata. Changing models leaves
   incompatible vectors, and centroid calculation mishandles mixed dimensions.
6. A failed Mastermind acceptance embedding is suppressed and never retried.
7. Duplicate group names are allowed although several workflows use names as
   identifiers.
8. Clarification options become stale after group rename/delete and unknown
   choices silently fall back to General.
9. Core repository fetch/save failures are frequently suppressed with `try?`.
10. Snapshots perform independent fetches and are not atomic.

### Distribution and Privacy Gaps

- No signing/notarization/release/install/update workflow or universal-helper
  verification exists.
- No README, license, third-party notices, privacy policy, security policy,
  backup/export guide, or troubleshooting guide exists besides this overview.
- There are no project-owned tests, test target, CI checks, or migration tests.
- User task text, history, and document contents can be sent to arbitrary
  configured endpoints without an in-product disclosure.
- The app is not sandboxed. Sandboxing later will require a deliberate design
  for CLI access to security-scoped document URLs.

## External Interface Readiness

Do not implement two independent domain layers. Both future integrations should
remain thin CLI clients.

### Minimum Work Before Skill and Raycast Development

1. Decide and fix retention semantics. Completed-only cleanup is the least
   surprising default; export/backup is needed before any automatic permanent
   deletion.
2. Move secrets to stdin or a CLI-owned interactive/Keychain command.
3. Fix manual-move stage, ungrouped Mastermind coverage, completed-task AI
   processing, orphan clarifications, and failed-embedding retry.
4. Put every mutation under one interprocess store lock or otherwise establish
   a tested SwiftData multi-process transaction contract.
5. Define one public CLI install/discovery path.
6. Freeze protocol v1 with stable error codes and focused black-box tests for
   every command, partial failures, concurrency, and protocol decoding.
7. Add command timeouts/cancellation and an idempotency mechanism for creation
   before agents can safely retry.
8. Add app refresh on activation or a lightweight store-change notification so
   external writes appear promptly.

After those decisions, a skill and Raycast extension need only invoke the CLI,
decode the versioned envelope, display errors, and refresh snapshots. They do
not need Swift models, direct database access, LLM code, or a shared library.

## Verification Status

Verified locally on 2026-09-03:

- `swift build`: passed.
- `xcodebuild -project tydo.xcodeproj -scheme tydo -configuration Debug build
  CODE_SIGNING_ALLOWED=NO`: passed.
- Isolated CLI smoke test with `TYDO_DATA_DIR`: version, snapshot, add, group
  create, move, complete, reopen, filtered list, and final snapshot passed.
- The smoke test confirmed that completing the only active todo prunes its
  non-General group and relocates the todo to General.

Not verified:

- AI-backed commands, because they require a live configured provider.
- Production signing, notarization, installation, upgrades, or clean-machine
  launch.
- Automated tests, because the project has no test target or test files.
