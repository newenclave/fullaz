const pages = @import("fullaz").pages;

const Trait = struct {
    pub const kind_name: []const u8 = "test.component";
    pub const format_version: u32 = 1;
    pub const page_kind_count: usize = 1;
    pub const page_roles: [page_kind_count][]const u8 = .{"data"};

    pub fn Binding(comptime BackendT: type) type {
        _ = BackendT;
        return struct {};
    }
};

comptime {
    const Invalid = pages.Schema(.{ .page_id = u32 })
        .add("jobs/$fsm", .{ .Trait = Trait });
    _ = Invalid.fields;
}
