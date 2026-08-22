const std = @import("std");

pub fn ObserverImpl(comptime SyncPolicyT: type, comptime EventT: type, comptime IdT: type) type {
    return struct {
        const Self = @This();
        pub const SyncPolicy = SyncPolicyT;
        pub const Event = EventT;
        pub const Id = IdT;
        pub const Fn = *const fn (ctx: ?*anyopaque, event: *const Event) void;
        pub const Error = std.mem.Allocator.Error ||
            error{};

        const Record = struct {
            id: Id,
            ctx: ?*anyopaque,
            call: Fn,
        };

        slots: std.ArrayList(Record) = .empty,
        allocator: std.mem.Allocator,
        sync: SyncPolicyT,
        next_id: Id = 0,

        pub fn init(sync: SyncPolicy, allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .sync = sync,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn subscribe(self: *Self, call: Fn, ctx: ?*anyopaque) Error!Id {
            self.sync.lock();
            defer self.sync.unlock();

            const record = Record{
                .id = self.next_id,
                .ctx = ctx,
                .call = call,
            };
            self.next_id += 1;
            try self.slots.append(self.allocator, record);
            return record.id;
        }

        pub const UnsubscribeResult = struct {
            ctx: ?*anyopaque,
        };

        pub fn unsubscribe(self: *Self, id: Id) ?UnsubscribeResult {
            self.sync.lock();
            defer self.sync.unlock();

            for (self.slots.items, 0..) |record, index| {
                if (record.id == id) {
                    const removed = self.slots.orderedRemove(index);
                    return .{ .ctx = removed.ctx };
                }
            }

            return null;
        }

        pub fn notify(self: *Self, event: *const Event) Error!void {
            var tmp = tmp: {
                self.sync.lock();
                defer self.sync.unlock();
                break :tmp try self.slots.clone(self.allocator);
            };
            defer tmp.deinit(self.allocator);

            for (tmp.items) |record| {
                record.call(record.ctx, event);
            }
        }
    };
}
