# tydo workflows

Multi-step recipes. For single-command syntax see `cli-reference.md`.

- [Reading the list](#reading-the-list)
- [Capture](#capture)
- [Document → tasks](#document--tasks)
- [The processing pipeline](#the-processing-pipeline)
- [Clarifications](#clarifications)
- [Mastermind planning](#mastermind-planning)
- [Group housekeeping](#group-housekeeping)
- [Retention and provider config](#retention-and-provider-config)
- [Testing safely](#testing-safely)

## Reading the list

One call answers almost every read:

```bash
tydo snapshot 2>/dev/null
```

Then work in the JSON, not in more CLI calls. Use `todo list active <group-id>`
only when you already have the group UUID and want just that slice.

There is no search. To find "the dentist one", read the snapshot and match
`title` / `rawText` yourself. `title` is the AI-refined text and `rawText` is
what the user originally typed — match against both; report using `title`.

Success criteria: you have a UUID before you mutate. If two todos match, ask.

## Capture

Fast path, no provider needed:

```bash
tydo todo add "call the dentist"
echo '["call the dentist","book the venue"]' | tydo todo add-many
```

New todos land at `stage: "raw"` with no group. That is normal, not an error.

`--process` appends AI cleanup + grouping to the same invocation, but couples
capture to a slow, failure-prone step and makes retry unsafe (the todo is
already inserted when processing fails). Prefer plain capture, then a separate
`tydo process`.

Failure modes: empty text → `invalid_request`; a task whose text is exactly
`--process` cannot be captured (the token is stripped).

## Document → tasks

Read-only extraction, then explicit confirmation, then bulk insert:

```bash
tydo document extract ~/Meeting.pdf 2>/dev/null
```

1. Show the returned strings to the user. Extraction is a model guess; it drops
   and rewords things.
2. Let them remove any.
3. Insert the survivors: `echo '<json array>' | tydo todo add-many`.

Never pipe extraction straight into `add-many` without showing the list first.

Failure modes: unsupported extension or >5 MiB → `invalid_request`; missing file
→ `not_found`; provider down → `timeout`/`internal`. An **empty array** means the
model's replies were unparseable as often as it means the document had no
actions — say which you cannot distinguish rather than "no action items found".

Recovery: extraction never writes, so it is always safe to re-run.

## The processing pipeline

```bash
tydo process 2>/dev/null     # slow: roughly ~45s per unprocessed todo
```

Stages, visible in each todo's `stage` field:

| Stage | Meaning |
|---|---|
| `raw` | just captured |
| `grammar` | grammar-cleaned (`title` updated, `rawText` preserved) |
| `enriched` | title/body refined against up to 40 peer todos, embedding computed |
| `grouped` | organizer assigned a group |

The organizer embeds the todo, takes the 3 nearest group centroids and 5 nearest
loose todos in General, and asks the model to assign / create a group / use
General. If two groups are both strong (≥0.80) and near-tied (within 0.05), it
refuses to guess: the todo stays ungrouped and a **clarification** is created.

Notes:
- Each stage is saved as it completes, so `process` is safe to re-run and resumes.
- A partial failure returns `Processing partially completed: …` with exit 1, yet
  some todos did advance. Re-read the snapshot before reacting.
- Unparseable model output silently keeps the existing title / falls back to
  General. Nothing errors.
- Completed todos are not excluded from processing.

## Clarifications

```bash
tydo clarification list 2>/dev/null
```

Each has `todoTitle` and `optionGroupNames` (best match first). Present the
options to the user; do not pick for them — this is a question the organizer
deliberately declined to answer.

```bash
tydo clarification resolve <clarification-id> "<one of optionGroupNames>"
```

The name must match an option case-insensitively **and** a group with that name
must still exist, otherwise `conflict`. If the group was renamed or deleted since
the question was created, the option is stale: `tydo todo move` the todo
directly instead, and the clarification will clear when the todo is deleted or
unassigned.

`clarification mark-presented` only flips a display flag for the macOS app. An
agent has no reason to call it.

## Mastermind planning

```bash
tydo group list 2>/dev/null                      # resolve the group name → UUID
tydo mastermind analyze <group-id> 2>/dev/null   # or omit the ID for the whole list
```

Returns `summary` plus 2–5 proposals, each with `title`, `body`, `rationale`,
`group`. Nothing is written.

Present the summary and the proposals with their rationale. Only when the user
picks one, feed that exact object back:

```bash
echo '{"id":"…","title":"…","body":"…","rationale":"…","group":"Apartment"}' \
  | tydo mastermind accept
```

- All five fields are required; a partial object is `invalid_request`.
- Idempotent on `id`, so a retry is safe and returns the same todo.
- The `group` name creates the group if it does not exist.
- Whole-list analysis flattens groups, so **ungrouped todos are omitted** from
  it. Run `tydo process` first if you want everything considered.
- Long prompts on a slow local model hit the 30s request timeout. On `timeout`,
  narrow to one group or suggest a faster `reasoning-chat-model`.

## Group housekeeping

```bash
tydo group create "Apartment"
tydo todo move <todo-id> <group-id>
```

Then re-read: `todo move` and `todo complete` both prune non-General groups that
have no active todos left, deleting the group and relocating its todos to
General. A group UUID from earlier in the conversation may no longer exist.

To empty a group without destroying it, note that `todo unassign` does not
prune — but the group will be pruned the next time any prune runs.

`group delete <id> --yes` removes the group and moves its todos to General. The
todos are safe. Confirm with the user anyway: the organization is lost.

## Retention and provider config

```bash
tydo config get 2>/dev/null
```

`retentionDays` (default 30) is how long a **completed** todo survives after
completion. `tydo maintenance` is what actually deletes them — permanently, with
no export. Always confirm before running it, and say how many todos it will
affect (compute that from the snapshot: completed todos whose `completedAt` is
older than `retentionDays`).

Changing settings:

```bash
echo '{"version":1,"retentionDays":90}' | tydo config update
echo '{"reasoningBaseURL":"https://api.example.com/v1","reasoningAPIKey":"…"}' \
  | tydo config update
echo '{"reasoningAPIKey":null}' | tydo config update      # clear the key
```

Use `config update` rather than `config set` for anything secret — `config set`
puts the value in argv, visible to shell history and `ps`.

If `baseURL` is changed to a hosted provider, task text and document contents
leave the machine. Tell the user that before changing it for them.

Changing `embedding-model` invalidates existing embeddings (no dimension
metadata is stored); grouping quality degrades until todos are re-processed.

## Reaching the app's store

If `snapshot` comes back empty but the user insists they have tasks, you are on
the wrong store file — see "The store-path split" in `cli-reference.md`. Find the
newest `default.store` under `~/Library/Application Support` and pass its parent
directory inline:

```bash
TYDO_DATA_DIR="$HOME/Library/Application Support" tydo snapshot 2>/dev/null
```

Data commands work correctly under that override. `config get`/`set`/`update`
and every AI-backed command do not — they would see a different settings suite
and an empty keychain, so run those with no override and warn the user that the
two stores disagree.

## Testing safely

```bash
TYDO_DATA_DIR=$(mktemp -d) tydo snapshot   # a fresh store with just the General group
```

`TYDO_DATA_DIR` redirects the store, both lock files, the settings suite, and the
keychain service. Nothing done under it can touch the user's real list, which is
what makes it the right way to check an unfamiliar command before running it for
real. Set it **inline on that one command**. Do not `export` it: an exported
value silently redirects every later command, so the user's actual work would go
into a throwaway directory and their real list would look empty.

The macOS app does not observe external writes. After changing the store from the
CLI, tell the user the app window will show stale data until it next refreshes.
