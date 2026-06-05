const std = @import("std");
const core = @import("../../../core/core.zig");
const errors = core.errors;
const SubheaderView = @import("view.zig").View;

pub const Settings = struct {
    max_level: usize = undefined,
    key_len: usize = undefined,
    value_len: usize = undefined,
};

pub fn Paged(comptime PageCacheType: type, comptime StorageManager: type, comptime cmp: anytype, comptime Ctx: type) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const KeyT = []const u8;
    const ValueT = []const u8;

    _ = cmp;

    const ContextImpl = struct {
        const Self = @This();
        settings: Settings,
        rng: std.Random = undefined,
        cache: *PageCacheType = undefined,
        storage: *StorageManager = undefined,
        cmp_ctx: Ctx = undefined,
    };

    const PidImpl = struct {
        const Self = @This();
        page_id: BlockIdType,
        slot_id: usize,
    };

    const PidContainer = std.ArrayList(?PidImpl);

    const PathImpl = struct {
        const Self = @This();

        pub const Error = error{ OutOfMemory, OutOfBounds };
        pub const Pid = PidImpl;

        path: PidContainer = undefined,

        fn init(allocator: std.mem.Allocator, max_level: usize) Error!Self {
            var result = Self{
                .path = try PidContainer.initCapacity(allocator, max_level),
            };
            try result.path.resize(
                allocator,
                max_level,
            );
            return result;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.path.deinit(allocator);
            self.* = undefined;
        }

        pub fn get(self: *const Self, level: usize) Error!?PidImpl {
            if (self.path.items.len <= level) {
                return Error.OutOfBounds;
            }
            return self.path.items[level];
        }

        pub fn set(self: *Self, level: usize, pid: ?PidImpl) Error!void {
            if (self.path.items.len <= level) {
                return Error.OutOfBounds;
            }
            self.path.items[level] = pid;
        }

        fn dump(self: *const Self) void {
            for (self.path.items) |item| {
                if (item) |pid| {
                    std.debug.print("{d} ", .{pid.id});
                } else {
                    std.debug.print("<null> ", .{});
                }
            }
            std.debug.print("\n", .{});
        }
    };

    const NodeImpl = struct {
        const Self = @This();

        pid: PidImpl,
        ph: PageHandle,

        fn init(ph: PageHandle, pid: PidImpl) Self {
            return Self{
                .pid = pid,
                .ph = ph,
            };
        }
    };

    const AccessorImpl = struct {
        const Self = @This();

        pub const Pid = PidImpl;
        pub const Error = PageCacheType.Error || StorageManager.Error;
        pub const Path = PathImpl;

        context: ContextImpl,

        fn init(ctx: ContextImpl) Self {
            return Self{
                .context = ctx,
            };
        }

        pub fn loadNode(self: *Self, pid: Pid) Error!NodeImpl {
            var ph = try self.ctx.cache.fetch(pid.page_id);
            errdefer ph.deinit();
        }
    };

    return struct {
        const Self = @This();

        pub const Error = PageCacheType.Error || StorageManager.Error;

        pub const Accessor = AccessorImpl;
        pub const Node = NodeImpl;
        pub const Pid = PidImpl;

        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;

        pub const KeyOut = KeyIn;
        pub const ValueOut = ValueIn;
        pub const Path = PathImpl;

        accessor: AccessorImpl,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, settings: Settings, ctx: Ctx, rng: std.Random) Self {
            return Self{
                .accessor = AccessorImpl.init(ContextImpl{
                    .settings = settings,
                    .rng = rng,
                    .cache = device,
                    .storage = storage_mgr,
                    .cmp_ctx = ctx,
                }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor = undefined; // Clear the accessor to release references to resources.
        }
    };

    //const BlockDevice = PageCacheType.UnderlyingDevice;
    // const PageHandle = PageCacheType.Handle;
    // const BlockIdType = BlockDevice.BlockId;
}
