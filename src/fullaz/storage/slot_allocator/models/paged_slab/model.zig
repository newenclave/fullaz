const std = @import("std");
const page = @import("../../../../page/slab_allocator.zig");

pub fn Model(comptime PageCacheTypeT: type, comptime SlabStorageManagerT: type, comptime SizeClassT: type) type {
    const Context = struct {
        const Self = @This();
        page_cache: *PageCacheTypeT,
        slab_storage_manager: *SlabStorageManagerT,
    };

    return struct {
        const Self = @This();
        pub const Error = PageCacheTypeT.Error || SlabStorageManagerT.Error;

        ctx: Context = undefined,

        pub const PageCache = PageCacheTypeT;
        pub const SlabStorageManager = SlabStorageManagerT;
        pub const SizeClass = SizeClassT;

        pub fn init(page_cache: *PageCacheTypeT, slab_storage_manager: *SlabStorageManagerT) Error!Self {
            return Self{
                .ctx = Context{
                    .page_cache = page_cache,
                    .slab_storage_manager = slab_storage_manager,
                },
            };
        }
    };
}
