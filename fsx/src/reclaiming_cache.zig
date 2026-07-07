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

        inner: *InnerCache,
        freed_head: ?Pid,

        pub fn init(inner: *InnerCache) Error!Self {
            var ph = try inner.fetch(constants.superblock_pid);
            defer ph.deinit();
            const sb = superblock.View(true).init(try ph.getData());
            return .{ .inner = inner, .freed_head = sb.getFreedHead() };
        }

        pub fn getRoot(self: *const Self) ?Pid {
            return self.freed_head;
        }

        pub fn setRoot(self: *Self, r: ?Pid) Error!void {
            self.freed_head = r;
            var ph = try self.inner.fetch(constants.superblock_pid);
            defer ph.deinit();
            var sb = superblock.View(false).init(try ph.getDataMut());
            sb.setFreedHead(r);
            try self.inner.flush(constants.superblock_pid);
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
