# Antec Flux Pro Display (multi-GPU fork)

Drives the small digital display built into the [Antec Flux
Pro](https://www.antec.com/product/case/flux-pro) case, showing live CPU and
GPU temperatures. Talks to the panel over USB and reads sensors via Linux
hwmon (CPU) and NVML (NVIDIA GPUs).

This is a fork of [nishtahir/antec-flux-pro-display](https://github.com/nishtahir/antec-flux-pro-display)
that fixes GPU selection (see [Changes from upstream](#changes-from-upstream))
and adds a small config language so **either display slot can show any
combination of sensors**, including multiple GPUs.

## Features

- CPU temperature (auto-detected, or a specific hwmon/thermal path)
- Any number of NVIDIA GPUs via NVML, picked by index
- Each of the panel's two slots independently shows: a fixed sensor, or a
  timed rotation ("flicker") through several sensors
- Optional blank pulse when a flicker rotation wraps back to its first
  value, so you can tell it just restarted even if two values look the same
- Runs as a systemd service, self-documenting config file created on first run

## Requirements

- Linux, with the Antec Flux Pro display connected over its internal USB
  header (shows up as USB device `2022:0522`)
- NVIDIA driver + NVML (`libnvidia-ml.so.1`) if you want GPU readings
- Rust/Cargo to build (see [Building](#building))

## Installing

### Quick install (recommended)

One command builds it from source (installing Rust and build dependencies
if needed) and sets it up as a systemd service:

```bash
curl -fsSL https://raw.githubusercontent.com/Menimm/antec-flux-pro-display/main/install.sh | bash
```

Safe to re-run any time (e.g. after `git pull`) — it rebuilds, reinstalls,
and restarts the service so the update actually takes effect. It never
touches your `config.toml`.

If you'd rather review the script first (sensible, since it's piped into
`bash`):

```bash
git clone https://github.com/Menimm/antec-flux-pro-display.git
cd antec-flux-pro-display
less install.sh   # read it
./install.sh
```

### Manual install

If you'd rather do it by hand, or need to customize the steps:

```bash
git clone https://github.com/Menimm/antec-flux-pro-display.git
cd antec-flux-pro-display
cargo build --release

sudo install -m 0755 target/release/af-pro-display /usr/bin/af-pro-display
sudo install -m 0644 packaging/udev/99-af-pro-display.rules /lib/udev/rules.d/
sudo install -m 0644 packaging/systemd/af-pro-display.service /lib/systemd/system/

sudo udevadm control --reload-rules
sudo udevadm trigger
sudo systemctl daemon-reload
sudo systemctl enable --now af-pro-display.service
```

`install.sh` asks interactively whether to run the service as root (upstream's
default) or as an unprivileged user (recommended — see
[Security notes](#security-notes)); doing it by hand here defaults to root.

### Debian package

If you have [`cargo-deb`](https://github.com/kornelski/cargo-deb) installed:

```bash
cargo install cargo-deb
cargo deb
sudo apt install ./target/debian/af-pro-display_*.deb
```

## Configuration

On first run, a self-documenting config file is created at
`~/.config/af-pro-display/config.toml` (i.e. `/root/.config/...` when run as
the `af-pro-display` systemd service, since it runs as root). Edit it and
`sudo systemctl restart af-pro-display` to apply changes — no rebuild needed.

```toml
# The panel has two readouts: a "CPU" slot and a "GPU" slot. slot_1 controls
# the CPU slot, slot_2 controls the GPU slot -- but either one can show
# anything below.
slot_1 = "cpu"
slot_2 = "gpu:0"

# How long (ms) a "flicker:" slot shows each source before rotating.
flicker_interval_ms = 3000

# How long (ms) a "flicker:" slot blanks for right before it wraps back
# to its first source. 0 disables this (immediate wrap).
flicker_reset_pause_ms = 0

# hwmon/thermal path for "cpu" sources. Leave unset to auto-detect.
# cpu_device = "/sys/class/hwmon/hwmon0/temp1_input"

# How often (ms) to poll sensors and update the display.
polling_interval = 1000
```

### Slot syntax

Both `slot_1` and `slot_2` accept the same mini-language:

| Value | Meaning |
|---|---|
| `"cpu"` | The CPU temperature sensor |
| `"gpu:<index>"` | An NVML GPU device index — run `nvidia-smi -L` to see which index is which card |
| `"flicker:<a>,<b>,..."` | Rotate between two or more sources above, switching every `flicker_interval_ms` |

Out-of-range GPU indices are clamped to `gpu:0` with a warning logged to
the journal, rather than crashing the service.

### Examples

Show CPU and a single GPU (the default, matches upstream's original
behavior):

```toml
slot_1 = "cpu"
slot_2 = "gpu:0"
```

Alternate between two GPUs in the GPU slot, CPU stays fixed:

```toml
slot_1 = "cpu"
slot_2 = "flicker:gpu:0,gpu:1"
```

Alternate CPU and a second GPU in the CPU slot, first GPU fixed in the GPU
slot — useful when you have more sensors than slots:

```toml
slot_1 = "flicker:cpu,gpu:1"
slot_2 = "gpu:0"
```

Same, but blank the slot for 500ms every time the rotation restarts, so a
restart is visually obvious even if consecutive values happen to match:

```toml
slot_1 = "flicker:cpu,gpu:1"
slot_2 = "gpu:0"
flicker_interval_ms = 2000
flicker_reset_pause_ms = 500
```

### A malformed config

If `config.toml` has invalid syntax, the service currently fails to start
(it will restart-loop under systemd, `Restart=always`) and the panel goes
blank until it's fixed. Check `journalctl -u af-pro-display` for the parse
error — it points at the exact line/column.

## Service management

```bash
sudo systemctl status af-pro-display    # check status
journalctl -u af-pro-display -f         # follow logs
sudo systemctl restart af-pro-display   # apply a config change
sudo systemctl stop af-pro-display      # stop
```

## Security notes

- The unit ships with `ProtectSystem=strict` and `NoNewPrivileges=true`.
  Root is not actually required: the udev rule grants the display device to
  members of the `plugdev` group. `install.sh` asks which you want and sets
  it up either way — picking "unprivileged" adds the chosen user to
  `plugdev` and drops a `User=`/`Group=` systemd drop-in at
  `/etc/systemd/system/af-pro-display.service.d/override.conf`, without
  touching the shipped unit file. Re-run `install.sh` any time to switch
  between root and unprivileged; the config path follows whichever user the
  service runs as (`/root/.config/...` for root, `~/.config/...` otherwise).
- NVML is loaded via `libnvidia-ml.so.1` by bare filename (relies on the
  dynamic linker's default search path); this is upstream's existing
  behavior and is low-risk under systemd's clean environment, but be aware
  of it if you customize `LD_LIBRARY_PATH` for the service.
- No network I/O anywhere in this binary.

## Known hardware limitation: no button hook

The physical mode button on top of the Flux Pro case **cannot be hooked**
from software. The display's USB device declares exactly one endpoint — an
interrupt OUT — and no interrupt IN endpoint at all
(`usbhid: couldn't find an input interrupt endpoint` in `dmesg`, consistent
since boot). It's a write-only device: the host can push digits to it, but
it has no channel to report anything back, including button presses. The
button almost certainly just cycles the panel's own local firmware display
mode, invisible to the host.

## Changes from upstream

Upstream v0.1.2 had a `gpu_device: Option<String>` config field that was
never actually read anywhere — the binary always displayed NVML device
index 0 regardless of configuration. This fork:

- Fixes GPU display to actually honor configuration
- Replaces the single hardcoded CPU/GPU slot pairing with the `slot_1` /
  `slot_2` mini-language above, so either slot can show any sensor or
  rotate through several
- Adds `flicker_reset_pause_ms` for a visual "rotation restarted" marker
- Falls back to safe defaults and logs a warning on invalid slot config or
  out-of-range GPU indices, instead of using unvalidated input silently
- Ships a fully-commented default config file instead of an uncommented
  serialized struct

See `src/slot.rs` for the parsing/rotation logic and its unit tests.

## License

GPLv3, same as upstream — see [LICENSE](LICENSE). Copyright (C) Nish Tahir
and contributors; modifications Copyright (C) 2026 Meni Meller.
