const std = @import("std");

test {
    _ = @import("wordt.zig");
    _ = @import("bitset.zig");
    _ = @import("static_vector.zig");
    _ = @import("algorithm.zig");
    _ = @import("bpt_memory_model.zig");
    _ = @import("bpt_paged_model.zig");
    _ = @import("slots_variadic.zig");
    _ = @import("device_memory_block.zig");
    _ = @import("page_cache.zig");
    _ = @import("pages.zig");
    _ = @import("long_store.zig");
}
