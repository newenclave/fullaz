const std = @import("std");
const errors = @import("errors.zig");
const StaticVector = @import("static_vector.zig").StaticVector;

pub fn StaticStack(comptime T: type, comptime maximum_elements: usize, comptime DeinitCtx: type, comptime destructor: ?fn (DeinitCtx, *T) void) type {
    comptime {
        if (maximum_elements == 0) {
            @compileError("maximum_elements should have at least 1 element");
        }
    }
    const Vector = StaticVector(T, maximum_elements, DeinitCtx, destructor);
    return struct {
        const Self = @This();
        vector: Vector,

        pub const Error = Vector.Error || errors.SetError;

        pub fn init(ctx: DeinitCtx) Self {
            return .{
                .vector = Vector.init(ctx),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.vector.data[0..self.vector.len]) |*item| {
                if (destructor) |dtor| {
                    dtor(self.vector.deinit_ctx, item);
                }
            }
        }

        pub fn size(self: *const Self) usize {
            return self.vector.size();
        }

        pub fn capacity(self: *const Self) usize {
            return self.vector.capacity();
        }

        pub fn empty(self: *const Self) bool {
            return self.vector.empty();
        }

        pub fn full(self: *const Self) bool {
            return self.vector.full();
        }

        pub fn push(self: *Self, value: T) Error!void {
            try self.vector.pushBack(value);
        }

        pub fn top(self: *Self) Error!*T {
            if (self.empty()) {
                return Error.EmptySet;
            }
            return &self.vector.data[self.vector.len - 1];
        }

        pub fn ptrAt(self: anytype, pos: usize) ?*T {
            return self.vector.ptrAt(pos);
        }

        pub fn pop(self: *Self) Error!void {
            if (self.empty()) {
                return Error.EmptySet;
            }
            self.vector.len -= 1;
            if (destructor) |dtor| {
                dtor(self.vector.deinit_ctx, &self.vector.data[self.vector.len]);
            }
        }
    };
}
