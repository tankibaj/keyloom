//! Exercises the exported C symbols the way a native client calls them.

use keyloom_core::{keyloom_core_abi_version, ABI_VERSION};

#[test]
fn c_symbol_reports_abi_version() {
    assert_eq!(keyloom_core_abi_version(), ABI_VERSION);
}
