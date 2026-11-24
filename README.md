> **Warning:** This plugin was developed with the assistance of
> [Claude Code](https://claude.ai/claude-code). Use at your own risk.

# sweep.nvim

AI-powered code completions for Neovim using the
[sweep-next-edit](https://blog.sweep.dev/posts/oss-next-edit) model.
Inspired by [cursortab.nvim](https://github.com/postsinterthesis/cursortab.nvim).

Neovim talks directly to a local
[llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` over a Unix
domain socket. The plugin starts the server when needed and it stops itself
when idle.

## Why sweep.nvim

cursortab.nvim routes requests through a compiled Go server over HTTP before
they reach the model. sweep.nvim has no middleman:

```
cursortab:  Neovim → HTTP → Go server → HTTP → llama.cpp server → model
sweep.nvim: Neovim → Unix socket → llama-server → model
```

- **One shared server** — every open Neovim uses the same socket, so the model
  is loaded once. It exits after `provider.idle_timeout` seconds without
  requests and the next request starts it again.
- **Fast edits** — an edit prediction rewrites a window of code that is
  mostly unchanged, so the server drafts tokens from the prompt and verifies
  them in batches (`--spec-type ngram-simple`). On an M1 Pro a ~2k token edit
  prompt takes ~0.65 s instead of ~2.7 s, with identical output.
- **Two slots** — FIM and edit prompts each keep their KV cache, so switching
  between insert and normal mode does not re-read the prompt.
- **Streaming** — FIM output stops as soon as the line or block is done, and a
  superseded request is aborted on the server right away.
- **No extra runtime** — no Python, Go or Node: just `llama-server`.

## Features

- **FIM completions** — inline ghost text at the cursor in insert mode.
  The completion ends where the code does: mid-line it completes the rest of
  the line; on a line that opens a block it adds the block (deeper lines,
  `else`/`catch`, the closing `end`/`}`); on an empty line at the end of a
  block it continues the body until it dedents. `provider.max_fim_lines` is
  only a safety cap
- **Edit predictions** — next-edit suggestions in normal mode. Changes
  within a line are shown in place (replaced text is drawn over the old
  text, removed text is highlighted, added text is inserted) and new lines
  as virtual lines. Only changes within `provider.edit_proximity` lines of
  the cursor are shown, and output cut off by the token limit never turns
  into a deletion
- **Cancellation** — typing, moving to another line, switching mode or
  leaving the buffer aborts the request in flight, and stale responses are
  discarded
- **Blink.cmp integration** — hides ghost text while the completion menu is open
- **Cache** — avoids duplicate requests for the same context
- **Edit-history context** — recent diffs are fed to the model for better
  next-edit accuracy
- **Treesitter context** — enclosing scope and imports included in prompts

## Requirements

- Neovim 0.10+
- [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`
  (e.g. `brew install llama.cpp`, or a release build for your GPU)
- `curl` (used by the server wrapper to check for idleness)
- [YueScript](https://github.com/IppClub/YueScript) — only if rebuilding from source

## Installation

### 1. Install with lazy.nvim

Compiled Lua is included in the repo — no build step required:

```lua
{
    "c0r73x/sweep.nvim",
    event = { "VeryLazy", "InsertEnter", "BufReadPost", "BufNewFile" },
    config = function()
        require("sweep").setup({})
    end,
}
```

If you want to rebuild from the [YueScript](https://github.com/IppClub/YueScript)
sources, add `build = "make"`.

### 2. Model

By default `llama-server` downloads
[sweepai/sweep-next-edit-1.5B](https://huggingface.co/sweepai/sweep-next-edit-1.5B)
(`sweep-next-edit-1.5b.q8_0.v2.gguf`, ~1.6 GB) into its cache on first start
(`LLAMA_CACHE`, default `~/.cache/llama.cpp`). To use a local file instead:

```lua
require("sweep").setup({ provider = { model_path = "~/models/sweep-next-edit-1.5b.q8_0.v2.gguf" } })
```

### 3. Server

Nothing to do: the first completion request (or `VeryLazy`) starts
`bin/sweep-server`, which runs `llama-server` on
`$XDG_RUNTIME_DIR/sweep-server.sock` (or `/tmp/sweep-server-<uid>.sock`). A lock
next to the socket keeps it to one server per user. Its output goes to
`stdpath("log")/sweep-server.log`.

Extra `llama-server` arguments go in `provider.server_args`, and environment
variables in `provider.env` (e.g. `{ VK_DRIVER_FILES = "..." }` to pick a
Vulkan driver).

To run the server yourself, set `provider.url`; sweep.nvim then never starts
or stops it:

```bash
llama-server -hfr sweepai/sweep-next-edit-1.5B -hff sweep-next-edit-1.5b.q8_0.v2.gguf \
    -c 16384 -np 2 -ngl 99 -fa on --spec-type ngram-simple --cache-ram 512 \
    --port 8012
```

```lua
require("sweep").setup({ provider = { url = "http://127.0.0.1:8012" } })
```

## Configuration

All options and their defaults:

```lua
require("sweep").setup({
    enabled = true,
    log_level = "info",  -- "debug" | "info" | "warn" | "error"

    -- accept and sweep pass the key through when there is nothing to accept;
    -- <Esc> in normal mode rejects a visible prediction
    keymaps = {
        accept  = "<Tab>",   -- accept FIM completion (insert mode, or false)
        sweep   = "<Tab>",   -- accept edit prediction (normal mode, or false)
        trigger = false,     -- manual trigger (false = auto only)
    },

    behavior = {
        text_change_debounce  = 50,    -- ms debounce for TextChangedI
        edit_prediction_delay = 1000,  -- ms in normal mode before edit prediction
        ignore_filetypes      = { ... },
        enabled_modes         = { "i", "n" },
        max_file_lines        = 10000,
        hide_on_cursor_move   = true,
    },

    provider = {
        url                = nil,      -- nil = managed server on a Unix socket;
                                       -- "http://host:port" = external server
        mode               = "auto",   -- "auto" | "fim" | "edit"
        max_tokens         = 512,      -- min edit budget (grows with the window)
        fim_max_tokens     = 128,
        max_fim_lines      = 8,        -- safety cap, see FIM completions
        edit_proximity     = 8,        -- keep edits within this many lines of the cursor
        temperature        = 0.0,
        top_p              = 1.0,
        top_k              = 50,
        repeat_penalty     = 1.0,
        completion_timeout = 5000,     -- ms, FIM
        edit_timeout       = 15000,    -- ms, edit
        auto_start         = true,     -- start the managed server when needed
        server_cmd         = "llama-server",
        server_args        = {},       -- extra llama-server arguments
        model_path         = nil,      -- GGUF path (nil = download from Hugging Face)
        idle_timeout       = 900,      -- s without requests before the server exits (0 = never)
        start_timeout      = 300000,   -- ms to wait for start (first run downloads the model)
        socket             = nil,      -- socket path override
        env                = nil,      -- extra environment for llama-server
    },

    context = {
        window_radius      = 10,   -- lines above/below cursor (21 total)
        max_edit_history   = 6,    -- recent edit hunks in prompt
        restore_history    = true, -- seed a file's history from its undofile and git diff
        max_context_files  = 3,    -- recently visited files for context
        context_file_lines = 60,   -- max lines per context file
    },

    blink = {
        enabled = true,  -- hide ghost text while the blink.cmp menu is open
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
| `SweepAddition`     | `DiffAdd`     | Added text in edit preview   |
| `SweepDeletion`     | `DiffDelete`  | Removed text in edit preview |

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

Shows `● SW` when the server is reachable, `○ SW` when offline, and a spinner
while a request is in flight.

## Architecture

```
Neovim (any number)                 bin/sweep-server (one per user)
  │                                    │  lock, idle shutdown
  │── sweep.http (Unix socket) ───────▶│ llama-server /completion (streamed)
  │   POST /completion, SSE            │   sweep-next-edit model, 2 slots,
  │                                    │   prompt-lookup speculation
  │◀─ FIM text / rewritten window ─────│
  │
  ├── sweep.server       start / health of the managed server
  ├── sweep.client       prompts, streaming, cancellation
  ├── sweep.postprocess  FIM trimming, edit hunks near the cursor
  ├── sweep.ui           ghost text / virtual diff
  ├── sweep.buffer       context snapshot & diff
  ├── sweep.cache        LRU result cache
  ├── sweep.tracker      edit history & recent files
  └── sweep.config       defaults & highlight setup
```

## Troubleshooting

- `:SweepStatus` shows the server endpoint and whether it is reachable.
- The managed server logs to `stdpath("log")/sweep-server.log`
  (e.g. `~/.local/state/nvim/logs/sweep-server.log`).
- With `log_level = "debug"` every response logs its timings, e.g.
  `edit: prompt 485 tok 574ms, gen 94 tok 751ms, draft 47/144`.
- Slow completions usually mean `llama-server` runs on the CPU: use a build
  with GPU support (Metal on macOS via Homebrew, Vulkan or CUDA on Linux).

## Upgrading from the Python proxy

Earlier versions ran a Python proxy (`proxy/sweep_proxy.py`, llama-cpp-python)
on `/tmp/sweep-<uid>.sock` and port 5555. It is gone:

- Install `llama-server` (see [Requirements](#requirements)).
- Remove `provider.proxy_script` from your config. `provider.model_path` and
  `provider.env` still work and are passed to `llama-server`.
- A proxy that is still running exits on its own after 15 minutes idle, or
  kill it. Remove any systemd or launchd unit you installed for it.

## Development

Sources are [YueScript](https://github.com/IppClub/YueScript) in `yue/`; the
compiled Lua in `lua/` is committed. Rebuild with `make` and run the headless
tests:

```bash
make
for t in tests/*_test.lua; do nvim --headless --clean --cmd 'set rtp^=.' -l "$t"; done
```

## License

MIT — see [LICENSE](LICENSE).
