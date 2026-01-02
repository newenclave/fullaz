const std = @import("std");

pub const Order = enum { lt, eq, gt, unordered };

pub fn cmpNum(a: anytype, b: @TypeOf(a)) Order {
    const T = @TypeOf(a);
    const is_float = @typeInfo(T) == .float or @typeInfo(T) == .comptime_float;
    const is_int = @typeInfo(T) == .int or @typeInfo(T) == .comptime_int;
    comptime {
        if (!is_float and !is_int) {
            @compileError("T should be a numeric type; received " ++ @typeName(T));
        }
    }

    // Handle NaN for float types
    if (is_float) {
        const a_is_nan = std.math.isNan(a);
        const b_is_nan = std.math.isNan(b);

        if (a_is_nan and b_is_nan) {
            return .eq;
        }
        if (a_is_nan) {
            return .unordered;
        }
        if (b_is_nan) {
            return .unordered;
        }
    }

    if (b < a) {
        return .gt;
    }
    if (a < b) {
        return .lt;
    }
    return .eq;
}

pub fn CmpNum(comptime T: type) type {
    return struct {
        pub fn asc(a: T, b: T) Order {
            return cmpNum(a, b);
        }
        pub fn desc(a: T, b: T) Order {
            return cmpNum(b, a);
        }
    };
}

pub fn cmpSlices(comptime T: type, a: []const T, b: []const T, cmp: anytype) Order {
    const SliceT = @TypeOf(a);
    comptime {
        const ti = @typeInfo(SliceT);
        if (ti != .pointer or ti.pointer.size != .slice) {
            @compileError("a must be a slice, got " ++ @typeName(SliceT));
        }
        if (@TypeOf(b) != SliceT) {
            @compileError("a and b must have the same slice type");
        }
    }

    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const res = cmp(a[i], b[i]);
        if (res != .eq) {
            return res;
        }
    }

    if (a.len < b.len) {
        return .lt;
    }
    if (a.len > b.len) {
        return .gt;
    }
    return .eq;
}

pub fn CmpSlices(comptime T: type) type {
    return struct {
        pub fn asc(a: []const T, b: []const T, cmp: anytype) Order {
            return cmpSlices(a, b, cmp);
        }
        pub fn desc(a: []const T, b: []const T, cmp: anytype) Order {
            return cmpSlices(b, a, cmp);
        }
    };
}

pub fn lowerBound(comptime T: type, items: []const T, key: T, cmp: anytype) !usize {
    var lo: usize = 0;
    var hi: usize = items.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (cmp(items[mid], key)) {
            .lt => lo = mid + 1,
            .eq, .gt => hi = mid,
            .unordered => return error.Unordered,
        }
    }
    return lo;
}

pub fn upperBound(comptime T: type, items: []const T, key: T, cmp: anytype) !usize {
    var lo: usize = 0;
    var hi: usize = items.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (cmp(items[mid], key)) {
            .gt => hi = mid,
            .lt, .eq => lo = mid + 1,
            .unordered => return error.Unordered,
        }
    }
    return lo;
}
