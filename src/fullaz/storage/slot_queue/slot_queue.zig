const std = @import("std");
const errors = @import("../../core/errors.zig");
const slot_chain = @import("../slot_chain/slot_chain.zig");

pub fn SlotQueue(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const Chain = slot_chain.ForwardHandle(PageCacheT, StorageManagerT, Endian);

    return struct {
        const Self = @This();

        pub const Error = Chain.Error || errors.SetError;
        pub const ValueIn = Chain.ValueIn;

        /// Owns the iterator that keeps the peeked value borrowed from the queue.
        pub const Peek = struct {
            const PeekSelf = @This();

            iterator: Chain.Iterator,

            /// The returned slice is valid until `deinit()` or queue mutation.
            pub fn value(self: *const PeekSelf) Error![]const u8 {
                const result = (try self.iterator.get()) orelse return Error.InvalidIterator;
                return result.value;
            }

            pub fn deinit(self: *PeekSelf) void {
                self.iterator.deinit();
            }
        };

        pub const Iterator = struct {
            const IteratorSelf = @This();

            iterator: Chain.Iterator,

            /// The returned slice is valid until the next call or `deinit()`.
            pub fn next(self: *IteratorSelf) Error!?[]const u8 {
                const result = (try self.iterator.next()) orelse return null;
                return result.value;
            }

            pub fn deinit(self: *IteratorSelf) void {
                self.iterator.deinit();
            }
        };

        chain: Chain,

        pub fn init(
            page_cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            settings: slot_chain.Settings,
        ) Error!Self {
            return .{
                .chain = try Chain.init(page_cache, storage_manager, settings),
            };
        }

        pub fn deinit(self: *Self) void {
            self.chain.deinit();
        }

        pub fn size(self: *const Self) Error!usize {
            return self.chain.size();
        }

        pub fn isEmpty(self: *const Self) Error!bool {
            return (try self.size()) == 0;
        }

        pub fn enqueue(self: *Self, value: ValueIn) Error!void {
            _ = try self.chain.append(value);
        }

        pub fn front(self: *Self) Error!Peek {
            var chain_iterator = (try self.chain.iterator()) orelse return Error.EmptySet;
            errdefer chain_iterator.deinit();
            _ = (try chain_iterator.next()) orelse return Error.EmptySet;
            return .{ .iterator = chain_iterator };
        }

        pub fn dequeue(self: *Self) Error!void {
            var chain_iterator = (try self.chain.iterator()) orelse return Error.EmptySet;
            defer chain_iterator.deinit();
            _ = (try chain_iterator.next()) orelse return Error.EmptySet;

            var pending = try chain_iterator.markForRemoval();
            defer pending.deinit();
            if (!try pending.clean()) {
                return Error.InvalidIterator;
            }
        }

        pub fn iterator(self: *Self) Error!?Iterator {
            const chain_iterator = (try self.chain.iterator()) orelse return null;
            return .{ .iterator = chain_iterator };
        }
    };
}
