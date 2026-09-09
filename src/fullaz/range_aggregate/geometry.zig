const std = @import("std");
const range_aggregate = @import("range_aggregate.zig");

/// Stateless interval calculations over an integer or canonical float grid.
pub fn Geometry(comptime CoordT: type) type {
    const SettingsT = range_aggregate.Settings(CoordT);
    const Info = range_aggregate.LevelInfo(CoordT);
    const QueryRange = range_aggregate.Range(CoordT);

    return struct {
        pub const Error = SettingsT.Error || error{
            InvalidLevel,
            CoordinateOutOfRange,
            InvalidRange,
            UnalignedRange,
            OutputTooSmall,
        };

        pub fn alignRange(
            settings: SettingsT,
            from: CoordT,
            to: CoordT,
            options: range_aggregate.QueryOptions,
        ) Error!QueryRange {
            return switch (options.policy) {
                .exact => exactRange(settings, from, to),
                .center => centerRange(settings, from, to),
                .outward => outwardRange(settings, from, to),
            };
        }

        pub fn cover(
            settings: SettingsT,
            range: QueryRange,
            max_level: u8,
            output: []Info,
        ) Error![]Info {
            try settings.validate();
            if (max_level >= settings.level_count) {
                return error.InvalidLevel;
            }
            _ = try exactRange(settings, range.from, range.to);
            if (range.from == range.to) {
                return output[0..0];
            }

            const first: i128 = if (@typeInfo(CoordT) == .float)
                try canonicalBoundaryIndex(settings, range.from)
            else
                @divExact(@as(i128, range.from), @as(i128, settings.base_width));
            const end: i128 = if (@typeInfo(CoordT) == .float)
                try canonicalBoundaryIndex(settings, range.to)
            else
                @divExact(@as(i128, range.to), @as(i128, settings.base_width));
            const entry_count = try coverEntryCount(settings, first, end, max_level);
            if (output.len < entry_count) {
                return error.OutputTooSmall;
            }

            var index = first;
            var output_index: usize = 0;
            while (index < end) {
                const level = try coverLevel(settings, index, end, max_level);
                const span = try coverSpan(settings, level);
                const next_index = std.math.add(i128, index, span) catch
                    return error.CoordinateOutOfRange;
                output[output_index] = .{
                    .level = level,
                    .from = if (@typeInfo(CoordT) == .float)
                        try boundary(settings, index)
                    else
                        std.math.cast(
                            CoordT,
                            std.math.mul(i128, index, @as(i128, settings.base_width)) catch
                                return error.CoordinateOutOfRange,
                        ) orelse return error.CoordinateOutOfRange,
                    .to = if (@typeInfo(CoordT) == .float)
                        try boundary(settings, next_index)
                    else
                        std.math.cast(
                            CoordT,
                            std.math.mul(i128, next_index, @as(i128, settings.base_width)) catch
                                return error.CoordinateOutOfRange,
                        ) orelse return error.CoordinateOutOfRange,
                };
                index = next_index;
                output_index += 1;
            }
            return output[0..output_index];
        }

        fn coverEntryCount(settings: SettingsT, first: i128, end: i128, max_level: u8) Error!usize {
            var index = first;
            var count: usize = 0;
            while (index < end) {
                const level = try coverLevel(settings, index, end, max_level);
                const span = try coverSpan(settings, level);
                index = std.math.add(i128, index, span) catch return error.CoordinateOutOfRange;
                count = std.math.add(usize, count, 1) catch return error.CoordinateOutOfRange;
            }
            return count;
        }

        fn coverLevel(settings: SettingsT, index: i128, end: i128, max_level: u8) Error!u8 {
            const remaining = std.math.sub(i128, end, index) catch return error.CoordinateOutOfRange;
            var level = max_level;
            while (true) {
                const span = try coverSpan(settings, level);
                if (@mod(index, span) == 0 and span <= remaining) {
                    return level;
                }
                if (level == 0) {
                    return 0;
                }
                level -= 1;
            }
        }

        fn coverSpan(settings: SettingsT, level: u8) Error!i128 {
            var span: i128 = 1;
            for (0..level) |_| {
                span = std.math.mul(i128, span, settings.base) catch
                    return error.CoordinateOutOfRange;
            }
            return span;
        }

        pub fn exactRange(settings: SettingsT, from: CoordT, to: CoordT) Error!QueryRange {
            try settings.validate();
            if (@typeInfo(CoordT) == .float) {
                @setFloatMode(.strict);
                if (!std.math.isFinite(from) or !std.math.isFinite(to)) {
                    return error.CoordinateOutOfRange;
                }
            }
            if (from > to) {
                return error.InvalidRange;
            }
            if (from == to) {
                return .{ .from = from, .to = to };
            }
            if (@typeInfo(CoordT) == .int) {
                if (@mod(from, settings.base_width) != 0 or @mod(to, settings.base_width) != 0) {
                    return error.UnalignedRange;
                }
            } else {
                const from_index = try canonicalBoundaryIndex(settings, from);
                const to_index = try canonicalBoundaryIndex(settings, to);
                const next_from = std.math.add(i128, from_index, 1) catch
                    return error.CoordinateOutOfRange;
                const previous_to = std.math.sub(i128, to_index, 1) catch
                    return error.CoordinateOutOfRange;
                if (!(from < try boundary(settings, next_from)) or
                    !(try boundary(settings, previous_to) < to))
                {
                    return error.CoordinateOutOfRange;
                }
            }
            return .{ .from = from, .to = to };
        }

        pub fn outwardRange(settings: SettingsT, from: CoordT, to: CoordT) Error!QueryRange {
            try settings.validate();
            if (@typeInfo(CoordT) == .float) {
                @setFloatMode(.strict);
                if (!std.math.isFinite(from) or !std.math.isFinite(to)) {
                    return error.CoordinateOutOfRange;
                }
            }
            if (from > to) {
                return error.InvalidRange;
            }
            if (from == to) {
                return .{ .from = from, .to = to };
            }

            if (@typeInfo(CoordT) == .float) {
                const from_index = try bucketIndex(settings, from);
                const to_index = canonicalBoundaryIndex(settings, to) catch |err| switch (err) {
                    error.UnalignedRange => std.math.add(i128, try bucketIndex(settings, to), 1) catch
                        return error.CoordinateOutOfRange,
                    else => return err,
                };
                const aligned_from = try boundary(settings, from_index);
                const aligned_to = try boundary(settings, to_index);
                if (!(aligned_from < aligned_to)) {
                    return error.CoordinateOutOfRange;
                }
                return .{ .from = aligned_from, .to = aligned_to };
            }

            // Coordinates and step use at most 64 bits. Widen before rounding
            // so both signed floor alignment and unsigned upper overflow are safe.
            const width: i128 = settings.base_width;
            const start: i128 = from;
            const end: i128 = to;
            const aligned_from = start - @mod(start, width);
            const remainder = @mod(end, width);
            const aligned_to = if (remainder == 0) end else end + (width - remainder);
            return .{
                .from = std.math.cast(CoordT, aligned_from) orelse return error.CoordinateOutOfRange,
                .to = std.math.cast(CoordT, aligned_to) orelse return error.CoordinateOutOfRange,
            };
        }

        pub fn centerRange(settings: SettingsT, from: CoordT, to: CoordT) Error!QueryRange {
            try settings.validate();
            if (@typeInfo(CoordT) == .float) {
                @setFloatMode(.strict);
                if (!std.math.isFinite(from) or !std.math.isFinite(to)) {
                    return error.CoordinateOutOfRange;
                }
            }
            if (from > to) {
                return error.InvalidRange;
            }
            if (from == to) {
                return .{ .from = from, .to = to };
            }

            if (@typeInfo(CoordT) == .float) {
                const first = try firstCenterIndex(settings, from);
                const end_exclusive = try firstCenterIndex(settings, to);
                if (first >= end_exclusive) {
                    return .{ .from = from, .to = from };
                }
                _ = try bucketCenter(settings, first);
                _ = try bucketCenter(
                    settings,
                    std.math.sub(i128, end_exclusive, 1) catch return error.CoordinateOutOfRange,
                );
                return .{
                    .from = try boundary(settings, first),
                    .to = try boundary(settings, end_exclusive),
                };
            }

            // Centers are (2*k + 1)*width/2. The selected index range is
            // [ceil((2*from - width)/(2*width)), ceil((2*to - width)/(2*width))).
            // Widen before doubling; do not truncate width/2 for odd widths.
            const width: i128 = settings.base_width;
            const start: i128 = from;
            const end: i128 = to;
            const first = -@divFloor(width - 2 * start, 2 * width);
            const end_exclusive = -@divFloor(width - 2 * end, 2 * width);
            if (first == end_exclusive) {
                return .{ .from = from, .to = from };
            }
            return .{
                .from = std.math.cast(CoordT, first * width) orelse return error.CoordinateOutOfRange,
                .to = std.math.cast(CoordT, end_exclusive * width) orelse return error.CoordinateOutOfRange,
            };
        }

        pub fn boundary(settings: SettingsT, index: i128) Error!CoordT {
            if (@typeInfo(CoordT) != .float) {
                @compileError("RangeAggregate boundary conversion requires f32 or f64");
            }
            @setFloatMode(.strict);
            try settings.validate();
            if (index == 0) {
                return 0;
            }

            const Bits = std.meta.Int(.unsigned, @bitSizeOf(CoordT));
            const fraction_bits = std.math.floatFractionalBits(CoordT);
            const precision = fraction_bits + 1;
            const exponent_bias = std.math.floatExponentMax(CoordT);
            const bits: Bits = @bitCast(settings.base_width);
            const stored_exponent = bits >> fraction_bits;
            var significand: u64 = bits & ((@as(Bits, 1) << fraction_bits) - 1);
            var exponent: i32 = 1 - exponent_bias - fraction_bits;
            if (stored_exponent != 0) {
                significand |= @as(u64, 1) << fraction_bits;
                exponent = @as(i32, @intCast(stored_exponent)) - exponent_bias - fraction_bits;
            }

            const product = @as(u256, @abs(index)) * significand;
            const bit_count = 256 - @clz(product);
            const shift: u8 = @intCast(if (bit_count > precision) bit_count - precision else 0);
            var rounded = product >> shift;
            if (shift != 0) {
                const remainder = product & ((@as(u256, 1) << shift) - 1);
                const halfway = @as(u256, 1) << (shift - 1);
                if (remainder > halfway or (remainder == halfway and rounded & 1 != 0)) {
                    rounded += 1;
                }
            }

            const magnitude: CoordT = @floatFromInt(@as(u64, @intCast(rounded)));
            const coordinate = std.math.ldexp(magnitude, exponent + shift);
            if (!std.math.isFinite(coordinate)) {
                return error.CoordinateOutOfRange;
            }
            return if (index < 0) -coordinate else coordinate;
        }

        fn canonicalBoundaryIndex(settings: SettingsT, coordinate: CoordT) Error!i128 {
            const nearest = @round(@as(f128, coordinate) / @as(f128, settings.base_width));
            if (nearest < -0x1p127) {
                return error.CoordinateOutOfRange;
            }
            const index: i128 = if (nearest >= 0x1p127)
                std.math.maxInt(i128)
            else
                @intFromFloat(nearest);
            if (try boundary(settings, index) != coordinate) {
                return error.UnalignedRange;
            }
            return index;
        }

        fn bucketCenter(settings: SettingsT, index: i128) Error!f128 {
            const next_index = std.math.add(i128, index, 1) catch
                return error.CoordinateOutOfRange;
            const from = try boundary(settings, index);
            const to = try boundary(settings, next_index);
            if (!(from < to)) {
                return error.CoordinateOutOfRange;
            }
            return (@as(f128, from) + @as(f128, to)) / 2;
        }

        fn firstCenterIndex(settings: SettingsT, coordinate: CoordT) Error!i128 {
            const boundary_index = canonicalBoundaryIndex(
                settings,
                coordinate,
            ) catch |err| switch (err) {
                error.UnalignedRange => null,
                else => return err,
            };
            if (boundary_index) |index| {
                return index;
            }
            const index = try bucketIndex(settings, coordinate);
            if (try bucketCenter(settings, index) >= @as(f128, coordinate)) {
                return index;
            }
            return std.math.add(i128, index, 1) catch error.CoordinateOutOfRange;
        }

        pub fn bucketIndex(settings: SettingsT, coordinate: CoordT) Error!i128 {
            if (@typeInfo(CoordT) != .float) {
                @compileError("RangeAggregate bucket lookup currently requires f32 or f64");
            }
            @setFloatMode(.strict);
            try settings.validate();
            if (!std.math.isFinite(coordinate)) {
                return error.CoordinateOutOfRange;
            }

            const nearest = @round(@as(f128, coordinate) / @as(f128, settings.base_width));
            if (nearest < -0x1p127 or nearest >= 0x1p127) {
                return error.CoordinateOutOfRange;
            }

            var index: i128 = @intFromFloat(nearest);
            const anchor = try boundary(settings, index);
            var from: CoordT = anchor;
            var to: CoordT = undefined;
            if (coordinate < anchor) {
                index = std.math.sub(i128, index, 1) catch return error.CoordinateOutOfRange;
                from = try boundary(settings, index);
                to = anchor;
            } else {
                const next_index = std.math.add(i128, index, 1) catch
                    return error.CoordinateOutOfRange;
                to = try boundary(settings, next_index);
            }
            if (!(from < to) or coordinate < from or coordinate >= to) {
                return error.CoordinateOutOfRange;
            }
            return index;
        }

        pub fn validateCoordinate(settings: SettingsT, coordinate: CoordT) Error!void {
            try settings.validate();
            _ = try interval(settings, coordinate, settings.level_count - 1);
        }

        pub fn interval(settings: SettingsT, coordinate: CoordT, level: u8) Error!Info {
            try settings.validate();
            if (level >= settings.level_count) {
                return error.InvalidLevel;
            }

            const position: i128 = if (@typeInfo(CoordT) == .float)
                try bucketIndex(settings, coordinate)
            else
                coordinate;

            var span: i128 = if (@typeInfo(CoordT) == .float) 1 else settings.base_width;

            for (0..level) |_| {
                span = std.math.mul(i128, span, settings.base) catch
                    return error.CoordinateOutOfRange;
            }

            const bucket = @divFloor(position, span);
            const from = std.math.mul(i128, bucket, span) catch
                return error.CoordinateOutOfRange;
            const to = std.math.add(i128, from, span) catch
                return error.CoordinateOutOfRange;
            const info: Info = .{
                .level = level,
                .from = if (@typeInfo(CoordT) == .float)
                    try boundary(settings, from)
                else
                    std.math.cast(CoordT, from) orelse return error.CoordinateOutOfRange,
                .to = if (@typeInfo(CoordT) == .float)
                    try boundary(settings, to)
                else
                    std.math.cast(CoordT, to) orelse return error.CoordinateOutOfRange,
            };
            if (!(info.from < info.to) or coordinate < info.from or coordinate >= info.to) {
                return error.CoordinateOutOfRange;
            }
            return info;
        }
    };
}
