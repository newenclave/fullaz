const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");

// Every node slot is the same size, so the FSM only ever sees one request size
// and size classes would partition nothing: the capacity check happens inside
// the slab anyway. One class means one persisted root, four bytes.
pub const NodeSizePolicy = struct {
    pub const SizeClass = u16;

    pub fn getSizeClass(_: *const @This(), _: SizeClass) !SizeClass {
        return 0;
    }

    pub fn count(_: *const @This()) usize {
        return 1;
    }
};

pub fn Manager(comptime PageCacheType: type) type {
    comptime {
        if (PageCacheType.Pid != constants.PageId) {
            @compileError("page cache Pid must match the demo PageId");
        }
    }

    return struct {
        const Self = @This();

        pub const PageId = PageCacheType.Pid;
        pub const NodeId = superblock.NodeId;
        pub const Error = PageCacheType.Error;

        pub const State = struct {
            root: ?NodeId = null,
            entries_count: usize = 0,
            fsm_class_root: ?PageId = null,
        };

        cache: *PageCacheType,
        root: ?NodeId,
        entries_count: usize,
        fsm_class_root: ?PageId,

        pub fn init(cache: *PageCacheType, state: State) Self {
            return .{
                .cache = cache,
                .root = state.root,
                .entries_count = state.entries_count,
                .fsm_class_root = state.fsm_class_root,
            };
        }

        pub fn getRoot(self: *const Self) ?NodeId {
            return self.root;
        }

        pub fn setRoot(self: *Self, root: ?NodeId) Error!void {
            self.root = root;
            var view = try self.superblockMut();
            defer view.handle.deinit();
            view.sb.setRoot(root);
        }

        pub fn getEntriesCount(self: *const Self) Error!usize {
            return self.entries_count;
        }

        pub fn setEntriesCount(self: *Self, count: usize) Error!void {
            self.entries_count = count;
            var view = try self.superblockMut();
            defer view.handle.deinit();
            view.sb.setEntriesCount(count);
        }

        pub fn getSizeClassRoot(self: *const Self, _: NodeSizePolicy.SizeClass) Error!?PageId {
            return self.fsm_class_root;
        }

        pub fn setSizeClassRoot(
            self: *Self,
            _: NodeSizePolicy.SizeClass,
            root: ?PageId,
        ) Error!void {
            self.fsm_class_root = root;
            var view = try self.superblockMut();
            defer view.handle.deinit();
            view.sb.setFsmClassRoot(root);
        }

        // The demo is insert-only, so nothing ever asks for a page back. A page
        // released here would simply stay allocated inside the image.
        pub fn destroyPage(_: *Self, _: PageId) Error!void {}

        const MutableSuperblock = struct {
            handle: PageCacheType.Handle,
            sb: superblock.View(false),
        };

        // dataMut already marks the frame dirty, so there is no flush here:
        // setEntriesCount fires on every single insert and flushing would mean
        // one device write per point. Cloud.save owns the flush.
        fn superblockMut(self: *Self) Error!MutableSuperblock {
            var handle = try self.cache.fetch(constants.superblock_pid);
            errdefer handle.deinit();
            const bytes = try handle.dataMut();
            return .{ .handle = handle, .sb = superblock.View(false).init(bytes) };
        }
    };
}
