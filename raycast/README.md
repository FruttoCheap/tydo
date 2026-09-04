# Tydo for Raycast

Capture, review, organize, and plan todos through the Tydo CLI without opening the Tydo macOS app.

## Requirements

- macOS with [Raycast](https://www.raycast.com/)
- Tydo CLI 1.1.0 or newer using protocol 1

Install the CLI from the dedicated Homebrew tap:

```sh
brew install FruttoCheap/tap/tydo
```

The extension checks an optional **Tydo CLI Path** preference first, followed by `/opt/homebrew/bin/tydo`, `/usr/local/bin/tydo`, and `tydo` on `PATH`.

## Commands

- **Capture Todo** captures one todo or extracts actions from multiline text for review.
- **Browse Todos** searches and manages active, completed, grouped, and processing todos.
- **Import Document** extracts selected actions from PDF, text, Markdown, Word, RTF/RTFD, and HTML files.
- **Manage Tydo** resolves grouping questions, manages groups and settings, runs Mastermind, and starts confirmed maintenance.
- **Check Grouping Questions** runs every ten minutes, updates its subtitle, and announces newly created questions once.

Raycast command hotkeys can be assigned in Raycast Settings.

## Privacy

The extension launches the local `tydo` executable and exchanges protocol-v1 JSON over standard input and output. It does not access Tydo's database, UserDefaults, or Keychain directly, and it does not store task text or API keys in Raycast storage.

Tydo may send todo text, document contents, group context, and planning context to the OpenAI-compatible provider endpoints configured in **Manage Tydo**. Review those endpoint operators' privacy terms before use. Document extraction reads only files explicitly selected in Raycast. A replacement API key is sent to the CLI through standard input, never command arguments; the existing key is never displayed.

Maintenance permanently removes completed todos older than the configured retention period and always requires confirmation in Raycast.

## Troubleshooting

**CLI not found:** run `brew install FruttoCheap/tap/tydo`, or set **Tydo CLI Path** to an executable development build.

**CLI is incompatible:** run `brew update && brew upgrade FruttoCheap/tap/tydo`. This extension requires CLI 1.1.0+ and protocol 1.

**Tydo is busy:** wait for the app, another command, or processing job to finish, then retry. Mutations are never retried automatically.

**Provider timeout or processing failure:** the initial todo may already be safely stored. Open **Browse Todos** to refresh its current state, then process it again; do not repeat the capture solely because processing failed.

**No actionable items found:** confirm the selected file is supported, within the CLI's document-size limit, and contains explicit actions. Files are extracted sequentially and the first failing file is named in the error.

## Development

```sh
npm install
npm run lint
npm run build
```

Use the default development profile normally. If Raycast v2 was upgraded from
`Raycast Beta.app`, it may retain the beta development profile even after the
application becomes the stable `Raycast.app`:

```sh
npm run dev:stable
npm run dev:beta
```

Both commands build the same extension. `dev:beta` selects the retained
`~/.config/raycast-x` profile; it does not imply that the installed application
is still a beta version.

The extension source is maintained at [FruttoCheap/tydo](https://github.com/FruttoCheap/tydo).
