use anyhow::{Context, Result};
use nvml_wrapper::{Nvml, enum_wrappers::device::TemperatureSensor};

pub struct NvidiaGpu {
    nvml: Nvml,
}

impl NvidiaGpu {
    pub fn new(nvml: Nvml) -> Self {
        Self { nvml }
    }

    pub fn temp(&self, device_index: u32) -> Option<f32> {
        self.nvml
            .device_by_index(device_index)
            .inspect_err(|e| eprintln!("Error getting Nvidia GPU device {device_index}: {e:?}"))
            .and_then(|device| device.temperature(TemperatureSensor::Gpu))
            .inspect_err(|e| eprintln!("Error getting Nvidia GPU temperature: {e:?}"))
            .map(|temp| temp as f32)
            .ok()
    }

    pub fn device_count(&self) -> u32 {
        self.nvml.device_count().unwrap_or(0)
    }
}

pub enum AvailableGpu {
    Nvidia(Box<NvidiaGpu>),
    Unknown,
}

impl AvailableGpu {
    pub fn get_available_gpu() -> AvailableGpu {
        let maybe_nvidia =
            try_get_nvidia_gpu().inspect_err(|e| eprintln!("Failed to get Nvidia GPU. Error: {e}"));

        if let Ok(gpu) = maybe_nvidia {
            return gpu;
        }

        AvailableGpu::Unknown
    }

    pub fn temp(&self, device_index: u32) -> Option<f32> {
        match self {
            AvailableGpu::Nvidia(gpu) => gpu.temp(device_index),
            AvailableGpu::Unknown => None,
        }
    }

    pub fn device_count(&self) -> u32 {
        match self {
            AvailableGpu::Nvidia(gpu) => gpu.device_count(),
            AvailableGpu::Unknown => 0,
        }
    }
}

fn try_get_nvidia_gpu() -> Result<AvailableGpu> {
    let nvml = Nvml::builder()
        .lib_path(std::ffi::OsStr::new("libnvidia-ml.so.1"))
        .init()
        .context("Failed to initialize NVML")?;

    let driver_version = nvml
        .sys_driver_version()
        .context("Failed to get NVML driver version")?;
    println!("NVML initialized, driver version: {driver_version}");

    let device_count = nvml
        .device_count()
        .context("Failed to get NVML device count")?;

    println!("Found {device_count} NVML-supported GPUs");
    Ok(AvailableGpu::Nvidia(Box::new(NvidiaGpu::new(nvml))))
}
