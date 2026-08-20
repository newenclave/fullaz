const std = @import("std");
const pages = @import("fullaz").pages;

fn compare(_: void, left: []const u8, right: []const u8) @import("fullaz").core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

const CompareContext = struct {
    descending: bool,
};

fn compareWithContext(
    context: CompareContext,
    left: []const u8,
    right: []const u8,
) @import("fullaz").core.algorithm.Order {
    const order = compare({}, left, right);
    if (!context.descending) {
        return order;
    }
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
        .unordered => .unordered,
    };
}

const SyntheticTrait = struct {
    pub const kind_name: []const u8 = "test.synthetic";
    pub const format_version: u32 = 1;
    pub const page_kind_count: usize = 1;
    pub const page_roles: [page_kind_count][]const u8 = .{"data"};

    pub fn Binding(comptime BackendT: type) type {
        return struct {
            pub const Runtime = struct {};
            pub const Proxy = Runtime;
            pub const InitOptions = struct {};
            pub const Error = error{SyntheticFailure};

            pub fn initRuntime(
                runtime: *Runtime,
                backend: *BackendT,
                page_kinds: pages.PageKindRange,
                init_options: InitOptions,
            ) Error!void {
                runtime.* = .{};
                _ = backend;
                _ = page_kinds;
                _ = init_options;
            }

            pub fn deinitRuntime(_: *Runtime) void {}

            pub fn proxy(runtime: *Runtime) *Proxy {
                return runtime;
            }

            pub fn proxyConst(runtime: *const Runtime) *const Proxy {
                return runtime;
            }
        };
    }
};

test "Pages: empty memory database owns a pointer-stable backend" {
    const Schema = pages.Schema(.{ .page_id = u32 });
    const Db = pages.MemoryDatabase(Schema);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .cache_frames = 4,
    });
    const core_address = database.core_;
    const cache_address = &database.core_.cache;
    const device_address = &database.core_.device;

    var moved = database;
    database = undefined;
    defer moved.deinit();

    try std.testing.expect(moved.core_ == core_address);
    try std.testing.expect(moved.core_.backend.cache() == cache_address);
    try std.testing.expect(moved.core_.raw_cache.device == device_address);
    try std.testing.expectEqual(@as(usize, 4096), moved.core_.backend.cache().pageSize());
}

test "Pages: memory database rejects zero cache frames" {
    const Schema = pages.Schema(.{ .page_id = u32 });
    const Db = pages.MemoryDatabase(Schema);

    try std.testing.expectError(
        error.InvalidCacheFrames,
        Db.init(std.testing.allocator, .{
            .page_size = 4096,
            .cache_frames = 0,
        }),
    );
}

test "Pages: memory database generates exact runtime storage fields" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("index", pages.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 64,
            .maximum_value_size = 128,
        }))
        .add("secondary", pages.bpt(.{
        .compare = compareWithContext,
        .CompareContext = CompareContext,
        .comparator_id = 2,
        .maximum_key_size = 32,
        .maximum_value_size = 48,
    }));
    const Db = pages.MemoryDatabase(Schema);
    const Components = Db.ComponentsStorageType;
    const IndexBinding = Schema.trait("index").Binding(Db.BackendType);
    const SecondaryBinding = Schema.trait("secondary").Binding(Db.BackendType);
    const fields = @typeInfo(Components).@"struct".fields;

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("index", fields[0].name);
    try std.testing.expectEqualStrings("secondary", fields[1].name);
    try std.testing.expect(@FieldType(Components, "index") == IndexBinding.Runtime);
    try std.testing.expect(@FieldType(Components, "secondary") == SecondaryBinding.Runtime);
    try std.testing.expect(IndexBinding.Runtime != SecondaryBinding.Runtime);
}

test "Pages: memory database generates conditional component option defaults" {
    const MixedSchema = pages.Schema(.{ .page_id = u32 })
        .add("index", pages.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 64,
            .maximum_value_size = 128,
        }))
        .add("secondary", pages.bpt(.{
        .compare = compareWithContext,
        .CompareContext = CompareContext,
        .comparator_id = 2,
        .maximum_key_size = 32,
        .maximum_value_size = 48,
    }));
    const MixedDb = pages.MemoryDatabase(MixedSchema);
    const component_fields = @typeInfo(MixedDb.ComponentInitOptionsType).@"struct".fields;
    const init_fields = @typeInfo(MixedDb.InitOptions).@"struct".fields;

    try std.testing.expect(component_fields[0].default_value_ptr != null);
    try std.testing.expect(component_fields[1].default_value_ptr == null);
    try std.testing.expect(init_fields[2].default_value_ptr == null);
    const mixed_options = MixedDb.InitOptions{
        .page_size = 4096,
        .components = .{
            .secondary = .{ .compare_context = .{ .descending = true } },
        },
    };
    try std.testing.expectEqual(@as(usize, 64), mixed_options.cache_frames);
    try std.testing.expect(mixed_options.components.secondary.compare_context.descending);

    const DefaultSchema = pages.Schema(.{ .page_id = u32 })
        .add("index", pages.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 3,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const DefaultDb = pages.MemoryDatabase(DefaultSchema);
    const default_init_fields = @typeInfo(DefaultDb.InitOptions).@"struct".fields;
    try std.testing.expect(default_init_fields[2].default_value_ptr != null);
    const default_options = DefaultDb.InitOptions{ .page_size = 4096 };
    try std.testing.expectEqual(@as(usize, 64), default_options.cache_frames);
}

test "Pages: memory database composes exact component errors" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("synthetic", .{ .Trait = SyntheticTrait });
    const Db = pages.MemoryDatabase(Schema);
    const Binding = SyntheticTrait.Binding(Db.BackendType);
    const Expected = std.mem.Allocator.Error ||
        Db.DeviceType.Error ||
        Db.RawCacheType.Error ||
        Db.CacheType.Error ||
        Binding.Error ||
        error{InvalidCacheFrames};

    try std.testing.expect(Db.Error == Expected);
    const synthetic: Db.Error = error.SyntheticFailure;
    try std.testing.expectEqual(error.SyntheticFailure, synthetic);
}
