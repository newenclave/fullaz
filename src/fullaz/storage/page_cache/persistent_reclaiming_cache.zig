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
            const Phase = enum {
                active,
                root_restored,
                inactive,
            };

            cache: *Self,
            inner: InnerCacheT.WriteBatch,
            root_snapshot: ?PageId,
            phase: Phase = .active,

            pub fn commit(self: *WriteBatch) Error!void {
                if (self.phase != .active) {
                    return Error.TransactionInactive;
                }
                self.inner.commit() catch |err| {
                    if (!self.cache.inner.transactionActive()) {
                        self.phase = .inactive;
                    }
                    return err;
                };
                self.phase = .inactive;
            }

            pub fn discard(self: *WriteBatch) Error!void {
                if (self.phase == .inactive) {
                    return Error.TransactionInactive;
                }
                if (self.phase == .active) {
                    try self.cache.store.setRoot(self.root_snapshot);
                    self.phase = .root_restored;
                }
                self.inner.discard() catch |err| {
                    if (!self.cache.inner.transactionActive()) {
                        self.phase = .inactive;
                    }
                    return err;
                };
                self.phase = .inactive;
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
                var handle = self.inner.fetch(page_id) catch |err| {
                    self.inner.markTransactionFailed();
                    return err;
                };
                errdefer handle.deinit();
                const bytes = handle.dataMut() catch |err| {
                    self.inner.markTransactionFailed();
                    return err;
                };
                @memset(bytes, 0);
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
            self.store.setRoot(page_id) catch |err| {
                self.inner.markTransactionFailed();
                return err;
            };
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
                if (steps >= page_count) {
                    return Error.BadFreeList;
                }
                current = try self.nextFreePage(page_id);
                steps += 1;
            }
        }

        fn pop(self: *Self) Error!?PageId {
            const head = self.store.getRoot() orelse return null;
            const next = try self.nextFreePage(head);
            try self.store.setRoot(next);
            return head;
        }

        fn isFree(self: *Self, page_id: PageId) Error!bool {
            var current = self.store.getRoot();
            var steps: usize = 0;
            const max_steps = self.store.pageCount();
            while (current) |candidate| {
                if (candidate == page_id) {
                    return true;
                }
                if (steps >= max_steps) {
                    return Error.BadFreeList;
                }
                current = try self.nextFreePage(candidate);
                steps += 1;
            }
            return false;
        }

        fn nextFreePage(self: *Self, page_id: PageId) Error!?PageId {
            try self.validateFreePageId(page_id);
            var handle = try self.inner.fetch(page_id);
            defer handle.deinit();
            const bytes = try handle.data();
            if (bytes.len < @sizeOf(FreedView.FreedHeader)) {
                return Error.BadFreeList;
            }
            const header = FreedView.init(bytes).header();
            if (header.kind.get() != std.math.maxInt(u16)) {
                return Error.BadFreeList;
            }
            const next = header.next.get();
            if (next == nil) {
                return null;
            }
            try self.validateFreePageId(next);
            if (next == page_id) {
                return Error.BadFreeList;
            }
            return next;
        }

        fn validateFreePageId(self: *const Self, page_id: PageId) Error!void {
            const page_index = std.math.cast(usize, page_id) orelse return Error.BadFreeList;
            if (page_id == nil or page_index >= self.store.pageCount() or self.store.isReserved(page_id)) {
                return Error.BadFreeList;
            }
        }

        comptime {
            page_cache_contract.requiresTransactionalPageCache(Self);
        }
    };
}
