const std = @import("std");

pub fn BoundingBox(comptime CoordT: type, comptime DimV: usize) type {
    return struct {
        const Self = @This();
        pub const Coord = CoordT;
        pub const Dim = DimV;
        pub const Point = [Dim]Coord;

        low: Point = undefined,
        high: Point = undefined,

        pub fn init() Self {
            return Self{
                .low = [_]Coord{0} ** Dim,
                .high = [_]Coord{0} ** Dim,
            };
        }

        pub fn initWith(low: Point, high: Point) Self {
            return Self{
                .low = low,
                .high = high,
            };
        }

        pub fn valid(self: *const Self) bool {
            inline for (0..Dim) |i| {
                if (self.low[i] > self.high[i]) {
                    return false;
                }
            }
            return true;
        }

        pub fn measure(self: *const Self) Coord {
            var result: Coord = 1;
            inline for (0..Dim) |i| {
                result *= (self.high[i] - self.low[i]);
            }
            return result;
        }

        pub fn perimeter(self: *const Self) Coord {
            var result: Coord = 0;
            inline for (0..Dim) |i| {
                result += (self.high[i] - self.low[i]);
            }
            return result;
        }

        pub fn merged(self: *const Self, other: *const Self) Self {
            var result = Self.init();
            inline for (0..Dim) |i| {
                result.low[i] = @min(self.low[i], other.low[i]);
                result.high[i] = @max(self.high[i], other.high[i]);
            }
            return result;
        }

        pub fn contains(self: *const Self, point: Point) bool {
            inline for (0..Dim) |i| {
                if ((point[i] < self.low[i]) or (point[i] >= self.high[i])) {
                    return false;
                }
            }
            return true;
        }

        pub fn overlaps(self: *const Self, other: *const Self) bool {
            inline for (0..Dim) |i| {
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
            inline for (0..Dim) |i| {
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
            inline for (0..Dim) |i| {
                result[i] = self.low[i] + @divTrunc(self.high[i] - self.low[i], 2);
            }
            return result;
        }
    };
}
