const std = @import("std");
const range_aggregate = @import("fullaz").range_aggregate;

test "RangeAggregate settings keep geometry and value length at runtime" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 }) |CoordT| {
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 24,
        };
        try std.testing.expectEqual(@as(u32, 2), settings.base);
        try std.testing.expectEqual(@as(CoordT, 1), settings.base_width);
        settings.base = 3;
        settings.base_width = 2;
        try std.testing.expectEqual(@as(u32, 3), settings.base);
        try std.testing.expectEqual(@as(CoordT, 2), settings.base_width);
        try std.testing.expectEqual(@as(u8, 5), settings.level_count);
        try std.testing.expectEqual(@as(usize, 24), settings.value_size);
    }
}

test "RangeAggregate settings validate scalar constraints for every coordinate type" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 }) |CoordT| {
        const valid: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 24,
        };
        try valid.validate();

        var invalid = valid;
        invalid.base = 0;
        try std.testing.expectError(error.InvalidBase, invalid.validate());
        invalid.base = 1;
        try std.testing.expectError(error.InvalidBase, invalid.validate());

        invalid = valid;
        invalid.base_width = 0;
        try std.testing.expectError(error.InvalidBaseWidth, invalid.validate());

        invalid = valid;
        invalid.level_count = 0;
        try std.testing.expectError(error.InvalidLevelCount, invalid.validate());

        invalid = valid;
        invalid.value_size = 0;
        try std.testing.expectError(error.InvalidValueSize, invalid.validate());

        const minimum: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 1,
        };
        try minimum.validate();
    }
}

test "RangeAggregate settings reject negative integer widths" {
    inline for (.{ i8, i16, i32, i64 }) |CoordT| {
        var settings: range_aggregate.Settings(CoordT) = .{
            .base_width = -1,
            .level_count = 1,
            .value_size = 8,
        };
        try std.testing.expectError(error.InvalidBaseWidth, settings.validate());
        settings.base_width = std.math.minInt(CoordT);
        try std.testing.expectError(error.InvalidBaseWidth, settings.validate());
    }
}

test "RangeAggregate settings reject nonpositive and nonfinite float widths" {
    inline for (.{ f32, f64 }) |CoordT| {
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        for ([_]CoordT{
            0.0,
            -0.0,
            -0.25,
            std.math.nan(CoordT),
            std.math.inf(CoordT),
            -std.math.inf(CoordT),
        }) |width| {
            settings.base_width = width;
            try std.testing.expectError(error.InvalidBaseWidth, settings.validate());
        }
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(CoordT));
        const smallest_positive: CoordT = @bitCast(@as(Bits, 1));
        for ([_]CoordT{ 0.25, 0.1, 0.3333, smallest_positive }) |width| {
            settings.base_width = width;
            try settings.validate();
            try std.testing.expectEqual(width, settings.base_width);
        }
    }
}

test "RangeAggregate base is not narrowed to the coordinate type" {
    const settings: range_aggregate.Settings(u8) = .{
        .base = std.math.maxInt(u32),
        .base_width = 1,
        .level_count = 1,
        .value_size = 8,
    };
    try settings.validate();
    try std.testing.expectEqual(std.math.maxInt(u32), settings.base);
}

test "RangeAggregate keys are byte aligned and preserve numeric coordinates" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 }) |CoordT| {
        inline for (.{ .little, .big }) |endian| {
            const Key = range_aggregate.Key(CoordT, endian);
            const PackedCoord = @FieldType(Key, "value");
            const coordinate: CoordT = switch (@typeInfo(CoordT)) {
                .int => |info| if (info.signedness == .signed) -9 else 9,
                .float => -1.25,
                else => unreachable,
            };
            const key: Key = .{ .level = 4, .value = PackedCoord.init(coordinate) };
            try std.testing.expectEqual(@as(usize, 1), @alignOf(Key));
            try std.testing.expectEqual(1 + @sizeOf(CoordT), @sizeOf(Key));
            try std.testing.expectEqual(@as(usize, 1), @offsetOf(Key, "value"));
            try std.testing.expectEqual(@as(u8, 4), std.mem.asBytes(&key)[0]);
            try std.testing.expectEqual(coordinate, key.value.get());
        }
    }
}

test "RangeAggregate packed key bytes follow the selected endian" {
    const LittleKey = range_aggregate.Key(u32, .little);
    const BigKey = range_aggregate.Key(u32, .big);
    const little: LittleKey = .{
        .level = 6,
        .value = .init(0x01020304),
    };
    const big: BigKey = .{
        .level = 6,
        .value = .init(0x01020304),
    };
    try std.testing.expectEqualSlices(u8, &.{ 6, 4, 3, 2, 1 }, std.mem.asBytes(&little));
    try std.testing.expectEqualSlices(u8, &.{ 6, 1, 2, 3, 4 }, std.mem.asBytes(&big));
}

test "RangeAggregate query policy defaults to center" {
    const options: range_aggregate.QueryOptions = .{};
    try std.testing.expectEqual(range_aggregate.RangePolicy.center, options.policy);
    const exact: range_aggregate.QueryOptions = .{ .policy = .exact };
    const outward: range_aggregate.QueryOptions = .{ .policy = .outward };
    try std.testing.expectEqual(range_aggregate.RangePolicy.exact, exact.policy);
    try std.testing.expectEqual(range_aggregate.RangePolicy.outward, outward.policy);

    const interval: range_aggregate.LevelInfo(f64) = .{
        .level = 0,
        .from = 1.25,
        .to = 1.5,
    };
    try std.testing.expectEqual(@as(u8, 0), interval.level);
    try std.testing.expectEqual(@as(f64, 1.25), interval.from);
    try std.testing.expectEqual(@as(f64, 1.5), interval.to);
}

test "RangeAggregate durable state persists settings and starts with an empty B+ tree" {
    inline for (.{ i32, u32, f32, f64 }) |CoordT| {
        inline for (.{ .little, .big }) |endian| {
            const State = range_aggregate.State(u32, CoordT, endian);
            const settings: range_aggregate.Settings(CoordT) = .{
                .base = 3,
                .base_width = switch (@typeInfo(CoordT)) {
                    .int => 2,
                    .float => 0.25,
                    else => unreachable,
                },
                .level_count = 5,
                .value_size = 24,
            };
            const state = try State.init(settings);
            try std.testing.expectEqualDeep(settings, try state.settings());
            try std.testing.expect(state.tree.root.isMax());
            try std.testing.expectEqual(@as(usize, 1), @alignOf(State));
            try std.testing.expectEqual(@as(usize, 0), @offsetOf(State, "base"));
            try std.testing.expectEqual(
                @sizeOf(@FieldType(State, "base")),
                @offsetOf(State, "base_width"),
            );
            try std.testing.expectEqual(
                @sizeOf(@FieldType(State, "base")) + @sizeOf(@FieldType(State, "base_width")),
                @offsetOf(State, "level_count"),
            );
        }
    }
}

test "RangeAggregate durable state rejects invalid persisted settings" {
    const State = range_aggregate.State(u32, f64, .little);
    const valid: range_aggregate.Settings(f64) = .{
        .level_count = 1,
        .value_size = 8,
    };
    var state = try State.init(valid);
    state.base.set(1);
    try std.testing.expectError(error.InvalidBase, state.settings());
    state.base.set(2);
    state.base_width.set(std.math.nan(f64));
    try std.testing.expectError(error.InvalidBaseWidth, state.settings());
    state.base_width.set(1);
    state.level_count = 0;
    try std.testing.expectError(error.InvalidLevelCount, state.settings());
    state.level_count = 1;
    state.value_size.set(0);
    try std.testing.expectError(error.InvalidValueSize, state.settings());
}

test "RangeAggregate tree storage manager projects only the B+ tree state" {
    const State = range_aggregate.State(u32, i32, .little);
    const Lease = struct {
        pub const Error = error{};

        state: *State,

        pub fn data(self: *const @This()) Error![]const u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn dataMut(self: *@This()) Error![]u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };
    const ParentManager = struct {
        pub const PageId = u32;
        pub const Error = error{};
        pub const StateLeaseType = Lease;

        durable_state: State,

        pub fn state(self: *@This()) Error!StateLeaseType {
            return .{ .state = &self.durable_state };
        }

        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    };
    const TreeManager = range_aggregate.TreeStorageManager(ParentManager, u32, i32, .little);
    const settings: range_aggregate.Settings(i32) = .{
        .level_count = 1,
        .value_size = 8,
    };
    var parent: ParentManager = .{ .durable_state = try State.init(settings) };
    var tree_manager = TreeManager.init(&parent);
    var lease = try tree_manager.state();
    defer lease.deinit();
    try std.testing.expectEqual(@sizeOf(@FieldType(State, "tree")), (try lease.data()).len);
    const tree = @as(*@FieldType(State, "tree"), @ptrCast((try lease.dataMut()).ptr));
    tree.root.set(7);
    lease.finish();
    try std.testing.expectEqual(@as(u32, 7), parent.durable_state.tree.root.get());
}
