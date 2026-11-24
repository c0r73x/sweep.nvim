# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

sweep.nvim is a Neovim plugin for AI-powered inline completions and edit predictions. It uses the `sweep-next-edit` GGUF model through llama.cpp's `llama-server`, which the plugin starts on a Unix socket (shared by all Neovims, stopped when idle) and talks to over HTTP directly.

## Build

```bash
make        # Compile YueScript → Lua (minified, for release)
make debug  # Compile YueScript → Lua (readable, for development)
```

**Source files live in `yue/`; never edit files in `lua/` directly** — they are compiled output. The compiled Lua is committed so users don't need YueScript installed.

## Architecture

### Language: YueScript → Lua

The plugin is written in [YueScript](https://github.com/IppClub/YueScript), a CoffeeScript-like language that compiles to Lua. Class syntax compiles to Lua tables with metatables.

### Two-process design

1. **Neovim plugin** (`lua/sweep.lua` + `lua/sweep/`) — handles UI, buffer state, keymaps, prompts and post-processing
2. **llama-server** — started by `bin/sweep-server` (POSIX sh: lock dir next to the socket so one server per user, idle shutdown by watching `llamacpp:n_decode_total` on `/metrics`). Flags in `server.yue` `command()`: 2 slots, `--spec-type ngram-simple` (prompt-lookup speculation, ~4x faster edits), `--cache-ram`. With `provider.url` set, an external server is used and never started.

### Plugin module map (`yue/sweep/`)

| Module | Responsibility |
|--------|----------------|
| `sweep.yue` | Main `Sweep` class; orchestrates all other modules; entry point for `setup()` |
| `config.yue` | Default configuration and highlight group setup |
| `client.yue` | Builds FIM and edit prompts, streams `/completion`, cancels superseded requests, restarts the server on connect errors |
| `http.yue` | Minimal HTTP/1.1 client over libuv (Unix socket or TCP), SSE streaming, abort |
| `server.yue` | Managed llama-server: socket path, command line, spawn via `bin/sweep-server`, health / `ensure()` |
| `postprocess.yue` | Pure functions: FIM trimming and early stop, edit hunks near the cursor, truncated-output handling |
| `buffer.yue` | Buffer state snapshots, context window extraction, Treesitter integration, applying updates |
| `cache.yue` | LRU cache (100 entries, 5s TTL) keyed on context to avoid duplicate requests |
| `tracker.yue` | Records edit history (6 edits) and recent file visits (3 files) for prompt context |
| `ui.yue` | Extmark-based rendering for inline ghost text (FIM) and virtual diffs (edit mode) |
| `diff.yue` | LCS-based line diff engine used to compute hunks for edit mode display |
| `autocmds.yue` | Autocommand setup: debounced TextChangedI (FIM), CursorHold (edit prediction) |
| `keymaps.yue` | Conditional keymap setup (Tab accept, Esc reject) |
| `lualine.yue` | Optional lualine component showing server status and spinner |

### Completion flow

**FIM mode (insert):** `TextChangedI` → debounce → `client.build_fim_prompt()` → llama-server → `postprocess.post_process_fim()` → `ui.show_fim()` (extmarks) → Tab → insert text

**Edit prediction mode (normal):** `CursorHold` → `tracker.get_diff_sections()` + `tracker.get_context_files()` → `client.build_edit_prompt()` → llama-server → `postprocess.post_process_edit()` → `diff.diff()` → `ui.show_edit()` (virtual diff extmarks) → Tab → `buffer.apply_update()`

### Prompt formats

- **FIM:** `<|fim_prefix|>{before}<|fim_suffix|>{after}<|fim_middle|>`
- **Edit:** structured prompt with `<|file_sep|>` separators, diff sections, treesitter context, and recent file chunks

### Transport

Managed server socket: `$XDG_RUNTIME_DIR/sweep-server.sock` or `/tmp/sweep-server-<uid>.sock` (sun_path limit ~104 bytes, so not under stdpath). Requests are streamed (`stream: true`): closing the connection makes llama-server stop generating, non-streamed requests keep generating. Server log: `stdpath('log')/sweep-server.log`.

## User-facing commands

`SweepStatus`, `SweepCache`, `SweepReload`, `SweepHide`, `SweepToggle`, `SweepEdit` — all defined in `sweep.yue`.

## Tests

Headless, no framework:

```bash
for t in tests/*_test.lua; do nvim --headless --clean --cmd 'set rtp^=.' -l "$t"; done
```
