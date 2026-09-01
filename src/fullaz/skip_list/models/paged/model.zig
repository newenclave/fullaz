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
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime FsmT: type,
    comptime AdditionalT: type,
    comptime cmp: anytype,
    comptime CtxT: type,
) type {
    const PageHandle = PageCacheT.Handle;
    const CachePageId = PageCacheT.Pid;
    const StructuralMutationCoordinator = core.structural_mutation.StructuralMutationCoordinator;
    const StructuralMutationError = core.structural_mutation.Error;
    const ErrorSet = PageCacheT.Error ||
        StorageManagerT.Error ||
        FsmT.Error ||
        errors.SlotsError ||
        StructuralMutationError;

    const KeyT = []const u8;
    const ValueT = []const u8;

    const NodeViewMut = SubheaderView(CachePageId, u16, AdditionalT, .little, false);
    const NodeViewConst = SubheaderView(CachePageId, u16, AdditionalT, .little, true);
    const ConstSlotWrapper = NodeViewConst.ConstSlotWrapper;
    const SlotWrapper = NodeViewMut.ConstSlotWrapper;

    const ContextImpl = struct {
        const Self = @This();
        settings: Settings,
        rng: std.Random = undefined,
        cache: *PageCacheT = undefined,
        storage: *StorageManagerT = undefined,
        fsm: *FsmT = undefined,
        cmp_ctx: CtxT = undefined,
        allocator: std.mem.Allocator = undefined,
    };

    const PidImpl = struct {
        const Self = @This();
        page_id: CachePageId,
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

        pub const Error = PageCacheT.Error || errors.SlotsError;
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

        pub fn getKey(self: *const Self) Error!KeyOut {
            const view = NodeViewConst.init(try self.ph.data());
            const sw = try view.get(self.pid.slot_id);
            return sw.key;
        }

        pub fn getValue(self: *const Self) Error!ValueOut {
            const view = NodeViewConst.init(try self.ph.data());
            const sw = try view.get(self.pid.slot_id);
            return sw.value;
        }

        pub fn getLevel(self: *const Self) Error!usize {
            const view = NodeViewConst.init(try self.ph.data());
            const sw = try view.get(self.pid.slot_id);
            return @as(usize, sw.header().level);
        }

        fn getLevelRef(self: *const Self, level: usize) Error!*const ConstSlotWrapper.LevelRef {
            const view = NodeViewConst.init(try self.ph.data());
            const sw = try view.get(self.pid.slot_id);
            const current_level = @as(usize, sw.header().level);
            if (level >= current_level) {
                return Error.OutOfBounds;
            }
            return &sw.levels[level];
        }

        fn getLevelRefMut(self: *Self, level: usize) Error!*SlotWrapper.LevelRef {
            var view = NodeViewMut.init(try self.ph.dataMut());
            const sw = try view.getMut(self.pid.slot_id);
            const current_level = @as(usize, sw.header().level);
            if (level >= current_level) {
                return Error.OutOfBounds;
            }
            return &sw.levels[level];
        }

        pub fn getPrev(self: *const Self, level: usize) Error!?Pid {
            const lvl_ref = try self.getLevelRef(level);
            if (lvl_ref.prev.page_id.isMax()) {
                return null;
            } else {
                return .{
                    .page_id = lvl_ref.prev.page_id.get(),
                    .slot_id = lvl_ref.prev.slot_id.get(),
                };
            }
        }

        pub fn getNext(self: *const Self, level: usize) Error!?Pid {
            const lvl_ref = try self.getLevelRef(level);
            if (lvl_ref.next.page_id.isMax()) {
                return null;
            } else {
                return .{
                    .page_id = lvl_ref.next.page_id.get(),
                    .slot_id = lvl_ref.next.slot_id.get(),
                };
            }
        }

        pub fn setPrev(self: *Self, level: usize, pid: ?Pid) Error!void {
            const lvl_ref = try self.getLevelRefMut(level);
            if (pid) |p| {
                lvl_ref.prev.page_id.set(p.page_id);
                lvl_ref.prev.slot_id.set(@intCast(p.slot_id));
            } else {
                lvl_ref.prev.page_id.setMax();
                lvl_ref.prev.slot_id.setMax();
            }
        }

        pub fn setNext(self: *Self, level: usize, pid: ?Pid) Error!void {
            const lvl_ref = try self.getLevelRefMut(level);
            if (pid) |p| {
                lvl_ref.next.page_id.set(p.page_id);
                lvl_ref.next.slot_id.set(@intCast(p.slot_id));
            } else {
                lvl_ref.next.page_id.setMax();
                lvl_ref.next.slot_id.setMax();
            }
        }
    };

    comptime {
        interfaces.assertNode(NodeImpl);
    }

    const AccessorImpl = struct {
        const Self = @This();

        pub const Node = NodeImpl;
        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;
        pub const Pid = PidImpl;
        pub const Error = ErrorSet;
        const ValueEditorImpl = struct {
            const EditorSelf = @This();

            pub const Error = ErrorSet;
            pub const ValueMutType = []u8;

            layout_lock: ?PageHandle.LayoutLock,
            snapshot: ?PageHandle,
            position: usize,
            value_len: usize,
            coordinator: *StructuralMutationCoordinator,
            open: bool = true,

            fn init(
                layout_lock: PageHandle.LayoutLock,
                snapshot: PageHandle,
                position: usize,
                value_len: usize,
                coordinator: *StructuralMutationCoordinator,
            ) EditorSelf {
                return .{
                    .layout_lock = layout_lock,
                    .snapshot = snapshot,
                    .position = position,
                    .value_len = value_len,
                    .coordinator = coordinator,
                };
            }

            pub fn valueMut(self: *EditorSelf) ErrorSet!ValueMutType {
                try self.ensureOpen();
                if (self.layout_lock) |*layout_lock| {
                    var view = NodeViewMut.init(try layout_lock.dataMut());
                    const value = (try view.getMut(self.position)).value;
                    if (value.len != self.value_len) {
                        return error.EditorInvalidated;
                    }
                    return value;
                }
                return error.EditorInvalidated;
            }

            pub fn finish(self: *EditorSelf) ErrorSet!void {
                try self.ensureOpen();
                self.close();
            }

            pub fn deinit(self: *EditorSelf) void {
                if (!self.open) {
                    return;
                }
                self.restore() catch @panic("SkipList value editor rollback failed");
                self.close();
            }

            fn ensureOpen(self: *const EditorSelf) ErrorSet!void {
                if (!self.open) {
                    return error.EditorInvalidated;
                }
            }

            fn restore(self: *EditorSelf) ErrorSet!void {
                if (self.layout_lock) |*layout_lock| {
                    if (self.snapshot) |*snapshot| {
                        const snapshot_bytes = try snapshot.data();
                        var view = NodeViewMut.init(try layout_lock.dataMut());
                        const value = (try view.getMut(self.position)).value;
                        if (value.len != self.value_len) {
                            return error.EditorInvalidated;
                        }
                        @memcpy(value, snapshot_bytes[0..self.value_len]);
                        return;
                    }
                }
                return error.EditorInvalidated;
            }

            fn close(self: *EditorSelf) void {
                if (self.layout_lock) |*layout_lock| {
                    layout_lock.deinit();
                    self.layout_lock = null;
                }
                if (self.snapshot) |*snapshot| {
                    snapshot.deinit();
                    self.snapshot = null;
                }
                self.coordinator.finishValueEditor();
                self.open = false;
            }
        };

        pub const ValueEditorType = ValueEditorImpl;
        pub const Path = PathImpl;

        context: ContextImpl,
        coordinator: StructuralMutationCoordinator = .{},

        fn init(ctx: ContextImpl) Self {
            return Self{
                .context = ctx,
                .coordinator = .{},
            };
        }

        pub fn generateLevel(self: *const Self, k: usize) Error!usize {
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

        pub fn checkCompactPage(self: *Self, ph: *PageHandle, key: KeyT, value: ValueT, level_field: usize) Error!bool {
            var fview = NodeViewMut.init(try ph.dataMut());
            const pos = try fview.entries();
            const available = try fview.canInsert(pos, key, value, level_field);
            if (available == .need_compact) {
                var tmp_page = self.context.cache.getTemporaryPage() catch {
                    try fview.compact(null);
                    return true;
                };
                defer tmp_page.deinit();
                try fview.compact(try tmp_page.dataMut());
                return true;
            }
            return available == .enough;
        }

        pub fn createNode(self: *Self, key: KeyT, value: ValueT) Error!NodeImpl {
            const ctx = &self.context;
            const level_field = try self.generateLevel(2) + 1;

            const full_slot_bytes = NodeViewConst.fullSlotSizeNeeded(key.len, value.len, level_field);
            const slot_bytes = NodeViewConst.slotSizeNeeded(key.len, value.len, level_field);

            // find a page with room (fsm), else create a fresh one
            var ph: PageHandle = undefined;
            var page_id: CachePageId = undefined;
            var is_new = false;
            if (try ctx.fsm.find(@intCast(full_slot_bytes))) |found| {
                var fph = try ctx.cache.fetch(found);
                errdefer fph.deinit();
                const fits = try self.checkCompactPage(&fph, key, value, level_field);
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

            var view = NodeViewMut.init(try ph.dataMut());
            const slot_id = try view.entries();
            const sbytes = try view.reserveGet(slot_id, slot_bytes);

            const sw = try view.createSlot(sbytes, key.len, value.len, level_field);
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

        pub fn loadNode(self: *const Self, pid: Pid) Error!NodeImpl {
            var ph = try self.context.cache.fetch(pid.page_id);
            errdefer ph.deinit();

            const view = NodeViewConst.init(try ph.data());
            if (view.header().kind.get() != self.context.settings.node_page_kind) {
                return Error.BadType;
            }
            return NodeImpl.init(ph, pid);
        }

        pub fn destroy(self: *Self, pid: PidImpl) void {
            self.destroyImpl(pid) catch {};
        }

        pub fn getRoot(self: *const Self, level: usize) Error!?PidImpl {
            const root_pid = try self.context.storage.getRoot(level);
            if (root_pid) |rp| {
                return .{
                    .page_id = rp.page_id,
                    .slot_id = rp.slot_id,
                };
            } else {
                return null;
            }
        }

        pub fn setRoot(self: *Self, level: usize, pid: ?PidImpl) Error!void {
            if (pid) |p| {
                try self.context.storage.setRoot(level, .{
                    .page_id = p.page_id,
                    .slot_id = p.slot_id,
                });
            } else {
                try self.context.storage.setRoot(level, null);
            }
        }

        fn destroyImpl(self: *Self, pid: PidImpl) Error!void {
            var ph = try self.context.cache.fetch(pid.page_id);
            defer ph.deinit();
            var view = NodeViewMut.init(try ph.dataMut());
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
            var view = NodeViewMut.init(try ph.dataMut());
            try view.formatPage(self.context.settings.node_page_kind, pid, 0);
            return ph;
        }

        pub fn createPath(self: *Self) Error!PathImpl {
            return PathImpl.init(
                self.context.allocator,
                self.context.settings.max_level,
            );
        }

        pub fn deinitPath(self: *Self, path: *PathImpl) void {
            path.deinit(self.context.allocator);
        }

        pub fn openValueEditor(self: *Self, node: *NodeImpl) Error!ValueEditorType {
            try self.coordinator.beginValueEditor();
            errdefer self.coordinator.finishValueEditor();
            const value = try node.getValue();
            var snapshot = try self.context.cache.getTemporaryPage();
            errdefer snapshot.deinit();
            const snapshot_bytes = try snapshot.dataMut();
            @memcpy(snapshot_bytes[0..value.len], value);
            var layout_lock = try node.ph.lockLayout();
            errdefer layout_lock.deinit();
            return ValueEditorType.init(
                layout_lock,
                snapshot,
                node.pid.slot_id,
                value.len,
                &self.coordinator,
            );
        }
    };

    return struct {
        const Self = @This();

        pub const Error = AccessorImpl.Error ||
            errors.NotFoundError ||
            errors.SetError;

        pub const AccessorType = AccessorImpl;
        pub const ValueEditorType = AccessorType.ValueEditorType;
        pub const Node = NodeImpl;
        pub const Pid = PidImpl;
        pub const PageId = CachePageId;

        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;

        pub const KeyOut = KeyIn;
        pub const ValueOut = ValueIn;
        pub const Path = PathImpl;

        accessor_state: AccessorType,

        pub fn init(
            device: *PageCacheT,
            storage_mgr: *StorageManagerT,
            fsm: *FsmT,
            settings: Settings,
            ctx: CtxT,
            rng: std.Random,
            allocator: std.mem.Allocator,
        ) Self {
            return Self{
                .accessor_state = AccessorImpl.init(ContextImpl{
                    .settings = settings,
                    .rng = rng,
                    .cache = device,
                    .storage = storage_mgr,
                    .fsm = fsm,
                    .cmp_ctx = ctx,
                    .allocator = allocator,
                }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor_state = undefined; // Clear the accessor to release references to resources.
        }

        pub fn scanPageRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const view = NodeViewConst.init(page);
            const settings = self.accessor_state.context.settings;
            try view.validatePage(page_id, settings.node_page_kind);
            const slots = try view.slotsDir();
            for (0..slots.size()) |index| {
                const slot_bytes = try slots.get(index);
                if (slot_bytes.len == 0) {
                    continue;
                }
                const node = try view.get(index);
                const next = node.levels[0].next;
                if (!next.page_id.isMax()) {
                    try visitor.visit(next.page_id.get());
                }
                if (visitor.hasValueScanner()) {
                    try visitor.visitValue(node.value);
                }
            }
        }

        pub fn getMaxLevel(self: *const Self) Error!usize {
            return self.accessor_state.context.settings.max_level;
        }

        pub fn accessor(self: *Self) *AccessorType {
            return &self.accessor_state;
        }

        pub fn structuralMutationCoordinator(self: *Self) *StructuralMutationCoordinator {
            return &self.accessor_state.coordinator;
        }

        pub fn keysCompare(self: *const Self, k1: KeyIn, k2: KeyIn) std.math.Order {
            const CmpReturnType = @TypeOf(cmp(self.accessor_state.context.cmp_ctx, k1, k2));
            const is_error_union = @typeInfo(CmpReturnType) == .error_union;

            const order = blk: {
                if (comptime is_error_union) {
                    break :blk cmp(self.accessor_state.context.cmp_ctx, k1, k2) catch return .eq;
                } else {
                    break :blk cmp(self.accessor_state.context.cmp_ctx, k1, k2);
                }
            };
            return order;
        }

        pub fn keyOutAsIn(_: *const Self, k: KeyOut) KeyIn {
            return k;
        }

        pub fn valueOutAsIn(_: *const Self, v: ValueOut) ValueIn {
            return v;
        }
    };
}
