# Translate

Keyboard-first translation overlay for the Omarchy shell. Two panes, a language
chip per pane, a filterable language picker, and a free keyless backend.

![Translate overlay](preview.png)

## Keys

| Key | Action |
| --- | --- |
| `Super+Shift+K` | open / close the overlay |
| `Ctrl+Enter` | translate now |
| `Ctrl+S` | swap languages and panes (instant — the panes exchange text) |
| `Ctrl+L` | pick the source language |
| `Ctrl+Shift+L` | pick the target language |
| `Ctrl+1` / `Ctrl+2` | focus the source / translation pane (inside the picker: choose which side you are setting) |
| `Ctrl+Shift+C` | copy the translation |
| `Ctrl+Shift+V` | translate whatever is on the clipboard |
| `Ctrl+Shift+X` | clear both panes |
| `Ctrl+P` | toggle translate-while-typing |
| `Tab` / `Shift+Tab` | move focus between panes |
| `F1` | show the shortcut list |
| `Esc` | close the picker, then the overlay (cancels an in-flight request) |

In the language picker: type to filter (code, English name or native name),
`↑`/`↓` to choose, `Enter` to apply, `Tab` to switch between source and target,
`Esc` to cancel.

## Behaviour

- Default pair is English → Russian; the pair, the auto-translate switch, and
  the last panes persist in `~/.local/state/omarchy/translate.json`, so the
  overlay comes back the way you left it after a shell restart.
- With auto-translate on (the default), typing translates after 600 ms of
  quiet; `Ctrl+Enter` translates immediately, request per pause.
- Source `Auto` detects the input language and shows what it detected.
- `Esc` during a request kills the `curl` instead of waiting for it.

## Backend

`bin/translate-fetch <from> <to> <text|->` prints one JSON object:

```json
{"ok":true,"text":"привет","engine":"google","detected":"en"}
```

Engines, tried in order:

1. **google** — `clients5.google.com/translate_a/t?client=dict-chrome-ex`, the
   keyless endpoint the Chrome dictionary extension uses. Fast, good quality.
2. **mymemory** — `api.mymemory.translated.net/get`, keyless, ~5k characters/day
   anonymous.

Long text is chunked so no single request exceeds what an endpoint accepts, and
the chunks are rejoined on the newlines they were split on.

Knobs (environment):

| Variable | Effect |
| --- | --- |
| `OMARCHY_TRANSLATE_ENGINE` | `google` (default) or `mymemory` — which engine is tried first |
| `OMARCHY_TRANSLATE_EMAIL` | any address; raises MyMemory's anonymous daily quota |

The file is also usable from a terminal:

```bash
~/.config/omarchy/plugins/io.github.baltavay.translate/bin/translate-fetch en ru "hello"
echo "привет" | ~/.config/omarchy/plugins/io.github.baltavay.translate/bin/translate-fetch ru en -
```

## Layout

```
~/.config/omarchy/plugins/io.github.baltavay.translate/
  manifest.json          plugin manifest (kind: overlay, keepLoaded)
  Translate.qml          overlay: panes, picker, shortcuts, persistence
  Languages.js           language table (code, English name, native name)
  bin/translate-fetch    engine chain + chunking, one JSON object on stdout
  omarchy-menu.jsonc     menu row to merge into ~/.config/omarchy/extensions/
  preview.png
```

## Requirements

- Omarchy Quattro (`omarchy-shell` / Quickshell `PanelWindow` overlay).
- `curl` and `jq` — present on a stock Omarchy install; they do the talking in
  `bin/translate-fetch`.
- `wl-clipboard` (`wl-copy`, `wl-paste`) for the copy and paste shortcuts.
- Network access to `clients5.google.com` and/or `api.mymemory.translated.net`.
  No API keys, no accounts, nothing to configure.

## Install

From the marketplace listing, or straight from git:

```bash
omarchy plugin add https://github.com/baltavay/omarchy-translate.git --enable
```

That clones the repo into `~/.config/omarchy/plugins/io.github.baltavay.translate/`,
validates the manifest, and enables the overlay. Installing by hand instead:
check the folder, then add the id to `plugins[]` in `~/.config/omarchy/shell.json`
(the shell hot-reloads it) and add the keybinding to `~/.config/hypr/bindings.lua`:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.baltavay.translate
```

```lua
o.bind("SUPER + SHIFT + K", "Translate", "omarchy-shell shell toggle io.github.baltavay.translate")
hl.layer_rule({ match = { namespace = "^omarchy-translate$" }, no_anim = true, animation = "none" })
```

The plugin ships no keybinding and no menu row of its own — it never edits your
config. Add the lines above (plus the `trigger.translate` row from
`omarchy-menu.jsonc` if you want it in the Omarchy menu) to make it yours.
`Super+Shift+K` is free on stock Omarchy (`Super+K` is keybindings, `Super+Alt+K`
tmux, `Super+Ctrl+K` herdr). `omarchy-shell shell toggle io.github.baltavay.translate` is
the same thing from a terminal.

The overlay is also summonable with a payload:

```bash
omarchy-shell shell toggle io.github.baltavay.translate '{"text":"Good morning","source":"en","target":"ru"}'
omarchy-shell shell toggle io.github.baltavay.translate '{"source":"auto","target":"ru"}'
```

## Removal

```bash
omarchy plugin disable io.github.baltavay.translate   # or: remove the id from shell.json plugins[]
omarchy plugin remove  io.github.baltavay.translate
rm ~/.local/state/omarchy/translate.json              # the remembered language pair
```

Then drop the `o.bind(...)` line and the `hl.layer_rule(...)` line from
`~/.config/hypr/bindings.lua`, and the `trigger.translate` row from
`~/.config/omarchy/extensions/omarchy-menu.jsonc` if you merged it. Nothing else
outside `~/.config/omarchy/plugins/<id>/` is touched.
