const std = @import("std");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");

pub fn RootStorage(comptime PageCacheType: type) type {
    return struct {
        const Self = @This();

        pub const PageId = PageCacheType.Pid;
        pub const Error = PageCacheType.Error;
        pub const StateLeaseType = struct {
            const LeaseSelf = @This();

            pub const Error = PageCacheType.Error;

            layout_lock: PageCacheType.Handle.LayoutLock,

            pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                const view = superblock.View(true).init(try self.layout_lock.data());
                return std.mem.asBytes(&view.header().rtree_root);
            }

            pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                var view = superblock.View(false).init(try self.layout_lock.dataMut());
                return std.mem.asBytes(&view.headerMut().rtree_root);
            }

            pub fn finish(_: *LeaseSelf) void {}

            pub fn deinit(self: *LeaseSelf) void {
                self.layout_lock.deinit();
            }
        };

        cache: *PageCacheType,

        pub fn init(cache: *PageCacheType) Self {
            return .{ .cache = cache };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            var ph = try self.cache.fetch(constants.superblock_pid);
            defer ph.deinit();
            return .{ .layout_lock = try ph.lockLayout() };
        }

        pub fn destroyPage(_: *Self, _: PageId) Error!void {}
    };
}
