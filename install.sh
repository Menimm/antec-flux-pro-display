#!/bin/bash
# Interactive installer for af-pro-display (Antec Flux Pro Display).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Menimm/antec-flux-pro-display/main/install.sh | bash
# or, from a local checkout:
#   ./install.sh
#
# You can run this as your normal user (it calls sudo itself only for the
# few steps that need it) or with sudo/as root -- both work.
#
# It builds from source (installing Rust and build deps if needed), checks
# for the display over USB, probes your CPU/GPUs, walks you through a
# couple of simple questions, writes the config file, and starts the
# service. Just keep pressing Enter to accept the sensible default at
# every step.
#
# Safe to re-run any time (e.g. after `git pull`): it rebuilds, reinstalls,
# and restarts the service. It asks before touching an existing config.
set -euo pipefail

REPO_URL="https://github.com/Menimm/antec-flux-pro-display.git"
INSTALL_DIR=""
SERVICE_USER="root"
CONFIG_PATH="/root/.config/af-pro-display/config.toml"

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

log() {
    echo
    echo "==> $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1
}

# Run a command as root: uses sudo if we're not already root, otherwise
# just runs it directly (so this works whether the script itself is
# invoked normally or via `sudo ./install.sh` / as the root user).
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

have_tty() {
    { : </dev/tty; } 2>/dev/null
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# ask "question text [default]: " "default" resultvar
ask() {
    local prompt="$1" default="$2" __resultvar="$3" __reply=""
    if have_tty; then
        read -r -p "$prompt" __reply </dev/tty || __reply=""
    fi
    if [ -z "$__reply" ]; then
        __reply="$default"
    fi
    printf -v "$__resultvar" '%s' "$__reply"
}

# ask_number "question [default]: " "default" resultvar
ask_number() {
    local prompt="$1" default="$2" __resultvar="$3" __num
    ask "$prompt" "$default" __num
    if ! is_uint "$__num"; then
        echo "    (\"$__num\" isn't a plain number, using $default)"
        __num="$default"
    fi
    printf -v "$__resultvar" '%s' "$__num"
}

# ---------------------------------------------------------------------------
# USB device check
# ---------------------------------------------------------------------------

check_display_present() {
    if ! require_command lsusb; then
        log "Installing usbutils so I can check for the display..."
        if require_command apt-get; then
            as_root apt-get update -qq
            as_root apt-get install -y usbutils
        else
            echo "    No apt-get found -- please install usbutils (for lsusb) yourself"
            echo "    if you want this check; continuing without it."
        fi
    fi

    if require_command lsusb && lsusb -d 2022:0522 >/dev/null 2>&1; then
        log "Found the Antec Flux Pro display on USB (2022:0522). Good to go."
        return
    fi

    log "Heads up: I couldn't see the Antec Flux Pro display on USB (2022:0522)."
    echo "    Double check it's plugged into an internal USB header on your"
    echo "    motherboard. That's fine for now -- I'll set everything up"
    echo "    anyway, and it'll start working as soon as it's connected."
}

# ---------------------------------------------------------------------------
# build + install
# ---------------------------------------------------------------------------

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
    as_root apt-get update -qq
    as_root apt-get install -y "${missing[@]}"
}

install_rust() {
    if require_command cargo; then
        return
    fi

    log "Rust not found; installing via rustup (installs for the current user, no sudo)..."
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
    log "Downloading af-pro-display..."
    git clone --depth 1 --quiet "$REPO_URL" "$INSTALL_DIR"
}

build() {
    log "Building (first time can take a minute or two)..."
    (cd "$INSTALL_DIR" && cargo build --release --quiet)
}

install_files() {
    log "Installing binary, udev rule, and systemd unit..."
    as_root install -m 0755 "$INSTALL_DIR/target/release/af-pro-display" /usr/bin/af-pro-display
    as_root install -m 0644 "$INSTALL_DIR/packaging/udev/99-af-pro-display.rules" \
        /lib/udev/rules.d/99-af-pro-display.rules
    as_root install -m 0644 "$INSTALL_DIR/packaging/systemd/af-pro-display.service" \
        /lib/systemd/system/af-pro-display.service

    as_root udevadm control --reload-rules
    as_root udevadm trigger
    as_root systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# who should the service run as?
# ---------------------------------------------------------------------------

# Guess the "real" unprivileged user, even if this script itself was run
# with sudo or as root.
guess_target_user() {
    if [ "$(id -u)" -eq 0 ]; then
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            echo "$SUDO_USER"
        else
            logname 2>/dev/null || echo ""
        fi
    else
        id -un
    fi
}

choose_service_user() {
    local suggested
    suggested="$(guess_target_user)"

    log "Security: who should run the background service?"
    echo "  It only needs to read sensor files and talk to one USB device --"
    echo "  it doesn't need root. The udev rule already grants that USB"
    echo "  device to members of the 'plugdev' group."
    echo
    if [ -n "$suggested" ] && [ "$suggested" != "root" ]; then
        echo "  1) Run as '$suggested' (recommended -- more secure)"
    else
        echo "  1) Run as an unprivileged user I specify (recommended -- more secure)"
    fi
    echo "  2) Run as root (matches upstream's original behavior)"
    local choice
    ask "Enter 1-2 [1]: " "1" choice

    if [ "$choice" = "2" ]; then
        SERVICE_USER="root"
        CONFIG_PATH="/root/.config/af-pro-display/config.toml"
        return
    fi

    if [ -z "$suggested" ] || [ "$suggested" = "root" ]; then
        ask "Which username should it run as?: " "root" suggested
    fi
    SERVICE_USER="$suggested"

    if [ "$SERVICE_USER" = "root" ]; then
        CONFIG_PATH="/root/.config/af-pro-display/config.toml"
        return
    fi

    local home
    home="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
    if [ -z "$home" ]; then
        echo "    (no such user '$SERVICE_USER', falling back to root)"
        SERVICE_USER="root"
        CONFIG_PATH="/root/.config/af-pro-display/config.toml"
        return
    fi

    CONFIG_PATH="$home/.config/af-pro-display/config.toml"
    log "Adding $SERVICE_USER to the 'plugdev' group for USB access..."
    as_root groupadd -f plugdev
    as_root usermod -aG plugdev "$SERVICE_USER"
}

# Write (or remove) a systemd drop-in so the shipped unit file itself never
# needs editing, whichever user we end up running as.
apply_service_user() {
    local override_dir="/etc/systemd/system/af-pro-display.service.d"
    if [ "$SERVICE_USER" = "root" ]; then
        as_root rm -f "$override_dir/override.conf"
    else
        as_root mkdir -p "$override_dir"
        printf '[Service]\nUser=%s\nGroup=%s\n' "$SERVICE_USER" "$SERVICE_USER" \
            | as_root tee "$override_dir/override.conf" >/dev/null
    fi
    as_root systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# sensor detection
# ---------------------------------------------------------------------------

CPU_DESCRIPTION="CPU temperature (auto-detected)"

detect_cpu() {
    for hwmon in /sys/class/hwmon/hwmon*; do
        if [ -r "$hwmon/temp1_label" ] && [ "$(cat "$hwmon/temp1_label" 2>/dev/null)" = "Tctl" ]; then
            CPU_DESCRIPTION="CPU temperature (AMD Tctl sensor)"
            return
        fi
    done
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        CPU_DESCRIPTION="CPU temperature (thermal_zone0)"
        return
    fi
    CPU_DESCRIPTION="CPU temperature (couldn't auto-detect a sensor -- may show blank)"
}

GPU_NAMES=()

detect_gpus() {
    if ! require_command nvidia-smi; then
        return
    fi
    while IFS=',' read -r idx name; do
        idx="$(echo "$idx" | xargs)"
        name="$(echo "$name" | xargs)"
        [ -n "$idx" ] && GPU_NAMES[idx]="$name"
    done < <(nvidia-smi --query-gpu=index,name --format=csv,noheader 2>/dev/null)
}

# ---------------------------------------------------------------------------
# the wizard
# ---------------------------------------------------------------------------

SLOT_1="cpu"
SLOT_2="cpu"
FLICKER_INTERVAL_MS="3000"
FLICKER_RESET_PAUSE_MS="0"

configure() {
    if as_root test -f "$CONFIG_PATH" 2>/dev/null; then
        local keep
        ask "A config already exists at $CONFIG_PATH. Keep it as-is? [Y/n]: " "y" keep
        if [[ "$keep" =~ ^[Yy] ]]; then
            log "Keeping your existing config."
            return
        fi
    fi

    log "Let's set up your display."

    detect_cpu
    detect_gpus
    local gpu_count=${#GPU_NAMES[@]}

    echo "Found:"
    echo "  - $CPU_DESCRIPTION"
    if [ "$gpu_count" -eq 0 ]; then
        echo "  - No NVIDIA GPU detected (only NVIDIA GPUs are supported right now)"
    else
        local i
        for i in "${!GPU_NAMES[@]}"; do
            echo "  - GPU $i: ${GPU_NAMES[$i]}"
        done
    fi

    if [ "$gpu_count" -eq 0 ]; then
        SLOT_1="cpu"
        SLOT_2="cpu"
        echo
        echo "Both readouts on the panel will show CPU temperature for now."
        write_config
        return
    fi

    if [ "$gpu_count" -eq 1 ]; then
        SLOT_1="cpu"
        SLOT_2="gpu:0"
        echo
        echo "Easy: CPU on one readout, your GPU on the other."
        write_config
        return
    fi

    # Two or more GPUs: worth asking what they'd like to see.
    echo
    echo "You have $gpu_count GPUs. How should the display show them?"
    echo "  1) Simplest: CPU + your first GPU only               [default]"
    echo "  2) CPU + a specific GPU you pick"
    echo "  3) CPU fixed, other readout rotates through every GPU"
    echo "  4) Rotate CPU and a GPU together on one readout, keep"
    echo "     another GPU fixed on the other readout"
    echo
    local choice
    ask "Enter 1-4 [1]: " "1" choice

    case "$choice" in
        2)
            local idx
            ask_number "Which GPU number (0-$((gpu_count - 1))) [0]: " "0" idx
            if [ "$idx" -ge "$gpu_count" ]; then
                echo "    (no GPU $idx, using 0)"
                idx=0
            fi
            SLOT_1="cpu"
            SLOT_2="gpu:$idx"
            ;;
        3)
            SLOT_1="cpu"
            SLOT_2="flicker:$(all_gpu_sources)"
            ask_flicker_timing
            ;;
        4)
            local fixed_idx flicker_idx
            ask_number "Which GPU stays fixed on its own readout (0-$((gpu_count - 1))) [0]: " "0" fixed_idx
            [ "$fixed_idx" -ge "$gpu_count" ] && fixed_idx=0
            ask_number "Which GPU rotates with CPU (0-$((gpu_count - 1))) [$(( (fixed_idx + 1) % gpu_count ))]: " \
                "$(( (fixed_idx + 1) % gpu_count ))" flicker_idx
            [ "$flicker_idx" -ge "$gpu_count" ] && flicker_idx=$(( (fixed_idx + 1) % gpu_count ))
            SLOT_1="flicker:cpu,gpu:$flicker_idx"
            SLOT_2="gpu:$fixed_idx"
            ask_flicker_timing
            ;;
        *)
            SLOT_1="cpu"
            SLOT_2="gpu:0"
            ;;
    esac

    write_config
}

all_gpu_sources() {
    local out="" i
    for i in "${!GPU_NAMES[@]}"; do
        out="${out:+$out,}gpu:$i"
    done
    echo "$out"
}

ask_flicker_timing() {
    echo
    ask_number "How many milliseconds per value before switching? [3000]: " "3000" FLICKER_INTERVAL_MS
    local want_pause
    ask "Blank the readout briefly each time it loops back to the start, so you can tell it just restarted? [y/N]: " "n" want_pause
    if [[ "$want_pause" =~ ^[Yy] ]]; then
        ask_number "For how many milliseconds? [500]: " "500" FLICKER_RESET_PAUSE_MS
    else
        FLICKER_RESET_PAUSE_MS="0"
    fi
}

write_config() {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
# ==============================================================================
# Antec Flux Pro Display configuration
# ==============================================================================
#
# The panel has two readouts: a "CPU" slot and a "GPU" slot. slot_1 controls
# the CPU slot, slot_2 controls the GPU slot -- but either one can show
# anything below, so you can e.g. put the CPU reading in slot_2 instead, or
# rotate a slot through multiple sources.
#
# A slot value is one of:
#   "cpu"                 -- the CPU temperature sensor (see cpu_device below)
#   "gpu:<index>"          -- an NVML GPU device index; run "nvidia-smi -L" to
#                             see which index is which card
#   "flicker:<a>,<b>,..."  -- rotate between two or more of the sources above,
#                             switching every flicker_interval_ms
#
# This file was generated by install.sh based on your answers. Feel free to
# hand-edit it -- just run "sudo systemctl restart af-pro-display" after.
slot_1 = "$SLOT_1"
slot_2 = "$SLOT_2"

# How long (in milliseconds) a "flicker:" slot shows each source before
# switching to the next one. Ignored by slots that aren't "flicker:...".
flicker_interval_ms = $FLICKER_INTERVAL_MS

# How long (in milliseconds) a "flicker:" slot blanks out right before it
# wraps back around to its first source. 0 disables this (immediate wrap).
flicker_reset_pause_ms = $FLICKER_RESET_PAUSE_MS

# The direct Linux hwmon/thermal path to read for "cpu" sources. Left
# commented out so it auto-detects (recommended -- hwmon numbering can
# change across reboots, but auto-detect finds the right sensor by name
# every time). Uncomment and set a path only if auto-detect picks the
# wrong sensor.
# cpu_device = "/sys/class/hwmon/hwmon0/temp1_input"

# How often (in milliseconds) to poll sensors and update the display.
polling_interval = 1000
EOF

    local config_dir home_config_dir
    config_dir="$(dirname "$CONFIG_PATH")"
    home_config_dir="$(dirname "$config_dir")"

    as_root mkdir -p "$config_dir"
    as_root install -m 0644 "$tmp" "$CONFIG_PATH"
    if [ "$SERVICE_USER" != "root" ]; then
        # Fix ownership of anything we just created. ~/.config usually
        # already exists and is already owned correctly (this is then a
        # harmless no-op); this only matters for a brand new/minimal
        # account where it didn't exist yet.
        as_root chown "$SERVICE_USER":"$SERVICE_USER" "$home_config_dir" 2>/dev/null || true
        as_root chown -R "$SERVICE_USER":"$SERVICE_USER" "$config_dir"
    fi
    rm -f "$tmp"

    log "Config written to $CONFIG_PATH:"
    echo
    as_root sed -n '/^slot_1/,/^polling_interval/p' "$CONFIG_PATH" | grep -v '^#'
    echo
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

enable_and_start() {
    log "Starting the service (as $SERVICE_USER)..."
    as_root systemctl enable af-pro-display.service >/dev/null
    as_root systemctl restart af-pro-display.service
}

main() {
    echo "Antec Flux Pro Display -- setup"
    echo "You can just press Enter at every question to accept the default."

    check_display_present
    install_build_deps
    install_rust
    clone_or_use_repo
    build
    install_files
    choose_service_user
    apply_service_user
    configure
    enable_and_start

    log "All done!"
    echo "    Go check your case -- the display should be showing temperatures now."
    echo
    echo "    Status:  sudo systemctl status af-pro-display"
    echo "    Logs:    journalctl -u af-pro-display -f"
    echo "    Running as: $SERVICE_USER"
    echo "    Config:  $CONFIG_PATH"
    echo "    Change your mind? Edit that file, then:"
    echo "             sudo systemctl restart af-pro-display"
    echo "    (re-run this script any time to switch between root/unprivileged)"
}

main "$@"
