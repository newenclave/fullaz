const std = @import("std");
const view = @import("view.zig");
const page_header = @import("../../page/header.zig");
const interfaces = @import("../../contracts/contracts.zig");
const errors = @import("../../core/errors.zig");
const requiresStorageManager = @import("interfaces.zig").requiresStorageManager;

pub const Settings = struct {
    chunk_page_kind: u16 = 0x21,
};

// const StorageManager = struct {
//     const Error = error{};
//     const PageId = u64;
//     const Size = u64;
//     fn getTotalSize(self: *const StorageManager) Error!Size;
//     fn setTotalSize(self: *StorageManager, size: Size) Error!void;
//     fn getFirst(self: *const StorageManager) Error!?PageId;
//     fn getLast(self: *const StorageManager) Error!?PageId;
//     fn setFirst(self: *StorageManager, page_id: ?PageId) Error!void;
//     fn setLast(self: *StorageManager, page_id: ?PageId) Error!void;
//     fn destroyPage(self: *StorageManager, page_id: PageId) void;
// };

pub fn Handle(comptime PageCacheType: type, comptime StorageManager: type) type {
    comptime {
        interfaces.page_cache.requiresPageCache(PageCacheType);
        requiresStorageManager(StorageManager);
    }

    const PosType = StorageManager.Size;
    const Index = u16;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    //    const CommonPageView = page_header.View(BlockIdType, u16, .little, false);
    const CommonPageViewConst = page_header.View(BlockIdType, Index, .little, true);
    const ViewTypes = view.View(BlockIdType, Index, PosType, .little, false);
    const ViewTypesConst = view.View(BlockIdType, Index, PosType, .little, true);

    const CommonErrors = PageCacheType.Error ||
        StorageManager.Error ||
        errors.HandleError;

    const Context = struct {
        cache: *PageCacheType,
        mgr: *StorageManager,
        settings: Settings,
    };

    const ChunkImpl = struct {
        const Self = @This();
        const ViewType = ViewTypes.Chunk;
        const ViewTypeConst = ViewTypesConst.Chunk;
        const LinkType = ViewTypes.Link;
        const LinkTypeConst = ViewTypesConst.Link;

        const Error = errors.PageError;

        handle: PageHandle,
        fn init(ph: PageHandle) Self {
            return Self{
                .handle = ph,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        fn view(self: *const Self) Error!ViewTypeConst {
            return ViewTypeConst.init(try self.handle.getData());
        }

        fn viewMut(self: *Self) Error!ViewType {
            return ViewType.init(try self.handle.getDataMut());
        }

        fn getLink(self: *const Self) Error!LinkTypeConst {
            var v = try self.view();
            return v.getLink();
        }

        fn getLinkMut(self: *Self) Error!LinkType {
            var v = try self.viewMut();
            return v.getLinkMut();
        }

        fn pid(self: *const Self) Error!BlockIdType {
            return try self.handle.pid();
        }
    };

    const Cursor = struct {
        const Self = @This();
        pub const Error = PageCacheType.Error ||
            CommonErrors ||
            errors.PageError;

        const Link = ViewTypes.Link;
        const LinkConst = ViewTypesConst.Link;

        page: ?ChunkImpl,
        pos: Index,
        ctx: *const Context,

        pub fn init(page: PageHandle, pos: Index, ctx: *const Context) Self {
            return Self{
                .page = ChunkImpl.init(page),
                .pos = pos,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.page == null) {
                return;
            }
            if (self.page) |*ph| {
                ph.deinit();
            }
            self.page = null;
        }

        pub fn pid(self: *const Self) Error!BlockIdType {
            try self.testPage();
            const ph = self.page.?;
            return ph.pid();
        }

        pub fn getMaximumDataSize(self: *const Self) Error!Index {
            const data = try self.getData();
            return @intCast(data.len);
        }

        pub fn currentDataSize(self: *const Self) Error!Index {
            const link = try self.getLink();
            return link.getDataSize();
        }

        pub fn extendToPos(self: *Self) Error!Index {
            const max_size = try self.getMaximumDataSize();
            if (self.pos > max_size) {
                self.pos = max_size;
            }
            const current_pos = try self.currentDataSize();
            if (self.pos <= current_pos) {
                return 0;
            }
            var link = try self.getLinkMut();
            link.setDataSize(self.pos);
            return self.pos - current_pos;
        }

        pub fn setCurrentDataSize(self: *Self, size: Index) Error!void {
            var link = try self.getLinkMut();
            link.setDataSize(size);
        }

        pub fn currentTail(self: *const Self) Error![]const u8 {
            const data = try self.getData();
            const data_size = data.len;
            return data[self.pos..data_size];
        }

        pub fn currentTailMut(self: *Self) Error![]u8 {
            const data = try self.getDataMut();
            const data_size = data.len;
            return data[self.pos..data_size];
        }

        pub fn currentData(self: *const Self) Error![]const u8 {
            var link = try self.getLink();
            const data_size = link.getDataSize();
            const data = try self.getData();
            return data[@min(self.pos, data_size)..data_size];
        }

        pub fn currentDataMut(self: *Self) Error![]u8 {
            var link = try self.getLinkMut();
            const data_size = link.getDataSize();
            const data = try self.getDataMut();
            return data[@min(self.pos, data_size)..data_size];
        }

        pub fn hasNext(self: *const Self) Error!bool {
            const link = try self.getLink();
            return link.getFwd() != null;
        }

        pub fn hasPrev(self: *const Self) Error!bool {
            const link = try self.getLink();
            return link.getBack() != null;
        }

        pub fn movePrev(self: *Self) Error!void {
            const link = try self.getLink();
            const prev_pid = link.getBack();
            if (prev_pid == null) {
                return Error.InvalidId;
            }
            var prev_page = try self.ctx.cache.fetch(prev_pid.?);
            errdefer prev_page.deinit();

            const v = CommonPageViewConst.init(try prev_page.getData());
            const hdr = v.header();
            const kind = hdr.kind.get();
            if (kind == self.ctx.settings.chunk_page_kind) {
                self.deinit();
                self.page = ChunkImpl.init(prev_page);
            } else {
                return Error.InvalidId;
            }
            self.pos = 0;
        }

        pub fn moveNext(self: *Self) Error!void {
            const link = try self.getLink();
            const next_pid = link.getFwd();
            if (next_pid == null) {
                return Error.InvalidId;
            }
            var next_page = try self.ctx.cache.fetch(next_pid.?);
            errdefer next_page.deinit();

            const v = CommonPageViewConst.init(try next_page.getData());
            const hdr = v.header();
            const kind = hdr.kind.get();
            if (kind == self.ctx.settings.chunk_page_kind) {
                self.deinit();
                self.page = ChunkImpl.init(next_page);
            } else {
                return Error.InvalidId;
            }
            self.pos = 0;
        }

        pub fn isValid(self: *const Self) bool {
            return self.page != null;
        }

        fn testPage(self: *const Self) Error!void {
            if (self.page == null) {
                return Error.InvalidHandle;
            }
        }

        fn getLink(self: *const Self) Error!LinkConst {
            try self.testPage();
            if (self.page) |ph| {
                return ph.getLink();
            }
            return Error.InvalidHandle;
        }

        fn getLinkMut(self: *Self) Error!Link {
            try self.testPage();
            if (self.page) |*ph| {
                return ph.getLinkMut();
            }
            return Error.InvalidHandle;
        }

        fn getData(self: *const Self) Error![]const u8 {
            try self.testPage();
            if (self.page) |ph| {
                return (try ph.view()).getData();
            }
            return Error.InvalidHandle;
        }

        fn getDataMut(self: *Self) Error![]u8 {
            try self.testPage();
            if (self.page) |*ph| {
                var v = try ph.viewMut();
                return v.getDataMut();
            }
            return Error.InvalidHandle;
        }
    };

    return struct {
        const Self = @This();

        pub const Pid = BlockIdType;
        pub const Error = PageCacheType.Error ||
            CommonErrors ||
            errors.PageError ||
            errors.IndexError ||
            error{AlreadyExists};

        const Position = struct {
            page_id: ?Pid,
            pos: Index = 0,
            total_pos: usize = 0,
        };

        g_pos: Position = undefined,
        p_pos: Position = undefined,

        ctx: Context,

        pub const View = view.View;
        pub fn init(cache: *PageCacheType, mgr: *StorageManager, settings: Settings) Self {
            const ctx = Context{
                .cache = cache,
                .mgr = mgr,
                .settings = settings,
            };

            var start_pos: Position = .{
                .page_id = null,
                .pos = 0,
                .total_pos = 0,
            };

            if (try ctx.mgr.getFirst()) |first_page| {
                start_pos = .{
                    .page_id = first_page,
                    .pos = 0,
                    .total_pos = 0,
                };
            }

            const result = Self{
                .g_pos = start_pos,
                .p_pos = start_pos,
                .ctx = ctx,
            };
            return result;
        }

        pub fn deinit(_: *Self) void {
            // Clean up resources if needed
        }

        pub fn open(_: *Self) Error!void {}

        pub fn create(self: *Self) Error!void {
            if (try self.ctx.mgr.getFirst() != null) {
                return Error.AlreadyExists;
            }
            var ph = try self.createPage();
            defer ph.deinit();
            const pid = try ph.pid();
            try self.ctx.mgr.setFirst(pid);
            try self.ctx.mgr.setLast(pid);
            self.g_pos = Position{
                .page_id = pid,
                .pos = 0,
                .total_pos = 0,
            };
            self.p_pos = self.g_pos;
        }

        pub fn getp(self: *const Self) usize {
            return self.put_total_pos;
        }

        pub fn getg(self: *const Self) usize {
            return self.get_total_pos;
        }

        pub fn setp(self: *Self, pos: usize) Error!void {
            const position = try self.getPosition(pos);
            self.p_pos.page_id = position.page_id;
            self.p_pos.pos = @intCast(position.pos);
            self.p_pos.total_pos = position.total_pos;
        }

        pub fn setg(self: *Self, pos: usize) Error!void {
            const position = try self.getPosition(pos);
            self.g_pos.page_id = position.page_id;
            self.g_pos.pos = @intCast(position.pos);
            self.g_pos.total_pos = position.total_pos;
        }

        pub fn begin(self: *const Self) Error!Cursor {
            if (try self.ctx.mgr.getFirst()) |first_page| {
                return Cursor.init(try self.fetch(first_page), 0, &self.ctx);
            }
            return Error.InvalidHandle;
        }

        pub fn end(self: *const Self) Error!Cursor {
            if (try self.ctx.mgr.getLast()) |last_page| {
                var ph = try self.fetch(last_page);
                errdefer ph.deinit();
                const chunk_v = ViewTypesConst.Chunk.init(try ph.getData());
                const chunk_size = chunk_v.getLink().getDataSize();
                return Cursor.init(ph, chunk_size, &self.ctx);
            }
            return Error.InvalidHandle;
        }

        pub fn openPutCursor(self: *const Self) Error!Cursor {
            if (self.p_pos.page_id) |pid| {
                const ph = try self.fetch(pid);
                return Cursor.init(ph, self.p_pos.pos, &self.ctx);
            } else {
                return Cursor{
                    .page = null,
                    .pos = 0,
                    .ctx = &self.ctx,
                };
            }
        }

        fn openGetCursor(self: *const Self) Error!Cursor {
            if (self.g_pos.page_id) |pid| {
                const ph = try self.fetch(pid);
                return Cursor.init(ph, self.g_pos.pos, &self.ctx);
            }
            return Cursor{
                .page = null,
                .pos = 0,
                .ctx = &self.ctx,
            };
        }

        pub fn getPosition(self: *const Self, pos: usize) Error!Position {
            var cursor = try self.begin();
            defer cursor.deinit();

            var left_pos = pos;
            while (left_pos > 0) {
                const current_len = try cursor.currentDataSize();
                if (left_pos < current_len) {
                    return .{
                        .page_id = try cursor.pid(),
                        .pos = @as(Index, @intCast(left_pos)),
                        .total_pos = pos,
                    };
                }
                left_pos -= current_len;
                if (try cursor.hasNext()) {
                    try cursor.moveNext();
                } else {
                    break;
                }
            }
            return .{
                .page_id = try cursor.pid(),
                .pos = cursor.pos,
                .total_pos = pos - left_pos,
            };
        }

        pub fn read(self: *Self, buf: []u8) Error!usize {
            var cursor = try self.openGetCursor();
            defer cursor.deinit();
            var buf_tail = buf;
            var read_total: usize = 0;
            while (buf_tail.len > 0) {
                const current_data = try cursor.currentData();
                const to_read = @min(current_data.len, buf_tail.len);
                const data_to_read = current_data[0..to_read];
                @memcpy(buf_tail[0..to_read], data_to_read);

                read_total += to_read;
                cursor.pos += @intCast(to_read);
                self.g_pos.total_pos += to_read;

                buf_tail = buf_tail[to_read..];
                if (buf_tail.len > 0) {
                    if (!try cursor.hasNext()) {
                        break;
                    }
                    try cursor.moveNext();
                }
            }
            self.g_pos.page_id = try cursor.pid();
            self.g_pos.pos = cursor.pos;
            return read_total;
        }

        pub fn write(self: *Self, data: []const u8) Error!usize {
            var cursor = try self.openPutCursor();
            defer cursor.deinit();
            var data_tail = data;
            var written: usize = 0;
            while (data_tail.len > 0) {
                const has_next = try cursor.hasNext();
                var current_data = if (!has_next)
                    try cursor.currentTailMut()
                else
                    try cursor.currentDataMut();
                const to_write = @min(current_data.len, data_tail.len);
                const data_to_write = data_tail[0..to_write];
                @memcpy(current_data[0..to_write], data_to_write);

                written += to_write;
                cursor.pos += @intCast(to_write);
                self.p_pos.total_pos += to_write;

                const diff = try cursor.extendToPos();
                try self.ctx.mgr.setTotalSize(try self.ctx.mgr.getTotalSize() + diff);

                data_tail = data_tail[to_write..];
                if (data_tail.len > 0) {
                    if (!try cursor.hasNext()) {
                        try self.appendChunk();
                    }
                    try cursor.moveNext();
                }
            }
            self.p_pos.page_id = try cursor.pid();
            self.p_pos.pos = cursor.pos;
            return written;
        }

        fn fetch(self: *const Self, page_id: Pid) Error!PageHandle {
            var ph = try self.ctx.cache.fetch(page_id);
            errdefer ph.deinit();
            const pv = CommonPageViewConst.init(try ph.getData());
            if (pv.header().kind.get() != self.ctx.settings.chunk_page_kind) {
                return Error.InvalidId;
            }
            return ph;
        }

        pub fn totalSize(self: *const Self) Error!StorageManager.Size {
            const total_size = try self.ctx.mgr.getTotalSize();
            return total_size;
        }

        pub fn createPage(self: *Self) Error!PageHandle {
            var ph = try self.ctx.cache.create();
            errdefer ph.deinit();
            var pv = ViewTypes.Chunk.init(try ph.getDataMut());
            pv.formatPage(self.ctx.settings.chunk_page_kind, try ph.pid(), 0);
            return ph;
        }

        fn insertBefore(self: *Self, pid_before: Pid, ph: *PageHandle) Error!void {
            const pid = try ph.pid();

            const ph_before = try self.fetch(pid_before);
            defer ph_before.deinit();
            const pv_before_c = ViewTypesConst.Chunk.init(try ph_before.getData());

            const prev = pv_before_c.getPrev();
            if (prev) |prev_id| {
                const ph_prev = try self.fetch(prev_id);
                defer ph_prev.deinit();
                var pv_prev = ViewTypes.Chunk.init(try ph_prev.getDataMut());
                pv_prev.setNext(pid);
            } else {
                try self.ctx.mgr.setFirst(pid);
            }
            var pv = ViewTypes.Chunk.init(try ph.getDataMut());
            var pv_before = ViewTypes.Chunk.init(try ph_before.getDataMut());
            pv.setPrev(prev);
            pv.setNext(pid_before);
            pv_before.setPrev(pid);
        }

        fn insertAfter(self: *Self, pid_after: Pid, ph: *PageHandle) Error!void {
            const pid = try ph.pid();

            const ph_after = try self.fetch(pid_after);
            defer ph_after.deinit();
            const pv_after_c = ViewTypesConst.Chunk.init(try ph_after.getData());

            const next = pv_after_c.getNext();
            if (next) |next_id| {
                const ph_next = try self.fetch(next_id);
                defer ph_next.deinit();
                var pv_next = ViewTypes.Chunk.init(try ph_next.getDataMut());
                pv_next.setPrev(pid);
            } else {
                try self.ctx.mgr.setLast(pid);
            }
            var pv = ViewTypes.Chunk.init(try ph.getDataMut());
            var pv_after = ViewTypes.Chunk.init(try ph_after.getDataMut());
            pv.setNext(next);
            pv.setPrev(pid_after);
            pv_after.setNext(pid);
        }

        fn removeChunk(self: *Self, ph: *PageHandle) Error!void {
            var pv = ViewTypesConst.Chunk.init(try ph.getData());
            const prev = pv.getPrev();
            const next = pv.getNext();
            if (prev) |prev_id| {
                const ph_prev = try self.fetch(prev_id);
                defer ph_prev.deinit();
                var pv_prev = ViewTypes.Chunk.init(try ph_prev.getDataMut());
                pv_prev.setNext(next);
            } else {
                try self.ctx.mgr.setFirst(next);
            }
            if (next) |next_id| {
                const ph_next = try self.fetch(next_id);
                defer ph_next.deinit();
                var pv_next = ViewTypes.Chunk.init(try ph_next.getDataMut());
                pv_next.setPrev(prev);
            } else {
                try self.ctx.mgr.setLast(prev);
            }
            self.ctx.mgr.destroyPage(try ph.pid());
        }

        pub fn appendChunk(self: *Self) Error!void {
            var chunk = try self.appendGetChunk();
            defer chunk.deinit();
        }

        pub fn appendGetChunk(self: *Self) Error!ChunkImpl {
            var ph = try self.ctx.cache.create();
            errdefer ph.deinit();

            var v = ViewTypes.Chunk.init(try ph.getDataMut());
            v.formatPage(self.ctx.settings.chunk_page_kind, try ph.pid(), 0);

            const new_pid = try ph.pid();
            var last = new_pid;
            if (try self.ctx.mgr.getLast()) |last_page| {
                last = last_page;
            }

            var result = ChunkImpl.init(ph);

            if (last == new_pid) {
                // First chunk being added
                try self.ctx.mgr.setFirst(new_pid);
                try self.ctx.mgr.setLast(new_pid);
            } else {
                try self.pushChunkImpl(&result, last);
            }
            try self.ctx.mgr.setLast(new_pid);

            return result;
        }

        fn pushChunkImpl(self: *Self, chunk: *ChunkImpl, last: BlockIdType) Error!void {
            var cv = try chunk.viewMut();

            var last_chunk_ph = try self.loadPage(last, self.ctx.settings.chunk_page_kind);
            defer last_chunk_ph.deinit();

            var last_chunk = ChunkImpl.init(last_chunk_ph);
            var last_chunk_v = try last_chunk.viewMut();

            last_chunk_v.subheaderMut().link.fwd.set(try chunk.handle.pid());
            cv.subheaderMut().link.back.set(last);
        }

        fn loadPage(self: *const Self, pid: Pid, kind: u16) Error!PageHandle {
            var ph = try self.ctx.cache.fetch(pid);
            errdefer ph.deinit();
            const v = CommonPageViewConst.init(try ph.getData());
            const hdr = v.header();
            if (hdr.kind.get() != kind) {
                return Error.BadType;
            }
            return ph;
        }

        pub fn extend(self: *Self, len: usize) Error!void {
            var cursor = try self.end();
            defer cursor.deinit();
            var left = len;

            while (left > 0) {
                const current_size = try cursor.currentDataSize();
                const max_size = try cursor.getMaximumDataSize();
                const can_extend = max_size - current_size;
                if (can_extend >= left) {
                    const ileft = @as(Index, @intCast(left));
                    var link = try cursor.getLinkMut();
                    link.setDataSize(current_size + ileft);
                    try self.ctx.mgr.setTotalSize(try self.ctx.mgr.getTotalSize() + @as(StorageManager.Size, ileft));
                    break;
                } else {
                    var link = try cursor.getLinkMut();
                    link.setDataSize(max_size);
                    try self.ctx.mgr.setTotalSize(try self.ctx.mgr.getTotalSize() + @as(StorageManager.Size, @intCast(can_extend)));
                    left -= @intCast(can_extend);
                    if (try cursor.hasNext()) {
                        try cursor.moveNext();
                    } else {
                        try self.appendChunk();
                        try cursor.moveNext();
                    }
                }
            }
        }

        pub fn truncate(self: *Self, len: usize) Error!void {
            var cursor = try self.end();
            defer cursor.deinit();
            var left = len;
            while (left > 0) {
                const current_size = try cursor.currentDataSize();
                if (left < current_size) {
                    const total = try self.ctx.mgr.getTotalSize();
                    const new_total = total - left;
                    try self.ctx.mgr.setTotalSize(@as(StorageManager.Size, @intCast(new_total)));
                    const new_current = current_size - @as(Index, @intCast(left));
                    try cursor.setCurrentDataSize(new_current);
                    if (self.g_pos.total_pos >= new_total) {
                        self.g_pos.total_pos = new_total;
                        self.g_pos.page_id = try cursor.pid();
                        self.g_pos.pos = new_current;
                    }
                    if (self.p_pos.total_pos >= new_total) {
                        self.p_pos.total_pos = new_total;
                        self.p_pos.page_id = try cursor.pid();
                        self.p_pos.pos = new_current;
                    }
                    break;
                }
                left -= current_size;
                try self.ctx.mgr.setTotalSize(try self.ctx.mgr.getTotalSize() - @as(StorageManager.Size, @intCast(current_size)));

                if (!try cursor.hasPrev()) {
                    try self.ctx.mgr.setTotalSize(0);
                    try cursor.setCurrentDataSize(0);
                    self.g_pos = .{
                        .page_id = try cursor.pid(),
                        .pos = 0,
                        .total_pos = 0,
                    };
                    self.p_pos = self.g_pos;
                    break;
                } else {
                    try cursor.movePrev();
                    try self.popChunk();
                }
            }
        }

        pub fn writePage(self: *Self, ph: *PageHandle, pos: Index, data: []const u8) Error!usize {
            const page_data = try ph.getDataMut();
            var pv = ViewTypes.Chunk.init(page_data);
            const chunk_data = pv.getDataMut();
            const max_size = chunk_data.len;
            if (pos > max_size) {
                return Error.OutOfBounds;
            }
            const end_pos = @as(usize, @intCast(pos)) + data.len;
            const target_pos = if (end_pos > max_size) max_size else end_pos;
            const target_len = target_pos - @as(usize, @intCast(pos));
            const target_slice = chunk_data[pos..target_pos];
            @memcpy(target_slice, data[0..target_len]);
            const current_size = pv.getSize();
            if (target_pos > current_size) {
                pv.setSize(@intCast(target_pos));
                const size_diff = target_pos - current_size;
                try self.ctx.mgr.setTotalSize(try self.ctx.mgr.getTotalSize() + @as(StorageManager.Size, @intCast(size_diff)));
            }
            return target_len;
        }

        pub fn readPage(_: *const Self, ph: *PageHandle, pos: Index, data: []u8) Error!usize {
            const page_data = try ph.getDataMut();
            var pv = ViewTypesConst.Chunk.init(page_data);
            const chunk_data = pv.getChunkData();
            const max_size = chunk_data.len;
            if (pos > max_size) {
                return Error.OutOfBounds;
            }
            const end_pos = @as(usize, @intCast(pos)) + data.len;
            const target_pos = if (end_pos > max_size) max_size else end_pos;
            const target_len = target_pos - @as(usize, @intCast(pos));
            const target_slice = data[0..target_len];
            @memcpy(target_slice, chunk_data[pos..target_pos]);
            return target_len;
        }

        pub fn popChunk(self: *Self) Error!void {
            if (try self.ctx.mgr.getLast() == null) {
                return;
            }
            const last = (try self.ctx.mgr.getLast()).?;
            const first = (try self.ctx.mgr.getFirst()).?;

            var last_chunk_ph = try self.loadPage(last, self.ctx.settings.chunk_page_kind);
            defer last_chunk_ph.deinit();

            var last_chunk = ChunkImpl.init(last_chunk_ph);
            var last_chunk_v = try last_chunk.viewMut();
            var last_chunk_l = last_chunk_v.getLinkMut();
            const prev = last_chunk_l.link.back.get();

            if (prev == first) {
                return;
                // Removing the last chunk
            } else {
                try self.ctx.mgr.setLast(prev);
                try self.popImpl(prev);
            }
            try self.ctx.mgr.destroyPage(last);
        }

        fn popImpl(self: *Self, prev: BlockIdType) Error!void {
            var prev_h = try self.loadPage(prev, self.ctx.settings.chunk_page_kind);
            defer prev_h.deinit();
            var prev_chunk = ChunkImpl.init(prev_h);
            var prev_v = try prev_chunk.viewMut();
            var prev_l = prev_v.getLinkMut();
            prev_l.setFwd(null);
        }

        pub fn getView(_: *const Self, ph: *PageHandle) Error!ViewTypesConst.Chunk {
            const page_data = try ph.getData();
            return ViewTypesConst.Chunk.init(page_data);
        }

        pub fn getViewMut(_: *const Self, ph: *PageHandle) Error!ViewTypes.Chunk {
            const page_data = try ph.getDataMut();
            return ViewTypes.Chunk.init(page_data);
        }
    };
}
