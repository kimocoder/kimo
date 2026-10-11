# kimo

**Unified Local & Remote Model Management & External CLI Hub**

`kimo` is an advanced command-line tool designed for managing Ollama instances across local and remote environments, inspecting GPU VRAM residency, tuning execution parameters, and routing external LLM agent CLIs (`claude`, `codex`, `qwen`, `grok`, `kimi`, `agy`, `hermes`, `openclaw`) directly into your self-hosted models.

---

## Features

- **Multi-Host Routing**: Seamlessly query or execute against local daemons and remote GPU servers over SSH tunnels or direct LAN connections.
- **VRAM Residency & Cleanup**: Real-time VRAM allocation tracking and instant eviction (`stop` / `unload`) to prevent CUDA OOM collisions.
- **Model Tuning & Persistence**: Bake per-model parameters (`num_ctx`, `num_batch`, `num_predict`, `temperature`, `num_gpu`) into runtime launches without modifying raw Modelfiles.
- **Streaming & Keepalive Pinning**: Durable model availability via background keepalive and pre-warming (`stream`).
- **External CLI Hub**: Automatic model mapping, endpoint rewriting, context-window patching, and wire-format translation for:
  - **Claude Code CLI** (`claude`)
  - **Codex CLI** (`codex`)
  - **Qwen Code CLI** (`qwen`)
  - **Grok Build CLI** (`grok`)
  - **Kimi Code CLI** (`kimi`)
  - **Google Antigravity CLI** (`agy`)
  - **Hermes / OpenClaw**

---

## Installation & Setup

Clone the repository and install using `make`:

```bash
# System-wide installation to /usr/local/bin/kimo (default)
sudo make install

# Or create a live development symlink:
sudo make link

# Verify syntax & execution sanity
make check
```

### Makefile Targets

| Target | Description |
|---|---|
| `make install` | Installs `kimo` to `$(DESTDIR)$(BINDIR)/kimo` (default `/usr/local/bin/kimo`) with executable permissions |
| `make uninstall` | Removes installed `kimo` binary from `$(DESTDIR)$(BINDIR)` |
| `make link` | Creates development symlink from repo directly to `$(BINDIR)/kimo` |
| `make unlink` | Removes the development symlink |
| `make check` | Validates bash syntax (`bash -n`) and executes basic CLI sanity tests |
| `make lint` | Runs `shellcheck` with error filtering on `kimo` |
| `make clean` | Removes temporary and backup files (`*~`, `*.tmp`, `*.bak`) |
| `make help` | Displays list of available make targets and options |

---

## Usage

```bash
kimo [options] <command> [arguments...]
```

### Global Options

| Option | Description |
|---|---|
| `--remote` | Connect to remote server (e.g., `http://127.0.0.1:11438` tunnel) |
| `--local` | Connect strictly to local daemon (`http://127.0.0.1:11434`) |
| `--host <address>` | Target specific Ollama host address (can be repeated for multi-host) |
| `--json` | Output responses in structured JSON format |
| `--no-color` | Disable colored terminal output |
| `-h, --help` | Show help and usage information |

---

## Command Reference

| Command | Description | Example |
|---|---|---|
| `check`, `ping` | Connectivity, latency, and health check for local and remote hosts | `kimo check` |
| `status`, `health` | Operational snapshot: tunnel, remote API, VRAM residency, timer | `kimo status` |
| `hosts` | Detailed table of reachable servers, versions, models, disk GB | `kimo hosts` |
| `list [filter]` | List all installed models across hosts, highlighting active VRAM | `kimo list nemotron` |
| `search <query>` | Search models across catalogs by name, parameters, capabilities | `kimo search 27b` |
| `ps` | Display models currently resident in GPU/CPU VRAM with memory stats | `kimo ps` |
| `stop [model\|all]` | Unload models from VRAM immediately (`keep_alive: 0`) | `kimo stop all` |
| `warm <model> [dur]`| Pre-warm model into GPU VRAM (`keep_alive: 24h` by default) | `kimo warm kalidroid-27b` |
| `info <model>` | Inspect detailed model metadata, quant, template, parameters | `kimo info kalidroid-27b` |
| `tune <model> [opts]`| Register per-model defaults (`--ctx`, `--batch`, `--temp`, etc.) | `kimo tune model --ctx 32768` |
| `bench [model]` | Benchmark TTFT, generation throughput (tok/s), and memory | `kimo bench kalidroid-27b` |
| `tag <src> <dst>` | Create model tag/alias on target host | `kimo tag model:33b model:latest` |
| `rm <model>` | Delete a model from target Ollama server | `kimo rm old-model` |
| `stream <model>` | Pin model for durable availability via keepalive daemon | `kimo stream model --status` |
| `run <model> [args]`| Run model directly with auto-routing to remote GPU | `kimo run kalidroid-27b` |
| `launch <cli> [opts]`| Launch external CLI with automatic Ollama routing | `kimo launch grok --model 27b` |

---

## External CLI Hub (`launch`)

`kimo launch` wraps popular coding and conversational CLIs to redirect traffic to your target Ollama instance:

```bash
# Launch Claude Code on remote model
kimo --remote launch claude --model nemotron3:33b

# Launch Kimi Code CLI with thinking model support
kimo --remote launch kimi --model kalidroid-27b:latest

# Launch Grok Build TUI with tuned context
kimo --remote launch grok --model kalidroid-27b:latest

# Launch Google Antigravity CLI via automatic Gemini-to-Ollama wire shim
kimo launch agy --model kalidroid-27b:latest
```

### Environment Overrides

- `OLLAMA_REMOTE_URL`: Override default remote URL (defaults to `http://127.0.0.1:11438`).
- `OLLAMA_LOCAL_URL`: Override default local URL (defaults to `http://127.0.0.1:11434`).
- `KIMO_KIMI_EFFORT` (or `OM_KIMI_EFFORT`): Default thinking effort level for Kimi Code CLI (`low`, `medium`, `high`, `xhigh`, `max`).
- `KIMO_KIMI_CAPABILITIES` (or `OM_KIMI_CAPABILITIES`): Override detected capabilities (`tool_use`, `thinking`, `image_in`).
- `KIMO_AGY_CLAIM_DIR`: Session claim directory for concurrent Antigravity sessions.
- `KIMO_GROK_CLAIM_DIR`: Session claim directory for concurrent Grok sessions.
- `KIMO_KIMI_CONFIG_LOCK`: File lock path for concurrent Kimi config updates.

---

## License

GNU General Public License v3.0 (GPL-3.0). See [LICENSE](LICENSE) for details.
