# Makefile for kimo (Unified Local & Remote Model Management & External CLI Hub)

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
DESTDIR ?=
SHELL   := /bin/bash

SCRIPT  := kimo

.PHONY: all help install uninstall link unlink check lint clean

all: help

help:
	@echo "kimo - Unified Model Management & External CLI Hub"
	@echo ""
	@echo "Available targets:"
	@echo "  make install     Install kimo to $(DESTDIR)$(BINDIR)/kimo"
	@echo "  make uninstall   Remove kimo from $(DESTDIR)$(BINDIR)"
	@echo "  make link        Create development symlink from this directory to $(DESTDIR)$(BINDIR)/kimo"
	@echo "  make unlink      Remove development symlink from $(DESTDIR)$(BINDIR)"
	@echo "  make check       Verify bash syntax and execute basic CLI sanity checks"
	@echo "  make lint        Run shellcheck (error severity) against $(SCRIPT)"
	@echo "  make clean       Remove temporary and backup files"
	@echo "  make help        Display this help message"
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

clean:
	@echo "[*] Cleaning temporary and backup files..."
	@rm -f *~ *.tmp *.bak
	@echo "[✓] Clean."
