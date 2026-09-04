---
name: tydo
description: >-
  Manage the user's personal Tydo task list through the local `tydo` CLI (macOS,
  JSON-only output, SwiftData store, optional local/OpenAI-compatible AI).
  Use it to capture todos, read the task list and its groups, complete, reopen,
  rename, move, unassign or delete tasks, create and clean up groups, run the AI
  pipeline that tidies and auto-groups new todos, extract action items out of a
  document (PDF, Word, Markdown, RTF, HTML, text), answer parked grouping
  clarification questions, plan next actions with Mastermind, and read or change
  Tydo's provider/model/retention configuration. Trigger on personal
  task-management intent even when "tydo" is never said: "add a todo", "what's on
  my list", "what's still open", "mark that done", "what should I work on next",
  "turn these meeting notes into tasks", "pull the action items out of this PDF",
  "tidy up my task groups", "how long do finished tasks stick around". Do NOT use
  it for editing this repository's own Swift/app source, and not for writing an
  ad-hoc checklist into a file or chat reply.
---

# Tydo

`tydo` is a local, single-user task manager. Every command prints JSON. There is
no server, no account, no remote state — all writes land in one SwiftData store
on this Mac. AI-backed commands call an OpenAI-compatible endpoint that the user
configures (default: local Ollama).

## 1. Locate the binary

`tydo` is often not on `PATH`. Resolve it once per session and reuse the path:

```bash
command -v tydo || ls "$TYDO_CLI_PATH" /opt/homebrew/bin/tydo /usr/local/bin/tydo \
  /Applications/Tydo.app/Contents/Helpers/tydo ./.build/release/tydo 2>/dev/null | head -1
```

`brew install FruttoCheap/tap/tydo` puts it on `PATH`. The macOS app also ships it
at `Tydo.app/Contents/Helpers/tydo` and offers to symlink that into `/usr/local/bin`.
In this repository, `swift build -c release` → `./.build/release/tydo`.
Confirm with `tydo version` (prints `{"data":{"cli":…,"protocolVersion":1}}`).
If `protocolVersion` is not `1`, re-read `tydo help` before trusting anything below.

## 1b. An empty list is a store-path problem until proven otherwise

The CLI reads `~/Library/Application Support/Tydo/default.store`. An app build
made before that subdirectory existed used `~/Library/Application Support/default.store`
instead, and on such a machine both files exist holding different data — reading
the wrong one returns a valid, *empty* snapshot that is indistinguishable from
"nothing to do".

**Never report an empty or suspiciously short list without this check:**

```bash
ls -lt ~/Library/Application\ Support/default.store \
       ~/Library/Application\ Support/Tydo/default.store 2>/dev/null
```

- Only `Tydo/default.store` → normal, healthy. Trust the result.
- Both exist → the live one is the **most recently modified** (the app keeps
  touching it). If that is the root one, the two are out of sync: read it with an
  inline override and tell the user.

```bash
TYDO_DATA_DIR="$HOME/Library/Application Support" tydo snapshot 2>/dev/null
```

That override is a diagnostic, not a fix, and it has a sharp edge: it also swings
the settings suite and keychain, so `config get`/`set`/`update` and every
AI-backed command would read the **wrong** model/provider/key under it. Data
commands only; run those without it.

The real fix is to quit the app, move `default.store` (plus `-wal`/`-shm`) into
`Tydo/`, and rebuild the app from current source so both binaries resolve the
same path. Never do that while the app is running, and not without asking.

## 2. Output contract

- Success → one JSON object on **stdout**, exit `0`: `{"version":1,"data":…}`.
- Failure → one JSON object on **stderr**, exit `1`: `{"version":1,"code":…,"error":…}`.
- `help` / `--help` / no args → plain text, exit `0`. Never parse it as JSON.
- **stderr can also carry CoreData debug noise.** Silence it with `2>/dev/null`
  on reads only — never on a mutation, where you must see the error envelope.
  When a command fails, pick the JSON object out of stderr rather than assuming
  it is the only thing there.
- **Null fields are omitted, not null.** A todo with no group has no `groupID` key.
  Always use `.get("groupName")`-style access, never index blindly.
- Dates are ISO-8601. Every identifier is a UUID string.

Error `code` values: `invalid_request`, `not_found`, `conflict`, `busy`,
`timeout`, `internal`. Branch on `code`, not on the message text.

## 3. Core workflow

0. **Verify the store** (§1b) the first time you read in a session. An empty
   result is a store-path problem until proven otherwise.
1. **Read before you write.** `tydo snapshot` returns todos + groups +
   clarifications in one call — prefer it over three separate list commands.
2. **Resolve names to UUIDs from that snapshot.** The CLI has no search and no
   name-based lookup for todos or groups. Never invent or guess a UUID.
3. If the user's phrasing matches more than one todo, show the candidates and ask
   which one — do not pick for them on a mutation.
4. Perform the mutation.
5. **Re-read.** Group IDs are not durable (see §6) and the macOS app does not
   observe external writes; a fresh `snapshot` is the only reliable after-state.

## 4. Intent → command

| User wants | Command |
|---|---|
| see the list / anything by name | `tydo snapshot` |
| just open items, or one group's items | `tydo todo list active [group-id]` |
| capture one task | `tydo todo add "<text>"` |
| capture several | `echo '["a","b"]' \| tydo todo add-many` |
| detail on one task | `tydo todo show <todo-id>` |
| mark done / undo | `tydo todo complete\|reopen <todo-id>` |
| retitle | `tydo todo rename <todo-id> <new title>` |
| file into a group / pull out of one | `tydo todo move <todo-id> <group-id>` / `tydo todo unassign <todo-id>` |
| new bucket | `tydo group create <name>` |
| tidy + auto-group new todos | `tydo process` (slow, needs the provider) |
| purge old completed todos | `tydo maintenance` (**destructive** — see §7) |
| action items out of a document | `tydo document extract <path>` |
| "what should I do next" | `tydo mastermind analyze [group-id]` |
| accept a suggestion | `tydo mastermind accept '<proposal-json>'` |
| answer a pending grouping question | `tydo clarification list` → `resolve <id> <group-name>` |
| which model / retention is set | `tydo config get` |
| "the AI isn't working" / provider check | `tydo doctor` |

Full syntax, flags, and output schemas: **`references/cli-reference.md`**.

## 5. Structured output is the only output

There is no `--json` flag because there is no other mode, and no `--quiet`, no
pagination, and no confirmation prompt. The only stdin readers are
`todo add-many` and `mastermind accept` (only when their JSON argument is
omitted) and `config update` (always). If you invoke one of those without piping
anything in, it will read stdin to EOF — always give it a pipe or `</dev/null`
so it cannot hang waiting on a terminal.

Argument parsing is hand-rolled: no `--` terminator. On `todo add` / `add-many`,
any argv element that is exactly `--process` is removed **from any position** and
turns on processing. Quoting the whole task as one argument protects text that
contains it (`tydo todo add "review --process notes"` keeps the literal string
and does *not* process). `tydo todo add --process` alone is an empty-text error.
Everything else is positional; always quote text containing spaces.

## 6. Groups are ephemeral — read this before touching them

The store self-prunes. A non-General group with **no active todos left** is
deleted automatically, and its todos move to General. This fires after
`todo complete`, `todo move`, and `maintenance`.

Consequences you must not get wrong:
- Completing the last open task in a group silently destroys that group.
- Reopening that task puts it in **General**, not its old group.
- A group UUID captured earlier in the session may already be gone. Re-read.
- `todo unassign` does *not* prune, so it can leave an empty group behind.
- `General` is permanent: it cannot be deleted or renamed (`conflict`).

## 7. Mutations and risk

| Class | Commands |
|---|---|
| **Read-only** | `version`, `snapshot`, `todo list`, `todo show`, `group list`, `clarification list`, `config get`, `doctor`, `document extract`, `mastermind analyze` |
| **Local write** | `todo add`/`add-many`/`rename`/`complete`/`reopen`/`move`/`unassign`, `group create`/`rename`, `clarification mark-presented`/`resolve`, `mastermind accept`, `config set`/`update`, `process` |
| **Destroys data** | `todo delete <id> --yes`, `maintenance` |
| **Deletes a group (not its todos)** | `group delete <id> --yes` |

Run reads freely without asking. For local writes, just do what was asked.

**Confirm with the user first** for:
- `todo delete --yes` — permanent, no trash, no undo, no export. Show the todo's
  title from `todo show` before deleting so they can see what is about to go.
- `maintenance` — permanently deletes every **completed** todo whose
  `completedAt` is older than `config get`.`retentionDays` (default 30), then
  prunes emptied groups. Not reversible.
- `group delete --yes` — safe for the todos (they land in General) but the group
  and its organization are gone.

`--yes` is a required literal token on both delete commands; there is no separate
prompt and no `--dry-run`. Omitting it is a usage error, not a prompt.

## 8. AI-backed commands

`process`, `todo add --process`, `todo add-many --process`, `document extract`,
and `mastermind analyze`/`accept` call the configured provider.

- Check reachability first: `tydo config get` → `baseURL` (default
  `http://localhost:11434/v1`, i.e. Ollama must be running with the named
  `chatModel` and `embeddingModel` pulled).
- **They are slow.** Measured here: ~45s per todo for `process`; `document
  extract` seconds per 8k-char chunk. Per-request timeout is 30s, 120s overall.
  Use a generous tool timeout and tell the user it will take a while.
- `mastermind analyze` sends a large prompt and **times out (`code:"timeout"`) on
  a slow local model**. If it does, retry scoped to one group
  (`mastermind analyze <group-id>`) or suggest a faster `reasoning-chat-model`.
- Malformed model output is converted to an empty success, not an error. An empty
  `proposals` or an empty extract list means "nothing usable came back", not
  "nothing to do" — say so rather than reporting "no action items found".

**Retry rules — this is the one place a naive retry corrupts data:**

| Command | Safe to retry? |
|---|---|
| `todo add --process` / `add-many --process` | **No.** The todo is inserted *before* processing; a processing error still leaves it saved. Retrying duplicates it. Re-read with `todo list` and then run bare `tydo process`. |
| `tydo process` | Yes. Each stage is persisted; a rerun resumes where it stopped. |
| `mastermind accept` | Yes. Idempotent on the proposal's `id` — a repeat returns the same todo. |
| `document extract` | Yes. Never writes anything. |

Safer default for capture: `tydo todo add "<text>"` (instant, no provider), then
`tydo process` separately if the user wants it tidied and grouped.

## 9. Error recovery

| `code` | What happened | Do this |
|---|---|---|
| `invalid_request` | bad syntax, bad UUID, missing `--yes`, bad JSON | Read the message; it usually contains the exact usage line. Fix and re-run. Do not retry unchanged. |
| `not_found` | that UUID is gone | Re-run `tydo snapshot` — it was probably deleted or its group was pruned. |
| `conflict` | invariant refused (General group, stale clarification choice) | Explain to the user; do not force it. |
| `busy` | another process holds the store lock (2s deadline) | Wait ~1s and retry once. The macOS app or a background `process` is likely running. |
| `timeout` | provider did not answer in 30s | Check the provider is up; narrow the scope; or suggest a faster model. |
| `internal` | unexpected (missing file, encode failure) | Report the message verbatim. Do not retry blindly. |

If a command fails with no JSON on stderr at all, the binary path is wrong — go
back to §1. If a command *succeeds* but the list is empty or is missing todos the
user says are there, the store path is wrong — go back to §1b.

## 10. Configuration and secrets

`tydo config get` shows the effective settings. It never prints a key, only
`chatAPIKeyConfigured` / `embeddingAPIKeyConfigured` / `reasoningAPIKeyConfigured`.

There are three independent provider slots — **chat**, **embedding**, **reasoning** —
each with its own base URL, model and key. An empty `embeddingBaseURL` means
"same server as chat", which is the default and what a local-only setup wants.
The slot split exists because OpenRouter and Groq serve chat but have no
`/embeddings` endpoint: with them, `embeddingBaseURL` must point at a local
Ollama or LM Studio.

`tydo doctor` is the fastest way to find out what is actually broken. It makes a
real call per slot rather than trusting `GET /models`, and returns
`{ok, checks:[{name, ok, detail, remedy}]}`. It **exits 0 even when checks fail** —
read `data.ok`, not the exit status. Run it before blaming the store for odd
results, and after any provider change.

To change settings, **prefer `tydo config update` with a JSON object on stdin** —
it validates URLs and the 1–365 retention range, and applies atomically:

```bash
echo '{"version":1,"retentionDays":60}' | tydo config update
```

`config set` **rejects** every API key with `invalid_request`: argv is visible in
shell history and to `ps`. Use `config update` with `{"chatAPIKey":"…"}`,
`{"embeddingAPIKey":"…"}` or `{"reasoningAPIKey":"…"}`, and `null` to clear one.

A changed embedding model changes the vector width, which silently zeroes every
similarity and drops all grouping into General. `tydo doctor` reports that
mismatch; nothing else does.

`TYDO_DATA_DIR=<dir>` redirects the store, the settings suite, and the keychain
service all at once. Set it — inline on the single command, e.g.
`TYDO_DATA_DIR=$(mktemp -d) tydo …` — when you want to try a command's behaviour
out first. **Never export it for the user's actual work**, or their real list is
not the one you are reading and writing.

## 11. Examples

**"What's still on my plate?"**
```bash
tydo snapshot 2>/dev/null
```
Report active todos grouped by `groupName`, and mention any `clarifications`.
If it comes back empty, run the §1b store check before saying the list is empty.

**"Mark the landlord email done."**
```bash
tydo snapshot 2>/dev/null          # find the todo whose title matches; confirm if ambiguous
tydo todo complete <todo-id>       # a mutation: keep stderr so an error is visible
```
If its group vanished from the follow-up snapshot, say so — that is §6, not a bug.

**"Pull the action items out of ~/notes.pdf and add them."**
```bash
tydo document extract ~/notes.pdf 2>/dev/null    # read-only; show the list first
```
Show the extracted strings, let the user drop any, then:
```bash
echo '["…","…"]' | tydo todo add-many
```

**"What should I work on next in Apartment?"**
```bash
tydo group list 2>/dev/null                       # get the group UUID by name
tydo mastermind analyze <group-id> 2>/dev/null    # slow; summary + 2-5 proposals
```
Present `summary` and each proposal's `title` + `rationale`. Only after the user
picks one, pipe that exact proposal object (all of `id`, `title`, `body`,
`rationale`, `group`) into `tydo mastermind accept`.

**"Clean up my list."** — ambiguous, three different things. Ask which:
`tydo process` (tidy + auto-group unprocessed todos), `tydo maintenance`
(permanently delete old completed todos), or manual group tidying.

## 12. References

- **`references/cli-reference.md`** — every command's exact arguments, output
  field lists, config keys, and error codes. Read it before writing any command
  whose syntax is not spelled out above, and whenever a flag "should" exist.
- **`references/workflows.md`** — multi-step recipes (document import, the
  processing pipeline and its stages, clarifications, Mastermind, safe testing
  with `TYDO_DATA_DIR`). Read it when a request needs more than one command.

`check.py` in this directory verifies that every command documented in the
reference still exists in `tydo help`. Run it after the CLI changes.
