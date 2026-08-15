const std = @import("std");

pub fn sliceAligned(comptime T: type, buf: []u8, n: usize) ?[]T {
    const p_aligned_opt = std.mem.alignPointer(buf.ptr, @alignOf(T));
    if (p_aligned_opt == null) {
        return null;
    }
    const p_aligned = p_aligned_opt.?;

    const skipped = @intFromPtr(p_aligned) - @intFromPtr(buf.ptr);
    if (skipped > buf.len) {
        return null;
    }
    const tail = buf[skipped..];

    const need_bytes = n * @sizeOf(T);
    if (need_bytes > tail.len) {
        return null;
    }

    const p_t: [*]T = @ptrCast(@alignCast(p_aligned));
    return p_t[0..n];
}

pub fn alignUp(comptime T: type, value: T, al: T) T {
    return (value + (al - 1)) & ~(al - 1);
}

pub fn alignDown(comptime T: type, value: T, al: T) T {
    return value & ~(al - 1);
}
