const std = @import("std");

test {
    _ = @import("wordt.zig");
    _ = @import("bitset.zig");
    _ = @import("static_vector.zig");
    _ = @import("algorithm.zig");
    _ = @import("bpt_memory_model.zig");
    _ = @import("bpt_paged_model.zig");
    _ = @import("slots_variadic.zig");
    _ = @import("slots_fixed.zig");
    _ = @import("device_memory_block.zig");
    _ = @import("device_file_block.zig");
    _ = @import("page_cache.zig");
    _ = @import("pages.zig");
    _ = @import("chain_storage.zig");
    _ = @import("chain_store_indexed.zig");
    _ = @import("long_store.zig");
    _ = @import("wbpt_memory_model.zig");
    _ = @import("wbpt_paged_model.zig");
    _ = @import("radix_memory_model.zig");
    _ = @import("radix_paged_model.zig");
    _ = @import("skip_list_memory.zig");
    _ = @import("skip_list_paged.zig");
    _ = @import("fsm_memory.zig");
    _ = @import("fsm_paged_slab.zig");
    _ = @import("free_list.zig");
    _ = @import("wal.zig");
    _ = @import("rtree_geometry.zig");
    _ = @import("rtree_memory.zig");
    _ = @import("rtree_strategy.zig");
}
