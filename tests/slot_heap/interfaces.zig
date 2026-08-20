const std = @import("std");
const fullaz = @import("fullaz");

const interfaces = fullaz.storage.slot_heap.models.interfaces;
const WinnerChange = interfaces.WinnerChange;

const MockError = error{Example};
const Location = struct {
    page_id: u32,
    slot_id: u16,
};

const Leaf = struct {
    pub const Error = MockError;

    pub fn id(_: *const Leaf) u32 {
        return 0;
    }
    pub fn take(_: *Leaf) Error!Leaf {
        return .{};
    }
    pub fn size(_: *const Leaf) Error!usize {
        return 0;
    }
    pub fn getParent(_: *const Leaf) Error!?u32 {
        return null;
    }
    pub fn setParent(_: *Leaf, _: ?u32) Error!void {}
    pub fn getKey(_: *const Leaf, _: usize) Error![]const u8 {
        return "";
    }
    pub fn getValue(_: *const Leaf, _: usize) Error![]const u8 {
        return "";
    }
    pub fn canPush(_: *const Leaf, _: []const u8, _: []const u8) Error!bool {
        return true;
    }
    pub fn push(_: *Leaf, _: []const u8, _: []const u8) Error!WinnerChange {
        return .changed;
    }
    pub fn popTop(_: *Leaf) Error!void {}
    pub fn availableAfterCompact(_: *const Leaf) Error!u16 {
        return 0;
    }
    pub fn usedBytes(_: *const Leaf) Error!usize {
        return 0;
    }
    pub fn capacityBytes(_: *const Leaf) Error!usize {
        return 0;
    }
};

const Inode = struct {
    pub const Error = MockError;

    pub fn id(_: *const Inode) u32 {
        return 0;
    }
    pub fn take(_: *Inode) Error!Inode {
        return .{};
    }
    pub fn size(_: *const Inode) Error!usize {
        return 0;
    }
    pub fn capacity(_: *const Inode) Error!usize {
        return 2;
    }
    pub fn getLevel(_: *const Inode) Error!usize {
        return 1;
    }
    pub fn getParent(_: *const Inode) Error!?u32 {
        return null;
    }
    pub fn setParent(_: *Inode, _: ?u32) Error!void {}
    pub fn getAvailablePrev(_: *const Inode) Error!?u32 {
        return null;
    }
    pub fn setAvailablePrev(_: *Inode, _: ?u32) Error!void {}
    pub fn getAvailableNext(_: *const Inode) Error!?u32 {
        return null;
    }
    pub fn setAvailableNext(_: *Inode, _: ?u32) Error!void {}
    pub fn isAvailableLinked(_: *const Inode) Error!bool {
        return false;
    }
    pub fn setAvailableLinked(_: *Inode, _: bool) Error!void {}
    pub fn findChild(_: *const Inode, _: u32) Error!?usize {
        return null;
    }
    pub fn getKey(_: *const Inode, _: usize) Error![]const u8 {
        return "";
    }
    pub fn getChild(_: *const Inode, _: usize) Error!u32 {
        return 0;
    }
    pub fn getWinner(_: *const Inode, _: usize) Error!Location {
        return .{ .page_id = 0, .slot_id = 0 };
    }
    pub fn insertChild(_: *Inode, _: []const u8, _: u32, _: Location) Error!WinnerChange {
        return .changed;
    }
    pub fn updateChild(_: *Inode, _: usize, _: []const u8, _: Location) Error!WinnerChange {
        return .changed;
    }
    pub fn removeChild(_: *Inode, _: usize) Error!WinnerChange {
        return .changed;
    }
};

const Accessor = struct {
    pub const Error = MockError;

    pub fn getRoot(_: *const Accessor) ?u32 {
        return null;
    }
    pub fn setRoot(_: *Accessor, _: ?u32) Error!void {}
    pub fn getCachedTop(_: *const Accessor) ?Location {
        return null;
    }
    pub fn setCachedTop(_: *Accessor, _: ?Location) Error!void {}
    pub fn getAvailableInode(_: *const Accessor, _: usize) Error!?u32 {
        return null;
    }
    pub fn setAvailableInode(_: *Accessor, _: usize, _: ?u32) Error!void {}
    pub fn createLeaf(_: *Accessor) Error!Leaf {
        return .{};
    }
    pub fn createInode(_: *Accessor, _: usize) Error!Inode {
        return .{};
    }
    pub fn loadLeaf(_: *Accessor, _: u32) Error!?Leaf {
        return .{};
    }
    pub fn loadInode(_: *Accessor, _: u32) Error!?Inode {
        return .{};
    }
    pub fn deinitLeaf(_: *Accessor, _: ?Leaf) void {}
    pub fn deinitInode(_: *Accessor, _: ?Inode) void {}
    pub fn isLeafId(_: *Accessor, _: u32) Error!bool {
        return true;
    }
    pub fn destroy(_: *Accessor, _: u32) Error!void {}
    pub fn findLeaf(_: *Accessor, _: u16) Error!?u32 {
        return null;
    }
    pub fn addLeafSpace(_: *Accessor, _: u32, _: u16) Error!void {}
    pub fn updateLeafSpace(_: *Accessor, _: u32, _: u16) Error!void {}
    pub fn removeLeafSpace(_: *Accessor, _: u32) Error!void {}
};

const Model = struct {
    pub const NodeIdType = u32;
    pub const SlotIdType = u16;
    pub const LocationType = Location;
    pub const CountType = u64;
    pub const SpaceType = u16;
    pub const KeyInType = []const u8;
    pub const KeyOutType = []const u8;
    pub const ValueInType = []const u8;
    pub const ValueOutType = []const u8;
    pub const LeafType = Leaf;
    pub const InodeType = Inode;
    pub const AccessorType = Accessor;
    pub const Error = MockError;

    accessor_state: Accessor = .{},

    pub fn accessor(self: *Model) *Accessor {
        return &self.accessor_state;
    }
    pub fn compareKeys(_: *const Model, _: []const u8, _: []const u8) Error!std.math.Order {
        return .eq;
    }
    pub fn keyOutAsIn(_: *const Model, key: []const u8) []const u8 {
        return key;
    }
    pub fn requiredLeafSpace(_: *const Model, _: []const u8, _: []const u8) Error!u16 {
        return 0;
    }
    pub fn incrementEntriesCount(_: *Model) Error!void {}
    pub fn decrementEntriesCount(_: *Model) Error!void {}
    pub fn getEntriesCount(_: *const Model) Error!u64 {
        return 0;
    }
};

const StorageManager = struct {
    pub const PageId = u32;
    pub const CountType = u64;
    pub const Error = MockError;

    pub fn getRoot(_: *const StorageManager) ?PageId {
        return null;
    }
    pub fn setRoot(_: *StorageManager, _: ?PageId) Error!void {}
    pub fn getCachedTop(_: *const StorageManager) ?Location {
        return null;
    }
    pub fn setCachedTop(_: *StorageManager, _: ?Location) Error!void {}
    pub fn getEntriesCount(_: *const StorageManager) Error!CountType {
        return 0;
    }
    pub fn setEntriesCount(_: *StorageManager, _: CountType) Error!void {}
    pub fn getAvailableInode(_: *const StorageManager, _: usize) Error!?PageId {
        return null;
    }
    pub fn setAvailableInode(_: *StorageManager, _: usize, _: ?PageId) Error!void {}
    pub fn destroyPage(_: *StorageManager, _: PageId) Error!void {}
};

test "SlotHeap model contract accepts a conforming model" {
    comptime interfaces.assertModel(Model);
}

test "SlotHeap storage manager contract accepts persistent metadata" {
    comptime interfaces.assertPagedStorageManager(StorageManager, Location);
}
