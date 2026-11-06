//! Keyloom core. Behavior-free scaffold: only the C ABI version is exported.

/// Version of the C interface in `include/keyloom_core.h`.
pub const ABI_VERSION: u32 = 1;

#[no_mangle]
pub extern "C" fn keyloom_core_abi_version() -> u32 {
    ABI_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abi_version_is_exported() {
        assert_eq!(keyloom_core_abi_version(), ABI_VERSION);
    }
}
