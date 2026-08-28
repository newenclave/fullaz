const std = @import("std");
const page_cache_contract = @import("../../contracts/page_cache.zig");
const interfaces = @import("../../contracts/interfaces.zig");
const freed = @import("../../page/freed.zig");

/// Adds a persistent, on-page free list to an append-only dense page cache.
/// The store owns the durable free-list root and must roll it back with the
/// surrounding metadata transaction if a write batch is discarded.
pub fn PersistentReclaimingCache(comptime InnerCacheT: type, comptime StoreT: type) type {
    comptime page_cache_contract.requiresAppendOnlyDensePageCache(InnerCacheT);
    comptime {
        if (!@hasDecl(StoreT, "PageId") or !@hasDecl(StoreT, "Error")) {
            @compileError("PersistentReclaimingCache store requires PageId and Error");
        }
        if (StoreT.PageId != InnerCacheT.Pid) {
            @compileError("PersistentReclaimingCache store PageId must match cache Pid");
        }
        interfaces.requiresFnSignature(StoreT, "getRoot", fn (*const StoreT) ?StoreT.PageId);
        interfaces.requiresFnSignature(StoreT, "setRoot", fn (*StoreT, ?StoreT.PageId) StoreT.Error!void);
        interfaces.requiresFnSignature(StoreT, "pageCount", fn (*const StoreT) usize);
        interfaces.requiresFnSignature(StoreT, "isReserved", fn (*const StoreT, StoreT.PageId) bool);
    }

    const PageId = InnerCacheT.Pid;
    const FreedView = freed.View(PageId, .little, true);
    const nil = std.math.maxInt(PageId);

    return struct {
        const Self = @This();

        pub const Handle = InnerCacheT.Handle;
        pub const Pid = PageId;
        pub const Error = InnerCacheT.Error || StoreT.Error || error{
            PageAlreadyFree,
            PageIdExhausted,
            PageNotAllocated,
            PageStillPinned,
            BadFreeList,
        };

        pub const WriteBatch = struct {
            cache: *Self,
            inner: InnerCacheT.WriteBatch,
            root_snapshot: ?PageId,
            active: bool = true,

            pub fn commit(self: *WriteBatch) Error!void {
                if (!self.active) {
                    return Error.TransactionInactive;
                }
                try self.inner.commit();
                self.active = false;
            }

            pub fn discard(self: *WriteBatch) Error!void {
                if (!self.active) {
                    return Error.TransactionInactive;
                }
                try self.inner.discard();
                try self.cache.store.setRoot(self.root_snapshot);
                self.active = false;
            }
        };

        inner: *InnerCacheT,
        store: *StoreT,

        pub fn init(inner: *InnerCacheT, store: *StoreT) Self {
            return .{ .inner = inner, .store = store };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            return self.inner.getTemporaryPage();
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            return .{
                .cache = self,
                .inner = try self.inner.begin(),
                .root_snapshot = self.store.getRoot(),
            };
        }

        pub fn fetch(self: *Self, page_id: PageId) Error!Handle {
            if (try self.isFree(page_id)) {
                return Error.PageNotAllocated;
            }
            return self.inner.fetch(page_id);
        }

        pub fn create(self: *Self) Error!Handle {
            if (try self.pop()) |page_id| {
                var handle = try self.inner.fetch(page_id);
                errdefer handle.deinit();
                @memset(try handle.dataMut(), 0);
                return handle;
            }
            const next_page_id = std.math.cast(PageId, self.store.pageCount()) orelse
                return Error.PageIdExhausted;
            if (next_page_id == nil) {
                return Error.PageIdExhausted;
            }
            return self.inner.create();
        }

        pub fn free(self: *Self, page_id: PageId) Error!void {
            const page_index = std.math.cast(usize, page_id) orelse return Error.PageNotAllocated;
            if (page_id == nil or
                page_index >= self.store.pageCount() or
                self.store.isReserved(page_id))
            {
                return Error.PageNotAllocated;
            }
            if (try self.inner.isPinned(page_id)) {
                return Error.PageStillPinned;
            }
            if (try self.isFree(page_id)) {
                return Error.PageAlreadyFree;
            }
            var handle = try self.inner.fetch(page_id);
            defer handle.deinit();

            const next = self.store.getRoot() orelse nil;
            const FreedMut = freed.View(PageId, .little, false);
            var view = FreedMut.init(try handle.dataMut());
            view.formatPage(next);
            try self.store.setRoot(page_id);
        }

        pub fn flush(self: *Self, page_id: PageId) Error!void {
            return self.inner.flush(page_id);
        }

        pub fn flushAll(self: *Self) Error!void {
            return self.inner.flushAll();
        }

        pub fn pageSize(self: *const Self) usize {
            return self.inner.pageSize();
        }

        pub fn pageCount(self: *const Self) usize {
            return self.store.pageCount();
        }

        pub fn isPinned(self: *const Self, page_id: PageId) Error!bool {
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

        /// Validates the persisted free-list before it is used after a reopen.
        pub fn validateFreeList(self: *Self) Error!void {
            var current = self.store.getRoot();
            var steps: usize = 0;
            const page_count = self.store.pageCount();
            while (current) |page_id| {
                const page_index = std.math.cast(usize, page_id) orelse return Error.BadFreeList;
                if (page_id == nil or
                    page_index >= page_count or
                    self.store.isReserved(page_id) or
                    steps >= page_count)
                {
                    return Error.BadFreeList;
                }
                var handle = try self.inner.fetch(page_id);
                defer handle.deinit();
                const next = FreedView.init(try handle.data()).header().next.get();
                current = if (next == nil) null else next;
                steps += 1;
            }
        }

        fn pop(self: *Self) Error!?PageId {
            const head = self.store.getRoot() orelse return null;
            var handle = try self.inner.fetch(head);
            defer handle.deinit();
            const next = FreedView.init(try handle.data()).header().next.get();
            try self.store.setRoot(if (next == nil) null else next);
            return head;
        }

        fn isFree(self: *Self, page_id: PageId) Error!bool {
            var current = self.store.getRoot();
            var steps: usize = 0;
            const max_steps = self.store.pageCount();
            while (current) |candidate| {
                if (candidate == nil or self.store.isReserved(candidate)) {
                    return Error.BadFreeList;
                }
                if (candidate == page_id) {
                    return true;
                }
                if (steps >= max_steps) {
                    return Error.BadFreeList;
                }
                var handle = try self.inner.fetch(candidate);
                defer handle.deinit();
                const next = FreedView.init(try handle.data()).header().next.get();
                current = if (next == nil) null else next;
                steps += 1;
            }
            return false;
        }

        comptime {
            page_cache_contract.requiresTransactionalPageCache(Self);
        }
    };
}
