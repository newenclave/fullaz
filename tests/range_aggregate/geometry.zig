const std = @import("std");
const range_aggregate = @import("fullaz").range_aggregate;

test "RangeAggregate integer intervals contain nine at every level" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 8,
        };
        const starts = [_]CoordT{ 9, 8, 8, 8, 0 };
        const ends = [_]CoordT{ 10, 10, 12, 16, 16 };
        for (starts, ends, 0..) |from, to, level| {
            const info = try range_aggregate.Geometry(CoordT).interval(settings, 9, @intCast(level));
            try std.testing.expectEqual(@as(u8, @intCast(level)), info.level);
            try std.testing.expectEqual(from, info.from);
            try std.testing.expectEqual(to, info.to);
        }
    }
}

test "RangeAggregate integer intervals floor negative coordinates" {
    inline for (.{ i8, i16, i32, i64 }) |CoordT| {
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 8,
        };
        const starts = [_]CoordT{ -9, -10, -12, -16, -16 };
        const ends = [_]CoordT{ -8, -8, -8, -8, 0 };
        for (starts, ends, 0..) |from, to, level| {
            const info = try range_aggregate.Geometry(CoordT).interval(settings, -9, @intCast(level));
            try std.testing.expectEqual(from, info.from);
            try std.testing.expectEqual(to, info.to);
        }
    }
}

test "RangeAggregate integer intervals support nonbinary bases and nonunit widths" {
    const settings: range_aggregate.Settings(i32) = .{
        .base = 3,
        .base_width = 2,
        .level_count = 3,
        .value_size = 8,
    };
    const starts = [_]i32{ 8, 6, 0 };
    const ends = [_]i32{ 10, 12, 18 };
    for (starts, ends, 0..) |from, to, level| {
        const info = try range_aggregate.Geometry(i32).interval(settings, 9, @intCast(level));
        try std.testing.expectEqual(from, info.from);
        try std.testing.expectEqual(to, info.to);
    }
    const boundary = try range_aggregate.Geometry(i32).interval(settings, 12, 1);
    try std.testing.expectEqual(@as(i32, 12), boundary.from);
    try std.testing.expectEqual(@as(i32, 18), boundary.to);
}

test "RangeAggregate integer intervals check coordinate extrema without narrowing widths" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = @bitSizeOf(CoordT),
            .value_size = 8,
        };
        const Geometry = range_aggregate.Geometry(CoordT);
        const minimum = std.math.minInt(CoordT);
        const maximum = std.math.maxInt(CoordT);
        const first = try Geometry.interval(settings, minimum, 0);
        try std.testing.expectEqual(minimum, first.from);
        try std.testing.expectEqual(minimum + 1, first.to);
        const last = try Geometry.interval(settings, maximum - 1, 0);
        try std.testing.expectEqual(maximum - 1, last.from);
        try std.testing.expectEqual(maximum, last.to);
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.interval(settings, maximum, 0));

        if (@typeInfo(CoordT).int.signedness == .signed) {
            const negative = try Geometry.interval(settings, -1, @bitSizeOf(CoordT) - 1);
            try std.testing.expectEqual(minimum, negative.from);
            try std.testing.expectEqual(@as(CoordT, 0), negative.to);

            var unaligned = settings;
            unaligned.base_width = 3;
            try std.testing.expectError(error.CoordinateOutOfRange, Geometry.interval(unaligned, minimum, 0));
        }
    }
}

test "RangeAggregate integer intervals reject invalid levels and overflowing powers" {
    const Geometry = range_aggregate.Geometry(u64);
    var settings: range_aggregate.Settings(u64) = .{
        .level_count = 1,
        .value_size = 8,
    };
    try std.testing.expectError(error.InvalidLevel, Geometry.interval(settings, 0, 1));
    settings.level_count = 255;
    try std.testing.expectError(error.CoordinateOutOfRange, Geometry.interval(settings, 0, 254));
    settings.base = 0;
    try std.testing.expectError(error.InvalidBase, Geometry.interval(settings, 0, 0));
    settings.base = 2;
    settings.base_width = 0;
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.interval(settings, 0, 0));

    const narrow: range_aggregate.Settings(i8) = .{
        .base = 128,
        .level_count = 2,
        .value_size = 8,
    };
    const negative = try range_aggregate.Geometry(i8).interval(narrow, -1, 1);
    try std.testing.expectEqual(@as(i8, -128), negative.from);
    try std.testing.expectEqual(@as(i8, 0), negative.to);
    try std.testing.expectError(
        error.CoordinateOutOfRange,
        range_aggregate.Geometry(i8).interval(narrow, 0, 1),
    );
}

test "RangeAggregate integer intervals are aligned half open and nested" {
    for ([_]u32{ 2, 3, 10 }) |base| {
        const settings: range_aggregate.Settings(i32) = .{
            .base = base,
            .base_width = 3,
            .level_count = 4,
            .value_size = 8,
        };
        var coordinate: i32 = -100;
        while (coordinate <= 100) : (coordinate += 1) {
            var previous: ?range_aggregate.LevelInfo(i32) = null;
            var width: i32 = settings.base_width;
            for (0..settings.level_count) |level| {
                const info = try range_aggregate.Geometry(i32).interval(settings, coordinate, @intCast(level));
                try std.testing.expect(info.from <= coordinate and coordinate < info.to);
                try std.testing.expectEqual(width, info.to - info.from);
                try std.testing.expectEqual(@as(i32, 0), @mod(info.from, width));
                if (previous) |child| {
                    try std.testing.expect(info.from <= child.from and child.to <= info.to);
                }
                previous = info;
                width *= @intCast(base);
            }
        }
    }
}

test "RangeAggregate coordinate validation supports every integer type" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 8,
        };
        try Geometry.validateCoordinate(settings, 9);

        var full_depth = settings;
        full_depth.level_count = @bitSizeOf(CoordT);
        try Geometry.validateCoordinate(full_depth, std.math.minInt(CoordT));
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.validateCoordinate(full_depth, std.math.maxInt(CoordT)),
        );
    }
}

test "RangeAggregate coordinate validation catches failure only at the highest level" {
    const settings: range_aggregate.Settings(u8) = .{
        .level_count = 5,
        .value_size = 8,
    };
    for (0..4) |level| {
        _ = try range_aggregate.Geometry(u8).interval(settings, 240, @intCast(level));
    }
    try std.testing.expectError(
        error.CoordinateOutOfRange,
        range_aggregate.Geometry(u8).validateCoordinate(settings, 240),
    );

    const negative: range_aggregate.Settings(i8) = .{
        .base = 3,
        .level_count = 4,
        .value_size = 8,
    };
    for (0..3) |level| {
        _ = try range_aggregate.Geometry(i8).interval(negative, -120, @intCast(level));
    }
    try std.testing.expectError(
        error.CoordinateOutOfRange,
        range_aggregate.Geometry(i8).validateCoordinate(negative, -120),
    );
}

test "RangeAggregate coordinate validation respects single and invalid level counts" {
    const Geometry = range_aggregate.Geometry(u8);
    var settings: range_aggregate.Settings(u8) = .{
        .base = std.math.maxInt(u32),
        .level_count = 1,
        .value_size = 8,
    };
    try Geometry.validateCoordinate(settings, 254);
    settings.level_count = 0;
    try std.testing.expectError(error.InvalidLevelCount, Geometry.validateCoordinate(settings, 254));
    settings.level_count = 255;
    try std.testing.expectError(error.CoordinateOutOfRange, Geometry.validateCoordinate(settings, 0));
    settings.level_count = 1;
    settings.base = 1;
    try std.testing.expectError(error.InvalidBase, Geometry.validateCoordinate(settings, 0));
    settings.base = 2;
    settings.base_width = 0;
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.validateCoordinate(settings, 0));
    settings.base_width = 1;
    settings.value_size = 0;
    try std.testing.expectError(error.InvalidValueSize, Geometry.validateCoordinate(settings, 0));
}

test "RangeAggregate coordinate validation matches exhaustive per-level checks" {
    inline for (.{ i8, u8 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        for ([_]u32{ 2, 3, 10 }) |base| {
            for ([_]CoordT{ 1, 3 }) |base_width| {
                for (1..9) |level_count| {
                    const settings: range_aggregate.Settings(CoordT) = .{
                        .base = base,
                        .base_width = base_width,
                        .level_count = @intCast(level_count),
                        .value_size = 8,
                    };
                    var at: i16 = std.math.minInt(CoordT);
                    while (at <= std.math.maxInt(CoordT)) : (at += 1) {
                        const coordinate: CoordT = @intCast(at);
                        var all_fit = true;
                        for (0..level_count) |level| {
                            _ = Geometry.interval(settings, coordinate, @intCast(level)) catch |err| {
                                try std.testing.expectEqual(error.CoordinateOutOfRange, err);
                                all_fit = false;
                                break;
                            };
                        }
                        if (all_fit) {
                            try Geometry.validateCoordinate(settings, coordinate);
                        } else {
                            try std.testing.expectError(
                                error.CoordinateOutOfRange,
                                Geometry.validateCoordinate(settings, coordinate),
                            );
                        }
                    }
                }
            }
        }
    }
}

test "RangeAggregate exact integer ranges preserve aligned bounds" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const settings: range_aggregate.Settings(CoordT) = .{
            .base = 3,
            .base_width = 4,
            .level_count = 2,
            .value_size = 8,
        };
        const range: range_aggregate.Range(CoordT) = try range_aggregate.Geometry(CoordT).exactRange(
            settings,
            4,
            24,
        );
        try std.testing.expectEqual(@as(CoordT, 4), range.from);
        try std.testing.expectEqual(@as(CoordT, 24), range.to);
        if (@typeInfo(CoordT).int.signedness == .signed) {
            const negative = try range_aggregate.Geometry(CoordT).exactRange(settings, -24, -4);
            try std.testing.expectEqual(@as(CoordT, -24), negative.from);
            try std.testing.expectEqual(@as(CoordT, -4), negative.to);
            const crossing_zero = try range_aggregate.Geometry(CoordT).exactRange(settings, -8, 12);
            try std.testing.expectEqual(@as(CoordT, -8), crossing_zero.from);
            try std.testing.expectEqual(@as(CoordT, 12), crossing_zero.to);
        }
    }
}

test "RangeAggregate exact integer ranges reject either unaligned endpoint" {
    const Geometry = range_aggregate.Geometry(i32);
    const settings: range_aggregate.Settings(i32) = .{
        .base_width = 4,
        .level_count = 1,
        .value_size = 8,
    };
    const starts = [_]i32{ 1, 4, 1, -7, -8, -7 };
    const ends = [_]i32{ 8, 9, 9, 4, 3, 3 };
    for (starts, ends) |from, to| {
        try std.testing.expectError(error.UnalignedRange, Geometry.exactRange(settings, from, to));
    }
}

test "RangeAggregate exact integer ranges preserve empty bounds and reject reversed bounds" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 3,
            .level_count = 1,
            .value_size = 8,
        };
        for ([_]CoordT{ std.math.minInt(CoordT), 1, std.math.maxInt(CoordT) }) |point| {
            const empty = try Geometry.exactRange(settings, point, point);
            try std.testing.expectEqual(point, empty.from);
            try std.testing.expectEqual(point, empty.to);
        }
        try std.testing.expectError(
            error.InvalidRange,
            Geometry.exactRange(settings, std.math.maxInt(CoordT), std.math.minInt(CoordT)),
        );
    }
}

test "RangeAggregate exact integer ranges accept extreme exclusive endpoints" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const minimum = std.math.minInt(CoordT);
        const maximum = std.math.maxInt(CoordT);
        const full = try Geometry.exactRange(settings, minimum, maximum);
        try std.testing.expectEqual(minimum, full.from);
        try std.testing.expectEqual(maximum, full.to);
        const last = try Geometry.exactRange(settings, maximum - 1, maximum);
        try std.testing.expectEqual(maximum - 1, last.from);
        try std.testing.expectEqual(maximum, last.to);
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.interval(settings, maximum, 0));
    }
}

test "RangeAggregate exact integer ranges validate settings before alignment" {
    const Geometry = range_aggregate.Geometry(i32);
    var settings: range_aggregate.Settings(i32) = .{
        .base_width = 0,
        .level_count = 1,
        .value_size = 8,
    };
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.exactRange(settings, 0, 4));
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.exactRange(settings, 0, 0));
    settings.base_width = 1;
    settings.base = 1;
    try std.testing.expectError(error.InvalidBase, Geometry.exactRange(settings, 0, 4));
    settings.base = 2;
    settings.level_count = 0;
    try std.testing.expectError(error.InvalidLevelCount, Geometry.exactRange(settings, 0, 4));
    settings.level_count = 1;
    settings.value_size = 0;
    try std.testing.expectError(error.InvalidValueSize, Geometry.exactRange(settings, 0, 4));
}

test "RangeAggregate outward integer ranges expand only unaligned endpoints" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 4,
            .level_count = 1,
            .value_size = 8,
        };
        const starts = [_]CoordT{ 1, 4, 1, 0, 3 };
        const ends = [_]CoordT{ 9, 24, 8, 1, 4 };
        const expected_starts = [_]CoordT{ 0, 4, 0, 0, 0 };
        const expected_ends = [_]CoordT{ 12, 24, 8, 4, 4 };
        for (starts, ends, expected_starts, expected_ends) |from, to, expected_from, expected_to| {
            const range = try Geometry.outwardRange(settings, from, to);
            try std.testing.expectEqual(expected_from, range.from);
            try std.testing.expectEqual(expected_to, range.to);
        }
    }
}

test "RangeAggregate outward integer ranges round negative bounds in the correct direction" {
    inline for (.{ i8, i16, i32, i64 }) |CoordT| {
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 3,
            .level_count = 1,
            .value_size = 8,
        };
        const starts = [_]CoordT{ -8, -6, -1, -3, -1 };
        const ends = [_]CoordT{ -4, -3, 1, 0, 0 };
        const expected_starts = [_]CoordT{ -9, -6, -3, -3, -3 };
        const expected_ends = [_]CoordT{ -3, -3, 3, 0, 0 };
        for (starts, ends, expected_starts, expected_ends) |from, to, expected_from, expected_to| {
            const range = try range_aggregate.Geometry(CoordT).outwardRange(settings, from, to);
            try std.testing.expectEqual(expected_from, range.from);
            try std.testing.expectEqual(expected_to, range.to);
        }
    }
}

test "RangeAggregate outward integer ranges preserve empty bounds and reject reversed bounds" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 3,
            .level_count = 1,
            .value_size = 8,
        };
        for ([_]CoordT{ std.math.minInt(CoordT), 1, std.math.maxInt(CoordT) }) |point| {
            const empty = try Geometry.outwardRange(settings, point, point);
            try std.testing.expectEqual(point, empty.from);
            try std.testing.expectEqual(point, empty.to);
        }
        try std.testing.expectError(
            error.InvalidRange,
            Geometry.outwardRange(settings, std.math.maxInt(CoordT), std.math.minInt(CoordT)),
        );
    }
}

test "RangeAggregate outward integer ranges check overflow without clamping" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const minimum = std.math.minInt(CoordT);
        const maximum = std.math.maxInt(CoordT);
        const full = try Geometry.outwardRange(settings, minimum, maximum);
        try std.testing.expectEqual(minimum, full.from);
        try std.testing.expectEqual(maximum, full.to);

        settings.base_width = 2;
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.outwardRange(settings, maximum - 1, maximum),
        );
        if (@typeInfo(CoordT).int.signedness == .signed) {
            settings.base_width = 3;
            try std.testing.expectError(
                error.CoordinateOutOfRange,
                Geometry.outwardRange(settings, minimum, minimum + 1),
            );
        }

        settings.base_width = maximum;
        const wide = try Geometry.outwardRange(settings, 0, 1);
        try std.testing.expectEqual(@as(CoordT, 0), wide.from);
        try std.testing.expectEqual(maximum, wide.to);
    }
}

test "RangeAggregate outward integer ranges form a minimal idempotent cover" {
    const Geometry = range_aggregate.Geometry(i32);
    for ([_]i32{ 1, 3, 4, 10 }) |width| {
        const settings: range_aggregate.Settings(i32) = .{
            .base_width = width,
            .level_count = 1,
            .value_size = 8,
        };
        var from: i32 = -16;
        while (from <= 16) : (from += 1) {
            var to = from + 1;
            while (to <= 17) : (to += 1) {
                const range = try Geometry.outwardRange(settings, from, to);
                try std.testing.expect(range.from <= from and to <= range.to);
                try std.testing.expect(from - range.from < width);
                try std.testing.expect(range.to - to < width);
                const again = try Geometry.outwardRange(settings, range.from, range.to);
                try std.testing.expectEqualDeep(range, again);
                const exact = try Geometry.exactRange(settings, range.from, range.to);
                try std.testing.expectEqualDeep(range, exact);
            }
        }
    }
}

test "RangeAggregate outward integer ranges validate settings before rounding" {
    const Geometry = range_aggregate.Geometry(i32);
    var settings: range_aggregate.Settings(i32) = .{
        .base_width = 0,
        .level_count = 1,
        .value_size = 8,
    };
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.outwardRange(settings, 1, 5));
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.outwardRange(settings, 1, 1));
    settings.base_width = 1;
    settings.base = 1;
    try std.testing.expectError(error.InvalidBase, Geometry.outwardRange(settings, 1, 5));
    settings.base = 2;
    settings.level_count = 0;
    try std.testing.expectError(error.InvalidLevelCount, Geometry.outwardRange(settings, 1, 5));
    settings.level_count = 1;
    settings.value_size = 0;
    try std.testing.expectError(error.InvalidValueSize, Geometry.outwardRange(settings, 1, 5));
}

test "RangeAggregate center integer ranges include the lower center and exclude the upper center" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 4,
            .level_count = 1,
            .value_size = 8,
        };
        const starts = [_]CoordT{ 2, 3, 3, 0, 1, 6 };
        const ends = [_]CoordT{ 6, 6, 7, 4, 9, 7 };
        const expected_starts = [_]CoordT{ 0, 3, 4, 0, 0, 4 };
        const expected_ends = [_]CoordT{ 4, 3, 8, 4, 8, 8 };
        for (starts, ends, expected_starts, expected_ends) |from, to, expected_from, expected_to| {
            const range = try Geometry.centerRange(settings, from, to);
            try std.testing.expectEqual(expected_from, range.from);
            try std.testing.expectEqual(expected_to, range.to);
        }
    }
}

test "RangeAggregate center integer ranges retain fractional centers for odd widths" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 3,
            .level_count = 1,
            .value_size = 8,
        };
        const selected = try Geometry.centerRange(settings, 1, 2);
        try std.testing.expectEqual(@as(CoordT, 0), selected.from);
        try std.testing.expectEqual(@as(CoordT, 3), selected.to);
        const before = try Geometry.centerRange(settings, 0, 1);
        try std.testing.expectEqual(@as(CoordT, 0), before.from);
        try std.testing.expectEqual(before.from, before.to);
        const after = try Geometry.centerRange(settings, 2, 3);
        try std.testing.expectEqual(@as(CoordT, 2), after.from);
        try std.testing.expectEqual(after.from, after.to);
        if (@typeInfo(CoordT).int.signedness == .signed) {
            const negative = try Geometry.centerRange(settings, -2, -1);
            try std.testing.expectEqual(@as(CoordT, -3), negative.from);
            try std.testing.expectEqual(@as(CoordT, 0), negative.to);
            const around_zero = try Geometry.centerRange(settings, -1, 1);
            try std.testing.expectEqual(@as(CoordT, -1), around_zero.from);
            try std.testing.expectEqual(around_zero.from, around_zero.to);
        }
    }
}

test "RangeAggregate center integer ranges preserve empty bounds and reject reversed bounds" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 3,
            .level_count = 1,
            .value_size = 8,
        };
        for ([_]CoordT{ std.math.minInt(CoordT), 1, std.math.maxInt(CoordT) }) |point| {
            const empty = try Geometry.centerRange(settings, point, point);
            try std.testing.expectEqual(point, empty.from);
            try std.testing.expectEqual(point, empty.to);
        }
        try std.testing.expectError(
            error.InvalidRange,
            Geometry.centerRange(settings, std.math.maxInt(CoordT), std.math.minInt(CoordT)),
        );
    }
}

test "RangeAggregate center integer ranges handle extrema and reject selected bucket overflow" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const minimum = std.math.minInt(CoordT);
        const maximum = std.math.maxInt(CoordT);
        const full = try Geometry.centerRange(settings, minimum, maximum);
        try std.testing.expectEqual(minimum, full.from);
        try std.testing.expectEqual(maximum, full.to);

        settings.base_width = 2;
        const empty = try Geometry.centerRange(settings, maximum - 1, maximum);
        try std.testing.expectEqual(maximum - 1, empty.from);
        try std.testing.expectEqual(empty.from, empty.to);
        settings.base_width = 4;
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.centerRange(settings, maximum - 1, maximum),
        );
        if (@typeInfo(CoordT).int.signedness == .signed) {
            settings.base_width = 3;
            try std.testing.expectError(
                error.CoordinateOutOfRange,
                Geometry.centerRange(settings, minimum, minimum + 1),
            );
        }

        settings.base_width = maximum;
        const middle = @divFloor(maximum, 2);
        const wide = try Geometry.centerRange(settings, middle, middle + 1);
        try std.testing.expectEqual(@as(CoordT, 0), wide.from);
        try std.testing.expectEqual(maximum, wide.to);
    }
}

test "RangeAggregate center integer ranges match explicit bucket-center selection" {
    const Geometry = range_aggregate.Geometry(i32);
    for ([_]i32{ 1, 3, 4, 5, 10 }) |width| {
        const settings: range_aggregate.Settings(i32) = .{
            .base_width = width,
            .level_count = 1,
            .value_size = 8,
        };
        var from: i32 = -16;
        while (from <= 16) : (from += 1) {
            var to = from + 1;
            while (to <= 17) : (to += 1) {
                var expected_from: ?i32 = null;
                var expected_to: i32 = undefined;
                var bucket: i32 = -32;
                while (bucket <= 32) : (bucket += 1) {
                    const twice_center = (2 * bucket + 1) * width;
                    if (2 * from <= twice_center and twice_center < 2 * to) {
                        if (expected_from == null) {
                            expected_from = bucket * width;
                        }
                        expected_to = (bucket + 1) * width;
                    }
                }
                const range = try Geometry.centerRange(settings, from, to);
                try std.testing.expectEqual(expected_from orelse from, range.from);
                try std.testing.expectEqual(if (expected_from != null) expected_to else from, range.to);
                const again = try Geometry.centerRange(settings, range.from, range.to);
                try std.testing.expectEqualDeep(range, again);
                const exact = try Geometry.exactRange(settings, range.from, range.to);
                try std.testing.expectEqualDeep(range, exact);
            }
        }
    }
}

test "RangeAggregate center integer ranges validate settings before selection" {
    const Geometry = range_aggregate.Geometry(i32);
    var settings: range_aggregate.Settings(i32) = .{
        .base_width = 0,
        .level_count = 1,
        .value_size = 8,
    };
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.centerRange(settings, 1, 5));
    try std.testing.expectError(error.InvalidBaseWidth, Geometry.centerRange(settings, 1, 1));
    settings.base_width = 1;
    settings.base = 1;
    try std.testing.expectError(error.InvalidBase, Geometry.centerRange(settings, 1, 5));
    settings.base = 2;
    settings.level_count = 0;
    try std.testing.expectError(error.InvalidLevelCount, Geometry.centerRange(settings, 1, 5));
    settings.level_count = 1;
    settings.value_size = 0;
    try std.testing.expectError(error.InvalidValueSize, Geometry.centerRange(settings, 1, 5));
}

test "RangeAggregate alignRange defaults to center for every integer type" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 4,
            .level_count = 1,
            .value_size = 8,
        };
        const default = try Geometry.alignRange(settings, 1, 9, .{});
        try std.testing.expectEqual(@as(CoordT, 0), default.from);
        try std.testing.expectEqual(@as(CoordT, 8), default.to);
        const center = try Geometry.alignRange(settings, 1, 9, .{ .policy = .center });
        try std.testing.expectEqualDeep(default, center);
        const outward = try Geometry.alignRange(settings, 1, 9, .{ .policy = .outward });
        try std.testing.expectEqual(@as(CoordT, 0), outward.from);
        try std.testing.expectEqual(@as(CoordT, 12), outward.to);
        try std.testing.expectError(
            error.UnalignedRange,
            Geometry.alignRange(settings, 1, 9, .{ .policy = .exact }),
        );
    }
}

test "RangeAggregate alignRange dispatch matches each policy including empty and reversed ranges" {
    const Geometry = range_aggregate.Geometry(i32);
    const settings: range_aggregate.Settings(i32) = .{
        .base_width = 3,
        .level_count = 1,
        .value_size = 8,
    };
    const starts = [_]i32{ 3, 1, 5, 9, -7, -6, -1 };
    const ends = [_]i32{ 12, 9, 5, 1, -2, 3, 1 };
    for ([_]range_aggregate.RangePolicy{ .exact, .center, .outward }) |policy| {
        for (starts, ends) |from, to| {
            const expected = switch (policy) {
                .exact => Geometry.exactRange(settings, from, to),
                .center => Geometry.centerRange(settings, from, to),
                .outward => Geometry.outwardRange(settings, from, to),
            };
            const result = Geometry.alignRange(settings, from, to, .{ .policy = policy });
            if (expected) |range| {
                try std.testing.expectEqualDeep(range, try result);
            } else |err| {
                try std.testing.expectError(err, result);
            }
        }
    }
}

test "RangeAggregate alignRange propagates settings and coordinate errors" {
    const Geometry = range_aggregate.Geometry(i8);
    var settings: range_aggregate.Settings(i8) = .{
        .base_width = 0,
        .level_count = 1,
        .value_size = 8,
    };
    for ([_]range_aggregate.RangePolicy{ .exact, .center, .outward }) |policy| {
        try std.testing.expectError(
            error.InvalidBaseWidth,
            Geometry.alignRange(settings, 1, 1, .{ .policy = policy }),
        );
    }
    settings.base_width = 4;
    try std.testing.expectError(
        error.CoordinateOutOfRange,
        Geometry.alignRange(settings, 126, 127, .{}),
    );
    try std.testing.expectError(
        error.CoordinateOutOfRange,
        Geometry.alignRange(settings, 126, 127, .{ .policy = .outward }),
    );
    try std.testing.expectError(
        error.UnalignedRange,
        Geometry.alignRange(settings, 126, 127, .{ .policy = .exact }),
    );
}

test "RangeAggregate integer cover emits a canonical left-to-right B-adic partition" {
    const Geometry = range_aggregate.Geometry(i32);
    const settings: range_aggregate.Settings(i32) = .{
        .base_width = 1,
        .level_count = 4,
        .value_size = 8,
    };
    var output: [6]range_aggregate.LevelInfo(i32) = undefined;
    const cover = try Geometry.cover(settings, .{ .from = 1, .to = 15 }, 3, &output);
    const expected = [_]range_aggregate.LevelInfo(i32){
        .{ .level = 0, .from = 1, .to = 2 },
        .{ .level = 1, .from = 2, .to = 4 },
        .{ .level = 2, .from = 4, .to = 8 },
        .{ .level = 2, .from = 8, .to = 12 },
        .{ .level = 1, .from = 12, .to = 14 },
        .{ .level = 0, .from = 14, .to = 15 },
    };
    try std.testing.expectEqualSlices(range_aggregate.LevelInfo(i32), &expected, cover);
}

test "RangeAggregate integer cover respects base width and level limit" {
    const Geometry = range_aggregate.Geometry(i32);
    const settings: range_aggregate.Settings(i32) = .{
        .base = 3,
        .base_width = 2,
        .level_count = 3,
        .value_size = 8,
    };
    var output: [9]range_aggregate.LevelInfo(i32) = undefined;
    const cover = try Geometry.cover(settings, .{ .from = -6, .to = 12 }, 1, &output);
    const expected = [_]range_aggregate.LevelInfo(i32){
        .{ .level = 1, .from = -6, .to = 0 },
        .{ .level = 1, .from = 0, .to = 6 },
        .{ .level = 1, .from = 6, .to = 12 },
    };
    try std.testing.expectEqualSlices(range_aggregate.LevelInfo(i32), &expected, cover);
}

test "RangeAggregate cover preflights output and validates its inputs" {
    const Geometry = range_aggregate.Geometry(i32);
    var settings: range_aggregate.Settings(i32) = .{
        .base_width = 2,
        .level_count = 2,
        .value_size = 8,
    };
    var output = [_]range_aggregate.LevelInfo(i32){.{ .level = 9, .from = 9, .to = 9 }} ** 2;
    try std.testing.expectError(
        error.OutputTooSmall,
        Geometry.cover(settings, .{ .from = 2, .to = 8 }, 1, output[0..1]),
    );
    try std.testing.expectEqual(@as(u8, 9), output[0].level);
    const empty = try Geometry.cover(settings, .{ .from = 2, .to = 2 }, 1, &output);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(
        error.UnalignedRange,
        Geometry.cover(settings, .{ .from = 1, .to = 4 }, 1, &output),
    );
    try std.testing.expectError(
        error.InvalidLevel,
        Geometry.cover(settings, .{ .from = 0, .to = 4 }, 2, &output),
    );
    settings.value_size = 0;
    try std.testing.expectError(
        error.InvalidValueSize,
        Geometry.cover(settings, .{ .from = 0, .to = 4 }, 1, &output),
    );
}
