const std = @import("std");
const device_interface = @import("../../device/interfaces.zig");
const page_cache = @import("../../page_cache.zig");
const bpt_page = @import("../../page/bpt.zig");

const Settings = struct {
    pub const maximum_key_size = 128;
};

pub fn PagedModel(comptime PageCacheType: type, settings: Settings) type {
    _ = settings;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const BptPage = bpt_page.Bpt(BlockIdType, u16, .little, false);
    const BptPageConst = bpt_page.Bpt(BlockIdType, u16, .little, true);

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = BptPage.LeafSubheaderView;
        const PageViewTypeConst = BptPageConst.LeafSubheaderView;
        handle: PageHandle = undefined,

        fn init(ph: PageHandle) Self {
            return .{
                .handle = ph,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn take(self: *Self) !Self {
            return Self{
                .handle = try self.handle.take(),
            };
        }

        pub fn size(self: *const Self) !usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.entries();
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const PageViewType = BptPage.InodeSubheaderView;
        handle: PageHandle = undefined,
        fn init(ph: PageHandle) Self {
            return .{
                .handle = ph,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn take(self: *Self) !Self {
            return Self{
                .handle = try self.handle.take(),
            };
        }
    };

    const KeyBorrowImpl = struct {
        const Self = @This();
        key: []const u8,
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const PageCache = PageCacheType;
        device: *PageCache = undefined,

        fn init(device: *PageCacheType) Self {
            return .{
                .device = device,
            };
        }

        pub fn deinit(_: Self) void {
            // nothing to yet
        }

        pub fn createLeaf(self: *Self) !LeafImpl {
            var ph = try self.device.create();
            var page_view = LeafImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(0, try ph.pid(), 0);
            return LeafImpl.init(ph);
        }

        pub fn createInode(self: *Self) !InodeImpl {
            var ph = try self.device.create();
            var page_view = InodeImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(1, try ph.pid(), 0);
            return InodeImpl.init(ph);
        }

        pub fn loadLeaf(self: *Self, id_opt: ?BlockIdType) !?LeafImpl {
            if (id_opt) |id| {
                const ph = try self.device.fetch(id);
                return LeafImpl.init(ph);
            }
            return null;
        }

        pub fn loadInode(self: *Self, id_opt: ?BlockIdType) !?InodeImpl {
            if (id_opt) |id| {
                const ph = try self.device.fetch(id);
                return InodeImpl.init(ph);
            }
            return null;
        }

        pub fn deinitLeaf(_: *Self, leaf: ?LeafImpl) void {
            if (leaf) |l_const| {
                var l = l_const;
                l.deinit();
            }
        }

        pub fn deinitInode(_: *Self, inode: ?InodeImpl) void {
            if (inode) |i_const| {
                var i = i_const;
                i.deinit();
            }
        }
    };

    return struct {
        const Self = @This();
        pub const KeyLikeType = []const u8;
        pub const KeyOutType = []const u8;

        pub const ValueInType = []const u8;
        pub const ValueOutType = []const u8;

        pub const KeyBorrowType = KeyBorrowImpl;

        pub const BlockDeviceType = BlockDevice;
        pub const AccessorType = AccessorImpl;

        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;

        pub const NodeIdType = BlockIdType;

        accessor: AccessorType,

        pub fn init(device: *PageCacheType) Self {
            return .{
                .accessor = AccessorImpl.init(device),
            };
        }

        pub fn deinit() void {
            // nothing to yet
        }

        pub fn getAccessor(self: *Self) *AccessorType {
            return &self.accessor;
        }
    };
}
