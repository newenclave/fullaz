const radix_tree = @import("fullaz").radix_tree;
const CatalogRef = @import("ref.zig").CatalogRef;
const catalog_ref = @import("ref.zig");
const system_kinds = @import("../system_kinds.zig");

/// Private paged Radix index mapping durable component IDs to catalog records.
pub fn CatalogIdIndex(comptime CacheT: type, comptime ManagerT: type) type {
    const ModelT = radix_tree.models.paged.Model(
        CacheT,
        ManagerT,
        u64,
        catalog_ref.encoded_size,
    );
    const TreeT = radix_tree.Tree(ModelT);

    return struct {
        const Self = @This();

        pub const Error = TreeT.Error || catalog_ref.Error;

        model: ModelT,

        pub fn init(cache: *CacheT, manager: *ManagerT) Error!Self {
            return .{ .model = try ModelT.init(cache, manager, .{
                .leaf_page_kind = system_kinds.component_id_radix_leaf,
                .inode_page_kind = system_kinds.component_id_radix_inode,
                .inode_base = 256,
                .leaf_base = 256,
            }) };
        }

        pub fn deinit(self: *Self) void {
            self.model.deinit();
            self.* = undefined;
        }

        pub fn get(self: *Self, component_id: u64) Error!?CatalogRef {
            if (component_id == 0) {
                return null;
            }
            var tree = TreeT.init(&self.model);
            defer tree.deinit();
            const bytes = (try tree.get(component_id)) orelse return null;
            return try CatalogRef.decode(bytes);
        }

        pub fn set(self: *Self, component_id: u64, ref: CatalogRef) Error!void {
            if (component_id == 0) {
                return error.BadCatalogRef;
            }
            var bytes: [catalog_ref.encoded_size]u8 = undefined;
            try ref.encode(&bytes);
            var tree = TreeT.init(&self.model);
            defer tree.deinit();
            try tree.set(component_id, &bytes);
        }
    };
}
