> **Warning:** This plugin was developed with the assistance of
> [Claude Code](https://claude.ai/claude-code). Use at your own risk.

# sweep.nvim

AI-powered code completions for Neovim using the
[sweep-next-edit](https://blog.sweep.dev/posts/oss-next-edit) model.
Inspired by [cursortab.nvim](https://github.com/postsinterthesis/cursortab.nvim).

Runs a local Python proxy (`sweep_proxy.py`) that loads the model via
`llama-cpp-python` and communicates with Neovim over a Unix domain socket
(with HTTP fallback).

## Why sweep.nvim

cursortab.nvim routes requests through a compiled Go server over HTTP before
they reach the model. sweep.nvim eliminates that middleman:

```
cursortab:  Neovim → HTTP → Go server → HTTP → llama.cpp server → model
sweep.nvim: Neovim → Unix socket → Python proxy → model
```

The Unix domain socket skips all TCP stack overhead and HTTP parsing.
Combined with `llama-cpp-python` running the model in-process (with flash
attention and full GPU KV-cache offload enabled by default), round-trip
latency is significantly lower — particularly noticeable on short FIM
completions where the model is fast but transport overhead dominates.

sweep.nvim also requires no extra language runtime to build: no Go toolchain,
just Python.

## Features

- **FIM completions** — inline ghost text at the cursor in insert mode
- **Edit predictions** — next-edit suggestions in normal mode, shown as
  virtual-text diffs
- **Dual transport** — Unix socket (low latency) with automatic HTTP fallback
- **Smart debounce** — stale responses are discarded when new input arrives
- **Blink.cmp integration** — hides ghost text while the completion menu is open
- **Cache** — avoids duplicate requests for the same context
- **Edit-history context** — recent diffs are fed to the model for better
  next-edit accuracy
- **Treesitter context** — enclosing scope and imports included in prompts

## Requirements

- Neovim 0.10+
- Python 3.10+ with `llama-cpp-python`, `fastapi`, `uvicorn`
- The `sweep-next-edit` GGUF model (see [Model](#model) below)

## Installation

### 1. Install with lazy.nvim

```lua
{
    "c0r73x/sweep.nvim",
    build = "make",
    event = { "VeryLazy", "InsertEnter", "BufReadPost", "BufNewFile" },
    config = function()
        require("sweep").setup({})
    end,
}
```

### 3. Set up the proxy

Install Python dependencies:

```bash
pip install llama-cpp-python fastapi uvicorn
```

#### Model

Download the GGUF model into `proxy/models/`:

```bash
mkdir -p proxy/models
# Example with huggingface-cli:
huggingface-cli download \
    sweepai/sweep-next-edit \
    sweep-next-edit-1.5b.q8_0.v2.gguf \
    --local-dir proxy/models
```

#### Run the proxy

```bash
python3 proxy/sweep_proxy.py
```

The proxy listens on:
- Unix socket: `$XDG_RUNTIME_DIR/sweep.sock` (or `/tmp/sweep-<uid>.sock`)
- HTTP: `http://127.0.0.1:5555`

#### Auto-start (systemd — Linux)

Copy and edit the template:

```bash
cp proxy/sweep-proxy.service ~/.config/systemd/user/sweep-proxy.service
# Edit WorkingDirectory and ExecStart to match your paths
systemctl --user enable --now sweep-proxy
```

#### Auto-start (LaunchAgent — macOS)

Copy and edit the template:

```bash
cp proxy/com.user.sweep-proxy.plist.template \
    ~/Library/LaunchAgents/com.user.sweep-proxy.plist
# Edit paths inside the plist to match your environment
launchctl load ~/Library/LaunchAgents/com.user.sweep-proxy.plist
```

## Configuration

All options and their defaults:

```lua
require("sweep").setup({
    enabled = true,
    log_level = "warn",  -- "debug" | "info" | "warn" | "error"

    keymaps = {
        accept         = "<Tab>",   -- accept FIM completion
        sweep          = "<Tab>",   -- accept edit prediction
        partial_accept = false,     -- accept word-by-word (key or false)
        reject         = false,     -- explicit reject (ESC always rejects)
        trigger        = false,     -- manual trigger (false = auto only)
    },

    ui = {
        completions = {
            addition_style = "highlight",  -- "highlight" | "inline"
            fg_opacity     = 1.0,
        },
        jump = {
            enabled      = false,   -- cursor-jump indicator
            symbol       = " ",
            text         = " TAB ",
            show_distance = true,
        },
    },

    behavior = {
        idle_completion_delay   = 50,    -- ms after typing stops
        text_change_debounce    = 50,    -- ms debounce for TextChangedI
        edit_prediction_delay   = 1000,  -- ms in normal mode before edit prediction
        ignore_filetypes        = { ... },
        ignore_gitignored       = false,
        enabled_modes           = { "i", "n" },
        min_line_length         = 0,
        max_file_lines          = 10000,
        hide_on_cursor_move     = true,
    },

    provider = {
        url                = "http://127.0.0.1:5555",
        mode               = "auto",   -- "auto" | "fim" | "edit"
        max_tokens         = 512,
        fim_max_tokens     = 128,
        max_fim_lines      = 4,
        temperature        = 0.0,
        top_p              = 1.0,
        top_k              = 50,
        repeat_penalty     = 1.0,
        completion_timeout = 5000,     -- ms
        auto_start         = true,
        proxy_script       = vim.fn.stdpath("config") .. "/scripts/sweep/sweep_proxy.py",
    },

    context = {
        window_radius      = 10,   -- lines above/below cursor (21 total)
        max_edit_history   = 6,    -- recent edit hunks in prompt
        max_context_files  = 3,    -- recently visited files for context
        context_file_lines = 60,   -- max lines per context file
        initial_file_lines = 300,  -- lines from original file in prompt
    },

    blink = {
        enabled    = true,
        ghost_text = true,
    },
})
```

## Commands

| Command         | Description                          |
|-----------------|--------------------------------------|
| `:SweepStatus`  | Show plugin status and cache stats   |
| `:SweepCache`   | Show cache statistics                |
| `:SweepReload`  | Reload plugin (preserves options)    |
| `:SweepHide`    | Hide current completion              |
| `:SweepToggle`  | Toggle enabled/disabled              |
| `:SweepEdit`    | Manually trigger edit prediction     |

## Highlight Groups

| Group               | Default link  | Purpose                      |
|---------------------|---------------|------------------------------|
| `SweepCompletion`   | `Comment`     | FIM ghost text               |
| `SweepAddition`     | `DiffAdd`     | Added lines in edit preview  |
| `SweepDeletion`     | `DiffDelete`  | Removed lines in edit preview|
| `SweepModification` | `DiffText`    | Changed lines in edit preview|
| `SweepJumpSymbol`   | `Identifier`  | Jump indicator symbol        |
| `SweepJumpText`     | (custom)      | Jump indicator label         |

## Lualine component

A minimal lualine component is available:

```lua
-- In your lualine config:
local sweep_component = require("sweep.lualine")

lualine.setup({
    sections = {
        lualine_x = { sweep_component },
    },
})
```

Shows `● SW` when the proxy is connected, `○ SW` when offline, and a spinner
while a request is in flight.

## Architecture

```
Neovim                         proxy/sweep_proxy.py
  │                                    │
  │── sweep.client (Unix socket) ─────▶│ llama-cpp-python
  │   (fallback: HTTP via curl)        │   sweep-next-edit model
  │                                    │
  │◀─ FIM text / updated lines ────────│
  │
  ├── sweep.ui       ghost text / virtual diff
  ├── sweep.buffer   context snapshot & diff
  ├── sweep.cache    LRU result cache
  ├── sweep.tracker  edit history & recent files
  └── sweep.config   defaults & highlight setup
```

## License

MIT — see [LICENSE](LICENSE).
