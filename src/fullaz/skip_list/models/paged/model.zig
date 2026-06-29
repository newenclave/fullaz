const std = @import("std");
const core = @import("../../../core/core.zig");
const errors = core.errors;
const SubheaderView = @import("view.zig").View;
const interfaces = @import("../interfaces.zig");

pub const Settings = struct {
    max_level: usize = undefined,
    key_len: usize = undefined,
    value_len: usize = undefined,
    node_page_kind: u16 = 1,
};

pub fn Paged(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime FsmT: type,
    comptime cmp: anytype,
    comptime Ctx: type,
) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const KeyT = []const u8;
    const ValueT = []const u8;

    const NodeViewMut = SubheaderView(BlockIdType, u16, .little, false);
    const NodeViewConst = SubheaderView(BlockIdType, u16, .little, true);

    _ = cmp;

    const ContextImpl = struct {
        const Self = @This();
        settings: Settings,
        rng: std.Random = undefined,
        cache: *PageCacheType = undefined,
        storage: *StorageManager = undefined,
        fsm: *FsmT = undefined,
        cmp_ctx: Ctx = undefined,
    };

    const PidImpl = struct {
        const Self = @This();
        page_id: BlockIdType,
        slot_id: usize,
    };

    const PidContainer = std.ArrayList(?PidImpl);

    const PathImpl = struct {
        const Self = @This();

        pub const Error = error{ OutOfMemory, OutOfBounds };
        pub const Pid = PidImpl;

        path: PidContainer = undefined,

        fn init(allocator: std.mem.Allocator, max_level: usize) Error!Self {
            var result = Self{
                .path = try PidContainer.initCapacity(allocator, max_level),
            };
            try result.path.resize(
                allocator,
                max_level,
            );
            return result;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.path.deinit(allocator);
            self.* = undefined;
        }

        pub fn get(self: *const Self, level: usize) Error!?PidImpl {
            if (self.path.items.len <= level) {
                return Error.OutOfBounds;
            }
            return self.path.items[level];
        }

        pub fn set(self: *Self, level: usize, pid: ?PidImpl) Error!void {
            if (self.path.items.len <= level) {
                return Error.OutOfBounds;
            }
            self.path.items[level] = pid;
        }

        fn dump(self: *const Self) void {
            for (self.path.items) |item| {
                if (item) |pid| {
                    std.debug.print("{d} ", .{pid.id});
                } else {
                    std.debug.print("<null> ", .{});
                }
            }
            std.debug.print("\n", .{});
        }
    };

    const NodeImpl = struct {
        const Self = @This();

        pub const Error = PageCacheType.Error || errors.SlotsError;
        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;
        pub const KeyOut = KeyT;
        pub const ValueOut = ValueT;
        pub const Pid = PidImpl;

        pid: PidImpl,
        ph: PageHandle,

        fn init(ph: PageHandle, pid: PidImpl) Self {
            return Self{
                .pid = pid,
                .ph = ph,
            };
        }

        pub fn deinit(self: *Self) void {
            self.ph.deinit();
            self.* = undefined;
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }

        // TODO(C4): read the node's slot via a const View over 'ph.getData()' at 'pid.slot_id'.
        pub fn getKey(_: *const Self) Error!KeyOut {
            @panic("TODO: NodeImpl.getKey");
        }

        pub fn getValue(_: *const Self) Error!ValueOut {
            @panic("TODO: NodeImpl.getValue");
        }

        pub fn getLevel(_: *const Self) Error!usize {
            @panic("TODO: NodeImpl.getLevel");
        }

        // TODO(C5): decode the level's LevelRef.prev/.next (PageSlotRef) into ?Pid.
        pub fn getPrev(_: *const Self, _: usize) Error!?Pid {
            @panic("TODO: NodeImpl.getPrev");
        }

        pub fn getNext(_: *const Self, _: usize) Error!?Pid {
            @panic("TODO: NodeImpl.getNext");
        }

        // TODO(C4): write key/value bytes into the slot via getMut on 'ph.getDataMut()'.
        pub fn setKey(_: *Self, _: KeyIn) Error!void {
            @panic("TODO: NodeImpl.setKey");
        }

        pub fn setValue(_: *Self, _: ValueIn) Error!void {
            @panic("TODO: NodeImpl.setValue");
        }

        // TODO(C5): encode 'pid' into the level's LevelRef.prev/.next.
        pub fn setPrev(_: *Self, _: usize, _: ?Pid) Error!void {
            @panic("TODO: NodeImpl.setPrev");
        }

        pub fn setNext(_: *Self, _: usize, _: ?Pid) Error!void {
            @panic("TODO: NodeImpl.setNext");
        }
    };

    // Compile-time proof the skeleton satisfies the Node contract (signatures only).
    comptime {
        interfaces.assertNode(NodeImpl);
    }

    const AccessorImpl = struct {
        const Self = @This();

        pub const Pid = PidImpl;
        pub const Error = PageCacheType.Error ||
            StorageManager.Error ||
            FsmT.Error ||
            errors.SlotsError;
        pub const Path = PathImpl;

        context: ContextImpl,

        fn init(ctx: ContextImpl) Self {
            return Self{
                .context = ctx,
            };
        }

        fn generateTargetLevel(self: *const Self) Error!usize {
            const max_level = self.context.settings.max_level;
            if (max_level == 0) {
                return 0;
            }
            return self.context.rng.intRangeAtMost(usize, 1, max_level);
        }

        fn generateLevel(self: *const Self, k: usize) Error!usize {
            if (k == 0) {
                @panic("k must be greater than 0");
            }
            if (k == 1) {
                return self.context.rng.intRangeAtMost(usize, 1, self.context.settings.max_level);
            }

            while (true) {
                var level: usize = 0;
                while (self.context.rng.intRangeAtMost(usize, 0, k - 1) == 0) {
                    level += 1;
                }

                if (level < self.context.settings.max_level) {
                    return level;
                }
            }
        }

        pub fn createNode(self: *Self, key: KeyT, value: ValueT) Error!NodeImpl {
            const ctx = &self.context;
            const level_field = try self.generateLevel(try self.generateTargetLevel());

            const slot_bytes = NodeViewConst.slotSizeNeeded(key.len, value.len, level_field);

            // find a page with room (fsm), else create a fresh one
            var ph: PageHandle = undefined;
            var page_id: BlockIdType = undefined;
            var is_new = false;
            if (try ctx.fsm.find(@intCast(slot_bytes))) |found| {
                var fph = try ctx.cache.fetch(found);
                const fits = blk: {
                    errdefer fph.deinit();
                    const fview = NodeViewMut.init(try fph.getDataMut());
                    const pos = try fview.entries();
                    break :blk (try fview.canInsert(pos, key, value, level_field)) == .enough;
                };
                if (fits) {
                    ph = fph;
                    page_id = found;
                } else {
                    fph.deinit();
                    ph = try self.createPage();
                    page_id = try ph.pid();
                    is_new = true;
                }
            } else {
                ph = try self.createPage();
                page_id = try ph.pid();
                is_new = true;
            }
            errdefer ph.deinit();

            var view = NodeViewMut.init(try ph.getDataMut());
            const slot_id = try view.entries();
            const sbytes = try view.reserveGet(slot_id, slot_bytes);

            const scratch = NodeViewMut.init(sbytes);
            const sw = try scratch.createSlot(sbytes, key.len, value.len, level_field);
            @memcpy(sw.key, key);
            @memcpy(sw.value, value);
            for (sw.levels) |*lr| {
                lr.format();
            }

            const free: u16 = @intCast(try (try view.slotsDir()).availableAfterCompact());
            if (is_new) {
                try ctx.fsm.add(page_id, free);
            } else {
                try ctx.fsm.update(page_id, free);
            }

            return NodeImpl.init(ph, .{
                .page_id = page_id,
                .slot_id = slot_id,
            });
        }

        pub fn loadNode(self: *Self, pid: Pid) Error!NodeImpl {
            var ph = try self.ctx.cache.fetch(pid.page_id);
            errdefer ph.deinit();
        }

        pub fn destroy(self: *Self, pid: PidImpl) void {
            self.destroyImpl(pid) catch {};
        }

        fn destroyImpl(self: *Self, pid: PidImpl) Error!void {
            var ph = try self.context.cache.fetch(pid.page_id);
            defer ph.deinit();
            var view = NodeViewMut.init(try ph.getDataMut());
            var sdir = try view.slotsDirMut();
            try sdir.free(pid.slot_id);
            const free: u16 = @intCast(try sdir.availableAfterCompact());
            try self.context.fsm.update(pid.page_id, free);
        }

        pub fn deinitNode(_: *const Self, node: *NodeImpl) void {
            node.deinit();
        }

        fn createPage(self: *Self) Error!PageHandle {
            var ph = try self.context.cache.create();
            errdefer ph.deinit();
            const pid = try ph.pid();
            var view = NodeViewMut.init(try ph.getDataMut());
            try view.formatPage(self.context.settings.node_page_kind, pid, 0);
            return ph;
        }
    };

    return struct {
        const Self = @This();

        pub const Error = PageCacheType.Error || StorageManager.Error;

        pub const Accessor = AccessorImpl;
        pub const Node = NodeImpl;
        pub const Pid = PidImpl;

        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;

        pub const KeyOut = KeyIn;
        pub const ValueOut = ValueIn;
        pub const Path = PathImpl;

        accessor: AccessorImpl,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, fsm: *FsmT, settings: Settings, ctx: Ctx, rng: std.Random) Self {
            return Self{
                .accessor = AccessorImpl.init(ContextImpl{
                    .settings = settings,
                    .rng = rng,
                    .cache = device,
                    .storage = storage_mgr,
                    .fsm = fsm,
                    .cmp_ctx = ctx,
                }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor = undefined; // Clear the accessor to release references to resources.
        }
    };

    //const BlockDevice = PageCacheType.UnderlyingDevice;
    // const PageHandle = PageCacheType.Handle;
    // const BlockIdType = BlockDevice.BlockId;
}
