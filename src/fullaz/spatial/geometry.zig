const std = @import("std");

pub fn BoundingBox(comptime CoordT: type, comptime dim_v: usize) type {
    return struct {
        const Self = @This();
        pub const Coord = CoordT;
        pub const dimention = dim_v;
        pub const Point = [dimention]Coord;

        low: Point = undefined,
        high: Point = undefined,

        pub fn init() Self {
            return Self{
                .low = [_]Coord{0} ** dimention,
                .high = [_]Coord{0} ** dimention,
            };
        }

        pub fn initWith(low: Point, high: Point) Self {
            return Self{
                .low = low,
                .high = high,
            };
        }

        pub fn valid(self: *const Self) bool {
            inline for (0..dimention) |i| {
                if (self.low[i] > self.high[i]) {
                    return false;
                }
            }
            return true;
        }

        pub fn measure(self: *const Self) Coord {
            var result: Coord = 1;
            inline for (0..dimention) |i| {
                result *= (self.high[i] - self.low[i]);
            }
            return result;
        }

        pub fn perimeter(self: *const Self) Coord {
            var result: Coord = 0;
            inline for (0..dimention) |i| {
                result += (self.high[i] - self.low[i]);
            }
            return result;
        }

        pub fn merged(self: *const Self, other: *const Self) Self {
            var result = Self.init();
            inline for (0..dimention) |i| {
                result.low[i] = @min(self.low[i], other.low[i]);
                result.high[i] = @max(self.high[i], other.high[i]);
            }
            return result;
        }

        pub fn contains(self: *const Self, point: Point) bool {
            inline for (0..dimention) |i| {
                if ((point[i] < self.low[i]) or (point[i] >= self.high[i])) {
                    return false;
                }
            }
            return true;
        }

        pub fn containsBox(self: *const Self, other: *const Self) bool {
            inline for (0..dimention) |i| {
                if ((other.low[i] < self.low[i]) or (other.high[i] > self.high[i])) {
                    return false;
                }
            }
            return true;
        }

        pub fn expanded(self: *const Self, amount: Coord) Self {
            var result = self.*;
            inline for (0..dimention) |i| {
                result.low[i] -= amount;
                result.high[i] += amount;
            }
            return result;
        }

        pub fn overlaps(self: *const Self, other: *const Self) bool {
            inline for (0..dimention) |i| {
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
            inline for (0..dimention) |i| {
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
            var result: Point = undefined;
            inline for (0..dimention) |i| {
                result[i] = self.low[i] + @divTrunc(self.high[i] - self.low[i], 2);
            }
            return result;
        }

        pub fn getLowAxis(self: *const Self, axis: usize) Coord {
            if (axis >= dimention) {
                @panic("Axis out of bounds");
            }
            return self.low[axis];
        }

        pub fn getHighAxis(self: *const Self, axis: usize) Coord {
            if (axis >= dimention) {
                @panic("Axis out of bounds");
            }
            return self.high[axis];
        }
    };
}
