const std = @import("std");
const kinds = @import("fullaz-db").file.system_kinds;

test "fullaz-db file system kinds occupy only the assigned system range" {
    const assigned = [_]u16{
        kinds.catalog_slot_chain,
        kinds.component_id_radix_leaf,
        kinds.component_id_radix_inode,
        kinds.component_name_bpt_leaf,
        kinds.component_name_bpt_inode,
        kinds.component_metadata,
    };

    for (assigned, 0..) |kind, index| {
        try std.testing.expect(kinds.isSystem(kind));
        try std.testing.expect(!kinds.isComponent(kind));
        for (assigned[0..index]) |previous| {
            try std.testing.expect(kind != previous);
        }
    }
    try std.testing.expect(!kinds.isSystem(kinds.invalid));
    try std.testing.expect(kinds.isComponent(kinds.first_component));
    try std.testing.expect(!kinds.isComponent(kinds.invalid_sentinel));
}
