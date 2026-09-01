const std = @import("std");
const wbpt_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;

pub const Settings = struct {
    maximum_value_size: usize = 256,
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
};

pub fn PagedModel(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime WeightT: type,
    comptime ValuePolicyT: type,
) type {
    comptime {
        contracts.storage_manager.requiresStorageManager(StorageManagerT);
        contracts.page_cache.requiresPageCache(PageCacheT);
    }

    const PageHandle = PageCacheT.Handle;
    const CachePageId = PageCacheT.Pid;
    const Weight = WeightT;
    const Index = u16;

    const Value = []const u8;

    const WBptPage = wbpt_page.View(CachePageId, Index, Weight, .little, false);
    const WBptPageConst = wbpt_page.View(CachePageId, Index, Weight, .little, true);

    const NodePosition = struct {
        pos: usize,
        diff: Weight,
        accumulated: Weight,
    };

    const Context = struct {
        cache: *PageCacheT = undefined,
        storage_mgr: *StorageManagerT = undefined,
        settings: Settings = undefined,
    };

    const ValuePolicyImplDefault = struct {
        const Self = @This();

        const Error = errors.HandleError ||
            errors.IndexError ||
            PageCacheT.Error ||
            errors.PageError;

        ctx: *Context = undefined,
        ph: ?PageHandle = null,
        val: Value,
        pub fn init(ctx: *Context, val: Value) Self {
            return Self{
                .ctx = ctx,
                .val = val,
            };
        }
        pub fn deinit(self: *Self) void {
            if (self.ph) |*hdl| {
                hdl.deinit();
            }
        }

        pub fn weight(self: *const Self) Error!Weight {
            return @as(Weight, @intCast(self.val.len));
        }

        pub fn get(self: *const Self) Error!Value {
            return self.val;
        }

        pub fn splitOfRight(self: *Self, pos: Weight) Error!Self {
            if (pos > try self.weight()) {
                return Error.OutOfBounds;
            }
            const result_weight = try self.weight() - pos;
            const result_len: usize = @intCast(result_weight);
            var tmp_page = try self.ctx.cache.getTemporaryPage();
            errdefer tmp_page.deinit();
            const page_data = try tmp_page.dataMut();
            const new_data = page_data[0..result_len];
            @memcpy(new_data, self.val[self.val.len - result_len ..]);
            self.val = self.val[0 .. self.val.len - result_len];
            var result = Self.init(self.ctx, new_data);
            result.ph = tmp_page;
            return result;
        }

        pub fn splitOfLeft(self: *Self, pos: Weight) Error!Self {
            if (pos > try self.weight()) {
                return Error.OutOfBounds;
            }
            const split_len: usize = @intCast(pos);
            var tmp_page = try self.ctx.cache.getTemporaryPage();
            errdefer tmp_page.deinit();
            const page_data = try tmp_page.dataMut();
            const new_data = page_data[0..split_len];
            @memcpy(new_data, self.val[0..split_len]);
            self.val = self.val[split_len..];
            var result = Self.init(self.ctx, new_data);
            result.ph = tmp_page;
            return result;
        }

        const SplitFormat = struct {
            left: usize,
            right: usize,
        };

        pub fn expectedSplitDataFormat(_: *const Self, val: Value, _: usize) SplitFormat {
            return .{
                .left = val.len,
                .right = val.len,
            };
        }
    };

    const ValuePolicyType = comptime if (@typeInfo(ValuePolicyT) == .void)
        ValuePolicyImplDefault
    else
        ValuePolicyT;

    const ValueViewImpl = struct {
        const Self = @This();
        const Error = ValuePolicyType.Error;

        val: Value,

        pub fn init(val: Value) error{}!Self {
            return Self{
                .val = val,
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn weight(self: *const Self) error{}!Weight {
            return @as(Weight, @intCast(self.val.len));
        }

        pub fn get(self: *const Self) error{}!Value {
            return self.val;
        }
    };

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheT.Error ||
        errors.OrderError ||
        errors.BptError ||
        core.structural_mutation.Error;

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = WBptPage.LeafSubheaderView;
        const PageViewTypeConst = WBptPageConst.LeafSubheaderView;

        handle: PageHandle = undefined,
        self_id: CachePageId = undefined,
        ctx: *Context = undefined,

        pub const Error = ErrorSet;

        fn init(ph: PageHandle, self_id: CachePageId, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn size(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.entries();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.capacityFor(self.ctx.settings.maximum_value_size);
        }

        pub fn isUnderflowed(self: *const Self) Error!bool {
            const view = PageViewTypeConst.init(try self.handle.data());
            const slots = try view.slotsDir();
            const page_cap = slots.capacitySpace();
            const page_used = try slots.usedSpace();

            return page_used < page_cap / 2;
        }

        pub fn id(self: *const Self) CachePageId {
            return self.self_id;
        }

        pub fn totalWeight(self: *const Self) Error!Weight {
            const view = PageViewTypeConst.init(try self.handle.data());
            var total: Weight = 0;
            for (0..try view.entries()) |idx| {
                const entry = try view.get(idx);
                total += entry.weight;
            }
            return total;
        }

        pub fn getParent(self: *const Self) Error!?CachePageId {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.getParent();
        }

        pub fn setParent(self: *Self, parent: ?CachePageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParent(parent);
        }

        pub fn getPrev(self: *const Self) Error!?CachePageId {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.getPrev();
        }

        pub fn setPrev(self: *Self, prev: ?CachePageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setPrev(prev);
        }

        pub fn getNext(self: *const Self) Error!?CachePageId {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.getNext();
        }

        pub fn setNext(self: *Self, next: ?CachePageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setNext(next);
        }

        pub fn getValue(self: *const Self, pos: usize) Error!ValuePolicyType {
            const view = PageViewTypeConst.init(try self.handle.data());
            const wv = try view.get(pos);
            return ValuePolicyType.init(self.ctx, wv.value);
        }

        pub fn updateValueWeight(self: *Self, pos: usize, weight: Weight) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.updateWeight(pos, weight);
        }

        fn compact(self: *Self, tmp_buf: []u8) Error!void {
            var view_mut = PageViewType.init(try self.handle.dataMut());
            var slots_dir = try view_mut.slotsDirMut();
            slots_dir.compactWithBuffer(tmp_buf) catch {
                try slots_dir.compactInPlace();
            };
        }

        fn insertAtWithBuf(self: *Self, pos: usize, val: Value, tmp_buf: []u8) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());

            var vp = ValuePolicyType.init(self.ctx, val);
            defer vp.deinit();

            const res = try view.canInsert(try vp.get());
            if (res == .not_enough) {
                return Error.NodeFull;
            } else if (res == .need_compact) {
                try self.compact(tmp_buf);
            }

            var view_mut = PageViewType.init(try self.handle.dataMut());
            try view_mut.insert(pos, try vp.weight(), try vp.get());
        }

        pub fn insertAt(self: *Self, pos: usize, val: Value) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());

            var vp = ValuePolicyType.init(self.ctx, val);
            defer vp.deinit();

            const res = try view.canInsert(try vp.get());
            if (res == .not_enough) {
                return Error.NodeFull;
            } else if (res == .need_compact) {
                var tmp_page = try self.ctx.cache.getTemporaryPage();
                defer tmp_page.deinit();
                const tmp_buf = try tmp_page.dataMut();
                try self.compact(tmp_buf);
            }

            var view_mut = PageViewType.init(try self.handle.dataMut());
            try view_mut.insert(pos, try vp.weight(), try vp.get());
        }

        // TODO: should be fixed. As we need to take in account the weight of values, that can be updated/removed
        pub fn canInsertWeight(self: *const Self, where: Weight, val: Value) Error!bool {
            const view = PageViewTypeConst.init(try self.handle.data());

            const pos = try self.selectPos(where);

            if (pos.diff == 0) {
                var vp = ValuePolicyType.init(self.ctx, val);
                defer vp.deinit();
                return try view.canInsert(try vp.get()) != .not_enough;
            } else {
                const entry = try view.get(pos.pos);
                var target_val = ValuePolicyType.init(self.ctx, entry.value);
                defer target_val.deinit();

                var new_val = ValuePolicyType.init(self.ctx, val);
                defer new_val.deinit();

                const expected_split_format = target_val.expectedSplitDataFormat(
                    try target_val.get(),
                    @intCast(pos.diff),
                );
                const new_val_size = (try new_val.get()).len;

                const res = try view.canInsert2(expected_split_format.right, new_val_size);

                return res != .not_enough;
            }
        }

        pub fn insertWeight(self: *Self, where: Weight, val: Value) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());

            var vp = ValuePolicyType.init(self.ctx, val);
            defer vp.deinit();

            const pos = try self.selectPos(where);
            if (pos.diff == 0) {
                try self.insertAt(pos.pos, val);
            } else {
                var val_at_pos = try self.getValue(pos.pos);
                defer val_at_pos.deinit();

                var policy = ValuePolicyType.init(self.ctx, try val_at_pos.get());
                defer policy.deinit();

                var new_policy = try policy.splitOfRight(pos.diff);
                defer new_policy.deinit();

                var tmp_page = try self.ctx.cache.getTemporaryPage();
                defer tmp_page.deinit();
                const tmp_buf = try tmp_page.dataMut();

                try view.update(pos.pos, try policy.weight(), try policy.get(), tmp_buf);
                try self.insertAtWithBuf(pos.pos + 1, try new_policy.get(), tmp_buf);
                try self.insertAtWithBuf(pos.pos + 1, try vp.get(), tmp_buf);
            }
        }

        pub fn removeAt(self: *Self, pos: usize) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            var slots_dir = try view.slotsDirMut();
            return slots_dir.remove(pos);
        }

        pub fn selectPos(self: *const Self, weight: Weight) Error!NodePosition {
            const view = PageViewTypeConst.init(try self.handle.data());
            var accumulated: Weight = 0;
            const entries = try view.entries();
            for (0..entries) |idx| {
                const current = try view.get(idx);
                const cweight = current.weight;
                accumulated += cweight;
                if (accumulated > weight) {
                    const diff = accumulated - weight;
                    const current_diff = (cweight - diff);
                    return .{
                        .pos = idx,
                        .diff = current_diff,
                        .accumulated = accumulated - cweight,
                    };
                } else if (accumulated == weight) {
                    return .{
                        .pos = idx + 1,
                        .diff = 0,
                        .accumulated = accumulated,
                    };
                }
            }
            return .{
                .pos = entries,
                .diff = 0,
                .accumulated = accumulated,
            };
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const PageViewType = WBptPage.InodeSubheaderView;
        const PageViewTypeConst = WBptPageConst.InodeSubheaderView;
        const AvailableStatus = WBptPageConst.SlotsAvailableStatus;
        const SlotType = WBptPageConst.InodeSlotType;

        pub const Error = ErrorSet;

        handle: PageHandle = undefined,
        self_id: CachePageId = undefined,
        ctx: *Context = undefined,

        fn init(ph: PageHandle, self_id: CachePageId, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn id(self: *const Self) CachePageId {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.entries();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.capacityFor();
        }

        pub fn isUnderflowed(self: *const Self) Error!bool {
            const sz = try self.size();
            const cap = try self.capacity();
            return sz < (cap / 2);
        }

        pub fn totalWeight(self: *const Self) Error!Weight {
            const view = PageViewTypeConst.init(try self.handle.data());
            return view.subheader().total_weight.get();
        }

        pub fn getParent(self: *const Self) Error!?CachePageId {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.getParent();
        }

        pub fn setParent(self: *Self, parent: ?CachePageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParent(parent);
        }

        fn compact(self: *Self, tmp_buf: []u8) Error!void {
            var view_mut = PageViewType.init(try self.handle.dataMut());
            var slots_dir = try view_mut.slotsDirMut();
            slots_dir.compactWithBuffer(tmp_buf) catch {
                try slots_dir.compactInPlace();
            };
        }

        pub fn insertChild(self: *Self, pos: usize, child: CachePageId, weight: Weight) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());

            const available = try self.canInsertImpl(pos, weight);
            if (available == .not_enough) {
                return Error.NotEnoughSpace;
            } else if (available == .need_compact) {
                var tmp_page = try self.ctx.cache.getTemporaryPage();
                defer tmp_page.deinit();
                const tmp_buf = try tmp_page.dataMut();
                try self.compact(tmp_buf);
            }

            try view.insert(pos, child, weight);
        }

        pub fn removeAt(self: *Self, pos: usize) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.remove(pos);
        }

        pub fn getChild(self: *const Self, pos: usize) Error!CachePageId {
            const view = PageViewTypeConst.init(try self.handle.data());
            return (try view.get(pos)).child;
        }

        pub fn getWeight(self: *const Self, pos: usize) Error!Weight {
            const view = PageViewTypeConst.init(try self.handle.data());
            return (try view.get(pos)).weight;
        }

        pub fn updateWeight(self: *Self, pos: usize, new_weight: Weight) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.updateWeight(pos, new_weight);
        }

        pub fn updateChild(self: *Self, pos: usize, new_child: CachePageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.updateChild(pos, new_child);
        }

        pub fn selectPos(self: *const Self, weight: Weight) Error!NodePosition {
            const view = PageViewTypeConst.init(try self.handle.data());
            var accumulated: Weight = 0;
            const entries = try view.entries();
            if (entries == 0) {
                return .{
                    .pos = 0,
                    .diff = weight,
                    .accumulated = 0,
                };
            }
            const last_entry = entries - 1;
            for (0..last_entry) |idx| {
                const current = try view.get(idx);
                const cweight = current.weight;
                accumulated += cweight;
                if (accumulated > weight) {
                    const diff = accumulated - weight;
                    const current_diff = (cweight - diff);
                    return .{
                        .pos = idx,
                        .diff = current_diff,
                        .accumulated = accumulated - cweight,
                    };
                } else if (accumulated == weight) {
                    return .{
                        .pos = idx + 1,
                        .diff = 0,
                        .accumulated = accumulated,
                    };
                }
            }
            return .{
                .pos = last_entry,
                .diff = weight - accumulated,
                .accumulated = accumulated,
            };
        }

        fn canInsertImpl(self: *const Self, pos: usize, weight: Weight) Error!AvailableStatus {
            const view = PageViewTypeConst.init(try self.handle.data());
            return try view.canInsert(pos, weight);
        }

        pub fn canInsertAt(self: *const Self, pos: usize, weight: Weight) Error!bool {
            return try self.canInsertImpl(pos, weight) != .not_enough;
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        const AccessorSelf = Self;

        pub const Pid = CachePageId;
        pub const Error = ErrorSet;

        ctx: Context = undefined,
        coordinator: core.structural_mutation.StructuralMutationCoordinator = .{},

        const ValueEditorImpl = struct {
            const EditorSelf = @This();

            pub const Error = ErrorSet;
            pub const ValueMut = []u8;

            layout_lock: ?PageHandle.LayoutLock,
            snapshot: ?PageHandle,
            leaf: ?LeafImpl,
            position: usize,
            value_len: usize,
            accessor: *AccessorSelf,
            coordinator: *core.structural_mutation.StructuralMutationCoordinator,
            open: bool = true,

            fn init(
                layout_lock: PageHandle.LayoutLock,
                snapshot: PageHandle,
                leaf: LeafImpl,
                position: usize,
                value_len: usize,
                coordinator: *core.structural_mutation.StructuralMutationCoordinator,
                accessor: *AccessorSelf,
            ) EditorSelf {
                return .{
                    .layout_lock = layout_lock,
                    .snapshot = snapshot,
                    .leaf = leaf,
                    .position = position,
                    .value_len = value_len,
                    .coordinator = coordinator,
                    .accessor = accessor,
                };
            }

            pub fn valueMut(self: *EditorSelf) EditorSelf.Error!ValueMut {
                try self.ensureOpen();
                if (self.layout_lock) |*layout_lock| {
                    var view = LeafImpl.PageViewType.init(try layout_lock.dataMut());
                    const value_bytes = try view.valueMut(self.position);
                    if (value_bytes.len != self.value_len) {
                        return error.EditorInvalidated;
                    }
                    return value_bytes;
                }
                return error.EditorInvalidated;
            }

            pub fn originalValue(self: *const EditorSelf) EditorSelf.Error![]const u8 {
                try self.ensureOpen();
                if (self.snapshot) |*snapshot| {
                    return (try snapshot.data())[0..self.value_len];
                }
                return error.EditorInvalidated;
            }

            pub fn value(self: *EditorSelf) EditorSelf.Error![]const u8 {
                return self.valueMut();
            }

            pub fn finish(self: *EditorSelf) EditorSelf.Error!void {
                try self.ensureOpen();
                const leaf = self.leaf orelse return error.EditorInvalidated;
                var old_policy = ValuePolicyType.init(leaf.ctx, try self.originalValue());
                defer old_policy.deinit();
                var new_policy = ValuePolicyType.init(leaf.ctx, try self.value());
                defer new_policy.deinit();
                try self.accessor.commitValueEditor(
                    &self.leaf.?,
                    self.position,
                    try old_policy.weight(),
                    try new_policy.weight(),
                );
                self.close();
            }

            pub fn deinit(self: *EditorSelf) void {
                if (!self.open) {
                    return;
                }
                self.restore() catch @panic("WeightedBPT value editor rollback failed");
                const leaf = self.leaf orelse @panic("WeightedBPT value editor lost its leaf");
                var restored_policy = ValuePolicyType.init(leaf.ctx, self.originalValue() catch unreachable);
                defer restored_policy.deinit();
                self.accessor.commitValueEditor(
                    &self.leaf.?,
                    self.position,
                    0,
                    restored_policy.weight() catch unreachable,
                ) catch @panic("WeightedBPT value editor rollback failed");
                self.close();
            }

            fn ensureOpen(self: *const EditorSelf) EditorSelf.Error!void {
                if (!self.open) {
                    return error.EditorInvalidated;
                }
            }

            fn restore(self: *EditorSelf) EditorSelf.Error!void {
                const old = try self.originalValue();
                const value_bytes = try self.valueMut();
                @memcpy(value_bytes, old);
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
                if (self.leaf) |*leaf| {
                    leaf.deinit();
                    self.leaf = null;
                }
                self.coordinator.finishValueEditor();
                self.open = false;
            }
        };

        pub const ValueEditorType = ValueEditorImpl;

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
                .coordinator = .{},
            };
        }

        pub fn openValueEditor(self: *Self, leaf: *LeafImpl, pos: usize) Error!ValueEditorImpl {
            try self.coordinator.beginValueEditor();
            errdefer self.coordinator.finishValueEditor();
            var value = try leaf.getValue(pos);
            defer value.deinit();
            const value_bytes = try value.get();
            var snapshot = try self.ctx.cache.getTemporaryPage();
            errdefer snapshot.deinit();
            const snapshot_bytes = try snapshot.dataMut();
            @memcpy(snapshot_bytes[0..value_bytes.len], value_bytes);
            var layout_lock = try leaf.handle.lockLayout();
            errdefer layout_lock.deinit();
            var editor_leaf = LeafImpl.init(try leaf.handle.clone(), leaf.id(), leaf.ctx);
            errdefer editor_leaf.deinit();
            return ValueEditorImpl.init(
                layout_lock,
                snapshot,
                editor_leaf,
                pos,
                value_bytes.len,
                &self.coordinator,
                self,
            );
        }

        fn commitValueEditor(
            self: *Self,
            leaf: *LeafImpl,
            position: usize,
            old_weight: Weight,
            new_weight: Weight,
        ) Error!void {
            _ = old_weight;
            try leaf.updateValueWeight(position, new_weight);
            try self.fixLeafParentWeight(leaf);
        }

        fn fixLeafParentWeight(self: *Self, leaf: *const LeafImpl) Error!void {
            const parent_id = try leaf.getParent() orelse return;
            var parent = try self.loadInode(parent_id);
            defer self.deinitInode(&parent);
            const child_pos = try self.childPosition(&parent, leaf.id());
            try parent.updateWeight(child_pos, try leaf.totalWeight());
            try self.fixInodeParentWeight(&parent);
        }

        fn fixInodeParentWeight(self: *Self, inode: *const InodeImpl) Error!void {
            const parent_id = try inode.getParent() orelse return;
            var parent = try self.loadInode(parent_id);
            defer self.deinitInode(&parent);
            const child_pos = try self.childPosition(&parent, inode.id());
            try parent.updateWeight(child_pos, try inode.totalWeight());
            try self.fixInodeParentWeight(&parent);
        }

        fn childPosition(self: *Self, parent: *const InodeImpl, child_id: CachePageId) Error!usize {
            _ = self;
            for (0..try parent.size()) |index| {
                if (try parent.getChild(index) == child_id) {
                    return index;
                }
            }
            return Error.BadData;
        }

        pub fn deinit(_: Self) void {
            // nothing to do yet
        }

        pub fn getRoot(self: *const Self) Error!?Pid {
            return self.ctx.storage_mgr.getRoot();
        }

        pub fn setRoot(self: *Self, root: ?Pid) Error!void {
            try self.ctx.storage_mgr.setRoot(root);
        }

        pub fn destroy(self: *Self, id: Pid) Error!void {
            try self.ctx.storage_mgr.destroyPage(id);
        }

        pub fn createLeaf(self: *Self) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = LeafImpl.PageViewType.init(try ph.dataMut());
            try page_view.formatPage(self.ctx.settings.leaf_page_kind, pid, 0);
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, id: CachePageId) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = LeafImpl.PageViewTypeConst.init(try ph.data());
            if (view.page_view.header().kind.get() != self.ctx.settings.leaf_page_kind) {
                return Error.BadType;
            }
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn deinitLeaf(_: *Self, leaf: *LeafImpl) void {
            leaf.deinit();
            leaf.* = undefined;
        }

        pub fn createInode(self: *Self) ErrorSet!InodeImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = InodeImpl.PageViewType.init(try ph.dataMut());
            try page_view.formatPage(self.ctx.settings.inode_page_kind, pid, 0);
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadInode(self: *Self, id: CachePageId) ErrorSet!InodeImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = InodeImpl.PageViewTypeConst.init(try ph.data());
            if (view.page_view.header().kind.get() != self.ctx.settings.inode_page_kind) {
                return Error.BadType;
            }
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn deinitInode(_: *Self, inode: *InodeImpl) void {
            inode.deinit();
            inode.* = undefined;
        }

        pub fn canMergeLeafs(_: *const Self, dst: *const LeafImpl, src: *const LeafImpl) Error!bool {
            const view_a = LeafImpl.PageViewTypeConst.init(try dst.handle.data());
            const view_b = LeafImpl.PageViewTypeConst.init(try src.handle.data());
            const slots_dir_a = try view_a.slotsDir();
            const slots_dir_b = try view_b.slotsDir();
            return try slots_dir_a.canMergeWith(&slots_dir_b) != .not_enough;
        }

        pub fn canMergeInodes(_: *Self, left: *const InodeImpl, right: *const InodeImpl) ErrorSet!bool {
            const view_a = InodeImpl.PageViewTypeConst.init(try left.handle.data());
            const view_b = InodeImpl.PageViewTypeConst.init(try right.handle.data());
            const slots_dir_a = try view_a.slotsDir();
            const slots_dir_b = try view_b.slotsDir();
            return try slots_dir_a.canMergeWith(&slots_dir_b) != .not_enough;
        }

        pub fn isLeaf(self: *const Self, id: CachePageId) Error!bool {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            var view = InodeImpl.PageViewTypeConst.init(try ph.data());
            return view.page_view.header().kind.get() == self.ctx.settings.leaf_page_kind;
        }
    };

    return struct {
        const Self = @This();

        pub const AccessorType = AccessorImpl;
        pub const ValueEditorType = AccessorImpl.ValueEditorType;
        pub const WeightType = Weight;
        pub const NodePositionType = NodePosition;
        pub const Error = ErrorSet;

        pub const ValueViewType = ValueViewImpl;
        pub const ValueType = Value;

        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;

        pub const NodeIdType = CachePageId;
        pub const PageId = CachePageId;

        accessor_state: AccessorType,

        pub fn init(device: *PageCacheT, storage_mgr: *StorageManagerT, settings: Settings) Self {
            const context = Context{
                .cache = device,
                .storage_mgr = storage_mgr,
                .settings = settings,
            };
            return .{
                .accessor_state = AccessorImpl.init(context),
            };
        }
        pub fn deinit(self: *Self) void {
            self.accessor_state.deinit();
        }

        pub fn scanInodeRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const view = WBptPageConst.InodeSubheaderView.init(page);
            const settings = self.accessor_state.ctx.settings;
            try view.validatePage(page_id, settings.inode_page_kind);
            const slots = try view.slotsDir();
            for (0..slots.size()) |index| {
                if ((try slots.get(index)).len == 0) {
                    continue;
                }
                try visitor.visit((try view.get(index)).child);
            }
        }

        pub fn scanLeafRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const view = WBptPageConst.LeafSubheaderView.init(page);
            const settings = self.accessor_state.ctx.settings;
            try view.validatePage(
                page_id,
                settings.leaf_page_kind,
                settings.maximum_value_size,
            );
            if (visitor.hasValueScanner()) {
                const slots = try view.slotsDir();
                for (0..slots.size()) |index| {
                    if ((try slots.get(index)).len == 0) {
                        continue;
                    }
                    try visitor.visitValue((try view.get(index)).value);
                }
            }
        }

        pub fn accessor(self: *Self) *AccessorType {
            return &self.accessor_state;
        }

        pub fn structuralMutationCoordinator(
            self: *Self,
        ) *core.structural_mutation.StructuralMutationCoordinator {
            return &self.accessor_state.coordinator;
        }
    };
}
