const fullaz_db = @import("fullaz-db");

const FirstTrait = struct {
    pub const kind_name: []const u8 = "test.compile.first";
    pub const format_version: u32 = 1;
    pub const page_kind_count: usize = 1;
    pub const page_roles: [page_kind_count][]const u8 = .{"data"};

    pub fn fingerprint(_: *fullaz_db.HierarchyFingerprintWriter) void {}

    pub fn Binding(comptime BackendT: type) type {
        _ = BackendT;
        return struct {};
    }
};

const SecondTrait = struct {
    pub const kind_name: []const u8 = "test.compile.second";
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
        .page_kind_base = 0xfffe,
        .types = &.{
            .{
                .tag = "first",
                .type_id = 1,
                .type_version = 1,
                .metadata_format_version = 1,
                .descriptor = .{ .Trait = FirstTrait },
                .allowed_child_type_ids = &.{},
            },
            .{
                .tag = "second",
                .type_id = 2,
                .type_version = 1,
                .metadata_format_version = 1,
                .descriptor = .{ .Trait = SecondTrait },
                .allowed_child_type_ids = &.{},
            },
        },
    });
}
