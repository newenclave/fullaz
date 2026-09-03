const std = @import("std");
const fullaz = @import("fullaz");

const contracts = fullaz.contracts.storage_manager;
const storage_manager = fullaz.core.storage_manager;

const TestError = error{
    StateFailed,
    ReadFailed,
    ReadOnly,
};

const ChildState = extern struct {
    bytes: [2]u8,
};

const OuterState = extern struct {
    prefix: u8,
    child: ChildState,
    items: [2]ChildState,
    suffix: u8,
};

const TrackingLease = struct {
    const Self = @This();

    pub const Error = TestError;

    bytes: []u8,
    fail_read: *bool,
    read_only: *bool,
    finish_count: *usize,
    deinit_count: *usize,

    pub fn data(self: *const Self) Error![]const u8 {
        if (self.fail_read.*) {
            return error.ReadFailed;
        }
        return self.bytes;
    }

    pub fn dataMut(self: *Self) Error![]u8 {
        if (self.read_only.*) {
            return error.ReadOnly;
        }
        return self.bytes;
    }

    pub fn finish(self: *Self) void {
        self.finish_count.* += 1;
    }

    pub fn deinit(self: *Self) void {
        self.deinit_count.* += 1;
    }
};

const TrackingManager = struct {
    const Self = @This();

    pub const PageId = u32;
    pub const Error = TestError;
    pub const StateLeaseType = TrackingLease;

    bytes: []u8,
    fail_state: bool = false,
    fail_read: bool = false,
    read_only: bool = false,
    finish_count: usize = 0,
    deinit_count: usize = 0,
    destroy_count: usize = 0,
    destroyed_page_id: ?PageId = null,

    fn init(bytes: []u8) Self {
        return .{ .bytes = bytes };
    }

    pub fn state(self: *Self) Error!StateLeaseType {
        if (self.fail_state) {
            return error.StateFailed;
        }
        return .{
            .bytes = self.bytes,
            .fail_read = &self.fail_read,
            .read_only = &self.read_only,
            .finish_count = &self.finish_count,
            .deinit_count = &self.deinit_count,
        };
    }

    pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
        self.destroy_count += 1;
        self.destroyed_page_id = page_id;
    }
};

const StateOnlyManager = struct {
    const Self = @This();

    pub const Error = TestError;
    pub const StateLeaseType = TrackingLease;

    inner: TrackingManager,

    pub fn state(self: *Self) Error!StateLeaseType {
        return self.inner.state();
    }
};

const PagedChildManager = storage_manager.PagedFieldStorageManager(
    TrackingManager,
    OuterState,
    "child",
);
const StateOnlyChildManager = storage_manager.FieldStorageManager(
    StateOnlyManager,
    OuterState,
    "child",
);
const ItemsManager = storage_manager.FieldStorageManager(
    TrackingManager,
    OuterState,
    "items",
);
const SecondItemManager = storage_manager.ArrayElementStorageManager(
    ItemsManager,
    @FieldType(OuterState, "items"),
    1,
);
const PagedItemsManager = storage_manager.PagedFieldStorageManager(
    TrackingManager,
    OuterState,
    "items",
);
const PagedSecondItemManager = storage_manager.PagedArrayElementStorageManager(
    PagedItemsManager,
    @FieldType(OuterState, "items"),
    1,
);
const BorrowedManager = storage_manager.BorrowedExactStateManager(
    StateOnlyManager,
    OuterState,
);
const BorrowedPagedManager = storage_manager.BorrowedExactPagedStorageManager(
    TrackingManager,
    OuterState,
);

comptime {
    contracts.assertStorageManager(StateOnlyManager);
    contracts.assertPagedStorageManager(TrackingManager, u32);
    contracts.assertStorageManager(StateOnlyChildManager);
    contracts.assertStorageManager(ItemsManager);
    contracts.assertStorageManager(SecondItemManager);
    contracts.assertPagedStorageManager(PagedChildManager, u32);
    contracts.assertPagedStorageManager(PagedSecondItemManager, u32);
    contracts.assertStorageManager(BorrowedManager);
    contracts.assertPagedStorageManager(BorrowedPagedManager, u32);
}

test "storage manager StateAccessor requires exact byte length" {
    const Accessor = storage_manager.StateAccessor(TrackingLease, ChildState);

    var exact_state = ChildState{ .bytes = .{ 1, 2 } };
    var exact_manager = TrackingManager.init(std.mem.asBytes(&exact_state));
    var exact_lease = try exact_manager.state();
    defer exact_lease.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &(try Accessor.view(&exact_lease)).bytes);

    var short_bytes: [@sizeOf(ChildState) - 1]u8 = undefined;
    var short_manager = TrackingManager.init(&short_bytes);
    var short_lease = try short_manager.state();
    defer short_lease.deinit();
    try std.testing.expectError(error.BadData, Accessor.view(&short_lease));

    var long_bytes: [@sizeOf(ChildState) + 1]u8 = undefined;
    var long_manager = TrackingManager.init(&long_bytes);
    var long_lease = try long_manager.state();
    defer long_lease.deinit();
    try std.testing.expectError(error.BadData, Accessor.viewMut(&long_lease));

    const ChildManager = storage_manager.FieldStorageManager(
        TrackingManager,
        OuterState,
        "child",
    );
    var oversized_outer: [@sizeOf(OuterState) + 1]u8 = undefined;
    var oversized_manager = TrackingManager.init(&oversized_outer);
    var child_manager = ChildManager.init(&oversized_manager);
    var child_lease = try child_manager.state();
    defer child_lease.deinit();
    try std.testing.expectError(error.BadData, child_lease.data());
}

test "storage manager field and array projections are mutable" {
    var outer = OuterState{
        .prefix = 1,
        .child = .{ .bytes = .{ 2, 3 } },
        .items = .{
            .{ .bytes = .{ 4, 5 } },
            .{ .bytes = .{ 6, 7 } },
        },
        .suffix = 8,
    };
    var parent = TrackingManager.init(std.mem.asBytes(&outer));

    var items_manager = ItemsManager.init(&parent);
    var second_item_manager = SecondItemManager.init(&items_manager);
    var lease = try second_item_manager.state();
    defer lease.deinit();

    const bytes = try lease.dataMut();
    try std.testing.expectEqual(@as(usize, @sizeOf(ChildState)), bytes.len);
    bytes[0] = 42;
    bytes[1] = 43;

    try std.testing.expectEqualSlices(u8, &.{ 42, 43 }, &outer.items[1].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, &outer.items[0].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, &outer.child.bytes);
}

test "storage manager projection propagates readonly and parent errors" {
    var outer = std.mem.zeroes(OuterState);
    var parent = TrackingManager.init(std.mem.asBytes(&outer));
    var manager = PagedChildManager.init(&parent);

    parent.read_only = true;
    var lease = try manager.state();
    try std.testing.expectEqual(@as(usize, @sizeOf(ChildState)), (try lease.data()).len);
    try std.testing.expectError(error.ReadOnly, lease.dataMut());

    parent.fail_read = true;
    try std.testing.expectError(error.ReadFailed, lease.data());
    lease.deinit();

    parent.fail_state = true;
    try std.testing.expectError(error.StateFailed, manager.state());
}

test "storage manager projected lease forwards finish and deinit once" {
    var outer = std.mem.zeroes(OuterState);
    var parent = TrackingManager.init(std.mem.asBytes(&outer));
    var manager = PagedChildManager.init(&parent);
    var lease = try manager.state();

    lease.finish();
    lease.finish();
    lease.deinit();
    lease.deinit();

    try std.testing.expectEqual(@as(usize, 1), parent.finish_count);
    try std.testing.expectEqual(@as(usize, 1), parent.deinit_count);

    try manager.destroyPage(27);
    try std.testing.expectEqual(@as(usize, 1), parent.destroy_count);
    try std.testing.expectEqual(@as(?u32, 27), parent.destroyed_page_id);
}

test "storage manager borrowed exact state keeps outer lease ownership" {
    var outer = std.mem.zeroes(OuterState);
    var parent = TrackingManager.init(std.mem.asBytes(&outer));
    var outer_lease = try parent.state();

    var manager = BorrowedPagedManager.init(&parent, &outer_lease);
    var lease = try manager.state();
    const bytes = try lease.dataMut();
    bytes[@offsetOf(OuterState, "suffix")] = 91;
    lease.finish();
    lease.deinit();

    try std.testing.expectEqual(@as(u8, 91), outer.suffix);
    try std.testing.expectEqual(@as(usize, 0), parent.finish_count);
    try std.testing.expectEqual(@as(usize, 0), parent.deinit_count);

    try manager.destroyPage(35);
    try std.testing.expectEqual(@as(?u32, 35), parent.destroyed_page_id);

    outer_lease.finish();
    outer_lease.deinit();
    try std.testing.expectEqual(@as(usize, 1), parent.finish_count);
    try std.testing.expectEqual(@as(usize, 1), parent.deinit_count);

    var short_bytes: [@sizeOf(OuterState) - 1]u8 = undefined;
    var short_parent = TrackingManager.init(&short_bytes);
    var short_outer_lease = try short_parent.state();
    defer short_outer_lease.deinit();
    var short_manager = BorrowedManager.init(&short_outer_lease);
    var short_lease = try short_manager.state();
    defer short_lease.deinit();
    try std.testing.expectError(error.BadData, short_lease.data());
}
