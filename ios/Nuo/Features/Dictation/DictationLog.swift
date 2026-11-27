import OSLog

/// Dictation diagnostics, readable with `log show --predicate 'subsystem == "<NUO_BUNDLE_ID>"'`: engines,
/// delays and sizes only, never what was said.
let dictationLog = Logger(subsystem: AppIdentity.identifier, category: "dictation")
