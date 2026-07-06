const std = @import("std");

pub fn Posix(comptime max_depth: usize) type {
    return struct {
        pub const MaxDepth = max_depth;
        pub const separator: u8 = '/';
        pub const Error = error{PathTooDeep};

        pub fn split(path: []const u8, comps: *[max_depth][]const u8) Error!usize {
            var n: usize = 0;
            var it = std.mem.tokenizeScalar(u8, path, separator);
            while (it.next()) |comp| {
                if (n >= max_depth) {
                    return Error.PathTooDeep;
                }
                comps[n] = comp;
                n += 1;
            }
            return n;
        }
    };
}

pub const Default = Posix(32);
