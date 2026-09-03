const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");

const FreeList = fullaz.storage.free_list.FreeList;

pub fn ReclaimingCache(comptime InnerCache: type) type {
    return struct {
        const Self = @This();

        pub const Handle = InnerCache.Handle;
        pub const Pid = InnerCache.Pid;
        pub const PageId = InnerCache.Pid;
        pub const UnderlyingDevice = InnerCache.UnderlyingDevice;
        pub const Error = InnerCache.Error;
        pub const StateLeaseType = struct {
            pub const Error = InnerCache.Error;

            handle: InnerCache.Handle,

            pub fn data(self: *const @This()) @This().Error![]const u8 {
                const bytes = try self.handle.data();
                const offset = @offsetOf(superblock.Header, "freed_head");
                return bytes[offset .. offset + @sizeOf(superblock.FreeListState)];
            }

            pub fn dataMut(self: *@This()) @This().Error![]u8 {
                const bytes = try self.handle.dataMut();
                const offset = @offsetOf(superblock.Header, "freed_head");
                return bytes[offset .. offset + @sizeOf(superblock.FreeListState)];
            }

            pub fn finish(_: *@This()) void {}

            pub fn deinit(self: *@This()) void {
                self.handle.deinit();
            }
        };

        inner: *InnerCache,

        pub fn init(inner: *InnerCache) Error!Self {
            return .{ .inner = inner };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .handle = try self.inner.fetch(constants.superblock_pid) };
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            return self.inner.getTemporaryPage();
        }

        pub fn fetch(self: *Self, pid: Pid) Error!Handle {
            return self.inner.fetch(pid);
        }

        pub fn flush(self: *Self, pid: Pid) Error!void {
            return self.inner.flush(pid);
        }

        pub fn flushAll(self: *Self) Error!void {
            return self.inner.flushAll();
        }

        pub fn pageCount(self: *const Self) usize {
            return self.inner.pageCount();
        }

        pub fn create(self: *Self) Error!Handle {
            var fl = FreeList(InnerCache, Self, constants.endian).init(self.inner, self);
            if (try fl.pop()) |pid| {
                return self.inner.fetch(pid);
            }
            return self.inner.create();
        }

        pub fn free(self: *Self, pid: Pid) Error!void {
            var fl = FreeList(InnerCache, Self, constants.endian).init(self.inner, self);
            try fl.push(pid);
        }
    };
}
