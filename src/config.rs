use anyhow::Result;
use serde::de::DeserializeOwned;
use serde_derive::{Deserialize, Serialize};
use std::{default::Default, fs, path::Path};

fn default_slot_1() -> String {
    "cpu".to_string()
}

fn default_slot_2() -> String {
    "gpu:0".to_string()
}

fn default_flicker_interval_ms() -> u64 {
    3000
}

fn default_flicker_reset_pause_ms() -> u64 {
    0
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct Config {
    pub cpu_device: Option<String>,
    /// What the display's first (CPU) readout shows. See `SLOT_DOC` / the
    /// default config file for the mini-language: "cpu", "gpu:<index>", or
    /// "flicker:<source>,<source>,...".
    #[serde(default = "default_slot_1")]
    pub slot_1: String,
    /// What the display's second (GPU) readout shows. Same syntax as `slot_1`.
    #[serde(default = "default_slot_2")]
    pub slot_2: String,
    /// How long (ms) a "flicker:" slot shows each source before rotating.
    #[serde(default = "default_flicker_interval_ms")]
    pub flicker_interval_ms: u64,
    /// How long (ms) a "flicker:" slot blanks out right before it wraps back
    /// around to its first source, as a visual marker that the rotation
    /// restarted. 0 (default) disables this: it wraps straight back with no
    /// blank, exactly like before this option existed.
    #[serde(default = "default_flicker_reset_pause_ms")]
    pub flicker_reset_pause_ms: u64,
    pub polling_interval: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            cpu_device: None,
            slot_1: default_slot_1(),
            slot_2: default_slot_2(),
            flicker_interval_ms: default_flicker_interval_ms(),
            flicker_reset_pause_ms: default_flicker_reset_pause_ms(),
            polling_interval: 1000,
        }
    }
}

/// Written out verbatim the first time the service runs, so the on-disk
/// config is self-documenting. Keep in sync with `Config::default()` --
/// `test_default_config_toml_matches_default` checks this.
pub const DEFAULT_CONFIG_TOML: &str = r#"# ==============================================================================
# Antec Flux Pro Display configuration
# ==============================================================================
#
# The panel has two readouts: a "CPU" slot and a "GPU" slot. `slot_1` controls
# the CPU slot, `slot_2` controls the GPU slot -- but either one can show
# anything below, so you can e.g. put the CPU reading in slot_2 instead, or
# rotate a slot through multiple sources.
#
# A slot value is one of:
#   "cpu"               -- the CPU temperature sensor (see `cpu_device` below)
#   "gpu:<index>"        -- an NVML GPU device index; run `nvidia-smi -L` to see
#                           which index is which card on your system
#   "flicker:<a>,<b>,..." -- rotate between two or more of the sources above,
#                           switching every `flicker_interval_ms`
#
# Examples:
#   slot_1 = "cpu"
#   slot_2 = "gpu:0"                      # a single fixed GPU
#   slot_2 = "flicker:gpu:0,gpu:1"        # alternate between two GPUs
#   slot_1 = "flicker:cpu,gpu:1"          # alternate CPU and a GPU
#
# Defaults to the original behavior: CPU in slot_1, GPU index 0 in slot_2.
slot_1 = "cpu"
slot_2 = "gpu:0"

# How long (in milliseconds) a "flicker:" slot shows each source before
# switching to the next one. Ignored by slots that aren't "flicker:...".
flicker_interval_ms = 3000

# How long (in milliseconds) a "flicker:" slot goes blank for, right before
# it wraps back around to its first source -- a visual marker so you can tell
# the rotation just restarted (handy when several values could plausibly be
# the same on screen). 0 (default) disables this: it wraps straight back to
# the first source with no blank, i.e. the original behavior.
flicker_reset_pause_ms = 0

# The direct Linux hwmon/thermal path to read for "cpu" sources. Leave unset
# (comment out or delete the line) to auto-detect: AMD Tctl sensor, then
# /sys/class/thermal/thermal_zone0/temp, then /sys/class/hwmon/hwmon0/temp1_input.
# cpu_device = "/sys/class/hwmon/hwmon0/temp1_input"

# How often (in milliseconds) to poll sensors and update the display.
polling_interval = 1000
"#;

pub trait FromConfigFile {
    /// Load ourselves from the configuration file located at @path
    fn from_config_file<P: AsRef<Path>>(path: P) -> Result<Self>
    where
        Self: Sized;
}

impl<T: DeserializeOwned> FromConfigFile for T {
    fn from_config_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let config = fs::read_to_string(path)?;
        Ok(toml::from_str(&config)?)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_default_config_toml_matches_default() {
        let parsed: Config = toml::from_str(DEFAULT_CONFIG_TOML).unwrap();
        assert_eq!(parsed, Config::default());
    }
}
