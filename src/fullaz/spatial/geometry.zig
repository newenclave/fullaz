const std = @import("std");

pub fn BoundingBox(comptime CoordT: type, comptime dim_v: usize) type {
    comptime {
        if (dim_v == 0) {
            @compileError("BoundingBox dimension must be greater than zero");
        }
    }

    return struct {
        const Self = @This();
        pub const Coord = CoordT;
        pub const dimension = dim_v;
        pub const Point = [dimension]Coord;

        const is_integer = @typeInfo(Coord) == .int;

        // R-tree scores must be ordered even when a valid box spans the native
        // coordinate range. Saturation trades score precision for safe routing.
        fn metricExtent(high: Coord, low: Coord) Coord {
            if (high <= low) {
                return 0;
            }
            if (comptime is_integer) {
                return std.math.sub(Coord, high, low) catch std.math.maxInt(Coord);
            }
            const result = high - low;
            return if (std.math.isFinite(result)) result else std.math.floatMax(Coord);
        }

        fn metricAdd(left: Coord, right: Coord) Coord {
            if (comptime is_integer) {
                return std.math.add(Coord, left, right) catch std.math.maxInt(Coord);
            }
            const result = left + right;
            return if (std.math.isFinite(result)) result else std.math.floatMax(Coord);
        }

        fn metricMul(left: Coord, right: Coord) Coord {
            if (comptime is_integer) {
                return std.math.mul(Coord, left, right) catch std.math.maxInt(Coord);
            }
            const result = left * right;
            return if (std.math.isFinite(result)) result else std.math.floatMax(Coord);
        }

        fn metricDifference(larger: Coord, smaller: Coord) Coord {
            if (larger <= smaller) {
                return 0;
            }
            if (comptime is_integer) {
                return std.math.sub(Coord, larger, smaller) catch std.math.maxInt(Coord);
            }
            const result = larger - smaller;
            return if (std.math.isFinite(result)) result else std.math.floatMax(Coord);
        }

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

        fn assertDimensionRange(comptime start: usize, comptime dims: usize) void {
            if (dims == 0 or start > dimension or dims > dimension - start) {
                @compileError("BoundingBox dimension range must be non-empty and within dimension");
            }
        }

        pub fn measureN(self: *const Self, comptime start: usize, comptime dims: usize) Coord {
            comptime assertDimensionRange(start, dims);

            var result: Coord = 1;
            inline for (0..dims) |i| {
                result = metricMul(result, metricExtent(
                    self.high[start + i],
                    self.low[start + i],
                ));
            }
            return result;
        }

        pub fn measure(self: *const Self) Coord {
            return self.measureN(0, dimension);
        }

        pub fn perimeterN(self: *const Self, comptime start: usize, comptime dims: usize) Coord {
            comptime assertDimensionRange(start, dims);

            var result: Coord = 0;
            inline for (0..dims) |i| {
                result = metricAdd(result, metricExtent(
                    self.high[start + i],
                    self.low[start + i],
                ));
            }
            return result;
        }

        pub fn perimeter(self: *const Self) Coord {
            return self.perimeterN(0, dimension);
        }

        pub fn surfaceAreaN(self: *const Self, comptime start: usize, comptime dims: usize) Coord {
            comptime assertDimensionRange(start, dims);

            var result: Coord = 0;
            inline for (0..dims) |i| {
                var face_measure: Coord = 1;
                inline for (0..dims) |j| {
                    if (i != j) {
                        face_measure = metricMul(face_measure, metricExtent(
                            self.high[start + j],
                            self.low[start + j],
                        ));
                    }
                }
                result = metricAdd(result, face_measure);
            }
            return metricMul(result, 2);
        }

        pub fn surfaceArea(self: *const Self) Coord {
            return self.surfaceAreaN(0, dimension);
        }

        pub fn sliceN(self: *const Self, comptime start: usize, comptime dims: usize) BoundingBox(Coord, dims) {
            comptime assertDimensionRange(start, dims);

            var result = BoundingBox(Coord, dims).init();
            inline for (0..dims) |i| {
                result.low[i] = self.low[start + i];
                result.high[i] = self.high[start + i];
            }
            return result;
        }

        pub fn embed(source: anytype, comptime start: usize) Self {
            const SourceBox = switch (@typeInfo(@TypeOf(source))) {
                .pointer => |pointer| pointer.child,
                else => @compileError("BoundingBox.embed source must be a pointer to BoundingBox"),
            };
            comptime {
                if (@typeInfo(SourceBox) != .@"struct" or
                    !@hasDecl(SourceBox, "Coord") or
                    !@hasDecl(SourceBox, "dimension") or
                    !@hasField(SourceBox, "low") or
                    !@hasField(SourceBox, "high"))
                {
                    @compileError("BoundingBox.embed source must be a BoundingBox");
                }
                if (SourceBox.Coord != Coord) {
                    @compileError("BoundingBox.embed source coordinate type must match target");
                }
                assertDimensionRange(start, SourceBox.dimension);
            }

            var result = Self.init();
            inline for (0..SourceBox.dimension) |i| {
                result.low[start + i] = source.low[i];
                result.high[start + i] = source.high[i];
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

        pub fn intersects(self: *const Self, other: *const Self) bool {
            inline for (0..dimension) |i| {
                if ((self.high[i] < other.low[i]) or (other.high[i] < self.low[i])) {
                    return false;
                }
            }
            return true;
        }

        pub fn enlargementN(
            self: *const Self,
            other: *const Self,
            comptime start: usize,
            comptime dims: usize,
        ) Coord {
            return metricDifference(
                self.merged(other).measureN(start, dims),
                self.measureN(start, dims),
            );
        }

        pub fn enlargement(self: *const Self, other: *const Self) Coord {
            return self.enlargementN(other, 0, dimension);
        }

        pub fn overlapMeasureN(
            self: *const Self,
            other: *const Self,
            comptime start: usize,
            comptime dims: usize,
        ) Coord {
            comptime assertDimensionRange(start, dims);

            var result: Coord = 1;
            inline for (0..dims) |i| {
                const axis = start + i;
                const lo = @max(self.low[axis], other.low[axis]);
                const hi = @min(self.high[axis], other.high[axis]);
                if (hi <= lo) {
                    return 0;
                }
                result = metricMul(result, metricExtent(hi, lo));
            }
            return result;
        }

        pub fn overlapMeasure(self: *const Self, other: *const Self) Coord {
            return self.overlapMeasureN(other, 0, dimension);
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
