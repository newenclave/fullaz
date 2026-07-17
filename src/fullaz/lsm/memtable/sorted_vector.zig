const std = @import("std");
const algorithm = @import("../../core/algorithm.zig");
const models_iface = @import("../models/interfaces.zig");

const Entry = @import("../models/entry.zig").Entry;
const EntryMut = @import("../models/entry.zig").EntryMut;

const Rec = EntryMut;

fn keyOrder(_: void, a: []const u8, b: []const u8) algorithm.Order {
    return algorithm.cmpSlices(u8, a, b, algorithm.CmpNum(u8).asc, {}) catch unreachable;
}

pub fn SortedVectorImpl(comptime keyCmp: anytype, comptime CmpCtx: type) type {
    const cmpRecKeyImpl = struct {
        fn cmp(ctx: CmpCtx, rec: Rec, key: []const u8) algorithm.Order {
            return keyCmp(ctx, rec.key, key);
        }
    };

    const Container = std.ArrayList(Rec);

    return struct {
        const Self = @This();

        pub const Error = std.mem.Allocator.Error;
        pub const KeyInType = []const u8;
        pub const ValueInType = []const u8;
        pub const ValueOutType = []const u8;

        pub const Iterator = struct {
            const ItSelf = @This();
            pub const Error = error{};

            recs: []const Rec,
            idx: usize,

            pub fn peek(self: *const ItSelf) ItSelf.Error!?Entry {
                if (self.idx >= self.recs.len) {
                    return null;
                }
                const r = self.recs[self.idx];
                return Entry{ .key = r.key, .value = r.value };
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
        cmp_ctx: CmpCtx,

        // Convenience for the common void-context case. Non-void contexts must use initWithContext.
        pub fn init(allocator: std.mem.Allocator) Error!Self {
            if (CmpCtx != void) {
                @compileError("SortedVectorImpl: a non-void context requires initWithContext");
            }
            return initWithContext(allocator, {});
        }

        pub fn initWithContext(allocator: std.mem.Allocator, cmp_ctx: CmpCtx) Error!Self {
            return .{
                .allocator = allocator,
                .recs = try Container.initCapacity(allocator, 4),
                .bytes = 0,
                .cmp_ctx = cmp_ctx,
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

        pub fn put(self: *Self, key: KeyInType, value: ValueInType) Error!void {
            const pos = self.position(key);
            if (pos < self.recs.items.len and keyCmp(self.cmp_ctx, self.recs.items[pos].key, key) == .eq) {
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

        pub fn get(self: *const Self, key: KeyInType) Error!?ValueOutType {
            const pos = self.position(key);
            if (pos < self.recs.items.len and keyCmp(self.cmp_ctx, self.recs.items[pos].key, key) == .eq) {
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

        pub fn seek(self: *const Self, key: KeyInType) Error!Iterator {
            return Iterator{ .recs = self.recs.items, .idx = self.position(key) };
        }

        fn position(self: *const Self, key: KeyInType) usize {
            return algorithm.lowerBound(
                Rec,
                self.recs.items,
                key,
                cmpRecKeyImpl.cmp,
                self.cmp_ctx,
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

pub const SortedVector = SortedVectorImpl(keyOrder, void);
