const errors = @import("../core/errors.zig");
const contracts = @import("../contracts/contracts.zig");
const interfaces = @import("../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;

pub const requiresStorageManager = contracts.storage_manager.requiresStorageManager;
pub const requiresPageCache = contracts.page_cache.requiresPageCache;

pub fn assertMemoryBlockWriter(comptime Writer: type) void {
    requiresErrorDeclaration(Writer, "Error");
    const Error = Writer.Error;

    requiresFnSignature(Writer, "extend", fn (*Writer, usize) Error!void);
    requiresFnSignature(Writer, "used", fn (*const Writer) []const u8);
    requiresFnSignature(Writer, "remaining", fn (*const Writer) usize);
    requiresFnSignature(Writer, "at", fn (*const Writer, usize, usize) []const u8);
    requiresFnSignature(Writer, "atMut", fn (*const Writer, usize, usize) []u8);
}

pub fn assertMemoryBlockView(comptime View: type) void {
    requiresErrorDeclaration(View, "Error");
    const Error = View.Error;

    requiresFnSignature(View, "at", fn (*const View, usize, usize) Error![]const u8);
    requiresFnSignature(View, "len", fn (*const View) Error!usize);
}

pub fn MemoryBlockWriter(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Error = errors.SpaceError;

        buf: []T,
        len: usize = 0,

        pub fn init(buf: []T) Self {
            return .{ .buf = buf };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn append(self: *Self, items: []const T) Error!void {
            if (items.len > (self.buf.len - self.len)) {
                return Error.BufferTooSmall;
            }

            @memcpy(self.buf[self.len..][0..items.len], items);
            self.len += items.len;
        }

        pub fn extend(self: *Self, len: usize) Error!void {
            if (len > (self.buf.len - self.len)) {
                return Error.BufferTooSmall;
            }
            self.len += len;
        }

        pub fn used(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        pub fn at(self: *const Self, index: usize, len: usize) []const T {
            return self.buf[index .. index + len];
        }

        pub fn atMut(self: *const Self, index: usize, len: usize) []T {
            return self.buf[index .. index + len];
        }

        pub fn remaining(self: *const Self) usize {
            return self.buf.len - self.len;
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
        }

        pub fn view(self: *const Self) MemoryBlockView(T) {
            return .{
                .items = self.used(),
            };
        }
    };
}

pub fn MemoryBlockView(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Error = error{};

        items: []const T,

        pub fn init(items: []const T) Self {
            return .{
                .items = items,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn at(self: *const Self, index: usize, length: usize) Error![]const T {
            return self.items[index .. index + length];
        }

        pub fn slice(self: *const Self) []const T {
            return self.items;
        }

        pub fn len(self: *const Self) Error!usize {
            return self.items.len;
        }
    };
}
