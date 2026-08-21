const std = @import("std");

/// Places every free-space value in a single class.
pub const One = struct {
    const Self = @This();
    pub const SizeClass = u16;

    pub fn getSizeClass(_: *const Self, _: u16) SizeClass {
        return 0;
    }

    pub fn count(_: *const Self) usize {
        return 1;
    }
};

/// Groups free-space values into monotonically increasing logarithmic classes.
pub const Logarithmic = struct {
    const Self = @This();
    pub const SizeClass = u16;
    pub const Error = error{
        InvalidBase,
        InvalidMinimumTrackedSpace,
    };

    pub const Options = struct {
        base: u8 = 8,
        minimum_tracked_space: u16 = 1,
    };

    base: u8,
    minimum_tracked_space: u16,

    pub fn init(options: Options) Error!Self {
        if (options.base < 2 or options.base > 128 or !std.math.isPowerOfTwo(options.base)) {
            return Error.InvalidBase;
        }
        if (options.minimum_tracked_space == 0) {
            return Error.InvalidMinimumTrackedSpace;
        }
        return .{
            .base = options.base,
            .minimum_tracked_space = options.minimum_tracked_space,
        };
    }

    pub fn getSizeClass(self: *const Self, size: u16) SizeClass {
        var remaining: u32 = size;
        const minimum: u32 = self.minimum_tracked_space;
        const base: u32 = self.base;
        var class: SizeClass = 0;
        while (remaining > minimum) {
            remaining = (remaining + base - 1) / base;
            class += 1;
        }
        return class;
    }

    pub fn count(self: *const Self) usize {
        return @as(usize, self.getSizeClass(std.math.maxInt(u16))) + 1;
    }
};
