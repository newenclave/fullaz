const constants = @import("constants.zig");
const superblock = @import("superblock.zig");

pub fn RootStorage(comptime PageCacheType: type) type {
    return struct {
        const Self = @This();

        pub const PageId = PageCacheType.Pid;
        pub const Error = PageCacheType.Error;

        cache: *PageCacheType,
        root: ?PageId,

        pub fn init(cache: *PageCacheType, root: ?PageId) Self {
            return .{ .cache = cache, .root = root };
        }

        pub fn getRoot(self: *const Self) ?PageId {
            return self.root;
        }

        pub fn setRoot(self: *Self, pid: ?PageId) Error!void {
            self.root = pid;
            var ph = try self.cache.fetch(constants.superblock_pid);
            defer ph.deinit();
            var sb = superblock.View(false).init(try ph.getDataMut());
            sb.setRoot(pid);
            try self.cache.flush(constants.superblock_pid);
        }

        pub fn destroyPage(_: *Self, _: PageId) Error!void {}
    };
}
