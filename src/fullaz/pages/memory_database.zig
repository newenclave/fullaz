const std = @import("std");
const device = @import("../device/device.zig");
const page_cache = @import("../storage/page_cache/page_cache.zig");
const MemoryReclaimingCache = @import("memory_reclaiming_cache.zig").MemoryReclaimingCache;

pub fn MemoryDatabase(comptime SchemaT: type) type {
    if (!@hasDecl(SchemaT, "PageId") or !@hasDecl(SchemaT, "fields")) {
        @compileError("MemoryDatabase requires a pages Schema type");
    }
    if (SchemaT.fields.len != 0) {
        @compileError("MemoryDatabase component runtime generation is not implemented yet");
    }

    const Device = device.MemoryBlock(SchemaT.PageId);
    const RawCache = page_cache.PageCache(Device);
    const Cache = MemoryReclaimingCache(RawCache);
    const Backend = struct {
        const Self = @This();

        pub const PageId = SchemaT.PageId;
        pub const CacheType = Cache;

        allocator_value: std.mem.Allocator,
        cache_ptr: *Cache,

        fn init(allocator_value: std.mem.Allocator, cache_ptr: *Cache) Self {
            return .{
                .allocator_value = allocator_value,
                .cache_ptr = cache_ptr,
            };
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.allocator_value;
        }

        pub fn cache(self: *Self) *CacheType {
            return self.cache_ptr;
        }

        pub fn cacheConst(self: *const Self) *const CacheType {
            return self.cache_ptr;
        }
    };
    const Core = struct {
        allocator: std.mem.Allocator,
        device: Device,
        raw_cache: RawCache,
        cache: Cache,
        backend: Backend,
    };

    return struct {
        const Self = @This();

        pub const Schema = SchemaT;
        pub const DeviceType = Device;
        pub const RawCacheType = RawCache;
        pub const CacheType = Cache;
        pub const BackendType = Backend;
        pub const InitOptions = struct {
            page_size: usize,
            cache_frames: usize = 64,
        };
        pub const Error = std.mem.Allocator.Error ||
            Device.Error ||
            RawCache.Error ||
            Cache.Error ||
            error{InvalidCacheFrames};

        core_: *Core,

        pub fn init(allocator: std.mem.Allocator, options: InitOptions) Error!Self {
            if (options.cache_frames == 0) {
                return Error.InvalidCacheFrames;
            }

            const core = try allocator.create(Core);
            errdefer allocator.destroy(core);
            core.allocator = allocator;
            core.device = try Device.init(allocator, options.page_size);
            errdefer core.device.deinit();
            core.raw_cache = try RawCache.init(
                &core.device,
                allocator,
                options.cache_frames,
            );
            errdefer core.raw_cache.deinit();
            core.cache = Cache.init(allocator, &core.raw_cache);
            core.backend = Backend.init(allocator, &core.cache);

            return .{ .core_ = core };
        }

        pub fn deinit(self: *Self) void {
            const core = self.core_;
            const allocator = core.allocator;
            core.cache.deinit();
            core.raw_cache.deinit();
            core.device.deinit();
            allocator.destroy(core);
            self.* = undefined;
        }
    };
}
