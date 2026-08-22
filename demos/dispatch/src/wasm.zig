const std = @import("std");
const dispatch = @import("dispatch");

pub const panic = std.debug.FullPanic(struct {
    fn handler(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.handler);

var last_status: u32 = 0;

/// Replays the deterministic dispatch trace in an ephemeral MemoryDatabase.
export fn replay() u32 {
    dispatch.runMemory(std.heap.wasm_allocator) catch {
        last_status = 1;
        return last_status;
    };
    last_status = 0;
    return last_status;
}

export fn status() u32 {
    return last_status;
}
