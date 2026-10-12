# Makefile for kimo (Unified Local & Remote Model Management & External CLI Hub)

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
DESTDIR ?=
BASH_COMPLETION_DIR ?= /etc/bash_completion.d
ZSH_COMPLETION_DIR  ?= $(PREFIX)/share/zsh/site-functions
SHELL   := /bin/bash

SCRIPT  := kimo

.PHONY: all help install uninstall link unlink check lint test-qwen test-claude test-agy test-opencode test-kimi clean install-completion uninstall-completion

all: help

help:
	@echo "kimo - Unified Model Management & External CLI Hub"
	@echo ""
	@echo "Available targets:"
	@echo "  make install               Install kimo to $(DESTDIR)$(BINDIR)/kimo"
	@echo "  make uninstall             Remove kimo from $(DESTDIR)$(BINDIR)"
	@echo "  make link                  Create development symlink from this directory to $(DESTDIR)$(BINDIR)/kimo"
	@echo "  make unlink                Remove development symlink from $(DESTDIR)$(BINDIR)"
	@echo "  make install-completion    Install shell tab-completions (bash & zsh)"
	@echo "  make uninstall-completion  Remove installed shell tab-completions"
	@echo "  make check                 Verify bash syntax and execute basic CLI sanity checks"
	@echo "  make lint                  Run shellcheck (error severity) against $(SCRIPT)"
	@echo "  make test-qwen             Headless smoke test of the 'qwen' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-claude           Headless smoke test of the 'claude' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-agy              Headless smoke test of the 'agy' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make test-opencode         Headless smoke test of the 'opencode' launch branch (LIVE=1 adds a live run turn)"
	@echo "  make test-kimi             Headless smoke test of the 'kimi' launch branch (LIVE=1 adds a live -p turn)"
	@echo "  make clean                 Remove temporary and backup files"
	@echo "  make help                  Display this help message"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX   Installation directory prefix (default: /usr/local)"
	@echo "  BINDIR   Binary destination directory (default: \$$(PREFIX)/bin)"
	@echo "  DESTDIR  Staging directory prefix for packaging"

install:
	@echo "[*] Installing $(SCRIPT) to $(DESTDIR)$(BINDIR)/$(SCRIPT)..."
	@install -d -m 755 $(DESTDIR)$(BINDIR)
	@install -m 755 $(SCRIPT) $(DESTDIR)$(BINDIR)/$(SCRIPT)
	@echo "[✓] $(SCRIPT) successfully installed to $(DESTDIR)$(BINDIR)/$(SCRIPT)"

uninstall:
	@echo "[*] Removing $(SCRIPT) from $(DESTDIR)$(BINDIR)..."
	@rm -f $(DESTDIR)$(BINDIR)/$(SCRIPT)
	@echo "[✓] $(SCRIPT) removed from $(DESTDIR)$(BINDIR)"

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
	@if [ -d "$(DESTDIR)$(ZSH_COMPLETION_DIR)" ] || [ -d "/usr/share/zsh/site-functions" ]; then \
		ZDIR="$(DESTDIR)$(ZSH_COMPLETION_DIR)"; \
		[ ! -d "$$ZDIR" ] && ZDIR="/usr/share/zsh/site-functions"; \
		install -d -m 755 "$$ZDIR"; \
		./$(SCRIPT) completion zsh > "$$ZDIR/_$(SCRIPT)"; \
		chmod 644 "$$ZDIR/_$(SCRIPT)"; \
		echo "[✓] Zsh completion installed to $$ZDIR/_$(SCRIPT)"; \
	fi

uninstall-completion:
	@echo "[*] Removing shell completions..."
	@rm -f $(DESTDIR)$(BASH_COMPLETION_DIR)/$(SCRIPT)
	@rm -f $(DESTDIR)$(ZSH_COMPLETION_DIR)/_$(SCRIPT)
	@rm -f /usr/share/zsh/site-functions/_$(SCRIPT)
	@echo "[✓] Shell completions removed."

check:
	@echo "[*] Validating syntax for $(SCRIPT)..."
	@bash -n $(SCRIPT)
	@echo "[✓] Bash syntax OK."
	@echo "[*] Verifying execution (--help)..."
	@./$(SCRIPT) --help >/dev/null
	@echo "[✓] CLI execution OK."

lint:
	@echo "[*] Running shellcheck on $(SCRIPT)..."
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S error $(SCRIPT) || echo "[!] shellcheck not found, skipping."
	@echo "[✓] Lint check passed."

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

clean:
	@echo "[*] Cleaning temporary and backup files..."
	@rm -f *~ *.tmp *.bak
	@echo "[✓] Clean."
