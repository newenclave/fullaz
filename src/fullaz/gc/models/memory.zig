const std = @import("std");
const bitset = @import("../../core/bitset.zig");
const gc = @import("../gc.zig");

/// In-memory GC model backed by a caller-provided page store.
pub fn Memory(comptime PageStoreT: type) type {
    const BitWord = u64;
    const BitSet = bitset.BitSet(BitWord, .little);

    return struct {
        const Self = @This();

        pub const PageId = usize;
        pub const Page = PageStoreT.Page;
        pub const Error = PageStoreT.Error ||
            std.mem.Allocator.Error ||
            BitSet.Error ||
            error{InvalidPageId};

        allocator_value: std.mem.Allocator,
        store: *PageStoreT,
        phase_value: gc.Phase = .idle,
        snapshot_page_count: usize = 0,
        prepare_cursor: usize = 0,
        sweep_cursor: usize = 0,
        registry_digest: u64 = 0,
        marked_bytes: []u8 = &.{},
        free_bytes: []u8 = &.{},
        queue: std.ArrayList(usize) = .empty,
        queue_head: usize = 0,

        pub fn init(allocator_value: std.mem.Allocator, store: *PageStoreT) Self {
            return .{ .allocator_value = allocator_value, .store = store };
        }

        pub fn deinit(self: *Self) void {
            self.allocator_value.free(self.marked_bytes);
            self.allocator_value.free(self.free_bytes);
            self.queue.deinit(self.allocator_value);
            self.* = undefined;
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.allocator_value;
        }

        pub fn isCycleActive(self: *const Self) bool {
            return self.phase_value != .idle;
        }

        pub fn beginCycle(self: *Self, registry_digest: u64) Error!usize {
            if (self.isCycleActive()) {
                return self.snapshot_page_count;
            }
            self.snapshot_page_count = self.store.pageCount();

            const byte_len = bitmapByteLen(self.snapshot_page_count);
            self.allocator_value.free(self.marked_bytes);
            self.allocator_value.free(self.free_bytes);

            self.marked_bytes = try self.allocator_value.alloc(u8, byte_len);
            errdefer self.allocator_value.free(self.marked_bytes);

            self.free_bytes = try self.allocator_value.alloc(u8, byte_len);

            @memset(self.marked_bytes, 0);
            @memset(self.free_bytes, 0);
            self.queue.clearRetainingCapacity();
            self.queue_head = 0;
            self.prepare_cursor = 0;
            self.sweep_cursor = 0;
            self.registry_digest = registry_digest;
            self.phase_value = .preparing;
            return self.snapshot_page_count;
        }

        pub fn phase(self: *const Self) gc.Phase {
            return self.phase_value;
        }

        pub fn setPhase(self: *Self, phase_value: gc.Phase) Error!void {
            self.phase_value = phase_value;
        }

        pub fn registryDigest(self: *const Self) Error!u64 {
            return self.registry_digest;
        }

        pub fn snapshotPageCount(self: *const Self) Error!usize {
            return self.snapshot_page_count;
        }

        pub fn prepare(self: *Self, maximum_pages: usize) Error!bool {
            const end = @min(self.prepare_cursor +| maximum_pages, self.snapshot_page_count);
            while (self.prepare_cursor < end) : (self.prepare_cursor += 1) {
                if (try self.store.isFree(self.prepare_cursor)) {
                    var free_set = try BitSet.initMutable(self.free_bytes, self.snapshot_page_count);
                    try free_set.set(self.prepare_cursor);
                }
            }
            return self.prepare_cursor == self.snapshot_page_count;
        }

        pub fn mark(self: *Self, page_id: usize) Error!bool {
            if (page_id >= self.snapshot_page_count) {
                return error.InvalidPageId;
            }
            var marks = try BitSet.initMutable(self.marked_bytes, self.snapshot_page_count);
            if (marks.isSet(page_id)) {
                return false;
            }
            try marks.set(page_id);
            return true;
        }

        pub fn isMarked(self: *const Self, page_id: usize) Error!bool {
            var marks = try BitSet.initConst(self.marked_bytes, self.snapshot_page_count);
            return marks.isSet(page_id);
        }

        pub fn enqueue(self: *Self, page_id: usize) Error!void {
            try self.queue.append(self.allocator_value, page_id);
        }

        pub fn dequeue(self: *Self) Error!?usize {
            if (self.queue_head == self.queue.items.len) {
                return null;
            }
            const page_id = self.queue.items[self.queue_head];
            self.queue_head += 1;
            return page_id;
        }

        pub fn fetchPage(self: *Self, page_id: usize) Error!Page {
            return self.store.fetchPage(page_id);
        }

        pub fn releasePage(self: *Self, page: *Page) void {
            self.store.releasePage(page);
        }

        pub fn pageKind(self: *Self, page: *Page, page_id: usize) Error!u16 {
            return self.store.pageKind(page, page_id);
        }

        pub fn pageData(self: *Self, page: *Page) Error![]const u8 {
            return self.store.pageData(page);
        }

        pub fn sweepCursor(self: *const Self) Error!usize {
            return self.sweep_cursor;
        }

        pub fn setSweepCursor(self: *Self, page_id: usize) Error!void {
            self.sweep_cursor = page_id;
        }

        pub fn isReserved(self: *Self, page_id: usize) Error!bool {
            return self.store.isReserved(page_id);
        }

        pub fn isFree(self: *Self, page_id: usize) Error!bool {
            if (page_id >= self.snapshot_page_count) {
                return error.InvalidPageId;
            }
            if (self.phase_value == .preparing or self.phase_value == .sweeping) {
                return self.store.isFree(page_id);
            }
            var free_set = try BitSet.initConst(self.free_bytes, self.snapshot_page_count);
            return free_set.isSet(page_id);
        }

        pub fn reclaim(self: *Self, page_id: usize) Error!void {
            return self.store.reclaim(page_id);
        }

        pub fn finishCycle(self: *Self) Error!void {
            return self.abortCycle();
        }

        /// Discards pending traversal work and returns the model to idle.
        pub fn abortCycle(self: *Self) Error!void {
            self.phase_value = .idle;
            self.queue.clearRetainingCapacity();
            self.queue_head = 0;
        }

        fn bitmapByteLen(page_count: usize) usize {
            const BitWordBits = @bitSizeOf(BitWord);
            const words = (page_count + BitWordBits - 1) / BitWordBits;
            return words * @sizeOf(BitWord);
        }
    };
}
