mod config;
mod cpu;
mod gpu;
mod slot;
mod usb;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::{fs, path::PathBuf, time::Duration};

use anyhow::Result;
use clap::Parser;

use config::{Config, DEFAULT_CONFIG_TOML, FromConfigFile};
use cpu::default_cpu_device;
use gpu::AvailableGpu;
use slot::{Source, SlotConfig, SlotState};
use usb::UsbDevice;

#[derive(clap::Parser)]
#[clap(author, version, about, long_about = None)]
struct Cli {
    #[arg(short, long, default_value = "~/.config/af-pro-display/config.toml")]
    config: String,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let config_path = shellexpand::tilde(&cli.config).to_string();
    let config_path = PathBuf::from(&config_path);
    if fs::File::open(&config_path).is_err() {
        eprintln!("Config file not found at: {}", config_path.display());
        eprintln!("Creating default config file...");

        let config_dir = config_path.parent().ok_or(anyhow::anyhow!(
            "Failed to get parent directory of config file"
        ))?;
        fs::create_dir_all(config_dir)?;
        fs::write(&config_path, DEFAULT_CONFIG_TOML)?;
    }

    let running = Arc::new(AtomicBool::new(true));
    let config = Config::from_config_file(&config_path)?;
    let device = UsbDevice::open(usb::VENDOR_ID, usb::PRODUCT_ID)?;
    let gpu = AvailableGpu::get_available_gpu();
    let device_count = gpu.device_count();

    let slot_1 = SlotConfig::parse_or(&config.slot_1, "slot_1", SlotConfig::Fixed(Source::Cpu))
        .validated(device_count, "slot_1");
    let slot_2 = SlotConfig::parse_or(&config.slot_2, "slot_2", SlotConfig::Fixed(Source::Gpu(0)))
        .validated(device_count, "slot_2");
    let flicker_interval = Duration::from_millis(config.flicker_interval_ms.max(1));
    let flicker_reset_pause = Duration::from_millis(config.flicker_reset_pause_ms);

    let mut slot_1_state = SlotState::new(slot_1);
    let mut slot_2_state = SlotState::new(slot_2);
    let cpu_device = config.cpu_device.clone().or_else(default_cpu_device);

    let read_source = |source: Source| -> Option<f32> {
        match source {
            Source::Cpu => cpu_device.as_ref().and_then(|path| cpu::read_temp(path)),
            Source::Gpu(index) => gpu.temp(index),
        }
    };

    // Handle CTRL+C and other termination gracefully
    let run = running.clone();
    ctrlc::set_handler(move || {
        run.store(false, Ordering::SeqCst);
    })
    .expect("Error setting Ctrl-C handler");

    // Loop until the program is terminated
    while running.load(Ordering::SeqCst) {
        let slot_1_temp = slot_1_state
            .current_output(flicker_interval, flicker_reset_pause)
            .and_then(read_source);
        let slot_2_temp = slot_2_state
            .current_output(flicker_interval, flicker_reset_pause)
            .and_then(read_source);

        device.send_payload(&slot_1_temp, &slot_2_temp);
        std::thread::sleep(Duration::from_millis(config.polling_interval));
    }

    // Finally, set the temps to zero before exiting
    device.send_payload(&Some(0.0), &Some(0.0));

    Ok(())
}
