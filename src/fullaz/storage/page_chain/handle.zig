const std = @import("std");
const view = @import("view.zig");
const errors = @import("../../core/errors.zig");

pub const Settings = struct {
    chunk_page_kind: u16 = 0x51,
};

pub fn Handle(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime SubheaderT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HandleImpl(
        PageCacheType,
        StorageManager,
        void,
        SubheaderT,
        Endian,
    );
}

pub fn HandleImpl(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const PosType = StorageManager.Size;
    const IndexT = u16;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const EmptyStruct = extern struct {};
    const SubheaderType = if (SubheaderT == void) EmptyStruct else SubheaderT;

    _ = PosType;

    const ViewType = view.ViewImpl(BlockIdType, IndexT, AdditionalT, Endian, false);
    const ViewTypeConst = view.ViewImpl(BlockIdType, IndexT, AdditionalT, Endian, true);

    const ChunkView = ViewType.Chunk;
    const ChunkViewConst = ViewTypeConst.Chunk;

    const ChunkHandle = struct {
        const Self = @This();
        pub const Error = PageCacheType.Error;

        ph: PageHandle = undefined,

        fn init(ph: PageHandle) Self {
            return .{ .ph = ph };
        }

        pub fn clone(self: *const Self) Error!Self {
            return .{
                .ph = try self.ph.clone(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.ph.deinit();
        }

        fn getViewMut(self: *Self) Error!ChunkView {
            return ChunkView.init(try self.ph.getDataMut());
        }

        fn getView(self: *const Self) Error!ChunkViewConst {
            return ChunkViewConst.init(try self.ph.getData());
        }

        pub fn getNext(self: *Self) Error!?BlockIdType {
            const cv = try self.getView();
            return cv.getNext();
        }

        pub fn getPrev(self: *Self) Error!?BlockIdType {
            const cv = try self.getView();
            return cv.getPrev();
        }

        pub fn setNext(self: *Self, pid: ?BlockIdType) Error!void {
            var cv = try self.getViewMut();
            cv.setNext(pid);
        }

        pub fn setPrev(self: *Self, pid: ?BlockIdType) Error!void {
            var cv = try self.getViewMut();
            cv.setPrev(pid);
        }

        pub fn id(self: *const Self) Error!BlockIdType {
            return self.ph.pid();
        }

        pub fn subheader(self: *Self) Error!*const SubheaderType {
            const cv = try self.getView();
            return @ptrCast(cv.subheader());
        }

        pub fn subheaderMut(self: *Self) Error!*SubheaderType {
            var cv = try self.getViewMut();
            return @ptrCast(cv.subheaderMut());
        }

        pub fn metadata(self: *Self) Error![]const u8 {
            const cv = try self.getView();
            return cv.metadata();
        }

        pub fn metadataMut(self: *Self) Error![]u8 {
            var cv = try self.getViewMut();
            return cv.metadataMut();
        }

        pub fn data(self: *const Self) Error![]const u8 {
            const cv = try self.getView();
            return cv.data();
        }
    };

    const IteratorImpl = struct {
        const Self = @This();
        pub const Error = ChunkHandle.Error;

        const Cursor = union(enum) {
            before_first,
            on: usize,
            after_last,
        };

        pub const Result = struct {
            value: []const u8,
            page_id: BlockIdType,
        };

        page_cache: *PageCacheType,
        page: ?ChunkHandle,
        cursor: Cursor,

        fn init(page_cache: *PageCacheType, page_id: BlockIdType, cursor: Cursor) Error!Self {
            return .{
                .page_cache = page_cache,
                .page = ChunkHandle.init(try page_cache.fetch(page_id)),
                .cursor = cursor,
            };
        }

        fn initEmpty(page_cache: *PageCacheType) Self {
            return .{
                .page_cache = page_cache,
                .page = null,
                .cursor = .after_last,
            };
        }

        pub fn get(self: *const Self) Error!?Result {
            if (self.cursor == .before_first or self.cursor == .after_last) {
                return null;
            }
            const page = self.page orelse return null;
            return .{
                .value = try page.data(),
                .page_id = try page.id(),
            };
        }

        pub fn chunk(self: *const Self) Error!?ChunkHandle {
            const page = self.page orelse return null;
            return @as(?ChunkHandle, try page.clone());
        }

        pub fn next(self: *Self) Error!void {
            switch (self.cursor) {
                .after_last => return,
                .before_first => {
                    if (self.page != null) {
                        self.cursor = .{ .on = 0 };
                    }
                    return;
                },
                .on => {},
            }

            const next_pid = if (self.page) |*page| try page.getNext() else return;
            if (next_pid) |pid| {
                var next_page = ChunkHandle.init(try self.page_cache.fetch(pid));
                errdefer next_page.deinit();
                if (self.page) |*page| {
                    page.deinit();
                }
                self.page = next_page;
                return;
            }
            self.cursor = .after_last;
        }

        pub fn prev(self: *Self) Error!void {
            switch (self.cursor) {
                .before_first => return,
                .after_last => {
                    if (self.page != null) {
                        self.cursor = .{ .on = 0 };
                    }
                    return;
                },
                .on => {},
            }

            const prev_pid = if (self.page) |*page| try page.getPrev() else return;
            if (prev_pid) |pid| {
                var prev_page = ChunkHandle.init(try self.page_cache.fetch(pid));
                errdefer prev_page.deinit();
                if (self.page) |*page| {
                    page.deinit();
                }
                self.page = prev_page;
                return;
            }
            self.cursor = .before_first;
        }

        pub fn deinit(self: *Self) void {
            if (self.page) |*page| {
                page.deinit();
            }
            self.page = null;
        }
    };

    return struct {
        const Self = @This();
        pub const Error = errors.PageError ||
            errors.IteratorError ||
            ChunkHandle.Error ||
            StorageManager.Error ||
            PageCacheType.Error;

        pub const PageId = BlockIdType;
        pub const Chunk = ChunkHandle;
        pub const Subheader = SubheaderType;
        pub const Iterator = IteratorImpl;

        page_cache: *PageCacheType,
        mgr: *StorageManager,
        settings: Settings = .{},

        pub fn init(
            page_cache: *PageCacheType,
            storage_manager: *StorageManager,
            settings: Settings,
        ) Error!Self {
            return .{
                .page_cache = page_cache,
                .mgr = storage_manager,
                .settings = settings,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn iterator(self: *const Self) Error!Iterator {
            if (try self.mgr.getFirst()) |page_id| {
                return self.iteratorOn(page_id);
            } else {
                return IteratorImpl.initEmpty(self.page_cache);
            }
        }

        pub fn iteratorFromEnd(self: *const Self) Error!Iterator {
            if (try self.mgr.getLast()) |page_id| {
                return IteratorImpl.init(self.page_cache, page_id, .{ .on = 0 });
            } else {
                return IteratorImpl.initEmpty(self.page_cache);
            }
        }

        fn iteratorOn(self: *const Self, page_id: PageId) Error!IteratorImpl {
            return IteratorImpl.init(self.page_cache, page_id, .{ .on = 0 });
        }

        /// Takes ownership of itr. On success, the returned iterator replaces it.
        pub fn remove(self: *Self, itr: Iterator) Error!Iterator {
            var current_itr = itr;
            if (current_itr.cursor != .on) {
                return Error.InvalidIterator;
            }
            if (current_itr.page) |*current| {
                const next = try current.getNext();
                const prev = try current.getPrev();
                var replacement = if (next) |next_id|
                    try IteratorImpl.init(self.page_cache, next_id, .{ .on = 0 })
                else if (prev) |prev_id|
                    try IteratorImpl.init(self.page_cache, prev_id, .after_last)
                else
                    IteratorImpl.initEmpty(self.page_cache);
                errdefer replacement.deinit();

                try self.evictChunk(current);
                const removed = current_itr.page.?;
                current_itr.page = null;
                try self.destroyChunk(removed);
                return replacement;
            }
            return Error.InvalidIterator;
        }

        pub fn loadChunk(self: *const Self, pid: PageId) Error!ChunkHandle {
            const page_handle = try self.page_cache.fetch(pid);
            const cv = ViewTypeConst.Chunk.init(try page_handle.getData());
            if (cv.header().kind.get() != self.settings.chunk_page_kind) {
                return Error.BadType;
            }
            return ChunkHandle.init(page_handle);
        }

        pub fn createChunk(self: *Self) Error!ChunkHandle {
            var ph = try self.page_cache.create();
            errdefer ph.deinit();

            var ch = ChunkHandle.init(ph);
            var v = try ch.getViewMut();
            v.formatPage(
                self.settings.chunk_page_kind,
                try ph.pid(),
                @sizeOf(SubheaderType),
                0,
            );
            return ch;
        }

        pub fn destroyChunk(self: *Self, ch: ChunkHandle) Error!void {
            var owned_chunk = ch;
            defer owned_chunk.deinit();
            const pid = try owned_chunk.ph.pid();
            try self.mgr.destroyPage(pid);
        }

        pub fn insertFirst(self: *Self, ch: *ChunkHandle) Error!void {
            const first = try self.mgr.getFirst();
            const chunk_id = try ch.id();
            if (first) |first_pid| {
                var first_ch = try self.loadChunk(first_pid);
                defer first_ch.deinit();
                var first_view = try first_ch.getViewMut();
                first_view.setPrev(chunk_id);
            } else {
                try self.mgr.setLast(chunk_id);
            }
            try ch.setNext(first);
            try ch.setPrev(null);
            try self.mgr.setFirst(chunk_id);
        }

        pub fn insertLast(self: *Self, ch: *ChunkHandle) Error!void {
            const last = try self.mgr.getLast();
            const chunk_id = try ch.id();
            if (last) |last_pid| {
                var last_ch = try self.loadChunk(last_pid);
                defer last_ch.deinit();
                var last_view = try last_ch.getViewMut();
                last_view.setNext(chunk_id);
            } else {
                try self.mgr.setFirst(chunk_id);
            }
            try ch.setPrev(last);
            try ch.setNext(null);
            try self.mgr.setLast(chunk_id);
        }

        pub fn insertBefore(self: *Self, before_id: PageId, ch: *ChunkHandle) Error!void {
            var before = try self.loadChunk(before_id);
            defer before.deinit();

            const prev = try before.getPrev();
            const chunk_id = try ch.id();
            if (prev) |prev_id| {
                var prev_ch = try self.loadChunk(prev_id);
                defer prev_ch.deinit();
                try prev_ch.setNext(chunk_id);
            } else {
                try self.mgr.setFirst(chunk_id);
            }

            try ch.setPrev(prev);
            try ch.setNext(before_id);
            try before.setPrev(chunk_id);
        }

        pub fn insertAfter(self: *Self, after_id: PageId, ch: *ChunkHandle) Error!void {
            var after = try self.loadChunk(after_id);
            defer after.deinit();

            const next = try after.getNext();
            const chunk_id = try ch.id();
            if (next) |next_id| {
                var next_ch = try self.loadChunk(next_id);
                defer next_ch.deinit();
                try next_ch.setPrev(chunk_id);
            } else {
                try self.mgr.setLast(chunk_id);
            }

            try ch.setNext(next);
            try ch.setPrev(after_id);
            try after.setNext(chunk_id);
        }

        pub fn evictChunk(self: *Self, ch: *ChunkHandle) Error!void {
            const prev = try ch.getPrev();
            const next = try ch.getNext();

            if (prev) |prev_pid| {
                var prev_ch = try self.loadChunk(prev_pid);
                defer prev_ch.deinit();
                var prev_view = try prev_ch.getViewMut();
                prev_view.setNext(next);
            } else {
                try self.mgr.setFirst(next);
            }

            if (next) |next_pid| {
                var next_ch = try self.loadChunk(next_pid);
                defer next_ch.deinit();
                var next_view = try next_ch.getViewMut();
                next_view.setPrev(prev);
            } else {
                try self.mgr.setLast(prev);
            }

            try ch.setNext(null);
            try ch.setPrev(null);
        }
    };
}
