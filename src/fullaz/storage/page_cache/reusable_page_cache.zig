const std = @import("std");
const page_cache_contract = @import("../../contracts/page_cache.zig");

/// Adds transaction-safe reuse of caller-supplied physical page IDs to an
/// append-only transactional cache. Reused pages are returned to the pool if
/// the surrounding write batch rolls back.
pub fn ReusablePageCache(comptime InnerCacheT: type, comptime PoolT: type) type {
    comptime page_cache_contract.requiresTransactionalPageCache(InnerCacheT);

    return struct {
        const Self = @This();

        pub const Handle = InnerCacheT.Handle;
        pub const Pid = InnerCacheT.Pid;
        pub const PidPolicyType = InnerCacheT.PidPolicyType;
        pub const BackingFork = InnerCacheT.BackingFork;
        pub const Error = InnerCacheT.Error || std.mem.Allocator.Error;
        pub const append_only_dense_page_ids = false;

        pub const WriteBatch = struct {
            cache: *Self,
            inner: InnerCacheT.WriteBatch,
            reused_start: usize,
            active: bool = true,

            pub fn commit(self: *WriteBatch) Error!void {
                if (!self.active) {
                    return error.TransactionInactive;
                }
                try self.inner.commit();
                self.cache.reused_pages.shrinkRetainingCapacity(self.reused_start);
                self.active = false;
            }

            pub fn discard(self: *WriteBatch) Error!void {
                if (!self.active) {
                    return error.TransactionInactive;
                }
                try self.inner.discard();
                for (self.cache.reused_pages.items[self.reused_start..]) |page_id| {
                    try self.cache.pool.put(page_id);
                }
                self.cache.reused_pages.shrinkRetainingCapacity(self.reused_start);
                self.active = false;
            }
        };

        inner: *InnerCacheT,
        pool: *PoolT,
        allocator: std.mem.Allocator,
        reused_pages: std.ArrayList(Pid) = .empty,
        reused_page_count: u64 = 0,

        pub fn init(inner: *InnerCacheT, pool: *PoolT, allocator: std.mem.Allocator) Self {
            return .{
                .inner = inner,
                .pool = pool,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.reused_pages.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            return self.inner.getTemporaryPage();
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            return .{
                .cache = self,
                .inner = try self.inner.begin(),
                .reused_start = self.reused_pages.items.len,
            };
        }

        pub fn fetch(self: *Self, page_id: Pid) Error!Handle {
            return self.inner.fetch(page_id);
        }

        pub fn create(self: *Self) Error!Handle {
            const page_id = self.pool.take() orelse return self.inner.create();
            errdefer self.pool.put(page_id) catch {};
            try self.reused_pages.append(self.allocator, page_id);
            errdefer {
                _ = self.reused_pages.pop();
            }
            var handle = try self.inner.fetch(page_id);
            errdefer handle.deinit();
            @memset(try handle.dataMut(), 0);
            self.reused_page_count += 1;
            return handle;
        }

        pub fn prepareBackingFork(
            self: *Self,
            source_pid: Pid,
            context: PidPolicyType.RemapContextType,
        ) Error!?BackingFork {
            const target_pid = self.pool.take() orelse {
                return self.inner.prepareBackingFork(source_pid, context);
            };
            var target_owned = true;
            errdefer if (target_owned) {
                self.pool.put(target_pid) catch {};
            };
            const fork = try self.inner.prepareBackingForkTo(source_pid, target_pid, context);
            if (fork) |pending| {
                try self.reused_pages.append(self.allocator, target_pid);
                target_owned = false;
                self.reused_page_count += 1;
                return pending;
            }
            target_owned = false;
            try self.pool.put(target_pid);
            return null;
        }

        pub fn commitBackingFork(self: *Self, fork: *BackingFork) void {
            self.inner.commitBackingFork(fork);
        }

        pub fn discardBackingFork(self: *Self, fork: *BackingFork) void {
            self.inner.discardBackingFork(fork);
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

        pub fn pageCount(self: *const Self) usize {
            return self.inner.pageCount();
        }

        pub fn isPinned(self: *const Self, page_id: Pid) Error!bool {
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

        pub fn reusedPageCount(self: *const Self) u64 {
            return self.reused_page_count;
        }

        comptime {
            page_cache_contract.requiresTransactionalPageCache(Self);
        }
    };
}
