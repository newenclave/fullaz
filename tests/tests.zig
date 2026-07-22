const std = @import("std");

test {
    _ = @import("core/wordt.zig");
    _ = @import("core/bitset.zig");
    _ = @import("core/static_vector.zig");
    _ = @import("core/algorithm.zig");

    _ = @import("bpt/memory_model.zig");
    _ = @import("bpt/paged_model.zig");
    _ = @import("bpt/wbpt_memory_model.zig");
    _ = @import("bpt/wbpt_paged_model.zig");
    _ = @import("rtree/geometry.zig");
    _ = @import("rtree/memory.zig");
    _ = @import("rtree/strategy.zig");
    _ = @import("rtree/tree.zig");
    _ = @import("rtree/rstar.zig");
    _ = @import("rtree/linear.zig");
    _ = @import("rtree/delete.zig");
    _ = @import("rtree/paged.zig");

    _ = @import("radix/memory_model.zig");
    _ = @import("radix/paged_model.zig");

    _ = @import("skip_list/memory.zig");
    _ = @import("skip_list/paged.zig");

    _ = @import("slots/variadic.zig");
    _ = @import("slots/fixed.zig");

    _ = @import("chain/storage.zig");
    _ = @import("chain/store_indexed.zig");

    _ = @import("fsm/memory.zig");
    _ = @import("fsm/paged_slab.zig");

    _ = @import("device/memory_block.zig");
    _ = @import("device/file_block.zig");

    _ = @import("keys/prefix_block_add.zig");

    _ = @import("page_cache.zig");
    _ = @import("pages.zig");
    _ = @import("long_store.zig");
    _ = @import("free_list.zig");
    _ = @import("wal.zig");
}
