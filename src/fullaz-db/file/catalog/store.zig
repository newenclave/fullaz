const std = @import("std");
const slot_chain = @import("fullaz").storage.slot_chain;
const catalog_record = @import("record.zig");
const CatalogRef = @import("ref.zig").CatalogRef;
const catalog_ref = @import("ref.zig");
const system_kinds = @import("../system_kinds.zig");

/// Append-only storage for immutable catalog record revisions.
pub fn CatalogStore(comptime CacheT: type, comptime ManagerT: type) type {
    const ChainT = slot_chain.Handle(CacheT, ManagerT, .little);

    return struct {
        const Self = @This();

        pub const Error = ChainT.ReferenceError ||
            catalog_record.Error ||
            catalog_ref.Error ||
            error{BadCatalogChain};
        pub const Entry = struct {
            ref: CatalogRef,
            /// Borrows the exact record bytes until the iterator advances.
            encoded_record: []const u8,
            record: catalog_record.View,
        };

        pub const LoadedRecord = struct {
            const LrSelf = @This();

            record: ChainT.Record,
            expected_revision: u32,

            pub fn deinit(self: *LrSelf) void {
                self.record.deinit();
                self.* = undefined;
            }

            /// The returned view borrows the pinned catalog page until deinit().
            pub fn view(self: *const LrSelf) Error!catalog_record.View {
                const value = try self.record.value();
                const record_view = try catalog_record.read(value);
                if (record_view.revision != self.expected_revision) {
                    return error.BadCatalogChain;
                }
                return record_view;
            }
        };

        pub const Iterator = struct {
            const ItrSelf = @This();
            chain_iterator: ?ChainT.Iterator,
            remaining: u64,
            finished: bool = false,

            pub fn deinit(self: *ItrSelf) void {
                if (self.chain_iterator) |*chain_iterator| {
                    chain_iterator.deinit();
                }
                self.* = undefined;
            }

            pub fn next(self: *ItrSelf) Error!?Entry {
                if (self.finished) {
                    return null;
                }
                const chain_iterator = if (self.chain_iterator) |*value| value else {
                    if (self.remaining != 0) {
                        return error.BadCatalogChain;
                    }
                    self.finished = true;
                    return null;
                };
                const result = (try chain_iterator.next()) orelse {
                    if (self.remaining != 0) {
                        return error.BadCatalogChain;
                    }
                    self.finished = true;
                    return null;
                };
                if (self.remaining == 0) {
                    return error.BadCatalogChain;
                }
                self.remaining -= 1;
                const record = try catalog_record.read(result.value);
                const page_id = std.math.cast(u64, result.page_id) orelse return error.BadCatalogChain;
                const slot_id = std.math.cast(u16, result.pos) orelse return error.BadCatalogChain;
                return .{
                    .ref = try CatalogRef.init(page_id, slot_id, record.revision),
                    .encoded_record = result.value,
                    .record = record,
                };
            }
        };

        chain: ChainT,

        pub fn init(cache: *CacheT, manager: *ManagerT) Error!Self {
            return .{ .chain = try ChainT.init(cache, manager, .{
                .chunk_page_kind = system_kinds.catalog_slot_chain,
            }) };
        }

        pub fn deinit(self: *Self) void {
            self.chain.deinit();
            self.* = undefined;
        }

        pub fn append(self: *Self, encoded_record: []const u8) Error!CatalogRef {
            const record = try catalog_record.read(encoded_record);
            const slot_ref = try self.chain.appendRef(encoded_record);
            const page_id = std.math.cast(u64, slot_ref.page_id) orelse return error.BadCatalogChain;
            return CatalogRef.init(page_id, slot_ref.slot_id, record.revision);
        }

        pub fn load(self: *const Self, ref: CatalogRef) Error!LoadedRecord {
            const page_id = std.math.cast(CacheT.Pid, ref.getPageId()) orelse return error.BadCatalogChain;
            var record = try self.chain.loadRef(.{
                .page_id = page_id,
                .slot_id = ref.getSlotId(),
            });
            errdefer record.deinit();
            const view = try catalog_record.read(try record.value());
            if (view.revision != ref.getRecordRevision()) return error.BadCatalogChain;
            return .{ .record = record, .expected_revision = ref.getRecordRevision() };
        }

        pub fn iterator(self: *Self, record_count: u64) Error!Iterator {
            return .{
                .chain_iterator = try self.chain.iterator(),
                .remaining = record_count,
            };
        }

        /// Removes every catalog record and releases empty chain pages.
        pub fn removeAll(self: *Self) Error!usize {
            const Remove = struct {
                fn call(_: void, _: anytype, _: usize, _: []const u8) error{}!bool {
                    return true;
                }
            };
            return self.chain.removeIf({}, Remove.call);
        }

        pub fn releaseCachedTail(self: *Self) void {
            self.chain.releaseCachedTail();
        }

        /// Collects unique physical pages containing the current catalog chain.
        pub fn collectPageIds(self: *Self, allocator: std.mem.Allocator, record_count: u64) Error![]CacheT.Pid {
            var page_ids: std.ArrayList(CacheT.Pid) = .empty;
            errdefer page_ids.deinit(allocator);
            var catalog_iterator = try self.iterator(record_count);
            defer catalog_iterator.deinit();
            while (try catalog_iterator.next()) |entry| {
                const page_id = std.math.cast(CacheT.Pid, entry.ref.getPageId()) orelse
                    return error.BadCatalogChain;
                var found = false;
                for (page_ids.items) |existing| {
                    if (existing == page_id) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try page_ids.append(allocator, page_id);
                }
            }
            return try page_ids.toOwnedSlice(allocator);
        }
    };
}
