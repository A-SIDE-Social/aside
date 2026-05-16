// Required by flutter_rust_bridge: exactly one `#[frb(init)]` function
// per crate, called once when the Dart side loads the shared library.
// We don't need custom init behavior yet — just the default hook.

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
