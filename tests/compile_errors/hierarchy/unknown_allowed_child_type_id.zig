const fullaz_db = @import("fullaz-db");

const Trait = struct {
    pub const kind_name: []const u8 = "test.compile.hierarchy";
    pub const format_version: u32 = 1;
    pub const page_kind_count: usize = 1;
    pub const page_roles: [page_kind_count][]const u8 = .{"data"};

    pub fn fingerprint(_: *fullaz_db.HierarchyFingerprintWriter) void {}

    pub fn Binding(comptime BackendT: type) type {
        _ = BackendT;
        return struct {};
    }
};

comptime {
    _ = fullaz_db.Hierarchy(.{
        .registry_id = 1,
        .types = &.{.{
            .tag = "node",
            .type_id = 1,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = .{ .Trait = Trait },
            .allowed_child_type_ids = &.{2},
        }},
    });
}
