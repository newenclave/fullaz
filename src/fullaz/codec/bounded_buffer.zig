const errors = @import("../core/errors.zig");
const contracts = @import("../contracts/contracts.zig");
const interfaces = @import("../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;

pub const requiresStorageManager = contracts.storage_manager.requiresStorageManager;
pub const requiresPageCache = contracts.page_cache.requiresPageCache;

pub fn assertMemoryBlockWriter(comptime WriterT: type) void {
    requiresErrorDeclaration(WriterT, "Error");
    const Error = WriterT.Error;

    requiresFnSignature(WriterT, "extend", fn (*WriterT, usize) Error!void);
    requiresFnSignature(WriterT, "used", fn (*const WriterT) []const u8);
    requiresFnSignature(WriterT, "remaining", fn (*const WriterT) usize);
    requiresFnSignature(WriterT, "at", fn (*const WriterT, usize, usize) []const u8);
    requiresFnSignature(WriterT, "atMut", fn (*const WriterT, usize, usize) []u8);
}

pub fn assertMemoryBlockView(comptime ViewT: type) void {
    requiresErrorDeclaration(ViewT, "Error");
    const Error = ViewT.Error;

    requiresFnSignature(ViewT, "at", fn (*const ViewT, usize, usize) Error![]const u8);
    requiresFnSignature(ViewT, "len", fn (*const ViewT) Error!usize);
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
