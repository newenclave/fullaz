const std = @import("std");
const contracts = @import("../../../../contracts/contracts.zig");
const contract_interfaces = @import("../../../../contracts/interfaces.zig");
const errors = @import("../../../../core/errors.zig");
const page_header = @import("../../../../page/header.zig");
const slots = @import("../../../../slots/slots.zig");
const interfaces = @import("../interfaces.zig");
const view_mod = @import("view.zig");
const scanner = @import("../../scanner.zig");
const StructuralMutationCoordinator = @import("../../../../core/core.zig").structural_mutation.StructuralMutationCoordinator;

const requiresErrorDeclaration = contract_interfaces.requiresErrorDeclaration;
const requiresFnSignature = contract_interfaces.requiresFnSignature;
const requiresTypeDeclaration = contract_interfaces.requiresTypeDeclaration;

pub const Settings = struct {
    key_size: usize,
    maximum_value_size: usize,
    comparator_id: u32,
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
    maximum_level: usize = 32,
};

pub fn Paged(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime FsmT: type,
    comptime cmp: anytype,
    comptime CompareContextT: type,
) type {
    const CompareReturn = @typeInfo(@TypeOf(cmp)).@"fn".return_type orelse
        @compileError("slot-heap comparator must have a return type");
    comptime {
        if (CompareReturn != std.math.Order) {
            @compileError("slot-heap comparator must return std.math.Order");
        }
        contracts.page_cache.requiresPageCache(PageCacheT);
        requiresTypeDeclaration(FsmT, "Pid");
        requiresTypeDeclaration(FsmT, "Size");
        requiresErrorDeclaration(FsmT, "Error");
    }

    const NodeId = PageCacheT.Pid;
    const SlotId = u16;
    const Count = StorageManagerT.CountType;
    const Space = FsmT.Size;
    const MutableView = view_mod.View(NodeId, SlotId, .little, false);
    const ReadView = view_mod.View(NodeId, SlotId, .little, true);
    const Location = MutableView.LocationType;
    const HeaderView = page_header.View(NodeId, SlotId, .little, true);
    const LeafSlots = slots.Variadic(SlotId, .little, true);
    const PageHandle = PageCacheT.Handle;

    comptime {
        interfaces.assertPagedStorageManager(StorageManagerT, Location);
        requiresFnSignature(PageCacheT, "pageSize", fn (*const PageCacheT) usize);
        requiresFnSignature(PageHandle, "deinit", fn (*PageHandle) void);
        if (StorageManagerT.PageId != NodeId) {
            @compileError("Slot-heap storage manager PageId must match page cache Pid");
        }
        if (FsmT.Pid != NodeId) {
            @compileError("Slot-heap FSM Pid must match page cache Pid");
        }
        requiresFnSignature(FsmT, "find", fn (*FsmT, Space) FsmT.Error!?NodeId);
        requiresFnSignature(FsmT, "add", fn (*FsmT, NodeId, Space) FsmT.Error!void);
        requiresFnSignature(FsmT, "update", fn (*FsmT, NodeId, Space) FsmT.Error!void);
        requiresFnSignature(FsmT, "remove", fn (*FsmT, NodeId) FsmT.Error!void);
        const space_info = switch (@typeInfo(Space)) {
            .int => |info| info,
            else => @compileError("Slot-heap FSM Size must be an unsigned integer"),
        };
        if (space_info.signedness != .unsigned) {
            @compileError("Slot-heap FSM Size must be an unsigned integer");
        }
    }

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheT.Error ||
        StorageManagerT.Error ||
        FsmT.Error ||
        MutableView.Error ||
        @import("../../../../core/core.zig").structural_mutation.Error ||
        error{
            BadKeyLength,
            ComparatorMismatch,
            CountOverflow,
            EmptySet,
            InvalidSettings,
            MaxDepth,
            NodeFull,
            ValueTooLarge,
        };

    const Context = struct {
        cache: *PageCacheT,
        storage_manager: *StorageManagerT,
        fsm: *FsmT,
        compare_context: CompareContextT,
        settings: Settings,

        fn compare(self: *const @This(), left: []const u8, right: []const u8) std.math.Order {
            return cmp(self.compare_context, left, right);
        }
    };

    const helpers = struct {
        fn validateKey(settings: Settings, key: []const u8) ErrorSet!void {
            if (key.len != settings.key_size) {
                return ErrorSet.BadKeyLength;
            }
        }

        fn validateEntry(settings: Settings, key: []const u8, value: []const u8) ErrorSet!void {
            try validateKey(settings, key);
            if (value.len > settings.maximum_value_size) {
                return ErrorSet.ValueTooLarge;
            }
        }

        fn completeLeafSlotSize(key_size: usize, value_size: usize) ?usize {
            const content = std.math.add(usize, key_size, value_size) catch return null;
            return LeafSlots.fullSlotSize(content);
        }

        fn toSpace(byte_len: usize) ErrorSet!Space {
            return std.math.cast(Space, byte_len) orelse ErrorSet.BadData;
        }
    };
    const validateKey = helpers.validateKey;
    const validateEntry = helpers.validateEntry;
    const completeLeafSlotSize = helpers.completeLeafSlotSize;
    const toSpace = helpers.toSpace;

    const LeafImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;

        handle: PageHandle,
        self_id: NodeId,
        ctx: *Context,

        fn init(handle: PageHandle, self_id: NodeId, ctx: *Context) Self {
            return .{ .handle = handle, .self_id = self_id, .ctx = ctx };
        }

        fn readView(self: *const Self) Error!ReadView.Leaf {
            return ReadView.Leaf.init(try self.handle.data());
        }

        fn mutableView(self: *Self) Error!MutableView.Leaf {
            return MutableView.Leaf.init(try self.handle.dataMut());
        }

        fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn id(self: *const Self) NodeId {
            return self.self_id;
        }

        pub fn take(self: *Self) Error!Self {
            return .{
                .handle = try self.handle.take(),
                .self_id = self.self_id,
                .ctx = self.ctx,
            };
        }

        pub fn size(self: *const Self) Error!usize {
            return (try self.readView()).entries();
        }

        pub fn getParent(self: *const Self) Error!?NodeId {
            return (try self.readView()).getParent();
        }

        pub fn setParent(self: *Self, parent: ?NodeId) Error!void {
            var view = try self.mutableView();
            try view.setParent(parent);
        }

        pub fn getKey(self: *const Self, index: usize) Error![]const u8 {
            return (try (try self.readView()).get(index)).key;
        }

        pub fn getValue(self: *const Self, index: usize) Error![]const u8 {
            return (try (try self.readView()).get(index)).value;
        }

        pub fn canPush(self: *const Self, key: []const u8, value: []const u8) Error!bool {
            try validateEntry(self.ctx.settings, key, value);
            return (try (try self.readView()).canAppend(value.len)) != .not_enough;
        }

        pub fn push(self: *Self, key: []const u8, value: []const u8) Error!interfaces.WinnerChange {
            try validateEntry(self.ctx.settings, key, value);
            const status = try (try self.readView()).canAppend(value.len);
            if (status == .not_enough) {
                return Error.NodeFull;
            }
            if (status == .need_compact) {
                var scratch = try self.ctx.cache.getTemporaryPage();
                defer scratch.deinit();
                var view = try self.mutableView();
                view.compact(try scratch.dataMut()) catch {
                    try view.compactInPlace();
                };
            }
            var view = try self.mutableView();
            const final_index = try self.siftUp(&view, try view.append(key, value));
            return if (final_index == 0) .changed else .unchanged;
        }

        pub fn popTop(self: *Self) Error!void {
            var view = try self.mutableView();
            const count = try view.entries();
            if (count == 0) {
                return Error.EmptySet;
            }
            if (count > 1) {
                try view.swapEntries(0, count - 1);
            }
            try view.removeLast();
            if (count > 2) {
                _ = try self.siftDown(&view, 0);
            }
        }

        pub fn availableAfterCompact(self: *const Self) Error!Space {
            return toSpace(try (try self.readView()).availableAfterCompact());
        }

        pub fn usedBytes(self: *const Self) Error!usize {
            const view = try self.readView();
            return (try view.capacityBytes()) - (try view.availableAfterCompact());
        }

        pub fn capacityBytes(self: *const Self) Error!usize {
            return (try self.readView()).capacityBytes();
        }

        fn siftUp(self: *Self, view: *MutableView.Leaf, start: usize) Error!usize {
            var index = start;
            while (index > 0) {
                const parent = (index - 1) / 2;
                if (self.ctx.compare((try view.get(index)).key, (try view.get(parent)).key) != .lt) {
                    break;
                }
                try view.swapEntries(index, parent);
                index = parent;
            }
            return index;
        }

        fn siftDown(self: *Self, view: *MutableView.Leaf, start: usize) Error!usize {
            const count = try view.entries();
            var index = start;
            while (true) {
                const left = index * 2 + 1;
                if (left >= count) {
                    break;
                }
                const right = left + 1;
                var best = left;
                if (right < count and
                    self.ctx.compare((try view.get(right)).key, (try view.get(left)).key) == .lt)
                {
                    best = right;
                }
                if (self.ctx.compare((try view.get(best)).key, (try view.get(index)).key) != .lt) {
                    break;
                }
                try view.swapEntries(index, best);
                index = best;
            }
            return index;
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;

        handle: PageHandle,
        self_id: NodeId,
        ctx: *Context,

        fn init(handle: PageHandle, self_id: NodeId, ctx: *Context) Self {
            return .{ .handle = handle, .self_id = self_id, .ctx = ctx };
        }

        fn readView(self: *const Self) Error!ReadView.Inode {
            return ReadView.Inode.init(try self.handle.data());
        }

        fn mutableView(self: *Self) Error!MutableView.Inode {
            return MutableView.Inode.init(try self.handle.dataMut());
        }

        fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn id(self: *const Self) NodeId {
            return self.self_id;
        }

        pub fn take(self: *Self) Error!Self {
            return .{
                .handle = try self.handle.take(),
                .self_id = self.self_id,
                .ctx = self.ctx,
            };
        }

        pub fn size(self: *const Self) Error!usize {
            return (try self.readView()).entries();
        }

        pub fn capacity(self: *const Self) Error!usize {
            return (try self.readView()).capacity();
        }

        pub fn getLevel(self: *const Self) Error!usize {
            return (try self.readView()).getLevel();
        }

        pub fn getParent(self: *const Self) Error!?NodeId {
            return (try self.readView()).getParent();
        }

        pub fn setParent(self: *Self, parent: ?NodeId) Error!void {
            var view = try self.mutableView();
            try view.setParent(parent);
        }

        pub fn getAvailablePrev(self: *const Self) Error!?NodeId {
            return (try self.readView()).getAvailablePrev();
        }

        pub fn setAvailablePrev(self: *Self, previous: ?NodeId) Error!void {
            var view = try self.mutableView();
            try view.setAvailablePrev(previous);
        }

        pub fn getAvailableNext(self: *const Self) Error!?NodeId {
            return (try self.readView()).getAvailableNext();
        }

        pub fn setAvailableNext(self: *Self, next: ?NodeId) Error!void {
            var view = try self.mutableView();
            try view.setAvailableNext(next);
        }

        pub fn isAvailableLinked(self: *const Self) Error!bool {
            return (try self.readView()).isAvailableLinked();
        }

        pub fn setAvailableLinked(self: *Self, linked: bool) Error!void {
            var view = try self.mutableView();
            view.setAvailableLinked(linked);
        }

        pub fn findChild(self: *const Self, child: NodeId) Error!?usize {
            return (try self.readView()).findChild(child);
        }

        pub fn getKey(self: *const Self, index: usize) Error![]const u8 {
            return (try (try self.readView()).get(index)).key;
        }

        pub fn getChild(self: *const Self, index: usize) Error!NodeId {
            return (try (try self.readView()).get(index)).child_pid;
        }

        pub fn getWinner(self: *const Self, index: usize) Error!Location {
            return (try (try self.readView()).get(index)).leaf_top;
        }

        pub fn insertChild(
            self: *Self,
            key: []const u8,
            child: NodeId,
            winner: Location,
        ) Error!interfaces.WinnerChange {
            try validateKey(self.ctx.settings, key);
            var view = try self.mutableView();
            const final_index = self.siftUp(&view, try view.append(key, child, winner)) catch |err| {
                if (err == error.NotEnoughSpace) {
                    return Error.NodeFull;
                }
                return err;
            };
            return if (final_index == 0) .changed else .unchanged;
        }

        pub fn updateChild(
            self: *Self,
            index: usize,
            key: []const u8,
            winner: Location,
        ) Error!interfaces.WinnerChange {
            try validateKey(self.ctx.settings, key);
            var view = try self.mutableView();
            const old = try view.get(index);
            const order = self.ctx.compare(key, old.key);
            try view.setEntry(index, key, old.child_pid, winner);
            const final_index = switch (order) {
                .lt => try self.siftUp(&view, index),
                .gt => try self.siftDown(&view, index),
                .eq => index,
            };
            return if (index == 0 or final_index == 0) .changed else .unchanged;
        }

        pub fn removeChild(self: *Self, index: usize) Error!interfaces.WinnerChange {
            var view = try self.mutableView();
            const count = try view.entries();
            if (index >= count) {
                return Error.OutOfBounds;
            }
            if (index != count - 1) {
                try view.swapEntries(index, count - 1);
            }
            try view.removeLast();
            if (index >= count - 1) {
                return if (index == 0) .changed else .unchanged;
            }
            const final_index = try self.fixAt(&view, index);
            return if (index == 0 or final_index == 0) .changed else .unchanged;
        }

        fn fixAt(self: *Self, view: *MutableView.Inode, index: usize) Error!usize {
            if (index > 0) {
                const parent = (index - 1) / 2;
                if (self.ctx.compare((try view.get(index)).key, (try view.get(parent)).key) == .lt) {
                    return self.siftUp(view, index);
                }
            }
            return self.siftDown(view, index);
        }

        fn siftUp(self: *Self, view: *MutableView.Inode, start: usize) Error!usize {
            var index = start;
            while (index > 0) {
                const parent = (index - 1) / 2;
                if (self.ctx.compare((try view.get(index)).key, (try view.get(parent)).key) != .lt) {
                    break;
                }
                try view.swapEntries(index, parent);
                index = parent;
            }
            return index;
        }

        fn siftDown(self: *Self, view: *MutableView.Inode, start: usize) Error!usize {
            const count = try view.entries();
            var index = start;
            while (true) {
                const left = index * 2 + 1;
                if (left >= count) {
                    break;
                }
                const right = left + 1;
                var best = left;
                if (right < count and
                    self.ctx.compare((try view.get(right)).key, (try view.get(left)).key) == .lt)
                {
                    best = right;
                }
                if (self.ctx.compare((try view.get(best)).key, (try view.get(index)).key) != .lt) {
                    break;
                }
                try view.swapEntries(index, best);
                index = best;
            }
            return index;
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;

        ctx: Context,
        coordinator: StructuralMutationCoordinator = .{},

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

            pub fn valueMut(self: *EditorSelf) ErrorSet![]u8 {
                try self.ensureOpen();
                if (self.layout_lock) |*layout_lock| {
                    var view = MutableView.Leaf.init(try layout_lock.dataMut());
                    const value = try view.getValueMut(self.position);
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
                self.restore() catch @panic("SlotHeap value editor rollback failed");
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
                        var view = MutableView.Leaf.init(try layout_lock.dataMut());
                        const value = try view.getValueMut(self.position);
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

        fn init(
            cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            fsm: *FsmT,
            compare_context: CompareContextT,
            settings: Settings,
        ) Self {
            return .{ .ctx = .{
                .cache = cache,
                .storage_manager = storage_manager,
                .fsm = fsm,
                .compare_context = compare_context,
                .settings = settings,
            }, .coordinator = .{} };
        }

        pub fn getRoot(self: *const Self) ?NodeId {
            return self.ctx.storage_manager.getRoot();
        }

        pub fn setRoot(self: *Self, root: ?NodeId) Error!void {
            try self.ctx.storage_manager.setRoot(root);
        }

        pub fn getCachedTop(self: *const Self) ?Location {
            return self.ctx.storage_manager.getCachedTop();
        }

        pub fn setCachedTop(self: *Self, top: ?Location) Error!void {
            try self.ctx.storage_manager.setCachedTop(top);
        }

        pub fn getAvailableInode(self: *const Self, level: usize) Error!?NodeId {
            return self.ctx.storage_manager.getAvailableInode(level);
        }

        pub fn setAvailableInode(self: *Self, level: usize, inode: ?NodeId) Error!void {
            try self.ctx.storage_manager.setAvailableInode(level, inode);
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            var handle = try self.ctx.cache.create();
            var created_page_id: ?NodeId = null;
            errdefer {
                handle.deinit();
                if (created_page_id) |page_id| {
                    self.ctx.storage_manager.destroyPage(page_id) catch {};
                }
            }
            const page_id = try handle.pid();
            created_page_id = page_id;
            if (page_id == std.math.maxInt(NodeId)) {
                return Error.BadData;
            }
            var view = MutableView.Leaf.init(try handle.dataMut());
            try view.formatPage(
                self.ctx.settings.leaf_page_kind,
                page_id,
                self.ctx.settings.key_size,
                self.ctx.settings.comparator_id,
            );
            return LeafImpl.init(try handle.take(), page_id, &self.ctx);
        }

        pub fn createInode(self: *Self, level: usize) Error!InodeImpl {
            if (level == 0 or level > self.ctx.settings.maximum_level or
                std.math.cast(SlotId, level) == null)
            {
                return Error.MaxDepth;
            }
            var handle = try self.ctx.cache.create();
            var created_page_id: ?NodeId = null;
            errdefer {
                handle.deinit();
                if (created_page_id) |page_id| {
                    self.ctx.storage_manager.destroyPage(page_id) catch {};
                }
            }
            const page_id = try handle.pid();
            created_page_id = page_id;
            if (page_id == std.math.maxInt(NodeId)) {
                return Error.BadData;
            }
            var view = MutableView.Inode.init(try handle.dataMut());
            try view.formatPage(
                self.ctx.settings.inode_page_kind,
                page_id,
                level,
                self.ctx.settings.key_size,
                self.ctx.settings.comparator_id,
            );
            return InodeImpl.init(try handle.take(), page_id, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, page_id: NodeId) Error!?LeafImpl {
            if (page_id == std.math.maxInt(NodeId)) {
                return Error.BadData;
            }
            var handle = try self.ctx.cache.fetch(page_id);
            errdefer handle.deinit();
            const kind = try pageKind(&handle);
            if (kind == self.ctx.settings.inode_page_kind) {
                const view = ReadView.Inode.init(try handle.data());
                try view.validatePage(
                    page_id,
                    self.ctx.settings.inode_page_kind,
                    self.ctx.settings.key_size,
                    self.ctx.settings.comparator_id,
                );
                handle.deinit();
                return null;
            }
            if (kind != self.ctx.settings.leaf_page_kind) {
                return Error.BadType;
            }
            const view = ReadView.Leaf.init(try handle.data());
            try view.validatePage(
                page_id,
                self.ctx.settings.leaf_page_kind,
                self.ctx.settings.key_size,
                self.ctx.settings.comparator_id,
            );
            return LeafImpl.init(try handle.take(), page_id, &self.ctx);
        }

        pub fn loadInode(self: *Self, page_id: NodeId) Error!?InodeImpl {
            if (page_id == std.math.maxInt(NodeId)) {
                return Error.BadData;
            }
            var handle = try self.ctx.cache.fetch(page_id);
            errdefer handle.deinit();
            const kind = try pageKind(&handle);
            if (kind == self.ctx.settings.leaf_page_kind) {
                const view = ReadView.Leaf.init(try handle.data());
                try view.validatePage(
                    page_id,
                    self.ctx.settings.leaf_page_kind,
                    self.ctx.settings.key_size,
                    self.ctx.settings.comparator_id,
                );
                handle.deinit();
                return null;
            }
            if (kind != self.ctx.settings.inode_page_kind) {
                return Error.BadType;
            }
            const view = ReadView.Inode.init(try handle.data());
            try view.validatePage(
                page_id,
                self.ctx.settings.inode_page_kind,
                self.ctx.settings.key_size,
                self.ctx.settings.comparator_id,
            );
            return InodeImpl.init(try handle.take(), page_id, &self.ctx);
        }

        pub fn deinitLeaf(_: *Self, maybe_leaf: ?LeafImpl) void {
            if (maybe_leaf) |leaf_value| {
                var leaf = leaf_value;
                leaf.deinit();
            }
        }

        pub fn deinitInode(_: *Self, maybe_inode: ?InodeImpl) void {
            if (maybe_inode) |inode_value| {
                var inode = inode_value;
                inode.deinit();
            }
        }

        pub fn isLeafId(self: *Self, page_id: NodeId) Error!bool {
            if (page_id == std.math.maxInt(NodeId)) {
                return Error.BadData;
            }
            var handle = try self.ctx.cache.fetch(page_id);
            defer handle.deinit();
            const kind = try pageKind(&handle);
            if (kind == self.ctx.settings.leaf_page_kind) {
                const view = ReadView.Leaf.init(try handle.data());
                try view.validatePage(
                    page_id,
                    kind,
                    self.ctx.settings.key_size,
                    self.ctx.settings.comparator_id,
                );
                return true;
            }
            if (kind == self.ctx.settings.inode_page_kind) {
                const view = ReadView.Inode.init(try handle.data());
                try view.validatePage(
                    page_id,
                    kind,
                    self.ctx.settings.key_size,
                    self.ctx.settings.comparator_id,
                );
                return false;
            }
            return Error.BadType;
        }

        pub fn destroy(self: *Self, page_id: NodeId) Error!void {
            try self.ctx.storage_manager.destroyPage(page_id);
        }

        pub fn findLeaf(self: *Self, required: Space) Error!?NodeId {
            return self.ctx.fsm.find(required);
        }

        pub fn addLeafSpace(self: *Self, page_id: NodeId, free: Space) Error!void {
            try self.ctx.fsm.add(page_id, free);
        }

        pub fn updateLeafSpace(self: *Self, page_id: NodeId, free: Space) Error!void {
            try self.ctx.fsm.update(page_id, free);
        }

        pub fn removeLeafSpace(self: *Self, page_id: NodeId) Error!void {
            try self.ctx.fsm.remove(page_id);
        }

        pub fn openValueEditor(self: *Self, leaf: *LeafImpl, index: usize) Error!ValueEditorType {
            try self.coordinator.beginValueEditor();
            errdefer self.coordinator.finishValueEditor();

            const value = try leaf.getValue(index);
            var snapshot = try self.ctx.cache.getTemporaryPage();
            errdefer snapshot.deinit();
            const snapshot_bytes = try snapshot.dataMut();
            @memcpy(snapshot_bytes[0..value.len], value);

            var layout_lock = try leaf.handle.lockLayout();
            errdefer layout_lock.deinit();
            return .{
                .layout_lock = layout_lock,
                .snapshot = snapshot,
                .position = index,
                .value_len = value.len,
                .coordinator = &self.coordinator,
            };
        }

        fn pageKind(handle: *const PageHandle) Error!u16 {
            const header = HeaderView.init(try handle.data());
            try header.validateTyped();
            return header.header().kind.get();
        }
    };

    return struct {
        const Self = @This();

        pub const NodeIdType = NodeId;
        pub const SlotIdType = SlotId;
        pub const LocationType = Location;
        pub const CountType = Count;
        pub const SpaceType = Space;
        pub const KeyInType = []const u8;
        pub const KeyOutType = []const u8;
        pub const ValueInType = []const u8;
        pub const ValueOutType = []const u8;
        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;
        pub const AccessorType = AccessorImpl;
        pub const ValueEditorType = AccessorType.ValueEditorType;
        pub const Error = ErrorSet;

        accessor_state: AccessorType,

        pub fn init(
            cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            fsm: *FsmT,
            settings: Settings,
            compare_context: CompareContextT,
        ) Error!Self {
            if (settings.key_size == 0 or
                settings.leaf_page_kind == settings.inode_page_kind or
                settings.maximum_level == 0 or
                std.math.cast(SlotId, settings.maximum_level) == null or
                std.math.cast(SlotId, settings.key_size) == null)
            {
                return Error.InvalidSettings;
            }
            const maximum_content = std.math.add(
                usize,
                settings.key_size,
                settings.maximum_value_size,
            ) catch return Error.InvalidSettings;
            if (std.math.cast(SlotId, maximum_content) == null or
                completeLeafSlotSize(settings.key_size, settings.maximum_value_size) == null or
                std.math.cast(SlotId, cache.pageSize()) == null or
                std.math.cast(Space, cache.pageSize()) == null)
            {
                return Error.InvalidSettings;
            }

            var scratch = try cache.getTemporaryPage();
            defer scratch.deinit();
            var leaf = MutableView.Leaf.init(try scratch.dataMut());
            leaf.formatPage(
                settings.leaf_page_kind,
                0,
                settings.key_size,
                settings.comparator_id,
            ) catch return Error.InvalidSettings;
            if ((leaf.canAppend(settings.maximum_value_size) catch return Error.InvalidSettings) == .not_enough) {
                return Error.InvalidSettings;
            }
            var inode = MutableView.Inode.init(try scratch.dataMut());
            inode.formatPage(
                settings.inode_page_kind,
                0,
                1,
                settings.key_size,
                settings.comparator_id,
            ) catch return Error.InvalidSettings;
            if ((inode.capacity() catch return Error.InvalidSettings) < 2) {
                return Error.InvalidSettings;
            }

            return .{
                .accessor_state = AccessorType.init(
                    cache,
                    storage_manager,
                    fsm,
                    compare_context,
                    settings,
                ),
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn scanLeafRefs(
            self: *const Self,
            page_id: NodeId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const settings = self.accessor_state.ctx.settings;
            return scanner.scanLeafRefs(
                NodeId,
                SlotId,
                .little,
                page_id,
                page,
                settings.leaf_page_kind,
                settings.key_size,
                settings.comparator_id,
                visitor,
            );
        }

        pub fn scanInodeRefs(
            self: *const Self,
            page_id: NodeId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const settings = self.accessor_state.ctx.settings;
            return scanner.scanInodeRefs(
                NodeId,
                SlotId,
                .little,
                page_id,
                page,
                settings.inode_page_kind,
                settings.key_size,
                settings.comparator_id,
                visitor,
            );
        }

        pub fn accessor(self: *Self) *AccessorType {
            return &self.accessor_state;
        }

        pub fn structuralMutationCoordinator(self: *Self) *StructuralMutationCoordinator {
            return &self.accessor_state.coordinator;
        }

        pub fn compareKeys(
            self: *const Self,
            left: KeyOutType,
            right: KeyOutType,
        ) Error!std.math.Order {
            return self.accessor_state.ctx.compare(left, right);
        }

        pub fn keyOutAsIn(_: *const Self, key: KeyOutType) KeyInType {
            return key;
        }

        pub fn requiredLeafSpace(
            self: *const Self,
            key: KeyInType,
            value: ValueInType,
        ) Error!Space {
            try validateEntry(self.accessor_state.ctx.settings, key, value);
            const byte_len = completeLeafSlotSize(key.len, value.len) orelse {
                return Error.ValueTooLarge;
            };
            return toSpace(byte_len);
        }

        pub fn maxLevel(self: *const Self) usize {
            return self.accessor_state.ctx.settings.maximum_level;
        }

        pub fn incrementEntriesCount(self: *Self) Error!void {
            const count = try self.accessor_state.ctx.storage_manager.getEntriesCount();
            const next = std.math.add(Count, count, 1) catch return Error.CountOverflow;
            try self.accessor_state.ctx.storage_manager.setEntriesCount(next);
        }

        pub fn decrementEntriesCount(self: *Self) Error!void {
            const count = try self.accessor_state.ctx.storage_manager.getEntriesCount();
            const next = std.math.sub(Count, count, 1) catch return Error.CountOverflow;
            try self.accessor_state.ctx.storage_manager.setEntriesCount(next);
        }

        pub fn getEntriesCount(self: *const Self) Error!Count {
            return self.accessor_state.ctx.storage_manager.getEntriesCount();
        }
    };
}
