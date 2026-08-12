const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");

const FreeList = fullaz.storage.free_list.FreeList;

pub fn ReclaimingCache(comptime InnerCacheT: type) type {
    return struct {
        const Self = @This();

        pub const Handle = InnerCacheT.Handle;
        pub const Pid = InnerCacheT.Pid;
        pub const PageId = Pid;
        pub const UnderlyingDevice = InnerCacheT.UnderlyingDevice;
        pub const Error = InnerCacheT.Error || error{CannotFreeSuperblock};

        pub const State = struct {
            free_page_root: ?Pid = null,
            free_page_count: usize = 0,
            reused_page_count: usize = 0,
        };

        inner: *InnerCacheT,
        state: State,

        pub fn init(inner: *InnerCacheT, state: State) Self {
            return .{ .inner = inner, .state = state };
        }

        pub fn getRoot(self: *const Self) ?Pid {
            return self.state.free_page_root;
        }

        pub fn setRoot(self: *Self, root: ?Pid) Error!void {
            self.state.free_page_root = root;
            try self.persistState();
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            return self.inner.getTemporaryPage();
        }

        pub fn fetch(self: *Self, pid: Pid) Error!Handle {
            return self.inner.fetch(pid);
        }

        pub fn create(self: *Self) Error!Handle {
            var free_list = FreeList(InnerCacheT, Self, constants.endian).init(self.inner, self);
            if (try free_list.pop()) |pid| {
                var handle = try self.inner.fetch(pid);
                errdefer handle.deinit();
                @memset(try handle.dataMut(), 0);
                self.state.free_page_count -= 1;
                self.state.reused_page_count += 1;
                try self.persistState();
                return handle;
            }
            return self.inner.create();
        }

        pub fn free(self: *Self, pid: Pid) Error!void {
            if (pid == constants.superblock_pid) {
                return Error.CannotFreeSuperblock;
            }
            var free_list = FreeList(InnerCacheT, Self, constants.endian).init(self.inner, self);
            try free_list.push(pid);
            self.state.free_page_count += 1;
            try self.persistState();
        }

        pub fn flush(self: *Self, pid: Pid) Error!void {
            return self.inner.flush(pid);
        }

        pub fn flushAll(self: *Self) Error!void {
            return self.inner.flushAll();
        }

        pub fn pageSize(self: *const Self) usize {
            return self.inner.pageSize();
        }

        fn persistState(self: *Self) Error!void {
            var handle = try self.inner.fetch(constants.superblock_pid);
            defer handle.deinit();
            var view = superblock.View(false).init(try handle.dataMut());
            view.setFreePageRoot(self.state.free_page_root);
            view.setFreePageCount(self.state.free_page_count);
            view.setReusedPageCount(self.state.reused_page_count);
        }
    };
}
