# kimo

**Unified Local & Remote Model Management & External CLI Hub**

`kimo` is an advanced command-line tool designed for managing Ollama instances across local and remote environments, inspecting GPU VRAM residency, tuning execution parameters, and routing external LLM agent CLIs (`claude`, `codex`, `qwen`, `grok`, `kimi`, `agy`, `hermes`, `openclaw`) directly into your self-hosted models.

---

## Features

- **Multi-Host Routing**: Seamlessly query or execute against local daemons and remote GPU servers over SSH tunnels or direct LAN connections.
- **Real-Time VRAM Monitor**: Live interactive GPU/CPU residency monitor (`top` / `ps --watch`) tracking memory usage across cluster hosts.
- **Streaming Model Pulling**: Pull models directly from Ollama registries with live multi-layer download progress, layer digests, transfer speeds, and status updates (`pull`).
- **Model Tuning & Persistence**: Bake per-model parameters (`num_ctx`, `num_batch`, `num_predict`, `temperature`, `num_gpu`) into runtime launches without modifying raw Modelfiles.
- **Streaming & Keepalive Pinning**: Durable model availability via background keepalive and pre-warming (`stream`).
- **Shell Autocompletion**: Comprehensive tab completion scripts for Bash and Zsh covering commands, flags, CLIs, config options, and dynamic model names (`completion`).
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

# Install shell tab-completions for Bash and Zsh
sudo make install-completion

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
| `make install-completion` | Installs shell autocompletion for Bash (`/etc/bash_completion.d/kimo`) and Zsh |
| `make uninstall-completion`| Removes installed completion scripts |
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
| `-v, --version` | Show kimo version |
| `-h, --help` | Show help and usage information |

---

## Command Reference

| Command | Description | Example |
|---|---|---|
| `check`, `ping` | Connectivity, latency, and health check for local and remote hosts | `kimo check` |
| `doctor` | All-in-one health diagnostics (system, tunnel, daemons, CLIs) | `kimo doctor` |
| `config [subcmd]` | View and manage persistent defaults in `~/.config/kimo/config` | `kimo config set default_host remote` |
| `status`, `health` | Operational snapshot: tunnel, remote API, VRAM residency, timer | `kimo status` |
| `hosts` | Detailed table of reachable servers, versions, models, disk GB | `kimo hosts` |
| `list [filter]` | List all installed models across hosts, highlighting active VRAM | `kimo list nemotron` |
| `search <query>` | Search models across catalogs by name, parameters, capabilities | `kimo search 27b` |
| `ps` | Display models currently resident in GPU/CPU VRAM with memory stats | `kimo ps` |
| `top` | Interactive real-time VRAM residency monitor (`ps --watch`) | `kimo top` |
| `pull <model>` | Pull model from registry with live streaming progress & speed | `kimo pull llama3:latest` |
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
| `install [cli\|all]` | Install/update external CLIs (`kimi`, `claude`, `grok`, `codex`, `qwen`, etc.) | `kimo install kimi` |
| `update [cli\|all]`  | Check for updates for all installed CLIs, or apply updates | `kimo update` |
| `completion [sh]`    | Generate shell tab-completion script for Bash or Zsh | `kimo completion bash` |

---

## Health & Environment Diagnostics (`doctor`)

`kimo doctor` inspects your host dependencies, Ollama daemons, network tunnels, storage stores, and external CLI agents, producing a consolidated health scorecard with remediation steps:

```bash
# Run comprehensive diagnostic suite
kimo doctor
```

Checks performed:
1. **System Tools**: `curl`, `jq`, `python3`, `python3-tomlkit`, `node/npm`, and `systemd`.
2. **Configuration & Storage**: `~/.config/kimo/config`, `/var/lib/ollama/tunings.json`, and `/tmp` permissions.
3. **Local Daemon**: Reachability, version, API latency, installed catalog count, and active VRAM residency.
4. **Remote GPU & SSH Tunnel**: `ollama-remote-tunnel.service` state, tunnel endpoint latency, remote model catalog, and remote VRAM state.
5. **CLI Ecosystem**: Installation status, versions, and paths for all 9 supported CLIs.

---

## Persistent Configuration (`config`)

`kimo` supports persistent user configuration stored at `~/.config/kimo/config` (or `/etc/kimo/config`), eliminating the need to re-supply flags or export environment variables for common workflows:

```bash
# View active configuration values and their sources (file, env, default)
kimo config

# Route all commands to the remote server by default
kimo config set default_host remote

# Set default model used when launching CLIs or native runs
kimo config set default_model kalidroid-27b:latest

# Set default thinking effort for Kimi Code CLI
kimo config set kimi_effort xhigh

# Query a specific setting value
kimo config get default_host

# Remove a setting (revert to built-in default)
kimo config unset default_host

# Print the configuration file path
kimo config path
```

### Supported Configuration Keys

| Key | Description | Built-in Default |
|---|---|---|
| `default_host` | Default routing target (`local`, `remote`, or custom URL/address) | `auto (local+remote)` |
| `default_model` | Fallback model name for agent CLI launches | `kalidroid-27b:latest` |
| `remote_url` | Endpoint URL for the remote Ollama GPU host | `http://127.0.0.1:11438` |
| `local_url` | Endpoint URL for the local Ollama daemon | `http://127.0.0.1:11434` |
| `kimi_effort` | Default thinking effort for Kimi (`low`, `medium`, `high`, `xhigh`, `max`) | `default` |
| `no_color` | Disable ANSI terminal color codes (`true`/`false`) | `false` |

---

## CLI Package Manager (`install` & `update`)

`kimo` provides automated installation, updating, and health inspection for supported external LLM CLIs:

```bash
# Display installed CLI inventory, versions, and paths
kimo install

# Install specific CLIs
kimo install kimi       # Installs Kimi Code CLI (code.kimi.com)
kimo install claude     # Installs Claude Code CLI (claude.ai)
kimo install grok       # Installs Grok Build CLI (x.ai)
kimo install codex      # Installs Codex CLI (npm)
kimo install qwen       # Installs Qwen Code CLI (npm)
kimo install opencode   # Installs OpenCode CLI
kimo install openclaw   # Installs OpenClaw CLI
kimo install hermes     # Installs Hermes Agent CLI

# Install or update all supported CLIs at once
kimo install all
```

### Checking for Updates Across Present CLIs

Running `kimo update` without arguments inspects only the CLIs currently installed on your system, querying upstream registries and release channels to report whether updates are available:

```bash
# Check for updates across all installed CLIs (read-only audit)
kimo update

# Update a specific installed CLI
kimo update qwen

# Apply all available updates for currently installed CLIs
kimo update --apply     # or: kimo update all
```

---

## Real-Time VRAM & Model Monitor (`top` / `ps --watch`)

Monitor memory residency, active layers, and keepalive expiration in real time with an interactive top-like terminal dashboard:

```bash
# Launch real-time VRAM residency monitor (default 2s interval)
kimo top

# Specify custom refresh interval
kimo top -n 1

# Equivalent via ps watch flag
kimo ps --watch --interval 3
```

Features:
- Clean interactive redraws with terminal cursor preservation and graceful `Ctrl+C` handling.
- Live VRAM footprint (GB) and percentage of model resident in GPU VRAM vs CPU memory.
- Multi-host aggregation when queried across cluster nodes.

---

## Native Model Pulling with Live Streaming Progress (`pull`)

Pull models directly from Ollama registries with layer-by-layer progress bars, download speed (`MB/s`), and digest verification:

```bash
# Pull model to local Ollama daemon
kimo pull llama3:latest

# Pull model directly to remote GPU server
kimo --remote pull kalidroid-27b:latest

# Pull to an explicit cluster host
kimo --host 192.168.1.131:11434 pull qwen2.5:32b

# Insecure registry pull
kimo pull my-registry.internal/model:latest --insecure
```

---

## Shell Autocompletions (`completion`)

`kimo` includes complete tab-completion for Bash and Zsh. It autocompletes commands, global flags, external CLIs, persistent configuration keys, and dynamically suggests installed Ollama models:

```bash
# Load completion into active Bash session
source <(kimo completion bash)

# Install system-wide via Makefile (Bash + Zsh)
sudo make install-completion

# Manual system-wide installation for Bash
sudo kimo completion bash > /etc/bash_completion.d/kimo

# Zsh setup: save to your fpath directory
kimo completion zsh > ~/.zsh/completion/_kimo
```

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
