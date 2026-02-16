const std = @import("std");
const device_interface = @import("../../../device/interfaces.zig");
const page_cache = @import("../../../storage/page_cache.zig");
const wbpt_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;

pub const Settings = struct {
    maximum_value_size: usize = 256,
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
};

pub fn PagedModel(comptime PageCacheType: type, comptime StorageManager: type, comptime ValuePolicy: type) type {
    comptime {
        contracts.storage_manager.requiresStorageManager(StorageManager);
        contracts.page_cache.requiresPageCache(PageCacheType);
    }

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;
    const Weight = u32;
    const Index = u16;

    const Value = []const u8;

    const WBptPage = wbpt_page.View(BlockIdType, Index, Weight, .little, false);
    const WBptPageConst = wbpt_page.View(BlockIdType, Index, Weight, .little, true);

    const NodePosition = struct {
        pos: usize,
        diff: Weight,
        accumulated: Weight,
    };

    const Context = struct {
        cache: *PageCacheType = undefined,
        storage_mgr: *StorageManager = undefined,
        settings: Settings = undefined,
    };

    const ValuePolicyImplDefault = struct {
        const Self = @This();

        const Error = errors.HandleError ||
            errors.IndexError ||
            PageCacheType.Error ||
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
            var tmp_page = try self.ctx.cache.getTemporaryPage();
            errdefer tmp_page.deinit();
            const page_data = try tmp_page.getDataMut();
            const new_data = page_data[0..result_weight];
            @memcpy(new_data, self.val[self.val.len - result_weight ..]);
            self.val = self.val[0 .. self.val.len - result_weight];
            var result = Self.init(self.ctx, new_data);
            result.ph = tmp_page;
            return result;
        }

        pub fn splitOfLeft(self: *Self, pos: Weight) Error!Self {
            if (pos > self.weight()) {
                return Error.OutOfBounds;
            }
            var tmp_page = try self.ctx.cache.getTemporaryPage();
            errdefer tmp_page.deinit();
            const page_data = try tmp_page.getDataMut();
            const new_data = page_data[0..pos];
            @memcpy(new_data, self.val[0..pos]);
            self.val = self.val[pos..];
            var result = Self.init(self.ctx, new_data);
            result.ph = tmp_page;
            return result;
        }

        const SplitFormat = struct {
            left: usize,
            right: usize,
        };

        pub fn expectedSplitDataFormat(_: *const Self, val: Value, pos: usize) SplitFormat {
            return .{
                .left = pos,
                .right = val.len - pos,
            };
        }
    };

    const ValueViewImpl = struct {
        const Self = @This();
        const Error = ValuePolicyImplDefault.Error;

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

    const ValuePolicyType = comptime if (@typeInfo(ValuePolicy) == .void)
        ValuePolicyImplDefault
    else
        ValuePolicy;

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheType.Error ||
        errors.OrderError ||
        errors.BptError;

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = WBptPage.LeafSubheaderView;
        const PageViewTypeConst = WBptPageConst.LeafSubheaderView;

        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        pub const Error = ErrorSet;

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
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
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.entries();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.capacityFor(self.ctx.settings.maximum_value_size);
        }

        // TODO: should count bytes, not entries, to allow variable sized values
        pub fn isUnderflowed(self: *const Self) Error!bool {
            return (try self.size()) < (try self.capacity() + 1) / 2;
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        pub fn totalWeight(self: *const Self) Error!Weight {
            const view = PageViewTypeConst.init(try self.handle.getData());
            var total: Weight = 0;
            for (0..try view.entries()) |idx| {
                const entry = try view.get(idx);
                total += entry.weight;
            }
            return total;
        }

        pub fn getParent(self: *const Self) Error!?BlockIdType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getParent();
        }

        pub fn setParent(self: *Self, parent: ?BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParent(parent);
        }

        pub fn getPrev(self: *const Self) Error!?BlockIdType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getPrev();
        }

        pub fn setPrev(self: *Self, prev: ?BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setPrev(prev);
        }

        pub fn getNext(self: *const Self) Error!?BlockIdType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getNext();
        }

        pub fn setNext(self: *Self, next: ?BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setNext(next);
        }

        pub fn getValue(self: *const Self, pos: usize) Error!ValuePolicyType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            const wv = try view.get(pos);
            return ValuePolicyType.init(self.ctx, wv.value);
        }

        pub fn insertAt(self: *Self, pos: usize, val: Value) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());

            var vp = ValuePolicyType.init(self.ctx, val);
            defer vp.deinit();

            const res = try view.canInsert(try vp.get());
            if (res == .not_enough) {
                return Error.NodeFull;
            } else if (res == .need_compact) {
                var tmp_page = try self.ctx.cache.getTemporaryPage();
                defer tmp_page.deinit();

                const page_data = try tmp_page.getDataMut();
                var view_mut = PageViewType.init(try self.handle.getDataMut());
                var slots_dir = try view_mut.slotsDirMut();
                slots_dir.compactWithBuffer(page_data) catch {
                    try slots_dir.compactInPlace();
                };
            }

            var view_mut = PageViewType.init(try self.handle.getDataMut());
            try view_mut.insert(pos, try vp.weight(), try vp.get());
        }

        // TODO: should be fixed. As we need to take in account the weight of values, that can be updated/removed
        pub fn canInsertWeight(self: *const Self, where: Weight, val: Value) Error!bool {
            const view = PageViewTypeConst.init(try self.handle.getData());

            const pos = try self.selectPos(where);
            const entry = try view.get(pos.pos);

            if (pos.diff == 0) {
                var vp = ValuePolicyType.init(self.ctx, val);
                defer vp.deinit();
                return try view.canInsert(try vp.get()) != .not_enough;
            } else {
                var target_val = ValuePolicyImplDefault.init(self.ctx, entry.value);
                defer target_val.deinit();

                var new_val = ValuePolicyImplDefault.init(self.ctx, val);
                defer new_val.deinit();

                const expected_split_format = target_val.expectedSplitDataFormat(try target_val.get(), pos.diff);
                const new_val_size = (try new_val.get()).len;

                const res = try view.canInsert2(expected_split_format.right, new_val_size);

                return res != .not_enough;
            }
        }

        pub fn insertWeight(self: *Self, where: Weight, val: Value) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());

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
                const page_data = try tmp_page.getDataMut();

                try view.update(pos.pos, try policy.weight(), try policy.get(), page_data);
                try self.insertAt(pos.pos + 1, try new_policy.get());
                try self.insertAt(pos.pos + 1, try vp.get());
            }
        }

        pub fn removeAt(self: *Self, pos: usize) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            var slots_dir = try view.slotsDirMut();
            return slots_dir.remove(pos);
        }

        pub fn selectPos(self: *const Self, weight: Weight) Error!NodePosition {
            const view = PageViewTypeConst.init(try self.handle.getData());
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
        const SlotType = WBptPageConst.InodeSlotType;

        pub const Error = ErrorSet;

        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.entries();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.capacityFor();
        }

        pub fn isUnderflowed(self: *const Self) Error!bool {
            const sz = try self.size();
            const cap = try self.capacity();
            return sz < (cap / 2);
        }

        pub fn totalWeight(self: *const Self) Error!Weight {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return view.subheader().total_weight.get();
        }

        pub fn getParent(self: *const Self) Error!?BlockIdType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getParent();
        }

        pub fn setParent(self: *Self, parent: ?BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParent(parent);
        }

        pub fn insertChild(self: *Self, pos: usize, child: BlockIdType, weight: Weight) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.insert(pos, child, weight);
        }

        pub fn removeAt(self: *Self, pos: usize) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            var slots_dir = try view.slotsDirMut();
            return try slots_dir.remove(pos);
        }

        pub fn getChild(self: *const Self, pos: usize) Error!BlockIdType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.get(pos)).child;
        }

        pub fn getWeight(self: *const Self, pos: usize) Error!Weight {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.get(pos)).weight;
        }

        pub fn updateWeight(self: *Self, pos: usize, new_weight: Weight) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.updateWeight(pos, new_weight);
        }

        pub fn updateChild(self: *Self, pos: usize, new_child: BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.updateChild(pos, new_child);
        }

        pub fn selectPos(self: *const Self, weight: Weight) Error!NodePosition {
            const view = PageViewTypeConst.init(try self.handle.getData());
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

        pub fn canInsertAt(self: *const Self, pos: usize, weight: Weight) Error!bool {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.canInsert(pos, weight) != .not_enough;
        }
    };

    const AccessorImpl = struct {
        const Self = @This();

        pub const Pid = BlockIdType;
        pub const Error = ErrorSet;

        ctx: Context = undefined,

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
            };
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

        pub fn createLeaf(self: *Self) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = LeafImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(self.ctx.settings.leaf_page_kind, pid, 0);
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, id: BlockIdType) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = LeafImpl.PageViewTypeConst.init(try ph.getData());
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
            var page_view = InodeImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(self.ctx.settings.inode_page_kind, pid, 0);
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadInode(self: *Self, id: BlockIdType) ErrorSet!InodeImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = InodeImpl.PageViewTypeConst.init(try ph.getData());
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
            const view_a = LeafImpl.PageViewTypeConst.init(try dst.handle.getData());
            const view_b = LeafImpl.PageViewTypeConst.init(try src.handle.getData());
            const slots_dir_a = try view_a.slotsDir();
            const slots_dir_b = try view_b.slotsDir();
            return try slots_dir_a.canMergeWith(&slots_dir_b) != .not_enough;
        }

        pub fn canMergeInodes(_: *Self, left: *const InodeImpl, right: *const InodeImpl) ErrorSet!bool {
            const view_a = InodeImpl.PageViewTypeConst.init(try left.handle.getData());
            const view_b = InodeImpl.PageViewTypeConst.init(try right.handle.getData());
            const slots_dir_a = try view_a.slotsDir();
            const slots_dir_b = try view_b.slotsDir();
            return try slots_dir_a.canMergeWith(&slots_dir_b) != .not_enough;
        }

        pub fn isLeaf(self: *const Self, id: BlockIdType) Error!bool {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            var view = InodeImpl.PageViewTypeConst.init(try ph.getData());
            return view.page_view.header().kind.get() == self.ctx.settings.leaf_page_kind;
        }
    };

    return struct {
        const Self = @This();

        pub const AccessorType = AccessorImpl;
        pub const WeightType = Weight;
        pub const NodePositionType = NodePosition;
        pub const Error = ErrorSet;

        pub const ValueViewType = ValueViewImpl;
        pub const ValueType = Value;

        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;

        pub const NodeIdType = BlockIdType;

        accessor: AccessorType,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, settings: Settings) Self {
            const context = Context{
                .cache = device,
                .storage_mgr = storage_mgr,
                .settings = settings,
            };
            return .{
                .accessor = AccessorImpl.init(context),
            };
        }
        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *AccessorType {
            return &self.accessor;
        }
    };
}
