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
        false,
        Endian,
    );
}

pub fn HandleImpl(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime forward_only: bool,
    comptime Endian: std.builtin.Endian,
) type {
    if (forward_only) {
        return HandleForwardImpl(
            PageCacheType,
            StorageManager,
            AdditionalT,
            SubheaderT,
            Endian,
        );
    } else {
        return HandleBidirectionalImpl(
            PageCacheType,
            StorageManager,
            AdditionalT,
            SubheaderT,
            Endian,
        );
    }
}

pub fn HandleForwardImpl(
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
    const has_tail = @hasDecl(StorageManager, "getLast") and @hasDecl(StorageManager, "setLast");

    const EmptyStruct = extern struct {};
    const SubheaderType = if (SubheaderT == void) EmptyStruct else SubheaderT;

    _ = PosType;

    const ViewType = view.ViewImpl(
        BlockIdType,
        IndexT,
        AdditionalT,
        true,
        Endian,
        false,
    );
    const ViewTypeConst = view.ViewImpl(
        BlockIdType,
        IndexT,
        AdditionalT,
        true,
        Endian,
        true,
    );

    const ChunkView = ViewType.Chunk;
    const ChunkViewConst = ViewTypeConst.Chunk;

    const ChunkHandle = struct {
        const Self = @This();
        pub const Error = PageCacheType.Error;

        ph: PageHandle = undefined,

        pub fn init(ph: PageHandle) Self {
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

        pub fn getPage(self: *const Self) Error![]const u8 {
            return self.ph.getData();
        }

        pub fn getPageMut(self: *Self) Error![]u8 {
            return self.ph.getDataMut();
        }

        pub fn getData(self: *const Self) Error![]const u8 {
            const cv = try self.getView();
            return cv.data();
        }

        pub fn getDataMut(self: *Self) Error![]u8 {
            var cv = try self.getViewMut();
            return cv.dataMut();
        }

        pub fn getNext(self: *Self) Error!?BlockIdType {
            const cv = try self.getView();
            return cv.getNext();
        }

        pub fn setNext(self: *Self, pid: ?BlockIdType) Error!void {
            var cv = try self.getViewMut();
            cv.setNext(pid);
        }

        pub fn id(self: *const Self) Error!BlockIdType {
            return self.ph.pid();
        }

        pub fn subheader(self: *Self) Error!*const SubheaderType {
            const cv = try self.getView();
            return @ptrCast(cv.subheader());
        }

        pub fn header(self: *const Self) Error!*const ViewTypeConst.PageHeader {
            const cv = try self.getView();
            return @ptrCast(cv.header());
        }

        pub fn headerMut(self: *Self) Error!*ViewType.PageHeader {
            var cv = try self.getViewMut();
            return @ptrCast(cv.headerMut());
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
    };

    const Loader = struct {
        const Error = errors.PageError ||
            ChunkHandle.Error ||
            PageCacheType.Error ||
            ViewTypeConst.PageView.Error;

        fn load(page_cache: *PageCacheType, page_kind: u16, pid: BlockIdType) Error!ChunkHandle {
            var page_handle = try page_cache.fetch(pid);
            errdefer page_handle.deinit();
            const cv = ViewTypeConst.Chunk.init(try page_handle.getData());
            try cv.pageView().validateTyped();
            if (cv.header().kind.get() != page_kind) {
                return Error.BadType;
            }
            return ChunkHandle.init(page_handle);
        }
    };

    const IteratorImpl = struct {
        const Self = @This();
        pub const Error = Loader.Error;

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
        page_kind: u16,
        prev: ?ChunkHandle,
        page: ?ChunkHandle,
        cursor: Cursor,

        fn init(page_cache: *PageCacheType, page_kind: u16, page_id: BlockIdType, cursor: Cursor) Error!Self {
            return .{
                .page_cache = page_cache,
                .page_kind = page_kind,
                .prev = null,
                .page = try Loader.load(page_cache, page_kind, page_id),
                .cursor = cursor,
            };
        }

        fn initEmpty(page_cache: *PageCacheType, page_kind: u16) Self {
            return .{
                .page_cache = page_cache,
                .page_kind = page_kind,
                .prev = null,
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
                .value = try page.getData(),
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
                var next_page = try Loader.load(self.page_cache, self.page_kind, pid);
                errdefer next_page.deinit();
                if (self.prev) |*prev| {
                    prev.deinit();
                }
                self.prev = self.page;
                self.page = next_page;
                return;
            }
            self.cursor = .after_last;
        }

        pub fn deinit(self: *Self) void {
            if (self.prev) |*prev| {
                prev.deinit();
            }
            self.prev = null;
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
            PageCacheType.Error ||
            ViewTypeConst.PageView.Error;

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

        pub fn cache(self: *const Self) *const PageCacheType {
            return self.page_cache;
        }
        pub fn cacheMut(self: *Self) *PageCacheType {
            return self.page_cache;
        }

        pub fn manager(self: *const Self) *const StorageManager {
            return self.mgr;
        }
        pub fn managerMut(self: *Self) *StorageManager {
            return self.mgr;
        }

        pub fn iterator(self: *const Self) Error!Iterator {
            if (try self.mgr.getFirst()) |page_id| {
                return self.iteratorOn(page_id);
            } else {
                return IteratorImpl.initEmpty(self.page_cache, self.settings.chunk_page_kind);
            }
        }

        fn iteratorOn(self: *const Self, page_id: PageId) Error!IteratorImpl {
            return IteratorImpl.init(self.page_cache, self.settings.chunk_page_kind, page_id, .{ .on = 0 });
        }

        /// Takes ownership of itr. On success, the returned iterator replaces it.
        pub fn remove(self: *Self, itr: Iterator) Error!Iterator {
            var current_itr = itr;
            errdefer current_itr.deinit();
            if (current_itr.cursor != .on) {
                return Error.InvalidIterator;
            }
            var current = current_itr.page orelse return Error.InvalidIterator;
            const next = try current.getNext();

            var replacement = if (next) |next_id|
                try IteratorImpl.init(self.page_cache, self.settings.chunk_page_kind, next_id, .{ .on = 0 })
            else
                IteratorImpl.initEmpty(self.page_cache, self.settings.chunk_page_kind);
            errdefer replacement.deinit();

            var previous = current_itr.prev;
            current_itr.prev = null;
            errdefer {
                if (previous) |*prev| {
                    prev.deinit();
                }
            }
            if (previous) |*prev| {
                try prev.setNext(next);
            } else {
                try self.mgr.setFirst(next);
            }

            if (next == null) {
                if (comptime has_tail) {
                    try self.mgr.setLast(if (previous) |*prev| try prev.id() else null);
                }
            }

            var removed = current;
            try removed.setNext(null);
            current_itr.page = null;
            try self.destroyChunk(removed);

            if (next != null) {
                replacement.prev = previous;
            } else if (previous) |*prev| {
                prev.deinit();
            }
            return replacement;
        }

        pub fn removeById(self: *Self, pid: PageId) Error!bool {
            var itr = try self.iterator();
            while (true) {
                const result = (try itr.get()) orelse {
                    itr.deinit();
                    return false;
                };
                if (result.page_id == pid) {
                    var replacement = try self.remove(itr);
                    replacement.deinit();
                    return true;
                }
                try itr.next();
            }
        }

        pub fn loadChunk(self: *const Self, pid: PageId) Error!ChunkHandle {
            return Loader.load(self.page_cache, self.settings.chunk_page_kind, pid);
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
            if (first == null) {
                if (comptime has_tail) {
                    try self.mgr.setLast(chunk_id);
                }
            }
            try ch.setNext(first);
            try self.mgr.setFirst(chunk_id);
        }

        // Uses a manager tail in O(1) when available; otherwise traverses from root in O(n).
        pub fn insertLast(self: *Self, ch: *ChunkHandle) Error!void {
            if (comptime has_tail) {
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
                try ch.setNext(null);
                try self.mgr.setLast(chunk_id);
            } else {
                const chunk_id = try ch.id();
                var current_id = (try self.mgr.getFirst()) orelse {
                    try ch.setNext(null);
                    try self.mgr.setFirst(chunk_id);
                    return;
                };

                while (true) {
                    current_id = blk: {
                        var current = try self.loadChunk(current_id);
                        defer current.deinit();
                        if (try current.getNext()) |next_id| {
                            break :blk next_id;
                        }
                        try current.setNext(chunk_id);
                        try ch.setNext(null);
                        return;
                    };
                }
            }
        }

        // This call has O(n) complexity, as it needs to traverse
        // the list to find the chunk before the specified one.
        pub fn insertBefore(self: *Self, before_id: PageId, ch: *ChunkHandle) Error!void {
            const chunk_id = try ch.id();
            if (try self.mgr.getFirst()) |first_id| {
                if (first_id == before_id) {
                    return self.insertFirst(ch);
                }

                var current_id = first_id;
                while (true) {
                    current_id = blk: {
                        var current = try self.loadChunk(current_id);
                        defer current.deinit();
                        const next_id = (try current.getNext()) orelse return Error.InvalidId;
                        if (next_id == before_id) {
                            try ch.setNext(before_id);
                            try current.setNext(chunk_id);
                            return;
                        }
                        break :blk next_id;
                    };
                }
            }
            return Error.InvalidId;
        }

        pub fn insertAfter(self: *Self, after_id: PageId, ch: *ChunkHandle) Error!void {
            var after = try self.loadChunk(after_id);
            defer after.deinit();

            const next = try after.getNext();
            const chunk_id = try ch.id();
            try ch.setNext(next);
            try after.setNext(chunk_id);
            if (next == null) {
                if (comptime has_tail) {
                    try self.mgr.setLast(chunk_id);
                }
            }
        }
    };
}

pub fn HandleBidirectionalImpl(
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

    const has_tail = @hasDecl(StorageManager, "getLast") and @hasDecl(StorageManager, "setLast");

    _ = PosType;

    const ViewType = view.ViewImpl(
        BlockIdType,
        IndexT,
        AdditionalT,
        false,
        Endian,
        false,
    );
    const ViewTypeConst = view.ViewImpl(
        BlockIdType,
        IndexT,
        AdditionalT,
        false,
        Endian,
        true,
    );

    const ChunkView = ViewType.Chunk;
    const ChunkViewConst = ViewTypeConst.Chunk;

    const ChunkHandle = struct {
        const Self = @This();
        pub const Error = PageCacheType.Error;

        ph: PageHandle = undefined,

        pub fn init(ph: PageHandle) Self {
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

        pub fn getPage(self: *const Self) Error![]const u8 {
            return self.ph.getData();
        }

        pub fn getPageMut(self: *Self) Error![]u8 {
            return self.ph.getDataMut();
        }

        pub fn getData(self: *const Self) Error![]const u8 {
            const cv = try self.getView();
            return cv.data();
        }

        pub fn getDataMut(self: *Self) Error![]u8 {
            var cv = try self.getViewMut();
            return cv.dataMut();
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

        pub fn header(self: *const Self) Error!*const ViewTypeConst.PageHeader {
            const cv = try self.getView();
            return @ptrCast(cv.header());
        }

        pub fn headerMut(self: *Self) Error!*ViewType.PageHeader {
            var cv = try self.getViewMut();
            return @ptrCast(cv.headerMut());
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
    };

    const Loader = struct {
        const Error = errors.PageError ||
            ChunkHandle.Error ||
            PageCacheType.Error ||
            ViewTypeConst.PageView.Error;

        fn load(page_cache: *PageCacheType, page_kind: u16, pid: BlockIdType) Error!ChunkHandle {
            var page_handle = try page_cache.fetch(pid);
            errdefer page_handle.deinit();
            const cv = ViewTypeConst.Chunk.init(try page_handle.getData());
            try cv.pageView().validateTyped();
            if (cv.header().kind.get() != page_kind) {
                return Error.BadType;
            }
            return ChunkHandle.init(page_handle);
        }
    };

    const IteratorImpl = struct {
        const Self = @This();
        pub const Error = Loader.Error;

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
        page_kind: u16,
        page: ?ChunkHandle,
        cursor: Cursor,

        fn init(page_cache: *PageCacheType, page_kind: u16, page_id: BlockIdType, cursor: Cursor) Error!Self {
            return .{
                .page_cache = page_cache,
                .page_kind = page_kind,
                .page = try Loader.load(page_cache, page_kind, page_id),
                .cursor = cursor,
            };
        }

        fn initEmpty(page_cache: *PageCacheType, page_kind: u16) Self {
            return .{
                .page_cache = page_cache,
                .page_kind = page_kind,
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
                .value = try page.getData(),
                .page_id = try page.id(),
            };
        }

        pub fn chunkPtrMut(self: *Self) ?*ChunkHandle {
            if (self.page) |*page| {
                return page;
            }
            return null;
        }

        pub fn chunkPtr(self: *const Self) ?*const ChunkHandle {
            if (self.page) |*page| {
                return page;
            }
            return null;
        }

        pub fn cloneChunk(self: *const Self) Error!?ChunkHandle {
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
                var next_page = try Loader.load(self.page_cache, self.page_kind, pid);
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
                var prev_page = try Loader.load(self.page_cache, self.page_kind, pid);
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
            PageCacheType.Error ||
            ViewTypeConst.PageView.Error;

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

        pub fn cache(self: *const Self) *const PageCacheType {
            return self.page_cache;
        }
        pub fn cacheMut(self: *Self) *PageCacheType {
            return self.page_cache;
        }

        pub fn manager(self: *const Self) *const StorageManager {
            return self.mgr;
        }
        pub fn managerMut(self: *Self) *StorageManager {
            return self.mgr;
        }

        pub fn iterator(self: *const Self) Error!Iterator {
            if (try self.mgr.getFirst()) |page_id| {
                return self.iteratorOn(page_id);
            } else {
                return IteratorImpl.initEmpty(self.page_cache, self.settings.chunk_page_kind);
            }
        }

        pub fn iteratorFromEnd(self: *const Self) Error!Iterator {
            if (try self.lastId()) |page_id| {
                return IteratorImpl.init(self.page_cache, self.settings.chunk_page_kind, page_id, .{ .on = 0 });
            }
            return IteratorImpl.initEmpty(self.page_cache, self.settings.chunk_page_kind);
        }

        fn lastId(self: *const Self) Error!?PageId {
            if (comptime has_tail) {
                return self.mgr.getLast();
            }

            var current_id = (try self.mgr.getFirst()) orelse return null;
            while (true) {
                var current = try self.loadChunk(current_id);
                defer current.deinit();
                current_id = (try current.getNext()) orelse return current_id;
            }
        }

        fn iteratorOn(self: *const Self, page_id: PageId) Error!IteratorImpl {
            return IteratorImpl.init(self.page_cache, self.settings.chunk_page_kind, page_id, .{ .on = 0 });
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
                    try IteratorImpl.init(self.page_cache, self.settings.chunk_page_kind, next_id, .{ .on = 0 })
                else if (prev) |prev_id|
                    try IteratorImpl.init(self.page_cache, self.settings.chunk_page_kind, prev_id, .after_last)
                else
                    IteratorImpl.initEmpty(self.page_cache, self.settings.chunk_page_kind);
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
            return Loader.load(self.page_cache, self.settings.chunk_page_kind, pid);
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
                if (comptime has_tail) {
                    try self.mgr.setLast(chunk_id);
                }
            }
            try ch.setNext(first);
            try ch.setPrev(null);
            try self.mgr.setFirst(chunk_id);
        }

        pub fn insertLast(self: *Self, ch: *ChunkHandle) Error!void {
            if (comptime has_tail) {
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
            } else {
                const chunk_id = try ch.id();
                var current_id = (try self.mgr.getFirst()) orelse {
                    try ch.setPrev(null);
                    try ch.setNext(null);
                    try self.mgr.setFirst(chunk_id);
                    return;
                };

                while (true) {
                    current_id = blk: {
                        var current = try self.loadChunk(current_id);
                        defer current.deinit();
                        if (try current.getNext()) |next_id| {
                            break :blk next_id;
                        }
                        try current.setNext(chunk_id);
                        try ch.setPrev(current_id);
                        try ch.setNext(null);
                        return;
                    };
                }
            }
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
                if (comptime has_tail) {
                    try self.mgr.setLast(chunk_id);
                }
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
                if (comptime has_tail) {
                    try self.mgr.setLast(prev);
                }
            }

            try ch.setNext(null);
            try ch.setPrev(null);
        }
    };
}
