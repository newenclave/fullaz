const StaticVector = @import("fullaz").StaticVector;
const std = @import("std");
const expect = std.testing.expect;

test "StaticVector basic operations" {
    var sv = StaticVector(u8, 64, void, null).init(undefined);
    try sv.pushBack(10);
    try sv.pushBack(20);
    try sv.pushBack(30);
    try expect(sv.size() == 3);
    const first = sv.ptrAt(0) orelse @panic("Expected element at index 0");
    const second = sv.ptrAt(1) orelse @panic("Expected element at index 1");
    const third = sv.ptrAt(2) orelse @panic("Expected element at index 2");
    try expect(first.* == 10);
    try expect(second.* == 20);
    try expect(third.* == 30);
    try expect(sv.back().?.* == 30);
    try expect(!sv.empty());
    try expect(!sv.full());
}

test "Static Vector overflow" {
    var sv = StaticVector(u8, 2, void, null).init(undefined);
    try sv.pushBack(1);
    try sv.pushBack(2);
    const result = sv.pushBack(3);
    try expect(result == error.Full);
}

test "StaticVector ptrAt out of bounds" {
    var sv = StaticVector(u8, 2, void, null).init(undefined);
    try sv.pushBack(1);
    const valid_ptr = sv.ptrAt(0);
    const invalid_ptr = sv.ptrAt(1);
    try expect(valid_ptr != null);
    try expect(invalid_ptr == null);
}

test "StaticVector back on empty vector" {
    var sv = StaticVector(u8, 2, void, null).init(undefined);
    const back_ptr = sv.back();
    try expect(back_ptr == null);
}

test "StaticVector capacity check" {
    var sv = StaticVector(u8, 5, void, null).init(undefined);
    try expect(sv.capacity() == 5);
    try sv.pushBack(1);
    try sv.pushBack(2);
    try expect(sv.capacity() == 5);
}

test "StaticVector full check" {
    var sv = StaticVector(u8, 2, void, null).init(undefined);
    try expect(!sv.full());
    try sv.pushBack(1);
    try expect(!sv.full());
    try sv.pushBack(2);
    try expect(sv.full());
}

test "StaticVector empty check" {
    var sv = StaticVector(u8, 2, void, null).init(undefined);
    try expect(sv.empty());
    try sv.pushBack(1);
    try expect(!sv.empty());
    try sv.pushBack(2);
    try expect(!sv.empty());
}

test "StaticVector remove elements" {
    var sv = StaticVector(u8, 3, void, null).init(undefined);
    try sv.pushBack(1);
    try sv.pushBack(2);
    try sv.pushBack(3);
    try expect(sv.size() == 3);

    // Simulate removal by decreasing length
    sv.len -= 1;
    try expect(sv.size() == 2);
    const back_ptr = sv.back() orelse @panic("Expected back element");
    try expect(back_ptr.* == 2);
}

test "StaticVector pushBack until full" {
    var sv = StaticVector(u8, 3, void, null).init(undefined);
    for (0..3) |i| {
        try sv.pushBack(@intCast(i));
    }
    try expect(sv.full());
    const result = sv.pushBack(4);
    try expect(result == error.Full);
}

test "StaticVector initialization with context" {
    const DeinitCtx = struct {
        value: u32,
    };
    const sv = StaticVector(u8, 2, DeinitCtx, null).init(DeinitCtx{ .value = 42 });
    try expect(sv.deinit_ctx.value == 42);
}

fn testDestructor(ctx: *usize, item: *u8) void {
    _ = item;
    ctx.* += 1;
}

test "StaticVector custom destructor" {
    var destroyed: usize = 0;
    var sv = StaticVector(u8, 2, *usize, testDestructor).init(&destroyed);
    try sv.pushBack(1);
    try sv.pushBack(2);
    const old_size = sv.size();

    // Manually call destructor for testing
    while (!sv.empty()) {
        try sv.remove(0);
    }
    try expect(destroyed == old_size);
}
