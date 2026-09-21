/// A single temperature source a slot can display.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Cpu,
    Gpu(u32),
}

impl Source {
    fn parse(s: &str) -> Result<Source, String> {
        let s = s.trim();
        if s.eq_ignore_ascii_case("cpu") {
            return Ok(Source::Cpu);
        }
        if let Some(rest) = s.strip_prefix("gpu:") {
            return rest
                .trim()
                .parse::<u32>()
                .map(Source::Gpu)
                .map_err(|_| format!("invalid GPU index in {s:?} (expected e.g. \"gpu:0\")"));
        }
        Err(format!(
            "unknown source {s:?} (expected \"cpu\" or \"gpu:<index>\")"
        ))
    }

    fn validated(self, device_count: u32, label: &str) -> Source {
        if let Source::Gpu(index) = self {
            if device_count > 0 && index >= device_count {
                eprintln!(
                    "{label}: GPU index {index} is out of range ({device_count} GPU(s) detected); using gpu:0"
                );
                return Source::Gpu(0);
            }
        }
        self
    }
}

/// What a display slot shows: either a fixed source, or a rotation through
/// several sources, switched on a timer.
#[derive(Debug, Clone)]
pub enum SlotConfig {
    Fixed(Source),
    Flicker(Vec<Source>),
}

impl SlotConfig {
    /// Parse a slot expression, e.g. "cpu", "gpu:1", or "flicker:cpu,gpu:1".
    pub fn parse(s: &str) -> Result<SlotConfig, String> {
        let s = s.trim();
        if let Some(rest) = s.strip_prefix("flicker:") {
            let sources = rest
                .split(',')
                .map(Source::parse)
                .collect::<Result<Vec<_>, _>>()?;
            if sources.len() < 2 {
                return Err(format!(
                    "{s:?} needs at least 2 comma-separated sources after \"flicker:\""
                ));
            }
            return Ok(SlotConfig::Flicker(sources));
        }
        Source::parse(s).map(SlotConfig::Fixed)
    }

    /// Parse `s`, falling back to `fallback` (and logging why) on error.
    pub fn parse_or(s: &str, label: &str, fallback: SlotConfig) -> SlotConfig {
        match SlotConfig::parse(s) {
            Ok(slot) => slot,
            Err(e) => {
                eprintln!("{label}: {e}; falling back to default");
                fallback
            }
        }
    }

    /// Clamp any GPU indices to the detected device count.
    pub fn validated(self, device_count: u32, label: &str) -> SlotConfig {
        match self {
            SlotConfig::Fixed(source) => SlotConfig::Fixed(source.validated(device_count, label)),
            SlotConfig::Flicker(sources) => SlotConfig::Flicker(
                sources
                    .into_iter()
                    .map(|s| s.validated(device_count, label))
                    .collect(),
            ),
        }
    }
}

enum Phase {
    /// Showing `sources[.0]`.
    Showing(usize),
    /// Blanked out, about to wrap back around to the first source.
    Paused,
}

/// Runtime state for a slot: which source is currently showing, and when to
/// next rotate (only relevant for `SlotConfig::Flicker`).
pub struct SlotState {
    config: SlotConfig,
    phase: Phase,
    last_switch: std::time::Instant,
}

impl SlotState {
    pub fn new(config: SlotConfig) -> Self {
        Self {
            config,
            phase: Phase::Showing(0),
            last_switch: std::time::Instant::now(),
        }
    }

    /// The source this slot should show right now (`None` means blank),
    /// advancing the rotation if `interval` has elapsed since the last
    /// switch. On wrapping back to the first source, the slot blanks out for
    /// `reset_pause` first -- pass `Duration::ZERO` to skip that and wrap
    /// immediately, as before.
    pub fn current_output(
        &mut self,
        interval: std::time::Duration,
        reset_pause: std::time::Duration,
    ) -> Option<Source> {
        let sources = match &self.config {
            SlotConfig::Fixed(source) => return Some(*source),
            SlotConfig::Flicker(sources) => sources,
        };

        match self.phase {
            Phase::Showing(index) => {
                if self.last_switch.elapsed() < interval {
                    return Some(sources[index]);
                }
                self.last_switch = std::time::Instant::now();
                let next_index = (index + 1) % sources.len();
                if next_index == 0 && !reset_pause.is_zero() {
                    self.phase = Phase::Paused;
                    None
                } else {
                    self.phase = Phase::Showing(next_index);
                    Some(sources[next_index])
                }
            }
            Phase::Paused => {
                if self.last_switch.elapsed() < reset_pause {
                    return None;
                }
                self.last_switch = std::time::Instant::now();
                self.phase = Phase::Showing(0);
                Some(sources[0])
            }
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::time::Duration;

    #[test]
    fn parses_cpu_and_gpu() {
        assert!(matches!(Source::parse("cpu"), Ok(Source::Cpu)));
        assert!(matches!(Source::parse("gpu:0"), Ok(Source::Gpu(0))));
        assert!(matches!(Source::parse("gpu:1"), Ok(Source::Gpu(1))));
        assert!(Source::parse("gpu:x").is_err());
        assert!(Source::parse("bogus").is_err());
    }

    #[test]
    fn parses_fixed_slot() {
        assert!(matches!(
            SlotConfig::parse("gpu:1"),
            Ok(SlotConfig::Fixed(Source::Gpu(1)))
        ));
    }

    #[test]
    fn parses_flicker_slot() {
        match SlotConfig::parse("flicker:cpu,gpu:1").unwrap() {
            SlotConfig::Flicker(sources) => {
                assert_eq!(sources, vec![Source::Cpu, Source::Gpu(1)]);
            }
            _ => panic!("expected Flicker"),
        }
    }

    #[test]
    fn flicker_needs_two_sources() {
        assert!(SlotConfig::parse("flicker:cpu").is_err());
    }

    #[test]
    fn out_of_range_gpu_clamps_to_zero() {
        let slot = SlotConfig::parse("gpu:5").unwrap().validated(2, "slot_test");
        assert!(matches!(slot, SlotConfig::Fixed(Source::Gpu(0))));
    }

    #[test]
    fn fixed_slot_never_blanks() {
        let mut state = SlotState::new(SlotConfig::Fixed(Source::Gpu(0)));
        for _ in 0..3 {
            assert_eq!(
                state.current_output(Duration::from_millis(10), Duration::from_millis(50)),
                Some(Source::Gpu(0))
            );
            std::thread::sleep(Duration::from_millis(15));
        }
    }

    #[test]
    fn zero_pause_wraps_immediately_like_before() {
        let slot = SlotConfig::Flicker(vec![Source::Cpu, Source::Gpu(1)]);
        let mut state = SlotState::new(slot);
        let interval = Duration::from_millis(15);

        assert_eq!(state.current_output(interval, Duration::ZERO), Some(Source::Cpu));
        std::thread::sleep(interval + Duration::from_millis(5));
        assert_eq!(state.current_output(interval, Duration::ZERO), Some(Source::Gpu(1)));
        std::thread::sleep(interval + Duration::from_millis(5));
        // Wraps straight back to the first source, no blank in between.
        assert_eq!(state.current_output(interval, Duration::ZERO), Some(Source::Cpu));
    }

    #[test]
    fn nonzero_pause_blanks_before_wrapping_to_first_source() {
        let slot = SlotConfig::Flicker(vec![Source::Cpu, Source::Gpu(1)]);
        let mut state = SlotState::new(slot);
        let interval = Duration::from_millis(15);
        let pause = Duration::from_millis(20);

        assert_eq!(state.current_output(interval, pause), Some(Source::Cpu));
        std::thread::sleep(interval + Duration::from_millis(5));
        assert_eq!(state.current_output(interval, pause), Some(Source::Gpu(1)));

        // Interval elapses on the last source: goes blank instead of
        // wrapping straight to the first source.
        std::thread::sleep(interval + Duration::from_millis(5));
        assert_eq!(state.current_output(interval, pause), None);
        // Still blank before the pause has elapsed.
        assert_eq!(state.current_output(interval, pause), None);

        // Once the pause elapses, it shows the first source again.
        std::thread::sleep(pause + Duration::from_millis(5));
        assert_eq!(state.current_output(interval, pause), Some(Source::Cpu));
    }
}
