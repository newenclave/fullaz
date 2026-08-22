const std = @import("std");
const dispatch = @import("dispatch");

pub const panic = std.debug.FullPanic(struct {
    fn handler(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.handler);

var last_status: u32 = 0;

// Four f64 values per order: latitude, longitude, priority rank, and status.
// The browser reads this immutable render snapshot from WASM linear memory.
const marker_stride = 4;
var markers = [_]f64{
    60.1717, 24.9415, 2, 0,
    60.1648, 24.9193, 1, 0,
    60.1798, 24.9564, 3, 0,
    60.1555, 24.9433, 0, 1,
    60.1666, 24.9721, 2, 0,
};

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

export fn markersPtr() usize {
    return @intFromPtr(&markers);
}

export fn markersCount() u32 {
    return markers.len / marker_stride;
}

export fn ordersCount() u32 {
    return 5;
}

export fn queueCount() u32 {
    return 5;
}

export fn auditBytes() u32 {
    return 85;
}
