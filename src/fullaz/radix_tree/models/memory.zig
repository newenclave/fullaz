const std = @import("std");
const errors = @import("../../core/errors.zig");
const StructuralMutationCoordinator = @import("../../core/core.zig").structural_mutation.StructuralMutationCoordinator;
const StructuralMutationError = @import("../../core/core.zig").structural_mutation.Error;

const KeySplitter = @import("../splitter.zig").Splitter;

const SettingsImpl = struct {
    leaf_base: u32 = 128,
    inode_base: u32 = 512,
};

pub fn Model(comptime KeyT: type, comptime ValueT: type) type {
    const PidType = usize;
    const LevelType = usize;
    const SplitterType = KeySplitter(KeyT);

    const ErrorSet = errors.HandleError ||
        errors.PageError ||
        errors.IndexError ||
        errors.SpaceError ||
        std.mem.Allocator.Error ||
        StructuralMutationError;

    const SplitKeyImpl = struct {
        const Self = @This();
        pub const KeyDigitType = SplitterType.Result;
        const KeyDigit = KeyDigitType;
        stack: std.ArrayList(KeyDigit),
        items: []KeyDigit = undefined,

        fn init(stack: std.ArrayList(KeyDigit)) Self {
            return Self{
                .stack = stack,
                .items = stack.items,
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.stack.deinit(allocator);
            self.* = undefined;
        }

        pub fn size(self: *const Self) usize {
            return self.items.len;
        }

        pub fn empty(self: *const Self) bool {
            return self.items.len == 0;
        }

        pub fn get(self: *const Self, idx: usize) KeyDigit {
            if (idx >= self.items.len) {
                return .{
                    .digit = 0,
                    .quotient = 0,
                    .level = idx,
                };
            }
            return self.items[idx];
        }
    };

    const LeafContainer = struct {
        const Self = @This();
        const MemoryContainer = std.ArrayList(?ValueT);

        cont: MemoryContainer,
        parent_id: ?PidType = null,
        parent_quotient: KeyT = 0,
        parent_idx: KeyT = 0,
        elements_count: usize = 0,

        fn init(allocator: std.mem.Allocator, base: usize) ErrorSet!Self {
            var res = Self{
                .cont = try MemoryContainer.initCapacity(allocator, base),
            };
            try res.cont.resize(allocator, base);
            for (res.cont.items) |*item| {
                item.* = null;
            }
            return res;
        }

        fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.cont.deinit(alloc);
            self.* = undefined;
        }
    };

    const InodeContainer = struct {
        const Self = @This();
        const MemoryContainer = std.ArrayList(?PidType);

        cont: MemoryContainer,
        parent_id: ?PidType = null,
        parent_quotient: KeyT = undefined,
        parent_idx: KeyT = undefined,
        level: LevelType = 0,
        elements_count: usize = 0,

        fn init(allocator: std.mem.Allocator, base: usize, lvl: LevelType) ErrorSet!Self {
            var res = Self{
                .cont = try MemoryContainer.initCapacity(allocator, base),
                .level = lvl,
                .elements_count = 0,
            };
            try res.cont.resize(allocator, base);
            for (res.cont.items) |*item| {
                item.* = null;
            }
            return res;
        }

        fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.cont.deinit(alloc);
            self.* = undefined;
        }
    };

    const NoneNode = struct {};

    const InodeLeafUnion = union(enum) {
        leaf: *LeafContainer,
        inode: *InodeContainer,
        none: NoneNode,
    };

    const LeafImpl = struct {
        const Self = @This();
        const Container = LeafContainer;
        container: *Container,
        self_id: PidType,
        free_leaf_ids: *std.AutoHashMap(PidType, void),
        pub const Error = ErrorSet;

        fn init(
            cont: *Container,
            pid: PidType,
            free_leaf_ids: *std.AutoHashMap(PidType, void),
        ) Error!Self {
            return Self{
                .container = cont,
                .self_id = pid,
                .free_leaf_ids = free_leaf_ids,
            };
        }

        pub fn id(self: *const Self) PidType {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            return self.container.elements_count;
        }

        pub fn capacity(self: *const Self) Error!usize {
            return self.container.cont.items.len;
        }

        pub fn setParent(self: *Self, parent_id: ?PidType) Error!void {
            self.container.parent_id = parent_id;
        }

        pub fn getParent(self: *const Self) Error!?PidType {
            return self.container.parent_id;
        }

        pub fn setParentQuotient(self: *Self, parent_quotient: KeyT) Error!void {
            self.container.parent_quotient = parent_quotient;
        }

        pub fn getParentQuotient(self: *const Self) Error!KeyT {
            return self.container.parent_quotient;
        }

        pub fn setParentId(self: *Self, parent_idx: KeyT) Error!void {
            self.container.parent_idx = parent_idx;
        }

        pub fn getParentId(self: *const Self) Error!KeyT {
            return self.container.parent_idx;
        }

        pub fn set(self: *Self, key: KeyT, value: ValueT) Error!void {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx] == null) {
                self.container.elements_count += 1;
            }
            self.container.cont.items[idx] = value;
        }

        pub fn free(self: *Self, key: KeyT) Error!void {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx] != null) {
                self.container.elements_count -= 1;
                self.container.cont.items[idx] = null;
            }
        }

        pub fn getPtr(self: *const Self, key: KeyT) Error!*const ValueT {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx]) |*item| {
                return item;
            }
            return Error.InvalidId;
        }

        pub fn get(self: *const Self, key: KeyT) Error!ValueT {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx]) |*item| {
                return item.*;
            }
            return Error.InvalidId;
        }

        pub fn isSet(self: *const Self, key: KeyT) Error!bool {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.cont.items[idx] != null;
        }

        pub fn getFirstFree(self: *const Self) Error!?KeyT {
            for (self.container.cont.items, 0..) |value, index| {
                if (value == null) {
                    return @intCast(index);
                }
            }
            return null;
        }

        pub fn isInFree(self: *const Self) Error!bool {
            return self.free_leaf_ids.contains(self.self_id);
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const Container = InodeContainer;
        pub const Error = ErrorSet;

        container: *Container,
        self_id: PidType,

        fn init(cont: *Container, pid: PidType) Error!Self {
            return Self{
                .container = cont,
                .self_id = pid,
            };
        }

        pub fn id(self: *const Self) PidType {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            return self.container.elements_count;
        }

        pub fn capacity(self: *const Self) Error!usize {
            return self.container.cont.items.len;
        }

        pub fn set(self: *Self, key: KeyT, child_id: PidType) Error!void {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx] == null) {
                self.container.elements_count += 1;
            }
            self.container.cont.items[idx] = child_id;
        }

        pub fn get(self: *const Self, key: KeyT) Error!PidType {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx]) |*item| {
                return item.*;
            }
            return Error.InvalidId;
        }

        pub fn free(self: *Self, key: KeyT) Error!void {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx] != null) {
                self.container.elements_count -= 1;
                self.container.cont.items[idx] = null;
            }
        }

        pub fn setParent(self: *Self, parent_id: ?PidType) Error!void {
            self.container.parent_id = parent_id;
        }

        pub fn getParent(self: *const Self) Error!?PidType {
            return self.container.parent_id;
        }

        pub fn setParentQuotient(self: *Self, parent_quotient: KeyT) Error!void {
            self.container.parent_quotient = parent_quotient;
        }

        pub fn getParentQuotient(self: *const Self) Error!KeyT {
            return self.container.parent_quotient;
        }

        pub fn setParentId(self: *Self, parent_idx: KeyT) Error!void {
            self.container.parent_idx = parent_idx;
        }

        pub fn getParentId(self: *const Self) Error!KeyT {
            return self.container.parent_idx;
        }

        pub fn getLevel(self: *const Self) Error!usize {
            return self.container.level;
        }

        pub fn setLevel(self: *Self, level: LevelType) Error!void {
            self.container.level = level;
        }

        pub fn isSet(self: *const Self, key: KeyT) Error!bool {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.cont.items[idx] != null;
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        const Container = std.ArrayList(InodeLeafUnion);
        const Splitter = SplitterType;

        const KeyDigit = Splitter.Result;
        const SplitKeyResult = SplitKeyImpl;

        pub const Error = ErrorSet || Splitter.Error;

        const ValueEditorImpl = struct {
            const EditorSelf = @This();

            pub const Error = ErrorSet;
            pub const ValueMutType = *ValueT;

            leaf: *LeafContainer,
            position: usize,
            snapshot: ValueT,
            coordinator: *StructuralMutationCoordinator,
            open: bool = true,

            pub fn valueMut(self: *EditorSelf) ErrorSet!ValueMutType {
                try self.ensureOpen();
                return &self.leaf.cont.items[self.position].?;
            }

            pub fn finish(self: *EditorSelf) ErrorSet!void {
                try self.ensureOpen();
                self.close();
            }

            pub fn deinit(self: *EditorSelf) void {
                if (!self.open) {
                    return;
                }
                self.leaf.cont.items[self.position] = self.snapshot;
                self.close();
            }

            fn ensureOpen(self: *const EditorSelf) ErrorSet!void {
                if (!self.open) {
                    return error.EditorInvalidated;
                }
            }

            fn close(self: *EditorSelf) void {
                self.coordinator.finishValueEditor();
                self.open = false;
            }
        };

        pub const ValueEditorType = ValueEditorImpl;

        alloc: std.mem.Allocator,
        sett: SettingsImpl,
        cont: Container,
        splitter: Splitter,
        root: ?PidType = null,
        free_leaf_ids: std.AutoHashMap(PidType, void),
        coordinator: StructuralMutationCoordinator = .{},

        fn init(alloc: std.mem.Allocator, sett: SettingsImpl) Error!Self {
            return Self{
                .alloc = alloc,
                .cont = try Container.initCapacity(alloc, 4),
                .splitter = Splitter.init(sett.inode_base, sett.leaf_base),
                .sett = sett,
                .free_leaf_ids = std.AutoHashMap(PidType, void).init(alloc),
                .coordinator = .{},
            };
        }

        fn deinit(self: *Self) void {
            for (self.cont.items) |*item| {
                switch (item.*) {
                    .inode => |iptr| {
                        iptr.deinit(self.alloc);
                        self.alloc.destroy(iptr);
                    },
                    .leaf => |lptr| {
                        lptr.deinit(self.alloc);
                        self.alloc.destroy(lptr);
                    },
                    .none => {},
                }
            }
            self.cont.deinit(self.alloc);
            self.free_leaf_ids.deinit();
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            const old_size = self.cont.items.len;
            const leaf_ptr = try self.alloc.create(LeafContainer);
            leaf_ptr.* = try LeafContainer.init(self.alloc, self.sett.leaf_base);
            try self.cont.append(self.alloc, .{ .leaf = leaf_ptr });
            return LeafImpl.init(leaf_ptr, old_size, &self.free_leaf_ids);
        }

        pub fn loadLeaf(self: *Self, pid: PidType) Error!LeafImpl {
            if (pid >= self.cont.items.len) {
                return Error.OutOfBounds;
            }
            switch (self.cont.items[pid]) {
                .inode => return Error.InvalidId,
                .none => return Error.InvalidId,
                .leaf => |lptr| {
                    return LeafImpl.init(lptr, pid, &self.free_leaf_ids);
                },
            }
        }

        pub fn deinitLeaf(_: *Self, _: *LeafImpl) void {
            //leaf.deinit(self.alloc);
        }

        pub fn getFreeLeaf(self: *Self) Error!?LeafImpl {
            var keys = self.free_leaf_ids.keyIterator();
            const page_id = keys.next() orelse return null;
            return try self.loadLeaf(page_id.*);
        }

        pub fn addFreeLeaf(self: *Self, leaf: *LeafImpl) Error!void {
            try self.free_leaf_ids.put(leaf.id(), {});
        }

        pub fn removeFreeLeaf(self: *Self, page_id: PidType) Error!void {
            _ = self.free_leaf_ids.remove(page_id);
        }

        pub fn createInode(self: *Self) Error!InodeImpl {
            const old_size = self.cont.items.len;
            const inode_ptr = try self.alloc.create(InodeContainer);
            inode_ptr.* = try InodeContainer.init(self.alloc, self.sett.inode_base, 0);
            try self.cont.append(self.alloc, .{ .inode = inode_ptr });
            return InodeImpl.init(inode_ptr, old_size);
        }

        pub fn loadInode(self: *Self, pid: PidType) Error!InodeImpl {
            if (pid >= self.cont.items.len) {
                @breakpoint();
                return Error.OutOfBounds;
            }
            switch (self.cont.items[pid]) {
                .inode => |iptr| {
                    return InodeImpl.init(iptr, pid);
                },
                .leaf => return Error.InvalidId,
                .none => return Error.InvalidId,
            }
        }

        pub fn deinitInode(_: *Self, _: *InodeImpl) void {
            //inode.deinit(self.alloc);
        }

        pub fn splitKey(self: *const Self, key: KeyT) Error!SplitKeyResult {
            const maximum_levels = self.splitter.maximum_levels;
            var stack = try std.ArrayList(KeyDigit).initCapacity(self.alloc, maximum_levels);
            errdefer stack.deinit(self.alloc);
            try stack.resize(self.alloc, maximum_levels);
            const res = try self.splitter.split(key, stack.items);
            try stack.resize(self.alloc, res.len);
            return SplitKeyResult.init(stack);
        }

        pub fn deinitSplitKey(self: *Self, sk: *SplitKeyResult) void {
            sk.deinit(self.alloc);
        }

        pub fn openValueEditor(self: *Self, leaf: *LeafImpl, key: KeyT) Error!ValueEditorType {
            try self.coordinator.beginValueEditor();
            errdefer self.coordinator.finishValueEditor();
            _ = try leaf.get(key);
            const position: usize = @intCast(key);
            return .{
                .leaf = leaf.container,
                .position = position,
                .snapshot = leaf.container.cont.items[position].?,
                .coordinator = &self.coordinator,
            };
        }

        pub fn isLeaf(self: *const Self, pid: PidType) Error!bool {
            if (pid >= self.cont.items.len) {
                return Error.InvalidId;
            }
            switch (self.cont.items[pid]) {
                .inode => return false,
                .leaf => return true,
                .none => return Error.InvalidId,
            }
        }

        pub fn getRootLevel(self: *const Self) Error!?usize {
            if (self.root) |root_id| {
                switch (self.cont.items[root_id]) {
                    .inode => |iptr| {
                        return iptr.level;
                    },
                    .leaf => return 0,
                    .none => return Error.InvalidId,
                }
            }
            return null;
        }

        pub fn getRoot(self: *const Self) Error!?PidType {
            return self.root;
        }

        pub fn setRoot(self: *Self, pid: ?PidType) Error!void {
            if (pid) |id| {
                if (id >= self.cont.items.len) {
                    return Error.InvalidId;
                }
            }
            self.root = pid;
        }

        pub fn destroy(self: *Self, pid: PidType) Error!void {
            if (pid >= self.cont.items.len) {
                return Error.InvalidId;
            }
            switch (self.cont.items[pid]) {
                .inode => |iptr| {
                    iptr.deinit(self.alloc);
                    self.alloc.destroy(iptr);
                },
                .leaf => |lptr| {
                    lptr.deinit(self.alloc);
                    self.alloc.destroy(lptr);
                },
                .none => return Error.InvalidId,
            }
            self.cont.items[pid] = .{ .none = .{} };
        }
    };

    return struct {
        const Self = @This();

        pub const Settings = SettingsImpl;
        pub const NodeIdType = PidType;
        pub const PageId = PidType;

        pub const KeyInType = KeyT;
        pub const ValueInType = ValueT;
        pub const KeyOutType = KeyT;
        pub const ValueOutType = ValueT;

        pub const AccessorType = AccessorImpl;
        pub const ValueEditorType = AccessorType.ValueEditorType;
        pub const InodeType = InodeImpl;
        pub const LeafType = LeafImpl;
        pub const SplitKeyType = AccessorType.SplitKeyResult;

        pub const Error = ErrorSet;

        accessor_state: AccessorType,

        pub fn init(alloc: std.mem.Allocator, sett: Settings) !Self {
            return Self{
                .accessor_state = try AccessorType.init(alloc, sett),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor_state.deinit();
        }

        pub fn accessor(self: *Self) *AccessorType {
            return &self.accessor_state;
        }

        pub fn structuralMutationCoordinator(self: *Self) *StructuralMutationCoordinator {
            return &self.accessor_state.coordinator;
        }

        pub fn getSettings(self: *const Self) *const Settings {
            return &self.accessor_state.sett;
        }
    };
}
