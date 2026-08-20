const std = @import("std");
const page_cache_contract = @import("../contracts/page_cache.zig");

pub fn MemoryReclaimingCache(comptime InnerCacheT: type) type {
    comptime page_cache_contract.requiresPinAwarePageCache(InnerCacheT);

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

        comptime {
            page_cache_contract.requiresPageCache(Self);
        }
    };
}
