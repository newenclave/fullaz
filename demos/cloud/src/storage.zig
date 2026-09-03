const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");

// Every node slot is the same size, so the FSM only ever sees one request size
// and size classes would partition nothing: the capacity check happens inside
// the slab anyway. One class means one persisted root, four bytes.
pub const NodeSizePolicy = struct {
    pub const SizeClass = u16;
    pub const maximum_class_count: usize = 1;

    pub fn getSizeClass(_: *const @This(), _: SizeClass) SizeClass {
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
        pub const Error = PageCacheType.Error;
        pub const TreeState = fullaz.spatial.orthtree.models.paged.State(
            PageId,
            constants.endian,
        );
        pub const FsmState = fullaz.storage.fsm.models.paged.slab.State(
            PageId,
            NodeSizePolicy,
            constants.endian,
        );
        pub const State = extern struct {
            tree: TreeState = .{},
            fsm: FsmState = .{},
        };
        comptime {
            const state_offset = @offsetOf(superblock.Header, "root_page");
            const state_end = @offsetOf(superblock.Header, "fsm_class_root") +
                @sizeOf(@FieldType(superblock.Header, "fsm_class_root"));
            if (@alignOf(State) != 1 or
                @offsetOf(State, "tree") != 0 or
                @offsetOf(State, "fsm") != @sizeOf(TreeState) or
                @sizeOf(State) != state_end - state_offset)
            {
                @compileError("cloud index state must exactly match its superblock fields");
            }
        }
        pub const StateLeaseType = struct {
            pub const Error = PageCacheType.Error;

            handle: PageCacheType.Handle,

            pub fn data(self: *const @This()) @This().Error![]const u8 {
                const bytes = try self.handle.data();
                const offset = @offsetOf(superblock.Header, "root_page");
                return bytes[offset .. offset + @sizeOf(State)];
            }

            pub fn dataMut(self: *@This()) @This().Error![]u8 {
                const bytes = try self.handle.dataMut();
                const offset = @offsetOf(superblock.Header, "root_page");
                return bytes[offset .. offset + @sizeOf(State)];
            }

            pub fn finish(_: *@This()) void {}

            pub fn deinit(self: *@This()) void {
                self.handle.deinit();
            }
        };

        cache: *PageCacheType,

        pub fn init(cache: *PageCacheType) Self {
            return .{ .cache = cache };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .handle = try self.cache.fetch(constants.superblock_pid) };
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            try self.cache.free(page_id);
        }
    };
}

pub fn TreeManager(comptime PageCacheType: type) type {
    const ParentManager = Manager(PageCacheType);
    return fullaz.core.storage_manager.PagedFieldStorageManager(
        ParentManager,
        ParentManager.State,
        "tree",
    );
}

pub fn FsmManager(comptime PageCacheType: type) type {
    const ParentManager = Manager(PageCacheType);
    return fullaz.core.storage_manager.PagedFieldStorageManager(
        ParentManager,
        ParentManager.State,
        "fsm",
    );
}
