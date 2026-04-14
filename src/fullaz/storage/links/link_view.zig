const errors = @import("../../core/errors.zig");

// TODO: This is a very temporary implementation. Link must not contain the data size.
pub fn LinkView(comptime PageId: type, comptime Index: type, comptime LinkHeader: type, comptime read_only: bool) type {
    const FldPtr = if (read_only) *const LinkHeader else *LinkHeader;
    return struct {
        const Self = @This();
        pub const Error = error{} || errors.SpaceError;

        link: FldPtr = undefined,

        pub fn init(link: FldPtr) Self {
            return Self{
                .link = link,
            };
        }

        pub fn getFwd(self: *const Self) ?PageId {
            const val = self.link.fwd.get();
            return if (self.link.fwd.isMaxVal(val)) null else val;
        }

        pub fn setFwd(self: *Self, next: ?PageId) void {
            if (read_only) {
                @compileError("Cannot set next on a read-only view");
            }
            if (next) |n| {
                self.link.fwd.set(n);
            } else {
                self.link.fwd.setMax();
            }
        }

        pub fn getBack(self: *const Self) ?PageId {
            const val = self.link.back.get();
            return if (self.link.back.isMaxVal(val)) null else val;
        }

        pub fn setBack(self: *Self, last: ?PageId) void {
            if (read_only) {
                @compileError("Cannot set last on a read-only view");
            }
            if (last) |l| {
                self.link.back.set(l);
            } else {
                self.link.back.setMax();
            }
        }

        pub fn getDataSize(self: *const Self) Index {
            return self.link.payload.size.get();
        }

        pub fn setDataSize(self: *Self, size: Index) void {
            if (read_only) {
                @compileError("Cannot set data size on a read-only view");
            }
            self.link.payload.size.set(size);
        }

        pub fn incrementDataSize(self: *Self, increment: Index) void {
            if (read_only) {
                @compileError("Cannot increment data size on a read-only view");
            }
            const current = self.link.payload.size.get();
            self.link.payload.size.set(current + increment);
        }

        pub fn decrementDataSize(self: *Self, decrement: Index) void {
            if (read_only) {
                @compileError("Cannot decrement data size on a read-only view");
            }
            const current = self.link.payload.size.get();
            self.link.payload.size.set(current - decrement);
        }
    };
}
