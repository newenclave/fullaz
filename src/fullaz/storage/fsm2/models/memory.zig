const std = @import("std");
const algorithm = @import("../../../core/algorithm.zig");
const errors = @import("../../../core/errors.zig");

pub fn Memory(comptime PidT: type, comptime SizeT: type) type {
    const Entry = struct {
        pid: PidT,
        free: SizeT,
    };
    const Container = std.ArrayList(Entry);

    return struct {
        const Self = @This();

        pub const Pid = PidT;
        pub const Size = SizeT;
        pub const Error = std.mem.Allocator.Error || errors.SetError || errors.NotFoundError;

        allocator: std.mem.Allocator,
        entries: Container,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .allocator = allocator,
                .entries = try Container.initCapacity(allocator, 4),
            };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn find(self: *Self, size: Size) Error!?Pid {
            const idx = self.lowerBound(size);
            if (idx >= self.entries.items.len) {
                return null;
            }
            return self.entries.items[idx].pid;
        }

        pub fn add(self: *Self, pid: Pid, free: Size) Error!void {
            if (self.findPid(pid)) |_| {
                return Error.KeyAlreadyExists;
            }
            const idx = self.lowerBound(free);
            try self.entries.insert(self.allocator, idx, .{ .pid = pid, .free = free });
        }

        pub fn update(self: *Self, pid: Pid, free: Size) Error!void {
            const i = self.findPid(pid) orelse return Error.KeyNotFound;
            _ = self.entries.orderedRemove(i);
            const idx = self.lowerBound(free);
            try self.entries.insert(self.allocator, idx, .{ .pid = pid, .free = free });
        }

        pub fn remove(self: *Self, pid: Pid) Error!void {
            const i = self.findPid(pid) orelse return Error.KeyNotFound;
            _ = self.entries.orderedRemove(i);
        }

        fn lowerBound(self: *const Self, size: SizeT) usize {
            return algorithm.lowerBound(Entry, self.entries.items, size, entryCmp, {}) catch
                self.entries.items.len;
        }

        fn entryCmp(_: void, e: Entry, key: SizeT) algorithm.Order {
            return algorithm.cmpNum({}, e.free, key);
        }

        fn findPid(self: *const Self, pid: PidT) ?usize {
            for (self.entries.items, 0..) |e, i| {
                if (e.pid == pid) {
                    return i;
                }
            }
            return null;
        }
    };
}
