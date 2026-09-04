# Tydo

A local task manager for macOS that tidies, groups and plans your todos with an
LLM you choose. Nothing leaves your Mac unless you point it somewhere else.

The **CLI is the whole product**. Everything else — the menu-bar app, the Raycast
extension, the Claude Code skill — is an optional front end that shells out to it
and reads JSON back. Pick the one you like, or none.

```
    menu-bar app     Raycast     Claude Code skill     your own script
             \          |            /                    /
              \         |           /                    /
                     tydo CLI  (JSON in, JSON out)
                          |
              +-----------+-----------+
              |                       |
        SwiftData store        OpenAI-compatible APIs
```

## Install

```sh
brew install FruttoCheap/tap/tydo
tydo doctor
```

`doctor` tells you exactly what is missing. Requires macOS 14 or newer.

## Providers

Tydo has **three independent provider slots**. Each takes its own base URL, model
and API key, so you can mix them freely:

| Slot | Used for |
|---|---|
| `chat` | grammar cleanup, enrichment, grouping decisions, document extraction |
| `embedding` | the similarity vectors that drive grouping |
| `reasoning` | Mastermind planning only |

Any OpenAI-compatible server works:

| Provider | Base URL | Chat | Embedding | Key |
|---|---|---|---|---|
| **Ollama** | `http://localhost:11434/v1` | ✓ | ✓ `nomic-embed-text` | not needed |
| **LM Studio** | `http://localhost:1234/v1` | ✓ | ✓ `nomic-embed-text-v1.5` | not needed |
| llama.cpp server | `http://localhost:8080/v1` | ✓ | depends on the build | not needed |
| OpenAI | `https://api.openai.com/v1` | ✓ | ✓ `text-embedding-3-small` | yes |
| OpenRouter | `https://openrouter.ai/api/v1` | ✓ | ✗ none | yes |
| Groq | `https://api.groq.com/openai/v1` | ✓ | ✗ none | yes |

Fully local is the default and needs no configuration beyond pulling a model:

```sh
ollama pull llama3.2
ollama pull nomic-embed-text
tydo doctor
```

**Keep embeddings local even when chat is not.** The embedding vector describes
the content of every task you write, so it is the most revealing thing Tydo
produces. Leaving that slot on localhost costs nothing and is also mandatory
with OpenRouter and Groq, which serve chat but have no `/embeddings` endpoint:

```sh
tydo config set base-url https://openrouter.ai/api/v1
tydo config set chat-model meta-llama/llama-3.3-70b-instruct
tydo config set embedding-base-url http://localhost:11434/v1
echo '{"chatAPIKey":"sk-or-…"}' | tydo config update
tydo doctor
```

An empty `embedding-base-url` means "same server as chat", which is the default.

### API keys

Keys live in the Keychain and are written **only** through `config update` on
stdin. `config set` rejects them on purpose: arguments are visible in `ps` and
land in your shell history.

```sh
echo '{"reasoningAPIKey":"sk-…"}' | tydo config update   # set
echo '{"reasoningAPIKey":null}'   | tydo config update   # clear
```

### Changing the embedding model

A different embedding model means a different vector width, which silently
zeroes every similarity — grouping quietly degrades into "everything lands in
General". `tydo doctor` is the only thing that reports this. Existing todos need
to be re-added to pick up the new width.

## Usage

```sh
tydo todo add "call the dentist" --process
tydo snapshot
tydo todo complete <id>
tydo mastermind analyze
tydo document extract ~/notes/meeting.pdf
tydo help
```

Every command prints one JSON object on stdout and exits 0, or prints
`{"version":1,"error":…,"code":…}` on stderr and exits 1. `doctor` is the
exception worth knowing: failed checks are data, so it still exits 0 — branch on
`data.ok`.

## Front ends

| | Install | Needs |
|---|---|---|
| **macOS app** | download the DMG from Releases | the CLI is bundled |
| **Raycast** | clone `extensions/raycast`, `npm install && npm run dev` | the CLI on `PATH` |
| **Claude Code** | `/plugin marketplace add FruttoCheap/tydo` then `/plugin install tydo` | the CLI on `PATH` |

The app ships its own copy of the CLI at `Tydo.app/Contents/Helpers/tydo` and can
symlink it into `/usr/local/bin`, so installing the app alone is enough to give
Raycast and Claude Code a working `tydo`.

## Things to know before you rely on it

- **macOS 14+ only.** The CLI links AppKit, SwiftData and PDFKit; there is no
  Linux build and there will not be one.
- **No export, backup, trash or undo.** `tydo maintenance` permanently deletes
  completed todos older than `retention-days` (default 30). Active todos are
  never deleted.
- **AI calls can be slow.** Requests time out after 30 seconds, 120 seconds
  total, with no retry.
- **Concurrent writes are not fully serialised.** Only `process` and
  `maintenance` hold the global lock. Driving the CLI from the app, Raycast and a
  script at the same instant is not covered.
- **The store is a single file** at `~/Library/Application Support/Tydo/default.store`.
  Set `TYDO_DATA_DIR` to point everything — store, settings and Keychain service —
  somewhere else for testing.

## Build from source

```sh
swift build -c release --arch arm64 --arch x86_64 --product tydo
swift test
```

## License

MIT
