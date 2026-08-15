const std = @import("std");

pub fn BoundingBox(comptime CoordT: type, comptime dim_v: usize) type {
    return struct {
        const Self = @This();
        pub const Coord = CoordT;
        pub const dimension = dim_v;
        pub const Point = [dimension]Coord;

        low: Point = undefined,
        high: Point = undefined,

        pub fn init() Self {
            return Self{
                .low = [_]Coord{0} ** dimension,
                .high = [_]Coord{0} ** dimension,
            };
        }

        pub fn initWith(low: Point, high: Point) Self {
            return Self{
                .low = low,
                .high = high,
            };
        }

        pub fn create(low: Point, high: Point) Self {
            return Self.initWith(low, high);
        }

        pub fn valid(self: *const Self) bool {
            inline for (0..dimension) |i| {
                if (self.low[i] > self.high[i]) {
                    return false;
                }
            }
            return true;
        }

        pub fn measure(self: *const Self) Coord {
            var result: Coord = 1;
            inline for (0..dimension) |i| {
                result *= (self.high[i] - self.low[i]);
            }
            return result;
        }

        pub fn perimeter(self: *const Self) Coord {
            var result: Coord = 0;
            inline for (0..dimension) |i| {
                result += (self.high[i] - self.low[i]);
            }
            return result;
        }

        pub fn merged(self: *const Self, other: *const Self) Self {
            var result = Self.init();
            inline for (0..dimension) |i| {
                result.low[i] = @min(self.low[i], other.low[i]);
                result.high[i] = @max(self.high[i], other.high[i]);
            }
            return result;
        }

        pub fn contains(self: *const Self, point: Point) bool {
            inline for (0..dimension) |i| {
                if ((point[i] < self.low[i]) or (point[i] >= self.high[i])) {
                    return false;
                }
            }
            return true;
        }

        pub fn containsBox(self: *const Self, other: *const Self) bool {
            inline for (0..dimension) |i| {
                if ((other.low[i] < self.low[i]) or (other.high[i] > self.high[i])) {
                    return false;
                }
            }
            return true;
        }

        pub fn expanded(self: *const Self, amount: Coord) Self {
            var result = self.*;
            inline for (0..dimension) |i| {
                result.low[i] -= amount;
                result.high[i] += amount;
            }
            return result;
        }

        pub fn overlaps(self: *const Self, other: *const Self) bool {
            inline for (0..dimension) |i| {
                if ((self.high[i] <= other.low[i]) or (other.high[i] <= self.low[i])) {
                    return false;
                }
            }
            return true;
        }

        pub fn enlargement(self: *const Self, other: *const Self) Coord {
            return self.merged(other).measure() - self.measure();
        }

        pub fn overlapMeasure(self: *const Self, other: *const Self) Coord {
            var result: Coord = 1;
            inline for (0..dimension) |i| {
                const lo = @max(self.low[i], other.low[i]);
                const hi = @min(self.high[i], other.high[i]);
                if (hi <= lo) {
                    return 0;
                }
                result *= (hi - lo);
            }
            return result;
        }

        pub fn center(self: *const Self) Point {
            const is_float = comptime @typeInfo(Coord) == .float;
            var result: Point = undefined;
            inline for (0..dimension) |i| {
                const extent = self.high[i] - self.low[i];
                result[i] = self.low[i] + if (is_float) extent / 2 else @divTrunc(extent, 2);
            }
            return result;
        }

        pub fn splittable(self: *const Self, min_cell_extent: Coord) bool {
            const mid = self.center();
            inline for (0..dimension) |i| {
                // Positive form on purpose: NaN bounds answer "not splittable".
                if (!(mid[i] > self.low[i]) or !(mid[i] < self.high[i])) {
                    return false;
                }
                if (!(mid[i] - self.low[i] >= min_cell_extent) or
                    !(self.high[i] - mid[i] >= min_cell_extent))
                {
                    return false;
                }
            }
            return true;
        }

        pub fn getLowAxis(self: *const Self, axis: usize) Coord {
            if (axis >= dimension) {
                @panic("Axis out of bounds");
            }
            return self.low[axis];
        }

        pub fn getHighAxis(self: *const Self, axis: usize) Coord {
            if (axis >= dimension) {
                @panic("Axis out of bounds");
            }
            return self.high[axis];
        }
    };
}
