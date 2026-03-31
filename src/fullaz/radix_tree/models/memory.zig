const std = @import("std");
const errors = @import("../../core/errors.zig");

const KeySplitter = @import("../splitter.zig").Splitter;

const Settings = struct {
    leaf_base: u32 = 128,
    inode_base: u32 = 512,
};

pub fn Model(comptime Key: type, comptime Value: type) type {
    const PidType = usize;
    const LevelType = usize;
    const SplitterType = KeySplitter(Key);

    const ErrorSet = errors.HandleError ||
        errors.PageError ||
        errors.IndexError ||
        std.mem.Allocator.Error;

    const SplitKeyImpl = struct {
        const Self = @This();
        const KeyDigit = SplitterType.Result;
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
        const MemoryContainer = std.ArrayList(?Value);

        cont: MemoryContainer,
        parent_id: ?PidType = null,
        parent_quotient: Key = undefined,
        parent_idx: Key = undefined,
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
        parent_quotient: Key = undefined,
        parent_idx: Key = undefined,
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
        const Error = ErrorSet;

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

        pub fn setParent(self: *Self, parent_id: ?PidType) Error!void {
            self.container.parent_id = parent_id;
        }

        pub fn getParent(self: *const Self) Error!?PidType {
            return self.container.parent_id;
        }

        pub fn setParentQuotient(self: *Self, parent_quotient: Key) Error!void {
            self.container.parent_quotient = parent_quotient;
        }

        pub fn getParentQuotient(self: *const Self) Error!Key {
            return self.container.parent_quotient;
        }

        pub fn setParentId(self: *Self, parent_idx: Key) Error!void {
            self.container.parent_idx = parent_idx;
        }

        pub fn getParentId(self: *const Self) Error!Key {
            return self.container.parent_idx;
        }

        pub fn set(self: *Self, key: Key, value: Value) Error!void {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx] == null) {
                self.container.elements_count += 1;
            }
            self.container.cont.items[idx] = value;
        }

        pub fn free(self: *Self, key: Key) Error!void {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx] != null) {
                self.container.elements_count -= 1;
                self.container.cont.items[idx] = null;
            }
        }

        pub fn getPtr(self: *const Self, key: Key) Error!*const Value {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx]) |*item| {
                return item;
            }
            return Error.InvalidId;
        }

        pub fn get(self: *const Self, key: Key) Error!Value {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx]) |*item| {
                return item.*;
            }
            return Error.InvalidId;
        }

        pub fn isSet(self: *const Self, key: Key) Error!bool {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.cont.items[idx] != null;
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const Container = InodeContainer;
        const Error = ErrorSet;

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

        pub fn set(self: *Self, key: Key, child_id: PidType) Error!void {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx] == null) {
                self.container.elements_count += 1;
            }
            self.container.cont.items[idx] = child_id;
        }

        pub fn get(self: *const Self, key: Key) Error!PidType {
            const idx = @as(usize, @intCast(key));
            if (idx >= self.container.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.container.cont.items[idx]) |*item| {
                return item.*;
            }
            return Error.InvalidId;
        }

        pub fn free(self: *Self, key: Key) Error!void {
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

        pub fn setParentQuotient(self: *Self, parent_quotient: Key) Error!void {
            self.container.parent_quotient = parent_quotient;
        }

        pub fn getParentQuotient(self: *const Self) Error!Key {
            return self.container.parent_quotient;
        }

        pub fn setParentId(self: *Self, parent_idx: Key) Error!void {
            self.container.parent_idx = parent_idx;
        }

        pub fn getParentId(self: *const Self) Error!Key {
            return self.container.parent_idx;
        }

        pub fn getLevel(self: *const Self) Error!usize {
            return self.container.level;
        }

        pub fn setLevel(self: *Self, level: LevelType) Error!void {
            self.container.level = level;
        }

        pub fn isSet(self: *const Self, key: Key) Error!bool {
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

        const Error = ErrorSet || Splitter.Error;

        alloc: std.mem.Allocator,
        sett: Settings,
        cont: Container,
        splitter: Splitter,
        root: ?PidType = null,

        fn init(alloc: std.mem.Allocator, sett: Settings) Error!Self {
            return Self{
                .alloc = alloc,
                .cont = try Container.initCapacity(alloc, 4),
                .splitter = Splitter.init(sett.inode_base, sett.leaf_base),
                .sett = sett,
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
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            const old_size = self.cont.items.len;
            const leaf_ptr = try self.alloc.create(LeafContainer);
            leaf_ptr.* = try LeafContainer.init(self.alloc, self.sett.leaf_base);
            try self.cont.append(self.alloc, .{ .leaf = leaf_ptr });
            return LeafImpl.init(leaf_ptr, old_size);
        }

        pub fn loadLeaf(self: *Self, pid: PidType) Error!LeafImpl {
            if (pid >= self.cont.items.len) {
                return Error.OutOfBounds;
            }
            switch (self.cont.items[pid]) {
                .inode => return Error.InvalidId,
                .none => return Error.InvalidId,
                .leaf => |lptr| {
                    return LeafImpl.init(lptr, pid);
                },
            }
        }

        pub fn deinitLeaf(_: *Self, _: *LeafImpl) void {
            //leaf.deinit(self.alloc);
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

        pub fn splitKey(self: *const Self, key: Key) Error!SplitKeyResult {
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

        pub fn setRoot(self: *Self, pid: PidType) Error!void {
            if (pid >= self.cont.items.len) {
                return Error.InvalidId;
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

        pub const Pid = PidType;
        pub const Level = LevelType;

        pub const KeyIn = Key;
        pub const ValueIn = Value;
        pub const KeyOut = Key;
        pub const ValueOut = Value;

        pub const Accessor = AccessorImpl;
        pub const Inode = InodeImpl;
        pub const Leaf = LeafImpl;
        pub const SplitKeyResult = Accessor.SplitKeyResult;

        pub const Error = ErrorSet;

        accessor: Accessor,

        pub fn init(alloc: std.mem.Allocator, sett: Settings) !Self {
            return Self{
                .accessor = try Accessor.init(alloc, sett),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *Accessor {
            return &self.accessor;
        }

        pub fn getSettings(self: *const Self) *const Settings {
            return &self.accessor.sett;
        }
    };
}
