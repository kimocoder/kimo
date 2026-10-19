# Makefile for kimo (Unified Local & Remote Model Management & External CLI Hub)

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
SHAREDIR ?= $(PREFIX)/share/kimo
DESTDIR ?=
BASH_COMPLETION_DIR ?= /etc/bash_completion.d
ZSH_COMPLETION_DIR  ?= $(PREFIX)/share/zsh/site-functions
# Fallback when $(ZSH_COMPLETION_DIR) does not exist (distribution zsh).
ZSH_VENDOR_COMPLETION_DIR ?= /usr/share/zsh/site-functions
SHELL   := /bin/bash
export KIMO_NO_AUTOSCAN := 1

SCRIPT  := kimo

.PHONY: all help install uninstall link unlink check lint test test-check test-web test-qwen test-claude test-agy test-opencode test-kimi test-codex test-codex-auth test-dashscope test-cursor test-grok test-gh test-thinking-tools test-gemini test-scan test-quota test-tunnel test-config-validate test-rotate-token test-jq-guard test-pull-json test-backup-prune test-web-url-esc test-gh-guard test-model-args test-launch-contract test-sync test-shim test-install-packages test-config-rules test-hardening test-extra clean install-completion uninstall-completion update update-% test-host-url test-web-bridge test-option-values test-update-lookup test-codex-update test-qwen-update test-cli-health

all: help

help:
	@echo "kimo - Unified Model Management & External CLI Hub"
	@echo ""
	@echo "Available targets:"
	@echo "  make install               Install kimo to $(DESTDIR)$(BINDIR)/kimo"
	@echo "  make uninstall             Remove kimo from $(DESTDIR)$(BINDIR)"
	@echo "  make link                  Create development symlink from this directory to $(DESTDIR)$(BINDIR)/kimo"
	@echo "  make unlink                Remove development symlink from $(DESTDIR)$(BINDIR)"
	@echo "  make update [cli]          Update external CLIs (e.g. make update opencode)"
	@echo "  make install-completion    Install shell tab-completions (bash & zsh)"
	@echo "  make uninstall-completion  Remove installed shell tab-completions"
	@echo "  make check                 Verify bash syntax and execute basic CLI sanity checks"
	@echo "  make lint                  Run shellcheck (warning severity) and ruff against scripts and tests"
	@echo "  make test                  Run all headless smoke tests (hermetic: see tests/lib/harness.sh)"
	@echo "  make test-check            Headless smoke test of check & ping connectivity"
	@echo "  make test-web              Headless smoke test of WebBridge and web research"
	@echo "  make test-qwen             Headless smoke test of the 'qwen' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-claude           Headless smoke test of the 'claude' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-agy              Headless smoke test of the 'agy' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-opencode         Headless smoke test of the 'opencode' launch branch (LIVE=1 adds a live run turn)"
	@echo "  make test-kimi             Headless smoke test of the 'kimi' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-abliteration     Headless smoke test of the abliteration.ai cloud provider ('launch --provider abliteration')"
	@echo "  make test-codex            Headless smoke test of the 'codex' launch branch (LIVE=1 adds a live exec turn)"
	@echo "  make test-codex-auth       Codex native forwarding, authentication and Kimi model sync"
	@echo "  make test-dashscope        Headless smoke test of the DashScope cloud provider ('launch --provider dashscope')"
	@echo "  make test-cursor           Headless smoke test of the 'cursor' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-grok             Headless smoke test of the 'grok' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-gh               Headless smoke test of GitHub CLI ('gh') integration (LIVE=1 adds a live turn)"
	@echo "  make test-thinking-tools   Checks thinking/tools capability mapping, overrides, and kimi env-channel wiring"
	@echo "  make test-gemini           Headless smoke test of 'gemini' token model sync into Kimi Code"
	@echo "  make test-scan             Headless smoke test of network scanning, discovery, and first-run wizard"
	@echo "  make test-quota            Headless smoke test of unified quota & usage dashboard"
	@echo "  make test-tunnel           Headless smoke test of remote Ollama SSH tunnel management"
	@echo "  make test-config-validate  Headless smoke test of persistent configuration validation"
	@echo "  make test-rotate-token     Headless smoke test of public API token rotation"
	@echo "  make test-jq-guard         Headless smoke test of jq prerequisite guarding"
	@echo "  make test-pull-json        Headless smoke test of pull --json streaming output"
	@echo "  make test-backup-prune     Headless smoke test of config backup pruning"
	@echo "  make test-web-url-esc      Headless smoke test of WebBridge URL escaping"
	@echo "  make test-gh-guard         Headless smoke test of GitHub CLI management guard"
	@echo "  make test-model-args       Model-command option guards, safe rm, secrets and lock paths"
	@echo "  make test-config-rules     Shared config parser/rules, precedence, color and JSON escaping"
	@echo "  make test-hardening        Installer download-then-run, request timeouts, symlinked shim lookup"
	@echo "  make test-launch-contract  Launch credential scrub, argument passthrough (--) and opt-in eviction"
	@echo "  make test-sync             Blob-level model sync between hosts, verified by weights/digest"
	@echo "  make test-shim             Gemini shim contract: paths, streaming, tools, images, errors"
	@echo "  make test-install-packages Installers use only official npm/PyPI packages (no look-alike fallbacks)"
	@echo "  make test-host-url           Host URL normalization (https, proxied paths, IPv6)"
	@echo "  make test-web-bridge         kimo web against fake WebBridge daemons (errors, quoting, --results)"
	@echo "  make test-option-values      Missing option values fail loudly instead of exiting silently"
	@echo "  make clean                 Remove temporary and backup files"
	@echo "  make help                  Display this help message"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX   Installation directory prefix (default: /usr/local)"
	@echo "  BINDIR   Binary destination directory (default: \$$(PREFIX)/bin)"
	@echo "  SHAREDIR Shared assets directory (default: \$$(PREFIX)/share/kimo)"
	@echo "  DESTDIR  Staging directory prefix for packaging"

install:
	@echo "[*] Installing $(SCRIPT) to $(DESTDIR)$(BINDIR)/$(SCRIPT)..."
	@install -d -m 755 $(DESTDIR)$(BINDIR)
	@install -m 755 $(SCRIPT) $(DESTDIR)$(BINDIR)/$(SCRIPT)
	@echo "[✓] $(SCRIPT) successfully installed to $(DESTDIR)$(BINDIR)/$(SCRIPT)"
	@if [ -f "lib/ollama-gemini-shim.py" ]; then \
		install -d -m 755 $(DESTDIR)$(SHAREDIR); \
		install -m 755 lib/ollama-gemini-shim.py $(DESTDIR)$(SHAREDIR)/ollama-gemini-shim.py; \
		echo "[✓] ollama-gemini-shim.py installed to $(DESTDIR)$(SHAREDIR)/ollama-gemini-shim.py"; \
	fi
	@install -d -m 755 $(DESTDIR)$(SHAREDIR)
	@install -m 644 lib/kimo-quota.py $(DESTDIR)$(SHAREDIR)/kimo-quota.py
	@install -m 644 lib/kimo-codex.py $(DESTDIR)$(SHAREDIR)/kimo-codex.py

uninstall: uninstall-completion
	@echo "[*] Removing $(SCRIPT) from $(DESTDIR)$(BINDIR)..."
	@rm -f $(DESTDIR)$(BINDIR)/$(SCRIPT)
	@rm -f $(DESTDIR)$(SHAREDIR)/ollama-gemini-shim.py
	@rm -f $(DESTDIR)$(SHAREDIR)/kimo-quota.py
	@rm -f $(DESTDIR)$(SHAREDIR)/kimo-codex.py
	@rmdir $(DESTDIR)$(SHAREDIR) 2>/dev/null || true
	@echo "[✓] $(SCRIPT) and assets removed from $(DESTDIR)$(PREFIX)"

link:
	@echo "[*] Linking $(CURDIR)/$(SCRIPT) -> $(DESTDIR)$(BINDIR)/$(SCRIPT)..."
	@install -d -m 755 $(DESTDIR)$(BINDIR)
	@ln -sf $(CURDIR)/$(SCRIPT) $(DESTDIR)$(BINDIR)/$(SCRIPT)
	@echo "[✓] Development symlink created: $(DESTDIR)$(BINDIR)/$(SCRIPT) -> $(CURDIR)/$(SCRIPT)"

unlink:
	@echo "[*] Removing symlink $(DESTDIR)$(BINDIR)/$(SCRIPT)..."
	@if [ -L "$(DESTDIR)$(BINDIR)/$(SCRIPT)" ]; then \
		rm -f "$(DESTDIR)$(BINDIR)/$(SCRIPT)"; \
		echo "[✓] Symlink removed."; \
	else \
		echo "[!] $(DESTDIR)$(BINDIR)/$(SCRIPT) is not a symlink, skipping."; \
	fi

install-completion:
	@echo "[*] Installing shell completions..."
	@install -d -m 755 $(DESTDIR)$(BASH_COMPLETION_DIR)
	@./$(SCRIPT) completion bash > $(DESTDIR)$(BASH_COMPLETION_DIR)/$(SCRIPT)
	@chmod 644 $(DESTDIR)$(BASH_COMPLETION_DIR)/$(SCRIPT)
	@echo "[✓] Bash completion installed to $(DESTDIR)$(BASH_COMPLETION_DIR)/$(SCRIPT)"
	@if [ -d "$(DESTDIR)$(ZSH_COMPLETION_DIR)" ] || [ -d "$(DESTDIR)$(ZSH_VENDOR_COMPLETION_DIR)" ]; then \
		ZDIR="$(DESTDIR)$(ZSH_COMPLETION_DIR)"; \
		[ ! -d "$$ZDIR" ] && ZDIR="$(DESTDIR)$(ZSH_VENDOR_COMPLETION_DIR)"; \
		install -d -m 755 "$$ZDIR"; \
		./$(SCRIPT) completion zsh > "$$ZDIR/_$(SCRIPT)"; \
		chmod 644 "$$ZDIR/_$(SCRIPT)"; \
		echo "[✓] Zsh completion installed to $$ZDIR/_$(SCRIPT)"; \
	fi

uninstall-completion:
	@echo "[*] Removing shell completions..."
	@rm -f $(DESTDIR)$(BASH_COMPLETION_DIR)/$(SCRIPT)
	@rm -f $(DESTDIR)$(ZSH_COMPLETION_DIR)/_$(SCRIPT)
	@rm -f $(DESTDIR)$(ZSH_VENDOR_COMPLETION_DIR)/_$(SCRIPT)
	@echo "[✓] Shell completions removed."

update:
	@./$(SCRIPT) update $(filter-out update,$(MAKECMDGOALS))

update-%:
	@./$(SCRIPT) update $*

# Dummy targets for CLI names when passed as goals to 'make update <cli>'
claude codex qwen grok kimi cursor opencode cyberstrike agy openclaw hermes gh all:
	@:

check:
	@echo "[*] Validating syntax for $(SCRIPT), tests and lib/..."
	@for f in $(SCRIPT) tests/*.sh tests/lib/*.sh; do bash -n "$$f" || exit 1; done
	@for f in lib/*.py tests/*.py tests/lib/*.py; do \
		python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$$f" || exit 1; \
	done
	@echo "[✓] Bash and Python syntax OK."
	@echo "[*] Verifying execution (--help)..."
	@./$(SCRIPT) --help >/dev/null
	@echo "[✓] CLI execution OK."

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "[!] shellcheck is required for 'make lint' (apt-get install shellcheck)." >&2; exit 1; }
	@command -v ruff >/dev/null 2>&1 || { echo "[!] ruff is required for 'make lint' (pipx install ruff)." >&2; exit 1; }
	@echo "[*] Running shellcheck (warning severity) on $(SCRIPT) and tests..."
	@shellcheck -x -S warning $(SCRIPT) tests/*.sh tests/lib/*.sh
	@echo "[*] Running ruff on lib/ and tests/..."
	@ruff check --no-cache lib tests
	@echo "[✓] Lint check passed."

test: test-check test-web test-scan test-gh test-thinking-tools test-gemini test-qwen test-claude test-agy test-opencode test-kimi test-abliteration test-codex test-codex-auth test-dashscope test-cursor test-grok test-quota test-tunnel test-config-validate test-rotate-token test-jq-guard test-pull-json test-backup-prune test-web-url-esc test-gh-guard test-model-args test-launch-contract test-sync test-shim test-install-packages test-config-rules test-hardening test-host-url test-web-bridge test-option-values test-update-lookup test-codex-update test-qwen-update test-cli-health
	@echo ""
	@echo "[✓] All test suites completed successfully."

test-abliteration:
	@echo "[*] Running abliteration.ai cloud-provider smoke tests..."
	@tests/abliteration-smoke.sh

test-dashscope:
	@echo "[*] Running DashScope cloud-provider smoke tests..."
	@tests/dashscope-smoke.sh

test-check:
	@echo "[*] Running check and ping connectivity smoke tests..."
	@tests/check-smoke.sh

test-web:
	@echo "[*] Running WebBridge and web research smoke tests..."
	@tests/web-smoke.sh

test-qwen:
	@echo "[*] Running 'qwen' launch smoke tests..."
	@tests/qwen-smoke.sh $(if $(LIVE),--live,)

test-claude:
	@echo "[*] Running 'claude' launch smoke tests..."
	@tests/claude-smoke.sh $(if $(LIVE),--live,)

test-agy:
	@echo "[*] Running 'agy' launch smoke tests..."
	@tests/agy-smoke.sh $(if $(LIVE),--live,)

test-opencode:
	@echo "[*] Running 'opencode' launch smoke tests..."
	@tests/opencode-smoke.sh $(if $(LIVE),--live,)

test-kimi:
	@echo "[*] Running 'kimi' launch smoke tests..."
	@tests/kimi-smoke.sh $(if $(LIVE),--live,)

test-codex:
	@echo "[*] Running 'codex' launch smoke tests..."
	@tests/codex-smoke.sh $(if $(LIVE),--live,)

test-codex-auth:
	@echo "[*] Running 'codex' authentication and launch integration tests..."
	@tests/codex_auth_test.sh

test-cursor:
	@echo "[*] Running 'cursor' launch smoke tests..."
	@tests/cursor-smoke.sh $(if $(LIVE),--live,)

test-grok:
	@echo "[*] Running 'grok' launch smoke tests..."
	@tests/grok-smoke.sh $(if $(LIVE),--live,)

test-gh:
	@echo "[*] Running 'gh' GitHub CLI smoke tests..."
	@tests/gh-smoke.sh $(if $(LIVE),--live,)

test-thinking-tools:
	@echo "[*] Running thinking/tools capability checks..."
	@tests/thinking-tools-smoke.sh

test-gemini:
	@echo "[*] Running 'gemini' model sync smoke tests..."
	@tests/gemini-smoke.sh

test-scan:
	@echo "[*] Running scan and discovery smoke tests..."
	@tests/scan-smoke.sh

test-quota:
	@echo "[*] Running quota dashboard smoke tests..."
	@tests/quota-smoke.sh
	@tests/lib/run-hermetic.sh python3 tests/quota_adapters_test.py

test-tunnel:
	@echo "[*] Running tunnel management smoke tests..."
	@tests/tunnel-smoke.sh

test-config-validate:
	@echo "[*] Running config validation smoke tests..."
	@tests/config_validate_test.sh

test-rotate-token:
	@echo "[*] Running rotate-token smoke tests..."
	@tests/rotate_token_test.sh

test-jq-guard:
	@echo "[*] Running jq guard smoke tests..."
	@tests/jq_guard_test.sh

test-pull-json:
	@echo "[*] Running pull --json smoke tests..."
	@tests/pull_json_test.sh

test-backup-prune:
	@echo "[*] Running backup pruning smoke tests..."
	@tests/backup_prune_test.sh

test-web-url-esc:
	@echo "[*] Running web URL escaping smoke tests..."
	@tests/web_url_esc_test.sh

test-gh-guard:
	@echo "[*] Running gh management guard smoke tests..."
	@tests/gh_guard_test.sh

test-model-args:
	@echo "[*] Running model-command argument and safety tests..."
	@tests/model_args_test.sh

test-config-rules:
	@echo "[*] Running config parser, rules and precedence tests..."
	@tests/config_rules_test.sh

test-hardening:
	@echo "[*] Running installer, timeout and shim-lookup hardening tests..."
	@tests/hardening_test.sh

test-launch-contract:
	@echo "[*] Running launch contract tests..."
	@tests/launch_contract_test.sh

test-sync:
	@echo "[*] Running model sync tests..."
	@tests/sync_test.sh

test-shim:
	@echo "[*] Running Gemini shim contract tests..."
	@tests/lib/run-hermetic.sh python3 tests/gemini_shim_test.py

test-install-packages:
	@echo "[*] Running installer package guard tests..."
	@tests/install_packages_test.sh

clean:
	@echo "[*] Cleaning temporary and backup files..."
	@rm -f *~ *.tmp *.bak
	@echo "[✓] Clean."

test-extra: test-config-validate test-rotate-token test-jq-guard test-pull-json test-backup-prune test-web-url-esc test-gh-guard test-model-args test-launch-contract test-sync test-shim test-install-packages test-config-rules test-hardening test-host-url test-web-bridge test-option-values test-update-lookup test-codex-update test-qwen-update test-cli-health

test-host-url:
	@echo "[*] Running host-url tests..."
	@tests/host_url_test.sh

test-web-bridge:
	@echo "[*] Running web-bridge tests..."
	@tests/web_bridge_test.sh

test-option-values:
	@echo "[*] Running option-values tests..."
	@tests/option_values_test.sh

test-update-lookup:
	@echo "[*] Running update latest-version lookup tests..."
	@tests/update_lookup_test.sh

test-codex-update:
	@echo "[*] Running codex update routing tests..."
	@tests/codex_update_test.sh

test-qwen-update:
	@echo "[*] Running qwen update routing tests..."
	@tests/qwen_update_test.sh

test-cli-health:
	@echo "[*] Running post-install CLI health tests..."
	@tests/cli_health_test.sh
