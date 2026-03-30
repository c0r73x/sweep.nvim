# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

sweep.nvim is a Neovim plugin for AI-powered inline completions and edit predictions. It uses a local `sweep-next-edit` GGUF model via a Python proxy process, communicating over Unix sockets (with HTTP fallback).

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

1. **Neovim plugin** (`lua/sweep.lua` + `lua/sweep/`) — handles UI, buffer state, keymaps, and communication
2. **Python proxy** (`proxy/sweep_proxy.py`) — single FastAPI/llama-cpp-python server shared across all Neovim instances, listens on Unix socket + HTTP

### Plugin module map (`yue/sweep/`)

| Module | Responsibility |
|--------|----------------|
| `sweep.yue` | Main `Sweep` class; orchestrates all other modules; entry point for `setup()` |
| `config.yue` | Default configuration and highlight group setup |
| `client.yue` | Network layer: Unix socket (preferred) or HTTP fallback; builds FIM and edit prompts |
| `buffer.yue` | Buffer state snapshots, context window extraction, Treesitter integration, applying updates |
| `cache.yue` | LRU cache (100 entries, 5s TTL) keyed on context to avoid duplicate requests |
| `tracker.yue` | Records edit history (6 edits) and recent file visits (3 files) for prompt context |
| `ui.yue` | Extmark-based rendering for inline ghost text (FIM) and virtual diffs (edit mode) |
| `diff.yue` | LCS-based line diff engine used to compute hunks for edit mode display |
| `autocmds.yue` | Autocommand setup: debounced TextChangedI (FIM), CursorHold (edit prediction) |
| `keymaps.yue` | Conditional keymap setup (Tab accept, Esc reject) |
| `lualine.yue` | Optional lualine component showing proxy status and spinner |

### Completion flow

**FIM mode (insert):** `TextChangedI` → debounce → `client.build_fim_prompt()` → proxy → `ui.show_fim()` (extmarks) → Tab → insert text

**Edit prediction mode (normal):** `CursorHold` → `tracker.get_diff_sections()` + `tracker.get_context_files()` → `client.build_edit_prompt()` → proxy → `diff.diff()` → `ui.show_edit()` (virtual diff extmarks) → Tab → `buffer.apply_update()`

### Prompt formats

- **FIM:** `<|fim_prefix|>{before}<|fim_suffix|>{after}<|fim_middle|>`
- **Edit:** structured prompt with `<|file_sep|>` separators, diff sections, treesitter context, and recent file chunks

### Transport

Client tries Unix socket at `/tmp/sweep-<uid>.sock` (or `$XDG_RUNTIME_DIR/sweep.sock`) first; falls back to `curl` HTTP POST to `http://127.0.0.1:5555/v1/completions`.

## User-facing commands

`SweepStatus`, `SweepCache`, `SweepReload`, `SweepHide`, `SweepToggle`, `SweepEdit` — all defined in `sweep.yue`.

## No tests

There are no automated tests in this repo.
