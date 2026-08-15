// Shared by the demos that draw a full-screen frame in a terminal. Not
// wasm-safe: terminal.zig reaches straight into posix and the Windows console.
pub const terminal = @import("terminal.zig");
