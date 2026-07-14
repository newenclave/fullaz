const std = @import("std");
const algorithm = @import("../../core/algorithm.zig");
const strategy = @import("../strategy.zig");

const Rec = struct {
    key: []u8,
    value: []u8,
};

fn keyOrder(a: []const u8, b: []const u8) algorithm.Order {
    return algorithm.cmpSlices(u8, a, b, algorithm.CmpNum(u8).asc, {}) catch unreachable;
}

pub fn SortedVectorImpl(comptime keyCmp: anytype) type {
    const cmpRecKeyImpl = struct {
        fn cmp(_: void, rec: Rec, key: []const u8) algorithm.Order {
            return keyCmp(rec.key, key);
        }
    };

    const Container = std.ArrayList(Rec);

    return struct {
        const Self = @This();

        pub const Error = std.mem.Allocator.Error;

        pub const Iterator = struct {
            const ItSelf = @This();
            pub const Error = error{};

            recs: []const Rec,
            idx: usize,

            pub fn peek(self: *const ItSelf) ItSelf.Error!?strategy.Entry {
                if (self.idx >= self.recs.len) {
                    return null;
                }
                const r = self.recs[self.idx];
                return strategy.Entry{ .key = r.key, .value = r.value };
            }

            pub fn advance(self: *ItSelf) ItSelf.Error!void {
                self.idx += 1;
            }

            pub fn deinit(self: *ItSelf) void {
                _ = self;
            }
        };

        allocator: std.mem.Allocator,
        recs: Container,
        bytes: usize,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .allocator = allocator,
                .recs = try Container.initCapacity(allocator, 4),
                .bytes = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.freeAll();
            self.recs.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn reset(self: *Self) Error!void {
            self.freeAll();
            self.recs.clearRetainingCapacity();
            self.bytes = 0;
        }

        pub fn put(self: *Self, key: []const u8, value: []const u8) Error!void {
            const pos = self.position(key);
            if (pos < self.recs.items.len and keyOrder(self.recs.items[pos].key, key) == .eq) {
                const new_val = try self.allocator.dupe(u8, value);
                const rec = &self.recs.items[pos];
                self.bytes -= rec.value.len;
                self.allocator.free(rec.value);
                rec.value = new_val;
                self.bytes += new_val.len;
                return;
            }
            const k = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(k);
            const v = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(v);

            try self.recs.insert(self.allocator, pos, .{ .key = k, .value = v });
            self.bytes += k.len + v.len;
        }

        pub fn get(self: *const Self, key: []const u8) Error!?[]const u8 {
            const pos = self.position(key);
            if (pos < self.recs.items.len and keyOrder(self.recs.items[pos].key, key) == .eq) {
                return self.recs.items[pos].value;
            }
            return null;
        }

        pub fn byteSize(self: *const Self) usize {
            return self.bytes;
        }

        pub fn count(self: *const Self) usize {
            return self.recs.items.len;
        }

        pub fn iterator(self: *const Self) Error!Iterator {
            return Iterator{ .recs = self.recs.items, .idx = 0 };
        }

        pub fn seek(self: *const Self, key: []const u8) Error!Iterator {
            return Iterator{ .recs = self.recs.items, .idx = self.position(key) };
        }

        fn position(self: *const Self, key: []const u8) usize {
            return algorithm.lowerBound(
                Rec,
                self.recs.items,
                key,
                cmpRecKeyImpl.cmp,
                {},
            ) catch unreachable;
        }

        fn freeAll(self: *Self) void {
            for (self.recs.items) |rec| {
                self.allocator.free(rec.key);
                self.allocator.free(rec.value);
            }
        }
    };
}

pub const SortedVector = SortedVectorImpl(keyOrder);
