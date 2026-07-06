const std = @import("std");
const fullaz = @import("fullaz");
const FreeList = fullaz.storage.free_list.FreeList;

const PAGE = 64;

const MemStore = struct {
    const Self = @This();
    pub const Error = error{OutOfBounds};
    pub const PageId = u32;

    buffers: [][PAGE]u8,
    root: ?u32 = null,

    pub fn getRoot(self: *const Self) ?u32 {
        return self.root;
    }
    pub fn setRoot(self: *Self, r: ?u32) Error!void {
        self.root = r;
    }
    pub fn pageMut(self: *Self, pid: u32) Error![]u8 {
        if (pid >= self.buffers.len) return Error.OutOfBounds;
        return self.buffers[pid][0..];
    }
    pub fn pageConst(self: *Self, pid: u32) Error![]const u8 {
        if (pid >= self.buffers.len) return Error.OutOfBounds;
        return self.buffers[pid][0..];
    }
};

test "FreeList: LIFO push/pop, empty behaviour, head persists in the Store" {
    const allocator = std.testing.allocator;
    const bufs = try allocator.alloc([PAGE]u8, 8);
    defer allocator.free(bufs);
    for (bufs) |*b| @memset(b, 0);

    var store = MemStore{ .buffers = bufs };
    const FL = FreeList(MemStore, .little);
    var fl = FL.init(&store);

    // Empty.
    try std.testing.expect(fl.isEmpty());
    try std.testing.expect((try fl.pop()) == null);

    // LIFO: push 3,5,7 -> pop 7,5,3.
    try fl.push(3);
    try std.testing.expect(!fl.isEmpty());
    try fl.push(5);
    try fl.push(7);
    try std.testing.expectEqual(@as(?u32, 7), try fl.pop());
    try std.testing.expectEqual(@as(?u32, 5), try fl.pop());
    try std.testing.expectEqual(@as(?u32, 3), try fl.pop());
    try std.testing.expect(fl.isEmpty());
    try std.testing.expect((try fl.pop()) == null);

    // Interleaved push/pop.
    try fl.push(2);
    try fl.push(4);
    try std.testing.expectEqual(@as(?u32, 4), try fl.pop());
    try fl.push(6);
    try std.testing.expectEqual(@as(?u32, 6), try fl.pop());
    try std.testing.expectEqual(@as(?u32, 2), try fl.pop());
    try std.testing.expect(fl.isEmpty());

    // The list lives entirely in the Store (FreeList is stateless): a fresh
    // FreeList over the same Store sees the same stack.
    try fl.push(1);
    try fl.push(3);
    var fl2 = FL.init(&store);
    try std.testing.expectEqual(@as(?u32, 3), try fl2.pop());
    try std.testing.expectEqual(@as(?u32, 1), try fl2.pop());
    try std.testing.expect(fl2.isEmpty());
}
