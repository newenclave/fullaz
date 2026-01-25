const std = @import("std");
const view = @import("view.zig");
const page_header = @import("../../page/header.zig");
const interfaces = @import("../../contracts/contracts.zig");
const errors = @import("../../core/errors.zig");

pub const Settings = struct {
    header_page_kind: u16 = 0x10,
    chunk_page_kind: u16 = 0x11,
};

pub fn Handle(comptime PageCacheType: type, comptime StorageManager: type) type {
    comptime {
        interfaces.page_cache.requiresPageCache(PageCacheType);
        interfaces.storage_manager.requiresStorageManager(StorageManager);
    }

    const PosType = u32;
    const Index = u16;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    //    const CommonPageView = page_header.View(BlockIdType, u16, .little, false);
    const CommonPageViewConst = page_header.View(BlockIdType, Index, .little, true);
    const ViewTypes = view.View(BlockIdType, Index, PosType, .little, false);
    const ViewTypesConst = view.View(BlockIdType, Index, PosType, .little, true);

    const CommonErrors = PageCacheType.Error ||
        StorageManager.Error;

    const Context = struct {
        cache: *PageCacheType,
        mgr: *StorageManager,
        settings: Settings,
    };

    const HeaderImpl = struct {
        const Self = @This();
        const ViewType = ViewTypes.HeaderView;
        const ViewTypeConst = ViewTypesConst.HeaderView;

        const Error = errors.PageError ||
            CommonErrors;

        handle: PageHandle,
        fn init(ph: PageHandle) Self {
            return Self{
                .handle = ph,
            };
        }

        fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        fn view(self: *const Self) Error!ViewTypeConst {
            const data = try self.handle.getData();
            return ViewTypeConst.init(data);
        }

        fn viewMut(self: *Self) Error!ViewType {
            const data = try self.handle.getDataMut();
            return ViewType.init(data);
        }
    };

    const ChunkImpl = struct {
        const Self = @This();
        const ViewType = ViewTypes.ChunkView;
        const ViewTypeConst = ViewTypesConst.ChunkView;

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
    };

    const PageVariant = union(enum) {
        header: HeaderImpl,
        chunk: ChunkImpl,
    };

    const Cursor = struct {
        const Self = @This();
        pub const Error = PageCacheType.Error ||
            CommonErrors ||
            errors.PageError;

        const Link = ViewTypes.Link;
        const LinkConst = ViewTypesConst.Link;

        page: ?PageVariant,
        pos: Index,
        ctx: *const Context,

        pub fn init(page: PageVariant, pos: Index, ctx: *const Context) Self {
            return Self{
                .page = page,
                .pos = pos,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.page == null) {
                return;
            }
            switch (self.page.?) {
                .header => |hdr_const| {
                    var hdr = hdr_const;
                    hdr.deinit();
                },
                .chunk => |chk_const| {
                    var chk = chk_const;
                    chk.deinit();
                },
            }
            self.page = null;
        }

        pub fn pid(self: *const Self) Error!BlockIdType {
            try self.testPage();
            const ph = switch (self.page.?) {
                .header => |hdr| hdr.handle,
                .chunk => |chk| chk.handle,
            };
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
            if (self.page.? == .header) {
                return Error.InvalidHandle;
            }
            var prev_page = try self.ctx.cache.fetch(prev_pid.?);
            errdefer prev_page.deinit();

            const v = CommonPageViewConst.init(try prev_page.getData());
            const hdr = v.header();
            const kind = hdr.kind.get();
            if (kind == self.ctx.settings.header_page_kind) {
                self.deinit();
                self.page = .{ .header = HeaderImpl.init(prev_page) };
            } else if (kind == self.ctx.settings.chunk_page_kind) {
                self.deinit();
                self.page = .{ .chunk = ChunkImpl.init(prev_page) };
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
                self.page = .{ .chunk = ChunkImpl.init(next_page) };
            } else {
                return Error.InvalidId;
            }
            self.pos = 0;
        }

        pub fn isValid(self: *const Self) bool {
            return self.page != null;
        }

        pub fn isHeader(self: *const Self) Error!bool {
            try self.testPage();
            return self.page.? == .header;
        }

        pub fn isChunk(self: *const Self) Error!bool {
            try self.testPage();
            return self.page.? == .chunk;
        }

        fn testPage(self: *const Self) Error!void {
            if (self.page == null) {
                return Error.InvalidHandle;
            }
        }

        fn isHeaderPage(self: *const Self) Error!bool {
            try self.testPage();
            switch (self.page.?) {
                .header => |_| return true,
                .chunk => |_| return false,
            }
        }

        fn getLink(self: *const Self) Error!LinkConst {
            try self.testPage();
            switch (self.page.?) {
                .header => |hdr| {
                    var v = try hdr.view();
                    return v.getLink();
                },
                .chunk => |chk| {
                    var v = try chk.view();
                    return v.getLink();
                },
            }
        }

        fn getLinkMut(self: *Self) Error!Link {
            try self.testPage();
            switch (self.page.?) {
                .header => |hdr_const| {
                    var hdr = hdr_const;
                    var v = try hdr.viewMut();
                    return v.getLinkMut();
                },
                .chunk => |chk_const| {
                    var chk = chk_const;
                    var v = try chk.viewMut();
                    return v.getLinkMut();
                },
            }
        }

        fn getData(self: *const Self) Error![]const u8 {
            try self.testPage();
            switch (self.page.?) {
                .header => |hdr| {
                    var v = try hdr.view();
                    return v.data();
                },
                .chunk => |chk| {
                    var v = try chk.view();
                    return v.data();
                },
            }
        }

        fn getDataMut(self: *Self) Error![]u8 {
            try self.testPage();
            switch (self.page.?) {
                .header => |hdr_const| {
                    var hdr = hdr_const;
                    var v = try hdr.viewMut();
                    return v.dataMut();
                },
                .chunk => |chk_const| {
                    var chk = chk_const;
                    var v = try chk.viewMut();
                    return v.dataMut();
                },
            }
        }
    };

    return struct {
        const Self = @This();

        pub const Pid = BlockIdType;
        pub const Error = PageCacheType.Error ||
            CommonErrors ||
            errors.PageError;

        header_pid: ?Pid = null,
        get_page_pid: ?Pid = null,
        put_page_pid: ?Pid = null,
        get_pos: Index = 0,
        put_pos: Index = 0,
        get_total_pos: usize = 0,
        put_total_pos: usize = 0,
        ctx: Context,

        pub const View = view.View;
        pub fn init(cache: *PageCacheType, mgr: *StorageManager, settings: Settings) Self {
            return Self{
                .ctx = Context{
                    .cache = cache,
                    .mgr = mgr,
                    .settings = settings,
                },
            };
        }

        pub fn reset(self: *Self) void {
            self.header_pid = null;
            self.get_page_pid = null;
            self.put_page_pid = null;
            self.get_pos = 0;
            self.put_pos = 0;
            self.get_total_pos = 0;
            self.put_total_pos = 0;
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }

        pub fn create(self: *Self) Error!Pid {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var v = ViewTypes.HeaderView.init(try ph.getDataMut());
            v.formatPage(self.ctx.settings.header_page_kind, pid, 0);
            v.subheaderMut().link.back.set(pid);
            try self.ctx.mgr.setRoot(pid);
            return pid;
        }

        pub fn open(self: *Self) Error!void {
            const header_pid_opt = self.ctx.mgr.getRoot();
            if (header_pid_opt == null) {
                return Error.InvalidId;
            }
            const header_pid = header_pid_opt.?;
            var ph = try self.ctx.cache.fetch(header_pid);
            defer ph.deinit();
            const v = CommonPageViewConst.init(try ph.getData());
            const hdr = v.header();
            if (hdr.kind.get() != self.ctx.settings.header_page_kind) {
                return Error.BadType;
            }
            self.header_pid = header_pid;
            self.get_page_pid = header_pid;
            self.put_page_pid = header_pid;
        }

        const Position = struct {
            page_pid: Pid,
            pos: Index,
            total_pos: usize,
        };

        pub fn getp(self: *const Self) usize {
            return self.put_total_pos;
        }

        pub fn getg(self: *const Self) usize {
            return self.get_total_pos;
        }

        pub fn setp(self: *Self, pos: usize) Error!void {
            const position = try self.get_position(pos);
            self.put_page_pid = position.page_pid;
            self.put_pos = @intCast(position.pos);
            self.put_total_pos = position.total_pos;
        }

        pub fn setg(self: *Self, pos: usize) Error!void {
            const position = try self.get_position(pos);
            self.get_page_pid = position.page_pid;
            self.get_pos = @intCast(position.pos);
            self.get_total_pos = position.total_pos;
        }

        fn get_position(self: *const Self, pos: usize) Error!Position {
            var cursor = try self.begin();
            defer cursor.deinit();

            var left_pos = pos;
            while (left_pos > 0) {
                const current_len = try cursor.currentDataSize();
                if (left_pos < current_len) {
                    return .{
                        .page_pid = try cursor.pid(),
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
                .page_pid = try cursor.pid(),
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
                self.get_total_pos += to_read;

                buf_tail = buf_tail[to_read..];
                if (buf_tail.len > 0) {
                    if (!try cursor.hasNext()) {
                        break;
                    }
                    try cursor.moveNext();
                }
            }
            self.get_page_pid = try cursor.pid();
            self.get_pos = cursor.pos;
            return read_total;
        }

        pub fn write(self: *Self, data: []const u8) Error!usize {
            var hdr = try self.loadHeader();
            defer hdr.deinit();
            var hdr_view = try hdr.viewMut();

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
                self.put_total_pos += to_write;

                const diff = try cursor.extendToPos();
                hdr_view.incrementTotalSize(diff);

                data_tail = data_tail[to_write..];
                if (data_tail.len > 0) {
                    if (!try cursor.hasNext()) {
                        try self.appendChunk();
                    }
                    try cursor.moveNext();
                }
            }
            self.put_page_pid = try cursor.pid();
            self.put_pos = cursor.pos;
            return written;
        }

        pub fn begin(self: *const Self) Error!Cursor {
            if (self.header_pid == null) {
                return Error.InvalidHandle;
            }
            return Cursor.init(try self.fetch(self.header_pid.?), 0, &self.ctx);
        }

        pub fn end(self: *const Self) Error!Cursor {
            if (self.header_pid == null) {
                return Error.InvalidHandle;
            }
            var hdr = try self.loadHeader();
            defer hdr.deinit();
            var hdr_v = try hdr.view();
            var link = &hdr_v.subheader().link;
            const last = link.back.get();
            if (last == try hdr.handle.pid()) {
                return Cursor.init(.{
                    .header = HeaderImpl.init(try hdr.handle.take()),
                }, link.payload.size.get(), &self.ctx);
            } else {
                var ph = try self.loadPage(last, self.ctx.settings.chunk_page_kind);
                defer ph.deinit();
                const chunk_v = ViewTypesConst.ChunkView.init(try ph.getData());
                const chunk_size = chunk_v.getLink().getDataSize();
                return Cursor.init(.{
                    .chunk = ChunkImpl.init(try ph.take()),
                }, chunk_size, &self.ctx);
            }
        }

        pub fn extend(self: *Self, len: usize) Error!void {
            var hdr = try self.loadHeader();
            defer hdr.deinit();
            var hdr_v = try hdr.viewMut();
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
                    hdr_v.incrementTotalSize(ileft);
                    break;
                } else {
                    var link = try cursor.getLinkMut();
                    link.setDataSize(max_size);
                    hdr_v.incrementTotalSize(@intCast(can_extend));
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
            var hdr = try self.loadHeader();
            defer hdr.deinit();
            var hdr_v = try hdr.viewMut();

            var cursor = try self.end();
            defer cursor.deinit();
            var left = len;
            while (left > 0) {
                const current_size = try cursor.currentDataSize();
                if (left < current_size) {
                    const total = hdr_v.getTotalSize();
                    const new_total = total - left;
                    hdr_v.setTotalSize(@as(PosType, @intCast(new_total)));
                    const new_current = current_size - @as(Index, @intCast(left));
                    try cursor.setCurrentDataSize(new_current);
                    if (self.get_total_pos >= new_total) {
                        self.get_total_pos = new_total;
                        self.get_page_pid = try cursor.pid();
                        self.get_pos = new_current;
                    }
                    if (self.put_total_pos >= new_total) {
                        self.put_total_pos = new_total;
                        self.put_page_pid = try cursor.pid();
                        self.put_pos = new_current;
                    }

                    break;
                }
                left -= current_size;
                hdr_v.decrementTotalSize(current_size);
                if (try cursor.isHeader()) {
                    self.put_page_pid = self.header_pid;
                    self.put_pos = 0;
                    self.put_total_pos = hdr_v.getTotalSize();

                    self.get_page_pid = self.header_pid;
                    self.get_pos = 0;
                    self.get_total_pos = hdr_v.getTotalSize();

                    break;
                } else {
                    try cursor.movePrev();
                    try self.popChunk();
                }
            }
        }

        pub fn resize(self: *Self, len: usize) Error!void {
            const total = try self.totalSize();
            if (len > total) {
                try self.extend(len - total);
            } else if (len < total) {
                try self.truncate(total - len);
            }
        }

        pub fn totalSize(self: *const Self) Error!usize {
            var pv = try self.loadHeader();
            defer pv.deinit();
            return (try pv.view()).getTotalSize();
        }

        pub fn loadHeader(self: *const Self) Error!HeaderImpl {
            if (self.header_pid) |hid| {
                const ph = try self.loadPage(hid, self.ctx.settings.header_page_kind);
                return HeaderImpl.init(ph);
            }
            return Error.InvalidId;
        }

        pub fn loadChunk(self: *const Self, pid: Pid) Error!ChunkImpl {
            const ph = try self.loadPage(pid, self.ctx.settings.chunk_page_kind);
            return ChunkImpl.init(ph);
        }

        pub fn appendChunk(self: *Self) Error!void {
            var c = try self.appendGetChunk();
            defer c.deinit();
        }

        pub fn appendGetChunk(self: *Self) Error!ChunkImpl {
            var ph = try self.ctx.cache.create();
            errdefer ph.deinit();

            var v = ViewTypes.ChunkView.init(try ph.getDataMut());
            v.formatPage(self.ctx.settings.chunk_page_kind, try ph.pid(), 0);
            var hdr_ph = try self.loadHeader();
            defer hdr_ph.deinit();

            var hdr_v = try hdr_ph.viewMut();
            var link = &hdr_v.subheaderMut().link;
            const last = link.back.get();

            var result = ChunkImpl.init(ph);
            var result_v = try result.viewMut();
            var result_link = &result_v.subheaderMut().link;

            if (last == try hdr_ph.handle.pid()) {
                // First chunk being added
                link.fwd.set(try ph.pid());
                result_v.setFlag(.first);
                result_link.back.set(try hdr_ph.handle.pid());
            } else {
                try self.pushChunkImpl(&result, last);
            }
            link.back.set(try ph.pid());

            return result;
        }

        pub fn popChunk(self: *Self) Error!void {
            var hdr_ph = try self.loadHeader();
            defer hdr_ph.deinit();

            var hdr_v = try hdr_ph.viewMut();
            var link = &hdr_v.subheaderMut().link;
            const last = link.back.get();
            if (last == try hdr_ph.handle.pid()) {
                return;
            }

            var last_chunk_ph = try self.loadPage(last, self.ctx.settings.chunk_page_kind);
            defer last_chunk_ph.deinit();

            var last_chunk = ChunkImpl.init(last_chunk_ph);
            var last_chunk_v = try last_chunk.viewMut();
            var last_chunk_l = last_chunk_v.getLinkMut();
            const prev = last_chunk_l.link.back.get();

            if (prev == try hdr_ph.handle.pid()) {
                // Removing the last chunk
                link.back.set(try hdr_ph.handle.pid());
                var hdr_link = hdr_v.getLinkMut();
                hdr_link.setFwd(null);
            } else {
                link.back.set(prev);
                try self.popImpl(prev);
            }
            try self.ctx.mgr.destroyPage(last);
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

        fn popImpl(self: *Self, prev: BlockIdType) Error!void {
            var prev_h = try self.loadPage(prev, self.ctx.settings.chunk_page_kind);
            defer prev_h.deinit();
            var prev_chunk = ChunkImpl.init(prev_h);
            var prev_v = try prev_chunk.viewMut();
            var prev_l = prev_v.getLinkMut();
            prev_l.setFwd(null);
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

        fn fetch(self: *const Self, pid: Pid) Error!PageVariant {
            var ph = try self.ctx.cache.fetch(pid);
            errdefer ph.deinit();
            const v = CommonPageViewConst.init(try ph.getData());
            const hdr = v.header();
            const kind = hdr.kind.get();
            if (kind == self.ctx.settings.header_page_kind) {
                return .{ .header = HeaderImpl.init(ph) };
            } else if (kind == self.ctx.settings.chunk_page_kind) {
                return .{ .chunk = ChunkImpl.init(ph) };
            } else {
                return Error.BadType;
            }
        }

        fn openGetCursor(self: *const Self) Error!Cursor {
            if (self.get_page_pid == null) {
                return Error.InvalidHandle;
            }
            return Cursor.init(try self.fetch(self.get_page_pid.?), self.get_pos, &self.ctx);
        }

        fn openPutCursor(self: *const Self) Error!Cursor {
            if (self.put_page_pid == null) {
                return Error.InvalidHandle;
            }
            return Cursor.init(try self.fetch(self.put_page_pid.?), self.put_pos, &self.ctx);
        }
    };
}
