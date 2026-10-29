/// Access to the Rust core. On platforms without `dart:ffi` (web preview) the
/// stub reports the core as unavailable and the lists stay empty.
library;

export 'core_bridge_stub.dart' if (dart.library.ffi) 'core_bridge_ffi.dart';
