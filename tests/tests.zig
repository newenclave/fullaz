const std = @import("std");

test {
    _ = @import("page_cache/persistent_reclaiming_cache.zig");
    _ = @import("fullaz-db/component/contracts.zig");
    _ = @import("fullaz-db/component/schema.zig");
    _ = @import("fullaz-db/component/fingerprint.zig");
    _ = @import("fullaz-db/components/bpt.zig");
    _ = @import("fullaz-db/components/rtree.zig");
    _ = @import("fullaz-db/components/slot_heap.zig");
    _ = @import("fullaz-db/components/chain_store.zig");
    _ = @import("fullaz-db/components/weighted_sequence.zig");
    _ = @import("fullaz-db/database/memory.zig");
    _ = @import("fullaz-db/database/static.zig");
    _ = @import("fullaz-db/database/static_wal.zig");
    _ = @import("fullaz-db/database/dynamic.zig");
    _ = @import("fullaz-db/file/static_superblock.zig");
    _ = @import("fullaz-db/file/tagged_fields.zig");
    _ = @import("fullaz-db/file/system_kinds.zig");
    _ = @import("fullaz-db/file/boot.zig");
    _ = @import("fullaz-db/file/catalog/ref.zig");
    _ = @import("fullaz-db/file/catalog/record.zig");
    _ = @import("fullaz-db/file/catalog/store.zig");
    _ = @import("fullaz-db/file/catalog/id_index.zig");
    _ = @import("fullaz-db/file/catalog/name_index.zig");
    _ = @import("fullaz-db/file/catalog/schema_preflight.zig");
    _ = @import("fullaz-db/file/metadata/component.zig");
    _ = @import("fullaz-db/file/metadata/page.zig");
    _ = @import("fullaz-db/file/metadata/io.zig");
    _ = @import("core/wordt.zig");
    _ = @import("core/bitset.zig");
    _ = @import("core/static_vector.zig");
    _ = @import("core/algorithm.zig");
    _ = @import("core/bloom.zig");

    _ = @import("bpt/memory_model.zig");
    _ = @import("bpt/paged_model.zig");
    _ = @import("bpt/paged_view.zig");
    _ = @import("bpt/wbpt_memory_model.zig");
    _ = @import("bpt/wbpt_paged_model.zig");
    _ = @import("spatial/geometry.zig");
    _ = @import("rtree/memory.zig");
    _ = @import("rtree/strategy.zig");
    _ = @import("rtree/tree.zig");
    _ = @import("rtree/rstar.zig");
    _ = @import("rtree/linear.zig");
    _ = @import("rtree/delete.zig");
    _ = @import("rtree/paged.zig");
    _ = @import("rtree/paged_view.zig");

    _ = @import("aabb_tree/tree.zig");

    _ = @import("radix/memory_model.zig");
    _ = @import("radix/paged_model.zig");

    _ = @import("skip_list/memory.zig");
    _ = @import("skip_list/paged.zig");

    _ = @import("slots/variadic.zig");
    _ = @import("slots/trailing.zig");
    _ = @import("slots/fixed.zig");

    _ = @import("slot_chain/slot_chain.zig");
    _ = @import("slot_stack/slot_stack.zig");
    _ = @import("slot_queue/slot_queue.zig");
    _ = @import("slot_heap/paged_view.zig");
    _ = @import("slot_heap/paged_model.zig");
    _ = @import("slot_heap/interfaces.zig");
    _ = @import("slot_heap/memory.zig");
    _ = @import("page_chain/page_chain.zig");

    _ = @import("chain/storage.zig");
    _ = @import("chain/store_indexed.zig");

    _ = @import("fsm/memory.zig");
    _ = @import("fsm/location.zig");
    _ = @import("fsm/location_accessor.zig");
    _ = @import("fsm/header_location_accessor.zig");
    _ = @import("fsm/paged_slab.zig");
    _ = @import("fsm/size_classes.zig");
    _ = @import("fsm/skip_list_integration.zig");

    _ = @import("device/memory_block.zig");
    _ = @import("device/memory_log.zig");
    _ = @import("device/file_block.zig");

    _ = @import("codec/fron_coded_block.zig");
    _ = @import("sstable/sstable.zig");

    _ = @import("spatial/geometry.zig");
    _ = @import("spatial/orthtree/orthtree.zig");
    _ = @import("spatial/orthtree/paged_model.zig");
    _ = @import("spatial/orthtree/paged_view.zig");

    _ = @import("page/extensions.zig");
    _ = @import("page/links.zig");
    _ = @import("page/orthtree.zig");
    _ = @import("page/slot_heap.zig");
    _ = @import("page_cache.zig");
    _ = @import("pages.zig");
    _ = @import("page_cache/memory_reclaiming_cache.zig");
    _ = @import("long_store.zig");
    _ = @import("free_list.zig");
    _ = @import("wal.zig");
    _ = @import("zync/observer.zig");
}
