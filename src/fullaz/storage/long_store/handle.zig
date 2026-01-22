const std = @import("std");
const view = @import("view.zig");
const page_header = @import("../../page/header.zig");
const interfaces = @import("../../contracts/contracts.zig");
const errors = @import("../../core/errors.zig");

pub const Settings = struct {
    header_page_kind: u16 = 0x10,
    chunk_page_kind: u16 = 0x11,
};

pub fn Handle(comptime PageCacheType: type) type {
    comptime {
        interfaces.page_cache.requiresPageCache(PageCacheType);
    }

    const PosType = u32;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    //    const CommonPageView = page_header.View(BlockIdType, u16, .little, false);
    const CommonPageViewConst = page_header.View(BlockIdType, u16, .little, true);
    const ViewTypes = view.View(BlockIdType, u16, PosType, .little, false);
    const ViewTypesConst = view.View(BlockIdType, u16, PosType, .little, true);

    const Context = struct {
        cache: *PageCacheType,
        settings: Settings,
    };

    const HeaderImpl = struct {
        const Self = @This();
        const ViewType = ViewTypes.HeaderView;
        const ViewTypeConst = ViewTypesConst.HeaderView;

        const Error = errors.PageError ||
            PageCacheType.Error;

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

        fn deinit(self: *Self) void {
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
            errors.PageError;

        page: PageVariant,
        pos: PosType,
        cache: *PageCacheType,
        ctx: *const Context,

        pub fn init(page: PageVariant, pos: PosType, cache: *PageCacheType, ctx: *const Context) Self {
            return Self{
                .page = page,
                .pos = pos,
                .cache = cache,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            switch (self.page) {
                .header => |hdr_const| {
                    var hdr = hdr_const;
                    hdr.deinit();
                },
                .chunk => |chk_const| {
                    var chk = chk_const;
                    chk.deinit();
                },
            }
        }

        pub fn currentDataSize(self: *const Self) Error!usize {
            switch (self.page) {
                .header => |hdr| {
                    var v = try hdr.view();
                    return v.getDataSize();
                },
                .chunk => |chk| {
                    var v = try chk.view();
                    return v.getDataSize();
                },
            }
        }

        pub fn setCurrentDataSize(self: *Self, size: u16) Error!void {
            switch (self.page) {
                .header => |hdr_const| {
                    var hdr = hdr_const;
                    var v = try hdr.viewMut();
                    return v.setDataSize(size);
                },
                .chunk => |chk_const| {
                    var chk = chk_const;
                    var v = try chk.viewMut();
                    return v.setDataSize(size);
                },
            }
        }

        pub fn currentData(self: *const Self) Error![]const u8 {
            switch (self.page) {
                .header => |hdr| {
                    var v = try hdr.view();
                    const data = v.data();
                    const data_size = v.getDataSize();
                    return data[self.pos..data_size];
                },
                .chunk => |chk| {
                    var v = try chk.view();
                    const data = v.data();
                    const data_size = v.getDataSize();
                    return data[self.pos..data_size];
                },
            }
        }
    };

    return struct {
        const Self = @This();

        pub const Pid = BlockIdType;
        pub const Error = PageCacheType.Error ||
            errors.PageError;

        header_pid: ?Pid = null,
        get_page_pid: ?Pid = null,
        set_page_pid: ?Pid = null,
        get_pos: PosType = 0,
        set_pos: PosType = 0,
        ctx: Context,

        pub const View = view.View;
        pub fn init(cache: *PageCacheType, settings: Settings) Self {
            return Self{
                .ctx = Context{
                    .cache = cache,
                    .settings = settings,
                },
            };
        }

        pub fn reset(self: *Self) void {
            self.header_pid = null;
            self.get_page_pid = null;
            self.set_page_pid = null;
            self.get_pos = 0;
            self.set_pos = 0;
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }

        pub fn create(self: *Self) Error!Pid {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            var v = ViewTypes.HeaderView.init(try ph.getDataMut());
            v.formatPage(self.ctx.settings.header_page_kind, try ph.pid(), 0);
            return try ph.pid();
        }

        pub fn open(self: *Self, header_pid: Pid) Error!void {
            var ph = try self.ctx.cache.fetch(header_pid);
            defer ph.deinit();
            const v = CommonPageViewConst.init(try ph.getData());
            const hdr = v.header();
            if (hdr.kind.get() != self.ctx.settings.header_page_kind) {
                return Error.BadType;
            }
            self.header_pid = header_pid;
            self.get_page_pid = header_pid;
            self.set_page_pid = header_pid;
        }

        pub fn begin(self: *const Self) Error!Cursor {
            if (self.header_pid == null) {
                return Error.InvalidHandle;
            }
            return Cursor.init(try self.fetch(self.header_pid.?), 0, self.ctx.cache, &self.ctx);
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
    };
}
