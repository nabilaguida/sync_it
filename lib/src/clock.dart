/// Injectable time source.
///
/// The engine never calls `DateTime.now()` directly — every timestamp
/// (backoff eligibility, watermarks, task updates) flows through a [Clock]
/// so behavior is deterministic under test.
typedef Clock = DateTime Function();

/// Default production clock.
DateTime systemClock() => DateTime.now();
