const interfaces = @import("../contracts/interfaces.zig");

// Decides when the active memtable should be frozen and flushed.
pub fn assertFlushPolicy(comptime PolicyT: type) void {
    interfaces.requiresFnSignature(PolicyT, "shouldFlush", fn (*const PolicyT, usize, usize) bool);
}

pub const ThresholdFlushPolicy = struct {
    max_bytes: ?usize = null,
    max_count: ?usize = null,

    pub fn init(max_bytes: ?usize, max_count: ?usize) ThresholdFlushPolicy {
        return .{
            .max_bytes = max_bytes,
            .max_count = max_count,
        };
    }

    pub fn shouldFlush(self: *const ThresholdFlushPolicy, byte_size: usize, count: usize) bool {
        if (self.max_bytes) |limit| {
            if (byte_size >= limit) {
                return true;
            }
        }
        if (self.max_count) |limit| {
            if (count >= limit) {
                return true;
            }
        }
        return false;
    }
};
