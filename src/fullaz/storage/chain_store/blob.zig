const std = @import("std");
const handle = @import("handle.zig");

/// A bounded long byte value backed by a bidirectional chain of chunk pages.
///
/// Unlike `Handle`, this facade has no mutable read/write cursor. All offsets
/// are explicit and values beyond the end are rejected rather than clamped.
pub fn Blob(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const HandleT = handle.Handle(PageCacheT, StorageManagerT, Endian);

    return struct {
        const Self = @This();

        pub const Error = HandleT.Error || error{OutOfBounds};

        handle: HandleT,

        pub fn init(
            cache: *PageCacheT,
            manager: *StorageManagerT,
            settings: handle.Settings,
        ) Self {
            return .{ .handle = HandleT.init(cache, manager, settings) };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn create(self: *Self) Error!void {
            if (try self.handle.isCreated()) {
                return Error.AlreadyExists;
            }
        }

        pub fn open(self: *Self) Error!void {
            try self.handle.open();
        }

        pub fn size(self: *const Self) Error!StorageManagerT.Size {
            return self.handle.totalSize();
        }

        pub fn readAt(self: *Self, offset: usize, out: []u8) Error!usize {
            const total = try self.size();
            const total_usize = std.math.cast(usize, total) orelse return Error.OutOfBounds;
            if (offset > total_usize) {
                return Error.OutOfBounds;
            }
            if (offset == total_usize) {
                return 0;
            }
            try self.handle.setg(offset);
            return self.handle.read(out);
        }

        pub fn writeAt(self: *Self, offset: usize, bytes: []const u8) Error!usize {
            const total = try self.size();
            const total_usize = std.math.cast(usize, total) orelse return Error.OutOfBounds;
            if (offset > total_usize) {
                return Error.OutOfBounds;
            }
            if (bytes.len == 0) {
                return 0;
            }
            if (!try self.handle.isCreated()) {
                try self.handle.create();
            }
            try self.handle.setp(offset);
            return self.handle.write(bytes);
        }

        pub fn append(self: *Self, bytes: []const u8) Error!usize {
            const total = try self.size();
            const total_usize = std.math.cast(usize, total) orelse return Error.OutOfBounds;
            return self.writeAt(total_usize, bytes);
        }

        /// Reduces the logical size. Extending through truncate is forbidden.
        pub fn truncate(self: *Self, new_size: usize) Error!void {
            const total = try self.size();
            const total_usize = std.math.cast(usize, total) orelse return Error.OutOfBounds;
            if (new_size > total_usize) {
                return Error.OutOfBounds;
            }
            if (new_size == total_usize) {
                return;
            }
            try self.handle.truncate(total_usize - new_size);
        }

        pub fn clear(self: *Self) Error!void {
            try self.handle.destroy();
        }
    };
}
