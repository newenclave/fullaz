const std = @import("std");
const page_cache_contract = @import("../contracts/page_cache.zig");

pub fn MemoryReclaimingCache(comptime InnerCacheT: type) type {
    comptime page_cache_contract.requiresAppendOnlyDensePageCache(InnerCacheT);

    return struct {
        const Self = @This();

        pub const Handle = InnerCacheT.Handle;
        pub const Pid = InnerCacheT.Pid;
        pub const UnderlyingDevice = InnerCacheT.UnderlyingDevice;
        pub const Error = InnerCacheT.Error ||
            std.mem.Allocator.Error ||
            error{
                PageAlreadyFree,
                PageIdExhausted,
                PageNotAllocated,
                PageStillPinned,
            };

        pub const WriteBatch = struct {
            cache: *Self,
            inner: InnerCacheT.WriteBatch,
            free_pages_snapshot: std.ArrayList(Pid),
            physical_page_count_snapshot: usize,
            active: bool = true,

            pub fn commit(self: *WriteBatch) Error!void {
                if (!self.active) {
                    return Error.TransactionInactive;
                }
                try self.inner.commit();
                self.free_pages_snapshot.deinit(self.cache.allocator);
                self.active = false;
            }

            pub fn discard(self: *WriteBatch) Error!void {
                if (!self.active) {
                    return Error.TransactionInactive;
                }
                try self.inner.discard();

                self.cache.free_pages.deinit(self.cache.allocator);
                self.cache.free_pages = self.free_pages_snapshot;
                self.free_pages_snapshot = .empty;
                self.cache.physical_page_count = self.physical_page_count_snapshot;
                self.active = false;
            }
        };

        allocator: std.mem.Allocator,
        inner: *InnerCacheT,
        free_pages: std.ArrayList(Pid) = .empty,
        physical_page_count: usize = 0,

        /// Starts tracking a fresh inner cache whose persistent pages are created through this wrapper.
        pub fn init(allocator: std.mem.Allocator, inner: *InnerCacheT) Self {
            return .{
                .allocator = allocator,
                .inner = inner,
            };
        }

        pub fn deinit(self: *Self) void {
            self.free_pages.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            return self.inner.getTemporaryPage();
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            var free_pages_snapshot: std.ArrayList(Pid) = .empty;
            errdefer free_pages_snapshot.deinit(self.allocator);
            try free_pages_snapshot.ensureTotalCapacity(
                self.allocator,
                self.physical_page_count,
            );
            free_pages_snapshot.appendSliceAssumeCapacity(self.free_pages.items);

            return .{
                .cache = self,
                .inner = try self.inner.begin(),
                .free_pages_snapshot = free_pages_snapshot,
                .physical_page_count_snapshot = self.physical_page_count,
            };
        }

        pub fn fetch(self: *Self, page_id: Pid) Error!Handle {
            if (std.mem.indexOfScalar(Pid, self.free_pages.items, page_id) != null) {
                return Error.PageNotAllocated;
            }
            return self.inner.fetch(page_id);
        }

        pub fn create(self: *Self) Error!Handle {
            if (self.free_pages.items.len > 0) {
                const page_id = self.free_pages.items[self.free_pages.items.len - 1];
                var handle = try self.inner.fetch(page_id);
                errdefer handle.deinit();
                @memset(try handle.dataMut(), 0);
                self.free_pages.items.len -= 1;
                return handle;
            }

            const next_page_id = std.math.cast(Pid, self.physical_page_count) orelse
                return Error.PageIdExhausted;
            if (next_page_id == std.math.maxInt(Pid)) {
                return Error.PageIdExhausted;
            }
            const next_page_count = std.math.add(
                usize,
                self.physical_page_count,
                1,
            ) catch return Error.PageIdExhausted;
            try self.free_pages.ensureTotalCapacity(self.allocator, next_page_count);

            const handle = try self.inner.create();
            const actual_page_id = handle.pid() catch
                @panic("Append-only dense page cache returned an invalid handle");
            if (actual_page_id != next_page_id) {
                @panic("Append-only dense page cache returned a non-sequential page ID");
            }
            self.physical_page_count = next_page_count;
            return handle;
        }

        /// Records an unpinned persistent page for reuse without allocating.
        pub fn free(self: *Self, page_id: Pid) Error!void {
            const page_index = std.math.cast(usize, page_id) orelse
                return Error.PageNotAllocated;
            if (page_index >= self.physical_page_count) {
                return Error.PageNotAllocated;
            }
            if (std.mem.indexOfScalar(Pid, self.free_pages.items, page_id) != null) {
                return Error.PageAlreadyFree;
            }
            if (self.inner.isPinned(page_id)) {
                return Error.PageStillPinned;
            }

            std.debug.assert(self.free_pages.items.len < self.free_pages.capacity);
            self.free_pages.appendAssumeCapacity(page_id);
        }

        pub fn flush(self: *Self, page_id: Pid) Error!void {
            return self.inner.flush(page_id);
        }

        pub fn flushAll(self: *Self) Error!void {
            return self.inner.flushAll();
        }

        pub fn pageSize(self: *const Self) usize {
            return self.inner.pageSize();
        }

        pub fn isPinned(self: *const Self, page_id: Pid) bool {
            return self.inner.isPinned(page_id);
        }

        pub fn transactionActive(self: *const Self) bool {
            return self.inner.transactionActive();
        }

        pub fn transactionGeneration(self: *const Self) ?u64 {
            return self.inner.transactionGeneration();
        }

        pub fn markTransactionFailed(self: *Self) void {
            self.inner.markTransactionFailed();
        }

        comptime {
            page_cache_contract.requiresTransactionalPageCache(Self);
        }
    };
}
