const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry.zig");

const IS_DEBUG = builtin.mode == .Debug;

// the very same idea as from weighted_bpt...
pub fn Model(
    comptime CoordT: type,
    comptime dims: usize,
    comptime ValueT: type,
    comptime max_entries_v: usize,
) type {
    comptime {
        if (max_entries_v < 4) {
            @compileError("max_entries must be at least 4");
        }
    }

    const Pid = usize;
    const Key = geometry.BoundingBox(CoordT, dims);

    const ModelError = error{ OutOfBounds, NodeFull, InvalidId } || std.mem.Allocator.Error;

    const LeafEntry = struct { mbr: Key, value: ValueT };
    const InodeEntry = struct { mbr: Key, child: Pid };

    const Context = struct {
        allocator: std.mem.Allocator,
    };

    const LeafContainer = struct {
        const Self = @This();
        entries: std.ArrayList(LeafEntry),
        parent: ?Pid = null,

        fn init(allocator: std.mem.Allocator) ModelError!Self {
            return .{
                .entries = try std.ArrayList(LeafEntry).initCapacity(allocator, 0),
            };
        }
        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }
    };

    const InodeContainer = struct {
        const Self = @This();
        entries: std.ArrayList(InodeEntry),
        parent: ?Pid = null,
        level: usize = 1,

        fn init(allocator: std.mem.Allocator) ModelError!Self {
            return .{
                .entries = try std.ArrayList(InodeEntry).initCapacity(allocator, 0),
            };
        }
        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }
    };

    const LeafImpl = struct {
        const Self = @This();
        pub const Error = ModelError;

        pid: Pid,
        container: *LeafContainer,
        ctx: *Context,
        sanitize_ptr: ?*u32 = null,

        pub fn deinit(self: *Self) void {
            if (IS_DEBUG) {
                if (self.sanitize_ptr) |p| {
                    self.ctx.allocator.destroy(p);
                }
            }
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }

        pub fn take(self: *Self) Error!Self {
            const copy = self.*;
            self.sanitize_ptr = null;
            return copy;
        }

        pub fn size(self: *const Self) Error!usize {
            return self.container.entries.items.len;
        }

        pub fn capacity(_: *const Self) Error!usize {
            return max_entries_v;
        }

        pub fn getMbr(self: *const Self, pos: usize) Error!Key {
            try self.checkPos(pos);
            return self.container.entries.items[pos].mbr;
        }

        pub fn nodeMbr(self: *const Self) Error!Key {
            const items = self.container.entries.items;
            if (items.len == 0) {
                return Key.init();
            }
            var acc = items[0].mbr;
            for (items[1..]) |*e| {
                acc = acc.merged(&e.mbr);
            }
            return acc;
        }

        pub fn erase(self: *Self, pos: usize) Error!void {
            try self.checkPos(pos);
            _ = self.container.entries.orderedRemove(pos);
        }

        pub fn clear(self: *Self) Error!void {
            self.container.entries.clearRetainingCapacity();
        }

        pub fn getParent(self: *const Self) Error!?Pid {
            return self.container.parent;
        }

        pub fn setParent(self: *Self, parent: ?Pid) Error!void {
            self.container.parent = parent;
        }

        pub fn getValue(self: *const Self, pos: usize) Error!ValueT {
            try self.checkPos(pos);
            return self.container.entries.items[pos].value;
        }

        pub fn canInsertEntry(self: *const Self, _: Key, _: ValueT) Error!bool {
            return self.container.entries.items.len < max_entries_v;
        }

        pub fn insertEntry(self: *Self, mbr: Key, value: ValueT) Error!void {
            if (self.container.entries.items.len >= max_entries_v) {
                return Error.NodeFull;
            }
            try self.container.entries.append(self.ctx.allocator, .{
                .mbr = mbr,
                .value = value,
            });
        }

        fn checkPos(self: *const Self, pos: usize) Error!void {
            if (pos >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        pub const Error = ModelError;

        pid: Pid,
        container: *InodeContainer,
        ctx: *Context,
        sanitize_ptr: ?*u32 = null,

        pub fn deinit(self: *Self) void {
            if (IS_DEBUG) {
                if (self.sanitize_ptr) |p| {
                    self.ctx.allocator.destroy(p);
                }
            }
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }

        pub fn take(self: *Self) Error!Self {
            const copy = self.*;
            self.sanitize_ptr = null;
            return copy;
        }

        pub fn size(self: *const Self) Error!usize {
            return self.container.entries.items.len;
        }

        pub fn capacity(_: *const Self) Error!usize {
            return max_entries_v;
        }

        pub fn getMbr(self: *const Self, pos: usize) Error!Key {
            try self.checkPos(pos);
            return self.container.entries.items[pos].mbr;
        }

        pub fn nodeMbr(self: *const Self) Error!Key {
            const items = self.container.entries.items;
            if (items.len == 0) {
                return Key.init();
            }
            var acc = items[0].mbr;
            for (items[1..]) |*e| {
                acc = acc.merged(&e.mbr);
            }
            return acc;
        }

        pub fn erase(self: *Self, pos: usize) Error!void {
            try self.checkPos(pos);
            _ = self.container.entries.orderedRemove(pos);
        }

        pub fn clear(self: *Self) Error!void {
            self.container.entries.clearRetainingCapacity();
        }

        pub fn getParent(self: *const Self) Error!?Pid {
            return self.container.parent;
        }

        pub fn setParent(self: *Self, parent: ?Pid) Error!void {
            self.container.parent = parent;
        }

        pub fn getLevel(self: *const Self) Error!usize {
            return self.container.level;
        }

        pub fn setLevel(self: *Self, level: usize) Error!void {
            self.container.level = level;
        }

        pub fn getChild(self: *const Self, pos: usize) Error!Pid {
            try self.checkPos(pos);
            return self.container.entries.items[pos].child;
        }

        pub fn canInsertChild(self: *const Self, _: Key, _: Pid) Error!bool {
            return self.container.entries.items.len < max_entries_v;
        }

        pub fn insertChild(self: *Self, mbr: Key, child: Pid) Error!void {
            if (self.container.entries.items.len >= max_entries_v) {
                return Error.NodeFull;
            }
            try self.container.entries.append(self.ctx.allocator, .{
                .mbr = mbr,
                .child = child,
            });
        }

        pub fn updateChildMbr(self: *Self, pos: usize, mbr: Key) Error!void {
            try self.checkPos(pos);
            self.container.entries.items[pos].mbr = mbr;
        }

        fn checkPos(self: *const Self, pos: usize) Error!void {
            if (pos >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
        }
    };

    const NodeVariant = union(enum) {
        inode: *InodeContainer,
        leaf: *LeafContainer,
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const Error = ModelError;
        const NodeList = std.ArrayList(?NodeVariant);

        ctx: Context,
        values: NodeList,
        root: ?Pid = null,

        fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .ctx = .{ .allocator = allocator },
                .values = try NodeList.initCapacity(allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.values.items) |maybe_node| {
                if (maybe_node) |node| {
                    switch (node) {
                        .inode => |c| {
                            c.deinit(self.ctx.allocator);
                            self.ctx.allocator.destroy(c);
                        },
                        .leaf => |c| {
                            c.deinit(self.ctx.allocator);
                            self.ctx.allocator.destroy(c);
                        },
                    }
                }
            }
            self.values.deinit(self.ctx.allocator);
        }

        pub fn getRoot(self: *const Self) ?Pid {
            return self.root;
        }

        pub fn setRoot(self: *Self, root: ?Pid) Error!void {
            self.root = root;
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            const pid = self.values.items.len;
            const c = try self.ctx.allocator.create(LeafContainer);
            errdefer self.ctx.allocator.destroy(c);
            c.* = try LeafContainer.init(self.ctx.allocator);
            errdefer c.deinit(self.ctx.allocator);

            const san: ?*u32 = if (IS_DEBUG) try self.ctx.allocator.create(u32) else null;
            errdefer {
                if (san) |p| {
                    self.ctx.allocator.destroy(p);
                }
            }

            try self.values.append(self.ctx.allocator, .{ .leaf = c });
            return .{
                .pid = pid,
                .container = c,
                .ctx = &self.ctx,
                .sanitize_ptr = san,
            };
        }

        pub fn createInode(self: *Self) Error!InodeImpl {
            const pid = self.values.items.len;
            const c = try self.ctx.allocator.create(InodeContainer);
            errdefer self.ctx.allocator.destroy(c);
            c.* = try InodeContainer.init(self.ctx.allocator);
            errdefer c.deinit(self.ctx.allocator);

            const san: ?*u32 = if (IS_DEBUG) try self.ctx.allocator.create(u32) else null;
            errdefer {
                if (san) |p| {
                    self.ctx.allocator.destroy(p);
                }
            }

            try self.values.append(self.ctx.allocator, .{ .inode = c });
            return .{
                .pid = pid,
                .container = c,
                .ctx = &self.ctx,
                .sanitize_ptr = san,
            };
        }

        pub fn loadLeaf(self: *Self, id: ?Pid) Error!?LeafImpl {
            const pid = id orelse return null;
            if (pid >= self.values.items.len) {
                return Error.InvalidId;
            }
            const node = self.values.items[pid] orelse return null;
            switch (node) {
                .leaf => |c| {
                    const san: ?*u32 = if (IS_DEBUG) try self.ctx.allocator.create(u32) else null;
                    return .{
                        .pid = pid,
                        .container = c,
                        .ctx = &self.ctx,
                        .sanitize_ptr = san,
                    };
                },
                .inode => return null,
            }
        }

        pub fn loadInode(self: *Self, id: ?Pid) Error!?InodeImpl {
            const pid = id orelse return null;
            if (pid >= self.values.items.len) {
                return Error.InvalidId;
            }
            const node = self.values.items[pid] orelse return null;
            switch (node) {
                .inode => |c| {
                    const san: ?*u32 = if (IS_DEBUG) try self.ctx.allocator.create(u32) else null;
                    return .{
                        .pid = pid,
                        .container = c,
                        .ctx = &self.ctx,
                        .sanitize_ptr = san,
                    };
                },
                .leaf => return null,
            }
        }

        pub fn deinitLeaf(_: *Self, leaf: ?LeafImpl) void {
            if (leaf) |l| {
                var vl = l;
                vl.deinit();
            }
        }

        pub fn deinitInode(_: *Self, inode: ?InodeImpl) void {
            if (inode) |n| {
                var vn = n;
                vn.deinit();
            }
        }

        pub fn isLeafId(self: *Self, pid: Pid) Error!bool {
            if (pid >= self.values.items.len) {
                return Error.InvalidId;
            }
            const node = self.values.items[pid] orelse return Error.InvalidId;
            return switch (node) {
                .leaf => true,
                .inode => false,
            };
        }

        pub fn destroy(self: *Self, pid: Pid) Error!void {
            if (pid >= self.values.items.len) {
                return Error.InvalidId;
            }
            if (self.values.items[pid]) |node| {
                switch (node) {
                    .inode => |c| {
                        c.deinit(self.ctx.allocator);
                        self.ctx.allocator.destroy(c);
                    },
                    .leaf => |c| {
                        c.deinit(self.ctx.allocator);
                        self.ctx.allocator.destroy(c);
                    },
                }
                self.values.items[pid] = null;
            }
        }
    };

    return struct {
        const Self = @This();

        pub const NodeIdType = Pid;
        pub const Error = ModelError;
        pub const KeyType = Key;
        pub const ValueInType = ValueT;
        pub const ValueOutType = ValueT;
        pub const ValueBufType = ValueT;
        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;
        pub const AccessorType = AccessorImpl;

        accessor: AccessorImpl,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .accessor = try AccessorImpl.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *AccessorImpl {
            return &self.accessor;
        }

        pub fn valueOutAsIn(_: *const Self, value: ValueOutType) ValueInType {
            return value;
        }

        pub fn copyValueOut(_: *const Self, value: ValueOutType) ValueBufType {
            return value;
        }

        pub fn valueBufAsIn(_: *const Self, buf: *const ValueBufType) ValueInType {
            return buf.*;
        }

        pub fn isValidId(self: *const Self, id: ?Pid) bool {
            const pid = id orelse return false;
            return pid < self.accessor.values.items.len;
        }
    };
}
