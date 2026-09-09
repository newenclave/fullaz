const std = @import("std");
const range_aggregate = @import("fullaz").range_aggregate;

test "RangeAggregate float boundaries use one canonical product" {
    inline for (.{ f32, f64 }) |CoordT| {
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 8,
        };
        for ([_]CoordT{ 0.25, 0.1, 0.3333 }) |width| {
            settings.base_width = width;
            var index: i128 = -100;
            while (index <= 100) : (index += 1) {
                // These small products are exact in f128, providing an
                // independent reference for the integer-based implementation.
                const exact = @as(f128, width) * @as(f128, @floatFromInt(index));
                const expected: CoordT = @floatCast(exact);
                const actual = try range_aggregate.Geometry(CoordT).boundary(settings, index);
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
}

test "RangeAggregate float boundaries do not round the index before multiplication" {
    inline for (.{ f32, f64 }) |CoordT| {
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 1.5,
            .level_count = 1,
            .value_size = 8,
        };
        const index = (@as(i128, 1) << precision) + 1;
        const expected_integer = (@as(i128, 3) << (precision - 1)) + 2;
        const actual = try range_aggregate.Geometry(CoordT).boundary(settings, index);
        try std.testing.expectEqual(expected_integer, @as(i128, @intFromFloat(actual)));
        const negative = try range_aggregate.Geometry(CoordT).boundary(settings, -index);
        try std.testing.expectEqual(-actual, negative);
    }
}

test "RangeAggregate float boundaries round halfway products to even" {
    inline for (.{ f32, f64 }) |CoordT| {
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const start = @as(i128, 1) << precision;
        for ([_]i128{ 1, 3 }, [_]i128{ 0, 4 }) |offset, rounded_offset| {
            const positive = try range_aggregate.Geometry(CoordT).boundary(settings, start + offset);
            const negative = try range_aggregate.Geometry(CoordT).boundary(settings, -start - offset);
            try std.testing.expectEqual(start + rounded_offset, @as(i128, @intFromFloat(positive)));
            try std.testing.expectEqual(-positive, negative);
        }
    }
}

test "RangeAggregate float boundaries preserve subnormal steps and canonical zero" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(CoordT));
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = @bitCast(@as(Bits, 1)),
            .level_count = 1,
            .value_size = 8,
        };
        for (1..9) |index| {
            const positive = try Geometry.boundary(settings, @intCast(index));
            const negative = try Geometry.boundary(settings, -@as(i128, @intCast(index)));
            try std.testing.expectEqual(@as(Bits, @intCast(index)), @as(Bits, @bitCast(positive)));
            try std.testing.expectEqual(-positive, negative);
        }
        const zero = try Geometry.boundary(settings, 0);
        try std.testing.expectEqual(@as(Bits, 0), @as(Bits, @bitCast(zero)));

        const exponent = 127 + std.math.floatExponentMin(CoordT) -
            std.math.floatFractionalBits(CoordT);
        const minimum = try Geometry.boundary(settings, std.math.minInt(i128));
        try std.testing.expectEqual(std.math.ldexp(@as(CoordT, -1), exponent), minimum);
    }
}

test "RangeAggregate float boundaries handle rounding carry and coordinate overflow" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const largest_index = try Geometry.boundary(settings, std.math.maxInt(i128));
        try std.testing.expectEqual(std.math.ldexp(@as(CoordT, 1), 127), largest_index);

        settings.base_width = std.math.floatMax(CoordT);
        try std.testing.expectEqual(settings.base_width, try Geometry.boundary(settings, 1));
        try std.testing.expectEqual(-settings.base_width, try Geometry.boundary(settings, -1));
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.boundary(settings, 2));
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.boundary(settings, -2));
    }
}

test "RangeAggregate float boundaries validate settings even at zero" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        for ([_]CoordT{ 0, -1, std.math.nan(CoordT), std.math.inf(CoordT) }) |width| {
            settings.base_width = width;
            try std.testing.expectError(error.InvalidBaseWidth, Geometry.boundary(settings, 0));
        }
        settings.base_width = 1;
        settings.value_size = 0;
        try std.testing.expectError(error.InvalidValueSize, Geometry.boundary(settings, 0));
    }
}

test "RangeAggregate float boundaries match exact products across exponent ranges" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(CoordT));
        const fraction_bits = std.math.floatFractionalBits(CoordT);
        const fraction_mask = (@as(Bits, 1) << fraction_bits) - 1;
        const exponent_limit = (@as(Bits, 1) << std.math.floatExponentBits(CoordT)) - 1;
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        var stored_exponent: Bits = 0;
        while (stored_exponent < exponent_limit) : (stored_exponent += 1) {
            for ([_]Bits{ 0, 1, fraction_mask }) |fraction| {
                const bits = (stored_exponent << fraction_bits) | fraction;
                if (bits == 0) {
                    continue;
                }
                settings.base_width = @bitCast(bits);
                for ([_]i128{ -17, -3, -1, 0, 1, 3, 17 }) |index| {
                    const exact = @as(f128, settings.base_width) *
                        @as(f128, @floatFromInt(index));
                    const expected: CoordT = @floatCast(exact);
                    const result = range_aggregate.Geometry(CoordT).boundary(settings, index);
                    if (std.math.isFinite(expected)) {
                        try std.testing.expectEqual(expected, try result);
                    } else {
                        try std.testing.expectError(error.CoordinateOutOfRange, result);
                    }
                }
            }
        }
    }
}

test "RangeAggregate float buckets contain signed coordinates on a quarter grid" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.25,
            .level_count = 5,
            .value_size = 8,
        };
        const coordinates = [_]CoordT{ -1.37, -0.25, -0.01, -0.0, 0.0, 0.21, 0.25, 1.37, 18.9 };
        const expected = [_]i128{ -6, -1, -1, 0, 0, 0, 1, 5, 75 };
        for (coordinates, expected) |coordinate, expected_index| {
            const index = try Geometry.bucketIndex(settings, coordinate);
            try std.testing.expectEqual(expected_index, index);
            const from = try Geometry.boundary(settings, index);
            const to = try Geometry.boundary(settings, index + 1);
            try std.testing.expect(from <= coordinate and coordinate < to);
        }
    }
}

test "RangeAggregate float buckets distinguish a canonical boundary from both neighbors" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        for ([_]CoordT{ 0.25, 0.1, 0.3333 }) |width| {
            settings.base_width = width;
            var index: i128 = -32;
            while (index <= 32) : (index += 1) {
                const at = try Geometry.boundary(settings, index);
                const before = std.math.nextAfter(CoordT, at, -std.math.inf(CoordT));
                const after = std.math.nextAfter(CoordT, at, std.math.inf(CoordT));
                try std.testing.expectEqual(index, try Geometry.bucketIndex(settings, at));
                try std.testing.expectEqual(index - 1, try Geometry.bucketIndex(settings, before));
                try std.testing.expectEqual(index, try Geometry.bucketIndex(settings, after));
            }
        }
    }

    const settings: range_aggregate.Settings(f64) = .{
        .base_width = 0.1,
        .level_count = 1,
        .value_size = 8,
    };
    const canonical = try range_aggregate.Geometry(f64).boundary(settings, 3);
    try std.testing.expect(canonical > @as(f64, 0.3));
    try std.testing.expectEqual(
        @as(i128, 2),
        try range_aggregate.Geometry(f64).bucketIndex(settings, 0.3),
    );
    try std.testing.expectEqual(
        @as(i128, 3),
        try range_aggregate.Geometry(f64).bucketIndex(settings, canonical),
    );
}

test "RangeAggregate float buckets reject lost resolution and nonfinite coordinates" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        const collapsed = std.math.ldexp(@as(CoordT, 1), precision);
        for ([_]CoordT{
            collapsed,
            -2 * collapsed,
            std.math.nan(CoordT),
            std.math.inf(CoordT),
            -std.math.inf(CoordT),
            std.math.floatMax(CoordT),
            -std.math.floatMax(CoordT),
        }) |coordinate| {
            try std.testing.expectError(
                error.CoordinateOutOfRange,
                Geometry.bucketIndex(settings, coordinate),
            );
        }
        const last_distinct = collapsed - 1;
        try std.testing.expectEqual(
            @as(i128, @intFromFloat(last_distinct)),
            try Geometry.bucketIndex(settings, last_distinct),
        );
    }
}

test "RangeAggregate float buckets preserve subnormal coordinates and reject index overflow" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(CoordT));
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .base_width = std.math.floatTrueMin(CoordT),
            .level_count = 1,
            .value_size = 8,
        };
        for (1..9) |index| {
            const coordinate: CoordT = @bitCast(@as(Bits, @intCast(index)));
            try std.testing.expectEqual(
                @as(i128, @intCast(index)),
                try Geometry.bucketIndex(settings, coordinate),
            );
            try std.testing.expectEqual(
                -@as(i128, @intCast(index)),
                try Geometry.bucketIndex(settings, -coordinate),
            );
        }
        try std.testing.expectEqual(@as(i128, 0), try Geometry.bucketIndex(settings, -0.0));
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.bucketIndex(settings, 1));
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.bucketIndex(settings, -1));

        settings.base_width = 1;
        try std.testing.expectEqual(
            @as(i128, 0),
            try Geometry.bucketIndex(settings, std.math.floatTrueMin(CoordT)),
        );
        try std.testing.expectEqual(
            @as(i128, -1),
            try Geometry.bucketIndex(settings, -std.math.floatTrueMin(CoordT)),
        );
    }
}

test "RangeAggregate float buckets allow finite edge intervals without requiring their neighbors" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = std.math.floatMax(CoordT),
            .level_count = 1,
            .value_size = 8,
        };
        try std.testing.expectEqual(@as(i128, 0), try Geometry.bucketIndex(settings, 0));
        try std.testing.expectEqual(
            @as(i128, -1),
            try Geometry.bucketIndex(settings, -settings.base_width),
        );
        const before_end = std.math.nextAfter(CoordT, settings.base_width, 0);
        try std.testing.expectEqual(@as(i128, 0), try Geometry.bucketIndex(settings, before_end));
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.bucketIndex(settings, settings.base_width),
        );
    }
}

test "RangeAggregate exact float ranges require canonical boundaries without tolerance" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.1,
            .level_count = 1,
            .value_size = 8,
        };
        const from = try Geometry.boundary(settings, -7);
        const to = try Geometry.boundary(settings, 11);
        const exact = try Geometry.exactRange(settings, from, to);
        try std.testing.expectEqual(from, exact.from);
        try std.testing.expectEqual(to, exact.to);
        try std.testing.expectError(
            error.UnalignedRange,
            Geometry.exactRange(settings, from, std.math.nextAfter(CoordT, to, 0)),
        );
    }

    const settings: range_aggregate.Settings(f64) = .{
        .base_width = 0.1,
        .level_count = 1,
        .value_size = 8,
    };
    const canonical = try range_aggregate.Geometry(f64).boundary(settings, 3);
    try std.testing.expect(canonical > @as(f64, 0.3));
    try std.testing.expectError(
        error.UnalignedRange,
        range_aggregate.Geometry(f64).exactRange(settings, 0.3, canonical + 1),
    );
}

test "RangeAggregate exact float ranges accept finite boundary edges" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = std.math.floatMax(CoordT),
            .level_count = 1,
            .value_size = 8,
        };
        const range = try Geometry.exactRange(settings, 0, settings.base_width);
        try std.testing.expectEqual(@as(CoordT, 0), range.from);
        try std.testing.expectEqual(settings.base_width, range.to);
        const empty = try Geometry.exactRange(settings, settings.base_width, settings.base_width);
        try std.testing.expectEqual(settings.base_width, empty.from);
        try std.testing.expectEqual(settings.base_width, empty.to);
    }
}

test "RangeAggregate exact float ranges reject collapsed boundaries and invalid bounds" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        const collapsed = std.math.ldexp(@as(CoordT, 1), precision);
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.exactRange(settings, collapsed, collapsed * 2),
        );
        try std.testing.expectError(error.InvalidRange, Geometry.exactRange(settings, 1, 0));
        for ([_]CoordT{ std.math.nan(CoordT), std.math.inf(CoordT), -std.math.inf(CoordT) }) |value| {
            try std.testing.expectError(error.CoordinateOutOfRange, Geometry.exactRange(settings, value, value));
        }
    }
}

test "RangeAggregate outward float ranges enclose signed canonical buckets" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.25,
            .level_count = 1,
            .value_size = 8,
        };
        const range = try Geometry.outwardRange(settings, -1.37, 1.37);
        try std.testing.expectEqual(@as(CoordT, -1.5), range.from);
        try std.testing.expectEqual(@as(CoordT, 1.5), range.to);
        const lower = try Geometry.outwardRange(settings, -0.01, 0.21);
        try std.testing.expectEqual(@as(CoordT, -0.25), lower.from);
        try std.testing.expectEqual(@as(CoordT, 0.25), lower.to);
    }
}

test "RangeAggregate outward float ranges exclude an exact upper boundary" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.1,
            .level_count = 1,
            .value_size = 8,
        };
        const upper = try Geometry.boundary(settings, 3);
        const range = try Geometry.outwardRange(settings, 0.01, upper);
        try std.testing.expectEqual(@as(CoordT, 0), range.from);
        try std.testing.expectEqual(upper, range.to);
        const before_upper = std.math.nextAfter(CoordT, upper, 0);
        const expanded = try Geometry.outwardRange(settings, 0.01, before_upper);
        try std.testing.expectEqual(@as(CoordT, 0), expanded.from);
        try std.testing.expectEqual(upper, expanded.to);
    }
}

test "RangeAggregate outward float ranges accept a finite upper boundary edge" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = std.math.floatMax(CoordT),
            .level_count = 1,
            .value_size = 8,
        };
        const range = try Geometry.outwardRange(settings, 0, settings.base_width);
        try std.testing.expectEqual(@as(CoordT, 0), range.from);
        try std.testing.expectEqual(settings.base_width, range.to);
    }
}

test "RangeAggregate outward float ranges preserve empty bounds and reject invalid coordinates" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const empty = try Geometry.outwardRange(settings, -0.0, -0.0);
        try std.testing.expectEqual(@as(CoordT, -0.0), empty.from);
        try std.testing.expectEqual(@as(CoordT, -0.0), empty.to);
        try std.testing.expectError(error.InvalidRange, Geometry.outwardRange(settings, 1, 0));
        for ([_]CoordT{ std.math.nan(CoordT), std.math.inf(CoordT), -std.math.inf(CoordT) }) |value| {
            try std.testing.expectError(error.CoordinateOutOfRange, Geometry.outwardRange(settings, value, value));
        }
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        const collapsed = std.math.ldexp(@as(CoordT, 1), precision);
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.outwardRange(settings, collapsed, collapsed * 2),
        );
    }
}

test "RangeAggregate center float ranges select canonical bucket midpoints" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.25,
            .level_count = 1,
            .value_size = 8,
        };
        const selected = try Geometry.centerRange(settings, -0.13, 0.13);
        try std.testing.expectEqual(@as(CoordT, -0.25), selected.from);
        try std.testing.expectEqual(@as(CoordT, 0.25), selected.to);
        const none = try Geometry.centerRange(settings, -0.12, 0.12);
        try std.testing.expectEqual(@as(CoordT, -0.12), none.from);
        try std.testing.expectEqual(none.from, none.to);
        const upper_excluded = try Geometry.centerRange(settings, 0.0, 0.125);
        try std.testing.expectEqual(@as(CoordT, 0.0), upper_excluded.from);
        try std.testing.expectEqual(upper_excluded.from, upper_excluded.to);
    }
}

test "RangeAggregate center float ranges use canonical boundaries and preserve finite edges" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.1,
            .level_count = 1,
            .value_size = 8,
        };
        const boundary = try Geometry.boundary(settings, 3);
        const canonical = try Geometry.centerRange(settings, 0.2, boundary);
        try std.testing.expectEqual(@as(CoordT, 0.2), canonical.from);
        try std.testing.expectEqual(boundary, canonical.to);

        const edge_settings: range_aggregate.Settings(CoordT) = .{
            .base_width = std.math.floatMax(CoordT),
            .level_count = 1,
            .value_size = 8,
        };
        const edge = try Geometry.centerRange(edge_settings, 0, edge_settings.base_width);
        try std.testing.expectEqual(@as(CoordT, 0), edge.from);
        try std.testing.expectEqual(edge_settings.base_width, edge.to);
    }
}

test "RangeAggregate center float ranges reject collapsed and invalid coordinates" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        const collapsed = std.math.ldexp(@as(CoordT, 1), precision);
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.centerRange(settings, collapsed, collapsed * 2),
        );
        try std.testing.expectError(error.InvalidRange, Geometry.centerRange(settings, 1, 0));
        for ([_]CoordT{ std.math.nan(CoordT), std.math.inf(CoordT), -std.math.inf(CoordT) }) |value| {
            try std.testing.expectError(error.CoordinateOutOfRange, Geometry.centerRange(settings, value, value));
        }
    }
}

test "RangeAggregate alignRange dispatches every float policy and defaults to center" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.25,
            .level_count = 1,
            .value_size = 8,
        };
        const from: CoordT = 0.12;
        const to: CoordT = 0.38;
        const default = try Geometry.alignRange(settings, from, to, .{});
        const center = try Geometry.centerRange(settings, from, to);
        try std.testing.expectEqualDeep(center, default);
        const outward = try Geometry.alignRange(settings, from, to, .{ .policy = .outward });
        try std.testing.expectEqualDeep(try Geometry.outwardRange(settings, from, to), outward);

        const exact_from = try Geometry.boundary(settings, 0);
        const exact_to = try Geometry.boundary(settings, 2);
        const exact = try Geometry.alignRange(
            settings,
            exact_from,
            exact_to,
            .{ .policy = .exact },
        );
        try std.testing.expectEqualDeep(
            try Geometry.exactRange(settings, exact_from, exact_to),
            exact,
        );
        try std.testing.expectError(
            error.UnalignedRange,
            Geometry.alignRange(settings, from, to, .{ .policy = .exact }),
        );
    }
}

test "RangeAggregate alignRange propagates float coordinate errors" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        for ([_]range_aggregate.RangePolicy{ .exact, .center, .outward }) |policy| {
            try std.testing.expectError(
                error.CoordinateOutOfRange,
                Geometry.alignRange(settings, std.math.nan(CoordT), 1, .{ .policy = policy }),
            );
        }
    }
}

test "RangeAggregate float cover uses canonical boundary indices" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.25,
            .level_count = 4,
            .value_size = 8,
        };
        const from = try Geometry.boundary(settings, 1);
        const to = try Geometry.boundary(settings, 15);
        var output: [6]range_aggregate.LevelInfo(CoordT) = undefined;
        const cover = try Geometry.cover(settings, .{ .from = from, .to = to }, 3, &output);
        const levels = [_]u8{ 0, 1, 2, 2, 1, 0 };
        const starts = [_]i128{ 1, 2, 4, 8, 12, 14 };
        const ends = [_]i128{ 2, 4, 8, 12, 14, 15 };
        try std.testing.expectEqual(levels.len, cover.len);
        for (cover, levels, starts, ends) |info, level, start, end| {
            try std.testing.expectEqual(level, info.level);
            try std.testing.expectEqual(try Geometry.boundary(settings, start), info.from);
            try std.testing.expectEqual(try Geometry.boundary(settings, end), info.to);
        }
    }
}

test "RangeAggregate float buckets validate settings before division" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 1,
            .value_size = 8,
        };
        settings.base_width = 0;
        try std.testing.expectError(error.InvalidBaseWidth, Geometry.bucketIndex(settings, 0));
        settings.base_width = 1;
        settings.base = 1;
        try std.testing.expectError(error.InvalidBase, Geometry.bucketIndex(settings, 0));
        settings.base = 2;
        settings.level_count = 0;
        try std.testing.expectError(error.InvalidLevelCount, Geometry.bucketIndex(settings, 0));
        settings.level_count = 1;
        settings.value_size = 0;
        try std.testing.expectError(error.InvalidValueSize, Geometry.bucketIndex(settings, 0));
    }
}

test "RangeAggregate float intervals follow integer ancestry on a quarter grid" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        const settings: range_aggregate.Settings(CoordT) = .{
            .base_width = 0.25,
            .level_count = 5,
            .value_size = 8,
        };
        const starts = [_]CoordT{ 2.25, 2, 2, 2, 0 };
        const ends = [_]CoordT{ 2.5, 2.5, 3, 4, 4 };
        const negative_starts = [_]CoordT{ -2.5, -2.5, -3, -4, -4 };
        const negative_ends = [_]CoordT{ -2.25, -2, -2, -2, 0 };
        for (0..settings.level_count) |level| {
            const positive = try Geometry.interval(settings, 2.3, @intCast(level));
            try std.testing.expectEqual(@as(u8, @intCast(level)), positive.level);
            try std.testing.expectEqual(starts[level], positive.from);
            try std.testing.expectEqual(ends[level], positive.to);
            const negative = try Geometry.interval(settings, -2.3, @intCast(level));
            try std.testing.expectEqual(negative_starts[level], negative.from);
            try std.testing.expectEqual(negative_ends[level], negative.to);
        }
    }
}

test "RangeAggregate float parent boundaries do not accumulate decimal rounding" {
    const Geometry = range_aggregate.Geometry(f64);
    const settings: range_aggregate.Settings(f64) = .{
        .base = 3,
        .base_width = 0.1,
        .level_count = 3,
        .value_size = 8,
    };
    const from = try Geometry.boundary(settings, 9);
    const to = try Geometry.boundary(settings, 18);
    const info = try Geometry.interval(settings, from, 2);
    try std.testing.expectEqual(@as(f64, 0.9), info.from);
    try std.testing.expectEqual(from, info.from);
    try std.testing.expectEqual(to, info.to);

    const before = std.math.nextAfter(f64, from, -std.math.inf(f64));
    const previous = try Geometry.interval(settings, before, 2);
    try std.testing.expectEqual(@as(f64, 0), previous.from);
    try std.testing.expectEqual(from, previous.to);
}

test "RangeAggregate float intervals remain nested across bases and decimal steps" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        for ([_]u32{ 2, 3, 10 }) |base| {
            for ([_]CoordT{ 0.25, 0.1, 0.3333 }) |base_width| {
                const settings: range_aggregate.Settings(CoordT) = .{
                    .base = base,
                    .base_width = base_width,
                    .level_count = 5,
                    .value_size = 8,
                };
                var index: i128 = -16;
                while (index <= 16) : (index += 1) {
                    const at = try Geometry.boundary(settings, index);
                    const before = std.math.nextAfter(CoordT, at, -std.math.inf(CoordT));
                    const after = std.math.nextAfter(CoordT, at, std.math.inf(CoordT));
                    for ([_]CoordT{ before, at, after }) |coordinate| {
                        var child = try Geometry.interval(settings, coordinate, 0);
                        for (1..settings.level_count) |level| {
                            const parent = try Geometry.interval(settings, coordinate, @intCast(level));
                            try std.testing.expect(parent.from <= coordinate and coordinate < parent.to);
                            try std.testing.expect(parent.from <= child.from and child.to <= parent.to);
                            child = parent;
                        }
                    }
                }
            }
        }
    }
}

test "RangeAggregate float intervals reject invalid levels and collapsed minimal buckets" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 8,
        };
        try std.testing.expectError(error.InvalidLevel, Geometry.interval(settings, 0, 5));
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        const collapsed = std.math.ldexp(@as(CoordT, 1), precision);
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.interval(settings, collapsed, 4),
        );
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.interval(settings, std.math.nan(CoordT), 1),
        );
        settings.base = 1;
        try std.testing.expectError(error.InvalidBase, Geometry.interval(settings, 0, 0));
    }
}

test "RangeAggregate float intervals check parent endpoint and index span overflow" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .base_width = std.math.floatMax(CoordT) / 2,
            .level_count = 3,
            .value_size = 8,
        };
        _ = try Geometry.interval(settings, 0, 0);
        const parent = try Geometry.interval(settings, 0, 1);
        try std.testing.expectEqual(std.math.floatMax(CoordT), parent.to);
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.interval(settings, 0, 2));

        const negative = try Geometry.interval(settings, -settings.base_width, 1);
        try std.testing.expectEqual(-std.math.floatMax(CoordT), negative.from);
        try std.testing.expectEqual(@as(CoordT, 0), negative.to);
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.interval(settings, -settings.base_width, 2),
        );

        settings.base_width = std.math.floatTrueMin(CoordT);
        settings.level_count = 128;
        _ = try Geometry.interval(settings, 0, 126);
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.interval(settings, 0, 127));
    }
}

test "RangeAggregate float coordinate validation accepts signed and canonical coordinates" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        for ([_]u32{ 2, 3, 10 }) |base| {
            for ([_]CoordT{ 0.25, 0.1, 0.3333, std.math.floatTrueMin(CoordT) }) |width| {
                const settings: range_aggregate.Settings(CoordT) = .{
                    .base = base,
                    .base_width = width,
                    .level_count = 5,
                    .value_size = 8,
                };
                for ([_]i128{ -9, 0, 9 }) |index| {
                    const at = try Geometry.boundary(settings, index);
                    try Geometry.validateCoordinate(settings, at);
                    try Geometry.validateCoordinate(
                        settings,
                        std.math.nextAfter(CoordT, at, -std.math.inf(CoordT)),
                    );
                    try Geometry.validateCoordinate(
                        settings,
                        std.math.nextAfter(CoordT, at, std.math.inf(CoordT)),
                    );
                }
                try Geometry.validateCoordinate(settings, -0.0);
            }
        }
    }
}

test "RangeAggregate float coordinate validation catches highest-level overflow" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .base_width = std.math.floatMax(CoordT) / 2,
            .level_count = 2,
            .value_size = 8,
        };
        try Geometry.validateCoordinate(settings, 0);
        try Geometry.validateCoordinate(settings, -settings.base_width);
        settings.level_count = 3;
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.validateCoordinate(settings, 0));
        try std.testing.expectError(
            error.CoordinateOutOfRange,
            Geometry.validateCoordinate(settings, -settings.base_width),
        );

        settings.base_width = std.math.floatTrueMin(CoordT);
        settings.level_count = 127;
        try Geometry.validateCoordinate(settings, 0);
        settings.level_count = 128;
        try std.testing.expectError(error.CoordinateOutOfRange, Geometry.validateCoordinate(settings, 0));
    }
}

test "RangeAggregate float coordinate validation rejects invalid input before insertion" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        var settings: range_aggregate.Settings(CoordT) = .{
            .level_count = 5,
            .value_size = 8,
        };
        const precision = std.math.floatFractionalBits(CoordT) + 1;
        for ([_]CoordT{
            std.math.ldexp(@as(CoordT, 1), precision),
            std.math.nan(CoordT),
            std.math.inf(CoordT),
            -std.math.inf(CoordT),
        }) |coordinate| {
            try std.testing.expectError(
                error.CoordinateOutOfRange,
                Geometry.validateCoordinate(settings, coordinate),
            );
        }
        settings.level_count = 0;
        try std.testing.expectError(error.InvalidLevelCount, Geometry.validateCoordinate(settings, 0));
        settings.level_count = 1;
        settings.base = std.math.maxInt(u32);
        try Geometry.validateCoordinate(settings, 0);
        settings.base_width = 0;
        try std.testing.expectError(error.InvalidBaseWidth, Geometry.validateCoordinate(settings, 0));
    }
}

test "RangeAggregate float coordinate validation matches explicit per-level checks" {
    inline for (.{ f32, f64 }) |CoordT| {
        const Geometry = range_aggregate.Geometry(CoordT);
        for ([_]u32{ 2, 3, 10 }) |base| {
            for ([_]CoordT{
                0.1,
                std.math.floatTrueMin(CoordT),
                std.math.floatMax(CoordT) / 4,
            }) |width| {
                for ([_]u8{ 1, 5, 128, 255 }) |level_count| {
                    const settings: range_aggregate.Settings(CoordT) = .{
                        .base = base,
                        .base_width = width,
                        .level_count = level_count,
                        .value_size = 8,
                    };
                    for ([_]CoordT{
                        -std.math.floatMax(CoordT),
                        -1,
                        -std.math.floatTrueMin(CoordT),
                        0,
                        std.math.floatTrueMin(CoordT),
                        1,
                        std.math.floatMax(CoordT),
                    }) |coordinate| {
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
