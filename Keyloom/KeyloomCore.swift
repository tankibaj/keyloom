/// Thin Swift face of the Rust static library (Core/include/keyloom_core.h).
enum KeyloomCore {
    static var abiVersion: UInt32 { keyloom_core_abi_version() }
}
