#!/usr/bin/env python3
"""
Sweep API Proxy with embedded llama-cpp-python
Serves both:
  - OpenAI-compatible /v1/completions HTTP endpoint
  - Unix domain socket for low-latency IPC with Neovim plugin
"""

import asyncio
import difflib
import fcntl
import json
import time
import uuid
import os
import signal
import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
import uvicorn
from llama_cpp import Llama

proxy = None
unix_server = None
server = None
lock_file = None
exit_code = 0

# The model loads in the background so the socket and port are bound
# immediately; requests wait on this event instead of failing meanwhile.
model_ready = None
model_error = None

# Exit after this many seconds with no connected clients and no requests
# (0 disables). Each Neovim keeps its socket open, so the proxy only exits
# once every editor is gone.
IDLE_TIMEOUT = float(os.environ.get("SWEEP_IDLE_TIMEOUT", "900"))
active_clients = set()
last_activity = time.monotonic()

# Special token constants for _strip_special_tokens
THINK_START = "\u6014\u601D"
THINK_END = "\u601D\u6029"
STRIP_TOKENS = ["\u60E9\u6029", "\u601D\u6029"]
BACKTICKS = "```"
CLOSE_S_TAG = "</s>"


class SweepProxy:
    def __init__(self, model_path, max_tokens=512, temperature=0.0):
        self.model_path = model_path
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.llm = None

    def load_model(self):
        print(f"Loading model: {self.model_path}")
        self.llm = Llama(
            model_path=self.model_path,
            n_ctx=8192,
            n_batch=1024,
            n_gpu_layers=-1,  # Offload all layers to GPU
            flash_attn=True,
            verbose=False,
            offload_kqv=True,  # Offload KQV cache to GPU
        )
        print("Model loaded successfully")

    def complete(self, prompt, max_tokens=None, temperature=None, stop=None,
                 top_p=None, top_k=None, repeat_penalty=None):
        """Run completion and return extracted text + metadata."""
        max_tokens = max_tokens or self.max_tokens
        # Ensure temperature is never exactly 0.0 - llama-cpp treats it as "default"
        if temperature is None:
            temperature = self.temperature
        if temperature == 0.0:
            temperature = 0.01  # Close enough to greedy, but explicitly set
        stop = stop or ["<|file_sep|>", "</s>"]

        kwargs = dict(
            max_tokens=max_tokens,
            temperature=temperature,
            stop=stop,
        )
        if top_p is not None and top_p < 1.0:
            kwargs["top_p"] = top_p
        if top_k is not None and top_k > 0:
            kwargs["top_k"] = top_k
        if repeat_penalty is not None and repeat_penalty != 1.0:
            kwargs["repeat_penalty"] = repeat_penalty

        result = self.llm(prompt, **kwargs)

        text = ""
        finish_reason = "stop"
        if result.get("choices"):
            text = result["choices"][0].get("text", "")
            finish_reason = result["choices"][0].get("finish_reason", "stop")

        return {
            "text": text,
            "finish_reason": finish_reason,
            "usage": result.get("usage", {}),
        }

    def _strip_special_tokens(self, text):
        """Strip special/think tokens from model output."""
        if not text:
            return ""
        if THINK_START in text and THINK_END in text:
            text = text[text.find(THINK_END) + len(THINK_END):]
        elif THINK_START in text:
            text = text[text.find(THINK_START) + len(THINK_START):]
        for tok in STRIP_TOKENS:
            text = text.replace(tok, "")
        text = text.replace(BACKTICKS, "")
        text = text.replace(CLOSE_S_TAG, "")
        return text.strip()

    def post_process_fim(self, text, finish_reason, suffix_lines=None, max_lines=21):
        """Post-process FIM completion response."""
        if not text:
            return ""
        text = self._strip_special_tokens(text)
        if finish_reason == "length" and "\n" in text:
            lines = text.rstrip("\n").rsplit("\n", 1)
            text = lines[0] if len(lines) > 1 else text
        lines = text.split("\n")
        if len(lines) > max_lines:
            lines = lines[:max_lines]
            text = "\n".join(lines)
        if suffix_lines:
            suffix_set = set(sl.strip() for sl in suffix_lines if sl.strip())
            for i in range(1, len(lines)):
                if lines[i].strip() in suffix_set:
                    lines = lines[:i]
                    break
            text = "\n".join(lines)
        return text.strip()

    def post_process_edit(self, text, finish_reason, current_lines=None, cursor_offset=0, proximity=8):
        """Post-process edit completion response."""
        if not text:
            return []
        text = self._strip_special_tokens(text)
        if finish_reason == "length" and "\n" in text:
            lines = text.rstrip("\n").rsplit("\n", 1)
            text = lines[0] if len(lines) > 1 else text
        text = text.strip()
        updated_lines = text.split("\n") if text else []
        if not current_lines:
            return updated_lines
        hunks = self._compute_diff(current_lines, updated_lines)
        if not hunks:
            # No diff - return the model output anyway for suggestions
            return updated_lines
        kept_hunks = []
        for hunk in hunks:
            hunk_pos = hunk.get("first_old_idx", hunk.get("first_new_idx", 0)) - 1
            distance = abs(hunk_pos - cursor_offset)
            if distance <= proximity:
                kept_hunks.append(hunk)
        if not kept_hunks:
            return []
        if len(kept_hunks) < len(hunks):
            updated_lines = self._apply_diff(current_lines, kept_hunks)
        return updated_lines

    def _compute_diff(self, old_lines, new_lines):
        """Compute diff between old and new lines using difflib."""
        if not old_lines and not new_lines:
            return []
        if old_lines == new_lines:
            return []
        matcher = difflib.SequenceMatcher(None, old_lines, new_lines)
        hunks = []
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                continue
            hunk = {
                "tag": tag,
                "first_old_idx": i1 + 1,
                "last_old_idx": i2,
                "first_new_idx": j1 + 1,
                "last_new_idx": j2,
                "old_lines": old_lines[i1:i2] if i2 > i1 else [],
                "new_lines": new_lines[j1:j2] if j2 > j1 else [],
            }
            hunks.append(hunk)
        return hunks

    def _apply_diff(self, old_lines, hunks):
        """Apply diff hunks to old lines."""
        if not hunks:
            return old_lines
        result = []
        old_idx = 0
        for hunk in sorted(hunks, key=lambda h: h["first_old_idx"]):
            start = hunk["first_old_idx"] - 1
            if start > old_idx:
                result.extend(old_lines[old_idx:start])
            result.extend(hunk["new_lines"])
            old_idx = hunk["last_old_idx"]
        if old_idx < len(old_lines):
            result.extend(old_lines[old_idx:])
        return result


# ---------------------------------------------------------------------------
# Unix domain socket server (low-latency IPC)
# Protocol: newline-delimited JSON
# ---------------------------------------------------------------------------

def get_socket_path():
    """Return the Unix socket path."""
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        return os.path.join(xdg, "sweep.sock")
    return f"/tmp/sweep-{os.getuid()}.sock"


def get_lock_path():
    """Return the single-instance lock path (next to the socket)."""
    return os.path.splitext(get_socket_path())[0] + ".lock"


def acquire_lock():
    """Take an exclusive lock held for the lifetime of the process.

    Stops a second proxy (e.g. from another Neovim started while the first
    proxy is still loading the model) from loading a second copy of the
    model and unlinking the first proxy's live socket.
    """
    global lock_file
    lock_file = open(get_lock_path(), "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_file.close()
        lock_file = None
        return False
    lock_file.write(str(os.getpid()))
    lock_file.flush()
    return True


def detach_output():
    """Send stdout/stderr to a log file.

    The proxy is spawned by whichever Neovim starts first but serves every
    instance and outlives its parent. Its stdout/stderr are pipes to that
    parent; once it exits, any print() (ours or uvicorn's) raises
    BrokenPipeError, which the request handlers then return as the error for
    every completion. Writing to a file instead makes output independent of
    the parent's lifetime.
    """
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    log_path = os.environ.get("SWEEP_LOG", os.path.join(state, "sweep-proxy.log"))
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    except OSError:
        fd = os.open(os.devnull, os.O_WRONLY)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)
    sys.stdout = os.fdopen(1, "w", buffering=1)
    sys.stderr = os.fdopen(2, "w", buffering=1)


def touch():
    global last_activity
    last_activity = time.monotonic()


def request_shutdown(code=0):
    global exit_code
    exit_code = code
    if server:
        server.should_exit = True


async def ensure_model():
    """Wait for the background model load; raise if it failed."""
    await model_ready.wait()
    if model_error:
        raise RuntimeError(f"Model failed to load: {model_error}")


async def load_model_task():
    global model_error
    try:
        await asyncio.to_thread(proxy.load_model)
    except Exception as e:
        model_error = str(e)
        print(f"ERROR: Failed to load model: {e}")
        request_shutdown(1)
    finally:
        model_ready.set()


async def idle_watcher():
    interval = min(30, max(IDLE_TIMEOUT / 2, 1))
    while True:
        await asyncio.sleep(interval)
        idle = time.monotonic() - last_activity
        if not active_clients and idle > IDLE_TIMEOUT:
            print(f"No clients for {int(idle)}s, shutting down")
            request_shutdown(0)
            return


async def handle_unix_client(reader, writer):
    """Handle a single client connection on the Unix socket."""
    active_clients.add(writer)
    touch()
    try:
        while True:
            data = await reader.readline()
            if not data:
                break
            touch()

            try:
                request = json.loads(data.decode("utf-8").strip())
            except json.JSONDecodeError:
                writer.write((json.dumps({"error": "Invalid JSON"}) + "\n").encode())
                await writer.drain()
                continue

            req_type = request.get("type", "completion")

            if req_type == "health":
                response = {
                    "status": "ok" if model_ready.is_set() else "loading",
                    "model": proxy.model_path if proxy else "not loaded",
                }
            elif req_type == "completion":
                try:
                    await ensure_model()
                    mode = request.get("mode", "fim")
                    print(f"Completion request (mode={mode}): temp={request.get('temperature')}")
                    result = await asyncio.to_thread(
                        proxy.complete,
                        prompt=request.get("prompt", ""),
                        max_tokens=request.get("max_tokens"),
                        temperature=request.get("temperature"),
                        stop=request.get("stop"),
                        top_p=request.get("top_p"),
                        top_k=request.get("top_k"),
                        repeat_penalty=request.get("repeat_penalty"),
                    )
                    # Apply mode-aware post-processing
                    text = result.get("text", "")
                    finish_reason = result.get("finish_reason", "stop")
                    if mode == "fim":
                        suffix_lines = request.get("suffix_lines")
                        max_lines = request.get("max_lines", 21)
                        text = proxy.post_process_fim(text, finish_reason, suffix_lines, max_lines)
                        response = {"text": text, "finish_reason": finish_reason}
                    elif mode == "edit":
                        current_lines = request.get("current_lines")
                        cursor_offset = request.get("cursor_offset", 0)
                        proximity = request.get("proximity", 8)
                        print(f"Edit mode: current_lines={len(current_lines) if current_lines else 0}, cursor_offset={cursor_offset}")
                        updated_lines = proxy.post_process_edit(text, finish_reason, current_lines, cursor_offset, proximity)
                        print(f"Edit result: {len(updated_lines)} lines")
                        response = {"updated_lines": updated_lines, "finish_reason": finish_reason}
                    else:
                        response = result
                except Exception as e:
                    response = {"error": str(e)}
            else:
                response = {"error": f"Unknown type: {req_type}"}

            writer.write((json.dumps(response) + "\n").encode())
            await writer.drain()
    except asyncio.CancelledError:
        pass
    except ConnectionResetError:
        pass
    except Exception as e:
        print(f"Unix client error: {e}")
    finally:
        active_clients.discard(writer)
        touch()
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def start_unix_server():
    """Start the Unix domain socket server alongside HTTP."""
    global unix_server
    sock_path = get_socket_path()

    # Remove stale socket
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    unix_server = await asyncio.start_unix_server(handle_unix_client, path=sock_path)
    os.chmod(sock_path, 0o600)
    print(f"Unix socket listening on {sock_path}")


def cleanup_socket():
    """Remove socket file on exit."""
    sock_path = get_socket_path()
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass


# ---------------------------------------------------------------------------
# HTTP endpoints
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app):
    global proxy, model_ready
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_model_path = os.path.join(
        script_dir, "models/sweep-next-edit-1.5b.q8_0.v2.gguf"
    )
    model_path = os.getenv("MODEL_PATH", default_model_path)

    if not os.path.exists(model_path):
        print(f"ERROR: Model file not found: {model_path}")
        print("Please download the model or set MODEL_PATH")
        sys.exit(1)

    proxy = SweepProxy(model_path)
    model_ready = asyncio.Event()

    # Bind the socket right away and load the model in the background, so
    # clients connect (and queue requests) instead of timing out, and a
    # second Neovim sees the proxy as running instead of spawning another.
    await start_unix_server()
    loader = asyncio.create_task(load_model_task())
    watcher = asyncio.create_task(idle_watcher()) if IDLE_TIMEOUT > 0 else None

    yield

    for task in (watcher, loader):
        if task:
            task.cancel()
    if unix_server:
        unix_server.close()
        # wait_closed() waits for every client (Python 3.12+), so close
        # them first or shutdown hangs while any Neovim is connected
        for writer in list(active_clients):
            writer.close()
        try:
            await asyncio.wait_for(unix_server.wait_closed(), 2)
        except (asyncio.TimeoutError, Exception):
            pass
    cleanup_socket()


app = FastAPI(lifespan=lifespan)


@app.post("/v1/completions")
async def completions(request: Request):
    try:
        touch()
        await ensure_model()
        req = await request.json()
        mode = req.get("mode", "fim")
        result = await asyncio.to_thread(
            proxy.complete,
            prompt=req.get("prompt", ""),
            max_tokens=req.get("max_tokens"),
            temperature=req.get("temperature"),
            stop=req.get("stop"),
            top_p=req.get("top_p"),
            top_k=req.get("top_k"),
            repeat_penalty=req.get("repeat_penalty"),
        )
        text = result.get("text", "")
        finish_reason = result.get("finish_reason", "stop")

        # Handle mode-specific post-processing (same as Unix socket)
        if mode == "fim":
            suffix_lines = req.get("suffix_lines")
            max_lines = req.get("max_lines", 21)
            text = proxy.post_process_fim(text, finish_reason, suffix_lines, max_lines)
            response_data = {"text": text, "finish_reason": finish_reason}
        elif mode == "edit":
            current_lines = req.get("current_lines")
            cursor_offset = req.get("cursor_offset", 0)
            proximity = req.get("proximity", 8)
            updated_lines = proxy.post_process_edit(text, finish_reason, current_lines, cursor_offset, proximity)
            response_data = {"updated_lines": updated_lines, "finish_reason": finish_reason}
        else:
            response_data = result

        return JSONResponse({
            "id": f"cmpl-{uuid.uuid4().hex[:24]}",
            "object": "text_completion",
            "created": int(time.time()),
            "model": proxy.model_path,
            **response_data,
            "usage": result.get("usage", {}),
        })
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
async def health():
    return {
        "status": "ok" if model_ready and model_ready.is_set() else "loading",
        "model": proxy.model_path if proxy else "not loaded",
        "socket": get_socket_path(),
    }


if __name__ == "__main__":
    import atexit

    # Only one proxy per user: the lock is held until this process exits,
    # so a proxy that is still loading the model counts as running too
    if not acquire_lock():
        print(f"Proxy already running (lock {get_lock_path()}), exiting...")
        sys.exit(0)

    detach_output()
    atexit.register(cleanup_socket)

    def handle_sigterm(signum, frame):
        cleanup_socket()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)

    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=5555))
    server.run()
    sys.exit(exit_code)
