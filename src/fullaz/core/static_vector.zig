const std = @import("std");
const errors = @import("errors.zig");

pub fn StaticVector(comptime T: type, comptime maximum_elements: usize, comptime DeinitCtx: type, comptime destructor: ?fn (DeinitCtx, *T) void) type {
    comptime {
        if (maximum_elements == 0) {
            @compileError("maximum_elements should have at least 1 element");
        }
    }

    return struct {
        const Self = @This();
        data: [maximum_elements]T = undefined,
        len: usize = 0,
        deinit_ctx: DeinitCtx = undefined,

        pub const Error = errors.StaticVectorError;

        pub fn init(ctx: DeinitCtx) Self {
            return .{
                .data = undefined,
                .len = 0,
                .deinit_ctx = ctx,
            };
        }

        pub fn size(self: *const Self) usize {
            return self.len;
        }

        pub fn capacity(_: *const Self) usize {
            return maximum_elements;
        }

        pub fn empty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn full(self: *const Self) bool {
            return self.len >= maximum_elements;
        }

        pub fn pushBack(self: *Self, value: T) Error!void {
            if (self.len >= maximum_elements) {
                return Error.NotEnoughSpace;
            }
            self.data[self.len] = value;
            self.len += 1;
        }

        pub fn ptrAt(self: anytype, pos: usize) ?*T {
            comptime isMySelf(@TypeOf(self));
            if (pos < self.len) {
                return &self.data[pos];
            }
            return null;
        }

        pub fn back(self: anytype) ?*T {
            comptime isMySelf(@TypeOf(self));
            if (self.len > 0) {
                return &self.data[self.len - 1];
            }
            return null;
        }

        pub fn insert(self: *Self, pos: usize, value: T) Error!void {
            if (self.len >= maximum_elements) {
                return Error.NotEnoughSpace;
            }
            if (pos > self.len) {
                return Error.OutOfBounds;
            }
            self.expand(pos);
            self.data[pos] = value;
            self.len += 1;
        }

        pub fn remove(self: *Self, pos: usize) Error!void {
            if (pos >= self.len) {
                return Error.OutOfBounds;
            }

            if (destructor) |destruct| {
                destruct(self.deinit_ctx, &self.data[pos]);
            }

            self.shrink(pos);
            self.len -= 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.data[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.data[0..self.len];
        }

        // helpers
        fn isMySelf(S: type) void {
            comptime {
                if (S != *Self and S != *const Self) {
                    @compileError("self must be *Self or *const Self");
                }
            }
        }

        fn shrink(self: *Self, idx: usize) void {
            for (idx..self.len - 1) |i| {
                self.data[i] = self.data[i + 1];
            }
        }

        fn expand(self: *Self, idx: usize) void {
            var k: usize = self.len;
            while (k > idx) : (k -= 1) {
                self.data[k] = self.data[k - 1];
            }
        }
    };
}
