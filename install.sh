#!/bin/bash
# Build-from-source installer for af-pro-display (Antec Flux Pro Display).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Menimm/antec-flux-pro-display/main/install.sh | bash
# or, from a local checkout:
#   ./install.sh
#
# Safe to re-run: it rebuilds and reinstalls in place, and restarts the
# service so an upgrade actually takes effect. It never touches your
# config.toml.
set -euo pipefail

REPO_URL="https://github.com/Menimm/antec-flux-pro-display.git"
INSTALL_DIR=""

log() {
    echo
    echo "==> $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1
}

install_build_deps() {
    if ! require_command apt-get; then
        log "No apt-get found; skipping automatic dependency install."
        echo "    Make sure you have: a C compiler, pkg-config, and libusb-1.0 dev headers."
        return
    fi

    local missing=()
    require_command pkg-config || missing+=(pkg-config)
    require_command cc || require_command gcc || missing+=(build-essential)
    pkg-config --exists libusb-1.0 2>/dev/null || missing+=(libusb-1.0-0-dev)

    if [ ${#missing[@]} -eq 0 ]; then
        return
    fi

    log "Installing build dependencies: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}"
}

install_rust() {
    if require_command cargo; then
        return
    fi

    log "Rust not found; installing via rustup (user-local, no sudo)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
    export PATH="$HOME/.cargo/bin:$PATH"
}

clone_or_use_repo() {
    if [ -f "Cargo.toml" ] && grep -q '^name = "af-pro-display"' Cargo.toml 2>/dev/null; then
        INSTALL_DIR="$(pwd)"
        log "Using existing checkout at $INSTALL_DIR"
        return
    fi

    require_command git || {
        echo "git is required to clone the repository." >&2
        exit 1
    }

    INSTALL_DIR=$(mktemp -d)
    trap 'rm -rf "$INSTALL_DIR"' EXIT
    log "Cloning $REPO_URL..."
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
}

build() {
    log "Building release binary (first build can take a minute)..."
    (cd "$INSTALL_DIR" && cargo build --release)
}

install_files() {
    log "Installing binary, udev rule, and systemd unit (sudo)..."
    sudo install -m 0755 "$INSTALL_DIR/target/release/af-pro-display" /usr/bin/af-pro-display
    sudo install -m 0644 "$INSTALL_DIR/packaging/udev/99-af-pro-display.rules" \
        /lib/udev/rules.d/99-af-pro-display.rules
    sudo install -m 0644 "$INSTALL_DIR/packaging/systemd/af-pro-display.service" \
        /lib/systemd/system/af-pro-display.service

    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sudo systemctl daemon-reload
}

enable_and_start() {
    log "Enabling and (re)starting the service..."
    sudo systemctl enable af-pro-display.service
    sudo systemctl restart af-pro-display.service
}

main() {
    require_command sudo || {
        echo "sudo is required to install system files." >&2
        exit 1
    }

    install_build_deps
    install_rust
    clone_or_use_repo
    build
    install_files
    enable_and_start

    log "Installation complete!"
    echo "    Status:  sudo systemctl status af-pro-display"
    echo "    Logs:    journalctl -u af-pro-display -f"
    echo "    Config:  /root/.config/af-pro-display/config.toml (created on first run)"
    echo "    Apply a config change with: sudo systemctl restart af-pro-display"
}

main "$@"
