# tydo CLI reference

Verified against `tydo` 1.1.0 / protocol 1 (`tydo/CLI/TydoCLI.swift`) by running
every read command and every mutation against an isolated `TYDO_DATA_DIR` store.

- [Invocation and contract](#invocation-and-contract)
- [Commands](#commands)
- [Output shapes](#output-shapes)
- [Error codes](#error-codes)
- [Configuration](#configuration)
- [Environment](#environment)
- [Risk classification](#risk-classification)

## Invocation and contract

```
tydo <command> [subcommand] [args…]
```

| | |
|---|---|
| Success | `{"version":1,"data":…}` on stdout, exit `0` |
| Failure | `{"version":1,"code":"…","error":"…"}` on stderr, exit `1` |
| Help | `tydo`, `tydo help`, `--help`, `-h` → plain text, exit `0` |
| Encoding | pretty-printed, keys sorted, `/` unescaped, ISO-8601 dates |
| Absent values | key is **omitted**, never `null` |
| stdin | only `todo add-many`, `mastermind accept`, `config update` |
| Option parsing | hand-rolled; no `--` terminator; an argv element exactly equal to `--process` is stripped from any position (a quoted phrase containing it is kept verbatim) |
| Locking | one exclusive store lock per command, 2s acquisition deadline → `busy` |
| Provider timeouts | 30s per request, 120s per resource |

## Commands

### version / help

| Command | Args | Result | Notes |
|---|---|---|---|
| `tydo version` | none | `{cli, protocolVersion}` | `--version` is an alias. Trailing args → `invalid_request`. |
| `tydo help` | none | plain text | also `--help`, `-h`, or no arguments |

### snapshot

| Command | Args | Result |
|---|---|---|
| `tydo snapshot` | none | `{todos[], groups[], clarifications[]}` |

Todos newest-first, groups name-sorted (case-insensitive), clarifications
oldest-first. Omits embeddings and event history. The three fetches are not
atomic with one another.

### todo

| Command | Args | Result |
|---|---|---|
| `tydo todo add <text…> [--process]` | free text (joined with spaces), trimmed, must be non-empty | created todo |
| | `--process` alone → `invalid_request` (empty text) | |
| `tydo todo add-many '<json-array>' [--process]` | JSON array of strings as one argument, or on stdin | array of created todos |
| `tydo todo list [all\|active\|completed] [group-id]` | status defaults to `all`; group is a UUID | array of todos |
| `tydo todo show <todo-id>` | UUID | todo |
| `tydo todo rename <todo-id> <title…>` | UUID then free text | todo |
| `tydo todo complete <todo-id>` | UUID | todo |
| `tydo todo reopen <todo-id>` | UUID | todo |
| `tydo todo move <todo-id> <group-id>` | two UUIDs | todo |
| `tydo todo unassign <todo-id>` | UUID | todo |
| `tydo todo delete <todo-id> --yes` | UUID + literal `--yes` | `{id, action:"deleted"}` |

- `add-many` drops empty/whitespace-only entries; an all-empty array is
  `invalid_request`.
- `list` filters in memory; there is no search, no sort option, no pagination.
- `rename` sets `title` only. `rawText` is never overwritten, and the pipeline
  stage is not reset, so the AI will not re-overwrite a manual rename.
- `move` sets stage to `grouped` and then prunes empty groups.
- `unassign` clears the group and rewinds stage to `enriched` / `grammar` / `raw`
  depending on what the todo already has. It deletes that todo's clarifications.
  It does **not** prune, so it can leave an empty group behind.
- `complete` sets `completedAt` and prunes empty groups. `reopen` clears
  `completedAt` (the key disappears from the JSON).
- `delete` logs a `deleted` event, removes the todo's clarifications, then
  removes the todo. Permanent — no trash, no undo, no export.

### group

| Command | Args | Result |
|---|---|---|
| `tydo group list` | none | array of groups |
| `tydo group create <name…>` | free text, trimmed, non-empty | group |
| `tydo group rename <group-id> <name…>` | UUID then free text | group |
| `tydo group delete <group-id> --yes` | UUID + literal `--yes` | `{id, action:"deleted"}` |

- Group names are **not unique** — two groups may share a name, yet
  `clarification resolve` and `mastermind accept` identify groups by name.
- General cannot be renamed or deleted (`conflict`).
- `group delete` moves the group's todos to General; it never deletes todos.

### clarification

| Command | Args | Result |
|---|---|---|
| `tydo clarification list` | none | array of clarifications |
| `tydo clarification mark-presented <id>` | UUID | clarification |
| `tydo clarification resolve <id> <group-name…>` | UUID then a **group name** | `{id, action:"resolved"}` |

The chosen name must appear in that clarification's `optionGroupNames`
(case-insensitive) or the call is a `conflict`. Resolving assigns the todo,
marks it `grouped`, and deletes the question. Clarifications are not cleaned up
when their group is renamed or deleted, so options can go stale.

### document

| Command | Args | Result |
|---|---|---|
| `tydo document extract <path>` | exactly one path token (quote paths with spaces) | array of action-item strings |

Read-only — it never writes to the store. Supported extensions: `pdf`, `txt`,
`md`, `markdown`, `doc`, `docx`, `rtf`, `rtfd`, `html`, `htm`. Limits: 5 MiB,
64 chunks of 8000 chars with 400-char overlap. Results are deduplicated
case-insensitively across chunks. A chunk whose model reply cannot be parsed
contributes nothing — an empty array can mean "model output was unusable".

### process

| Command | Args | Result |
|---|---|---|
| `tydo process` | none | full snapshot after the run |

Runs the pipeline then the organizer under the processing lock. Each stage is
saved as it succeeds, so a rerun resumes. On failure the error is
`Processing partially completed: …` with code `timeout` or `internal` — some
todos may still have advanced.

### mastermind

| Command | Args | Result |
|---|---|---|
| `tydo mastermind analyze [group-id]` | optional UUID; omitted = whole list | `{summary, proposals[]}` |
| `tydo mastermind accept '<proposal-json>'` | one proposal object as an argument or on stdin | created todo |

- `analyze` never writes. A missing group or unparseable model output returns a
  successful result with an explanatory `summary` and empty `proposals`.
- `accept` requires the complete proposal object: `id`, `title`, `body`,
  `rationale`, `group`. It is **idempotent on `id`** — re-accepting returns the
  existing todo. It resolves `group` by case-insensitive name, creating the group
  (`createdByAI: true`) if absent, and marks the todo `grouped`. It does not
  verify the proposal came from a real analysis.

### config

| Command | Args | Result |
|---|---|---|
| `tydo config get` | none | config (no secret value) |
| `tydo config update` | one JSON object on stdin | config |
| `tydo config set <key> <value…>` | key + value | config |

`config update` is the preferred path: it validates, and it keeps secrets out of
argv. Accepted fields: `version` (must be `1` if present), `baseURL`,
`chatModel`, `embeddingModel`, `reasoningBaseURL`, `reasoningChatModel`,
`reasoningAPIKey` (string, or `null` to clear), `retentionDays` (integer 1–365).
Unknown fields are rejected. URLs must be absolute `http`/`https`.

`config set` keys: `base-url`, `chat-model`, `embedding-model`,
`reasoning-base-url`, `reasoning-chat-model`, `reasoning-api-key`,
`retention-days`. It does **not** validate URLs.

### maintenance

| Command | Args | Result |
|---|---|---|
| `tydo maintenance` | none | full snapshot after cleanup |

Permanently deletes **completed** todos whose `completedAt` is older than
`retentionDays`, logging a `deleted` event for each, then prunes groups with no
active todos. Active todos are not touched. Runs under the processing lock.

## Output shapes

**Todo** — `id`, `rawText`, `title`, `body?`, `status` (`active`|`completed`),
`stage` (`raw`|`grammar`|`enriched`|`grouped`), `createdAt`, `completedAt?`,
`groupID?`, `groupName?`

**Group** — `id`, `name`, `isGeneral`, `createdByAI`, `createdAt`,
`activeCount`, `completedCount`

**Clarification** — `id`, `todoID`, `todoTitle`, `optionGroupNames[]`,
`createdAt`, `wasPresented`

**Snapshot** — `todos[]`, `groups[]`, `clarifications[]`

**Config** — `baseURL`, `chatModel`, `embeddingModel`, `reasoningBaseURL`,
`reasoningChatModel`, `reasoningAPIKeyConfigured` (bool), `retentionDays`

**Mastermind result** — `summary`, `proposals[]` where a proposal is
`id`, `title`, `body?`, `rationale`, `group`

**Mutation receipt** — `id`, `action` (`deleted` | `resolved`)

## Error codes

| Code | Raised by |
|---|---|
| `invalid_request` | usage errors, non-UUID identifiers, bad status filter, missing `--yes`, JSON decode failures, config validation, unsupported document type |
| `not_found` | unknown todo / group / clarification UUID; missing file |
| `conflict` | General group rename/delete; stale or unknown clarification choice; missing clarification todo |
| `busy` | store lock not acquired within 2s, or processing lock unavailable |
| `timeout` | provider request exceeded 30s |
| `internal` | anything else (unreadable file, lock open failure, encode failure) |

`code` is stable; `error` is a localized human message and is not.

## Configuration

Non-secret settings live in the `it.clait.tydo` UserDefaults suite. The reasoning
API key lives in the keychain (service `it.clait.tydo.reasoning`, account
`reasoning.apiKey`). With `TYDO_DATA_DIR` set, both are namespaced per directory.

| Key | Default |
|---|---|
| `base-url` / `baseURL` | `http://localhost:11434/v1` |
| `chat-model` / `chatModel` | provider default (see `config get`) |
| `embedding-model` / `embeddingModel` | `nomic-embed-text` |
| `reasoning-base-url` / `reasoningBaseURL` | same as `baseURL` |
| `reasoning-chat-model` / `reasoningChatModel` | same as `chatModel` |
| `reasoning-api-key` / `reasoningAPIKey` | keychain, falls back to `ollama` |
| `retention-days` / `retentionDays` | `30` |

The primary provider always sends `Authorization: Bearer ollama`; only the
reasoning provider honours a real key. Calls are plain OpenAI-compatible
`POST <baseURL>/chat/completions` and `POST <baseURL>/embeddings`.

## Environment

| Variable | Effect |
|---|---|
| `TYDO_DATA_DIR` | Store, lock files, settings suite **and** keychain service all move under this directory. Two uses: isolating a throwaway store for testing, and pointing the CLI at a store the app owns at a different path. |
| `TYDO_CLI_PATH` | Read by the macOS **app** to locate the CLI, not by the CLI itself. Still a useful hint when discovering the binary. |

Default store: `~/Library/Application Support/Tydo/default.store`.
Lock files: `tydo-store.lock`, `tydo-process.lock` in the same directory.

### The store-path split

`makeTydoModelContainer()` builds
`applicationSupportDirectory/Tydo/default.store` from an explicit URL. An app
build made before that subdirectory was introduced let SwiftData pick its own
default, `applicationSupportDirectory/default.store`, and the existing store was
never migrated. On such a machine both files exist and hold different data:

```bash
ls -lt ~/Library/Application\ Support/default.store \
       ~/Library/Application\ Support/Tydo/default.store 2>/dev/null
```

The live one is whichever the running app keeps touching (newest mtime). Reading
the other returns a valid, empty snapshot — indistinguishable from a genuinely
empty list unless you check.

Because `TYDO_DATA_DIR` also swings the UserDefaults suite (to
`it.clait.tydo.test.<base64 of the path>`) and the keychain service, using it to
reach the app's store means `config get` reports **compiled-in defaults instead
of the user's real settings**, and AI-backed commands would call the wrong model
with no keychain key. Use the override for todo/group/clarification data only.

`makeTydoModelContainer()` is already the single source of the path, so the fix
is not a code change: quit the app, move `default.store` and its `-wal`/`-shm`
sidecars into `Tydo/`, then rebuild the app from current source (an older bundle
keeps resolving SwiftData's default location). Verify afterwards that launching
the app does **not** recreate a root `default.store`. Never move a live store
while the app is running, and not without asking.

## Risk classification

| Class | Commands |
|---|---|
| READ_ONLY | `version`, `help`, `snapshot`, `todo list`, `todo show`, `group list`, `clarification list`, `config get`, `document extract`, `mastermind analyze` |
| LOCAL_MUTATION | `todo add`, `todo add-many`, `todo rename`, `todo complete`, `todo reopen`, `todo move`, `todo unassign`, `group create`, `group rename`, `clarification mark-presented`, `clarification resolve`, `mastermind accept`, `config set`, `config update`, `process` |
| DESTRUCTIVE | `todo delete --yes` (permanent todo loss), `maintenance` (permanent loss of aged completed todos), `group delete --yes` (group lost; todos survive in General) |
| REMOTE_MUTATION | none — `tydo` writes nothing outside this Mac |

`document extract`, `process`, `mastermind analyze`/`accept` and any
`--process` capture send task text or document contents to the configured
provider endpoint. With the default local Ollama that stays on the machine; if
`baseURL` points at a hosted provider, that content leaves the machine.
