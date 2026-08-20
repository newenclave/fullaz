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

const LifecycleState = struct {
    events: [16]u8 = undefined,
    len: usize = 0,

    fn push(self: *LifecycleState, event: u8) void {
        self.events[self.len] = event;
        self.len += 1;
    }

    fn recorded(self: *const LifecycleState) []const u8 {
        return self.events[0..self.len];
    }
};

fn LifecycleTrait(comptime id: u8, comptime fail_init: bool) type {
    return struct {
        pub const kind_name: []const u8 = "test.lifecycle";
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = 1;
        pub const page_roles: [page_kind_count][]const u8 = .{"data"};

        pub fn Binding(comptime BackendT: type) type {
            return struct {
                pub const Runtime = struct {
                    state: *LifecycleState,
                };
                pub const Proxy = Runtime;
                pub const InitOptions = struct {
                    state: *LifecycleState,
                };
                pub const Error = error{SyntheticFailure};

                pub fn initRuntime(
                    runtime: *Runtime,
                    backend: *BackendT,
                    page_kinds: pages.PageKindRange,
                    init_options: InitOptions,
                ) Error!void {
                    _ = backend;
                    _ = page_kinds;
                    init_options.state.push(id);
                    if (fail_init) {
                        return Error.SyntheticFailure;
                    }
                    runtime.* = .{ .state = init_options.state };
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    runtime.state.push(std.ascii.toUpper(id));
                    runtime.* = undefined;
                }

                pub fn proxy(runtime: *Runtime) *Proxy {
                    return runtime;
                }

                pub fn proxyConst(runtime: *const Runtime) *const Proxy {
                    return runtime;
                }
            };
        }
    };
}

fn StressContext(comptime id: usize) type {
    return struct {
        pub const component_id = id;
    };
}

fn StressComparator(comptime ContextT: type) type {
    return struct {
        fn compare(
            _: ContextT,
            left: []const u8,
            right: []const u8,
        ) @import("fullaz").core.algorithm.Order {
            return switch (std.mem.order(u8, left, right)) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
        }
    };
}

fn stressDescriptor(comptime index: usize) pages.Descriptor {
    const Context = StressContext(index);
    const Comparator = StressComparator(Context);
    return pages.bpt(.{
        .compare = Comparator.compare,
        .CompareContext = Context,
        .comparator_id = index + 1,
        .maximum_key_size = 8,
        .maximum_value_size = 8,
    });
}

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

test "Pages: memory database rolls back the initialized component prefix" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("first", .{ .Trait = LifecycleTrait('a', false) })
        .add("second", .{ .Trait = LifecycleTrait('b', true) });
    const Db = pages.MemoryDatabase(Schema);
    var state = LifecycleState{};

    try std.testing.expectError(
        error.SyntheticFailure,
        Db.init(std.testing.allocator, .{
            .page_size = 4096,
            .components = .{
                .first = .{ .state = &state },
                .second = .{ .state = &state },
            },
        }),
    );
    try std.testing.expectEqualStrings("abA", state.recorded());
}

test "Pages: memory database deinitializes components in reverse order" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("first", .{ .Trait = LifecycleTrait('a', false) })
        .add("second", .{ .Trait = LifecycleTrait('b', false) })
        .add("third", .{ .Trait = LifecycleTrait('c', false) });
    const Db = pages.MemoryDatabase(Schema);
    var state = LifecycleState{};

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .components = .{
            .first = .{ .state = &state },
            .second = .{ .state = &state },
            .third = .{ .state = &state },
        },
    });
    database.deinit();
    try std.testing.expectEqualStrings("abcCBA", state.recorded());
}

test "Pages: memory database returns an exact typed BPT proxy" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("index", pages.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const Db = pages.MemoryDatabase(Schema);
    const Binding = Schema.trait("index").Binding(Db.BackendType);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .cache_frames = 8,
    });
    defer database.deinit();

    const tree = database.get("index");
    try std.testing.expect(@TypeOf(tree) == *Binding.Proxy);
    try std.testing.expect(try tree.insert("hello", "world"));
    var found = (try tree.find("hello")).?;
    defer found.deinit();
    const entry = (try found.get()).?;
    try std.testing.expectEqualStrings("world", entry.value);

    const database_const: *const Db = &database;
    const tree_const = database_const.getConst("index");
    try std.testing.expect(@TypeOf(tree_const) == *const Binding.Proxy);
    try std.testing.expect(tree_const == tree);
}

test "Pages: two BPT components share one cache and keep independent roots" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("index", pages.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 8,
            .maximum_value_size = 16,
        }))
        .add("secondary", pages.bpt(.{
        .compare = compareWithContext,
        .CompareContext = CompareContext,
        .comparator_id = 2,
        .maximum_key_size = 8,
        .maximum_value_size = 16,
    }));
    const Db = pages.MemoryDatabase(Schema);
    var database = try Db.init(std.testing.allocator, .{
        .page_size = 160,
        .cache_frames = 8,
        .components = .{
            .secondary = .{ .compare_context = .{ .descending = true } },
        },
    });
    defer database.deinit();

    const index = database.get("index");
    const secondary = database.get("secondary");
    try std.testing.expect(try index.insert("shared", "primary"));
    try std.testing.expect(try secondary.insert("shared", "secondary"));

    const index_runtime = &database.core_.components.index;
    const secondary_runtime = &database.core_.components.secondary;
    try std.testing.expect(index_runtime.manager.cache_ptr == &database.core_.cache);
    try std.testing.expect(secondary_runtime.manager.cache_ptr == &database.core_.cache);
    try std.testing.expect(index_runtime.manager.getRoot() != secondary_runtime.manager.getRoot());
    try std.testing.expect(
        Schema.pageKinds("index").endExclusive() <= Schema.pageKinds("secondary").base,
    );

    {
        var found = (try index.find("shared")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("primary", (try found.get()).?.value);
    }
    {
        var found = (try secondary.find("shared")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("secondary", (try found.get()).?.value);
    }
}

test "Pages: BPT deletion returns pages to the shared reuse pool" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("index", pages.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 8,
        .maximum_value_size = 0,
        .rebalance_policy = .force_split,
    }));
    const Db = pages.MemoryDatabase(Schema);
    const keys = [_][]const u8{
        "00000001", "00000002", "00000003", "00000004",
        "00000005", "00000006", "00000007", "00000008",
        "00000009", "00000010", "00000011", "00000012",
        "00000013", "00000014", "00000015", "00000016",
    };
    var database = try Db.init(std.testing.allocator, .{
        .page_size = 84,
        .cache_frames = 32,
    });
    defer database.deinit();
    const tree = database.get("index");

    for (keys) |key| {
        try std.testing.expect(try tree.insert(key, ""));
    }
    const physical_pages = database.core_.cache.physical_page_count;
    try std.testing.expect(physical_pages > 1);
    try std.testing.expectEqual(physical_pages, database.core_.device.blocksCount());

    var index = keys.len;
    while (index > 0) {
        index -= 1;
        try std.testing.expect(try tree.remove(keys[index]));
    }
    try std.testing.expectEqual(null, database.core_.components.index.manager.getRoot());
    try std.testing.expectEqual(physical_pages, database.core_.cache.free_pages.items.len);

    const expected_page_id = database.core_.cache.free_pages.getLast();
    try std.testing.expect(try tree.insert("99999999", ""));
    try std.testing.expectEqual(expected_page_id, database.core_.components.index.manager.getRoot().?);
    try std.testing.expectEqual(physical_pages, database.core_.cache.physical_page_count);
    try std.testing.expectEqual(physical_pages, database.core_.device.blocksCount());
    try std.testing.expectEqual(physical_pages - 1, database.core_.cache.free_pages.items.len);
}

test "Pages: failed BPT initialization rolls back the complete backend" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("index", pages.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const Db = pages.MemoryDatabase(Schema);

    try std.testing.expectError(
        error.InvalidSettings,
        Db.init(std.testing.allocator, .{
            .page_size = 64,
            .cache_frames = 4,
        }),
    );

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .cache_frames = 4,
    });
    database.deinit();
}

test "Pages: memory database generates thirty-two distinct components" {
    const Schema = pages.Schema(.{ .page_id = u32 })
        .add("index_0", stressDescriptor(0))
        .add("index_1", stressDescriptor(1))
        .add("index_2", stressDescriptor(2))
        .add("index_3", stressDescriptor(3))
        .add("index_4", stressDescriptor(4))
        .add("index_5", stressDescriptor(5))
        .add("index_6", stressDescriptor(6))
        .add("index_7", stressDescriptor(7))
        .add("index_8", stressDescriptor(8))
        .add("index_9", stressDescriptor(9))
        .add("index_10", stressDescriptor(10))
        .add("index_11", stressDescriptor(11))
        .add("index_12", stressDescriptor(12))
        .add("index_13", stressDescriptor(13))
        .add("index_14", stressDescriptor(14))
        .add("index_15", stressDescriptor(15))
        .add("index_16", stressDescriptor(16))
        .add("index_17", stressDescriptor(17))
        .add("index_18", stressDescriptor(18))
        .add("index_19", stressDescriptor(19))
        .add("index_20", stressDescriptor(20))
        .add("index_21", stressDescriptor(21))
        .add("index_22", stressDescriptor(22))
        .add("index_23", stressDescriptor(23))
        .add("index_24", stressDescriptor(24))
        .add("index_25", stressDescriptor(25))
        .add("index_26", stressDescriptor(26))
        .add("index_27", stressDescriptor(27))
        .add("index_28", stressDescriptor(28))
        .add("index_29", stressDescriptor(29))
        .add("index_30", stressDescriptor(30))
        .add("index_31", stressDescriptor(31));
    const Db = pages.MemoryDatabase(Schema);
    const runtime_fields = @typeInfo(Db.ComponentsStorageType).@"struct".fields;
    const option_fields = @typeInfo(Db.ComponentInitOptionsType).@"struct".fields;

    try std.testing.expectEqual(@as(usize, 32), Schema.fields.len);
    try std.testing.expectEqual(@as(usize, 32), runtime_fields.len);
    try std.testing.expectEqual(@as(usize, 32), option_fields.len);
    try std.testing.expectEqualStrings("index_0", runtime_fields[0].name);
    try std.testing.expectEqualStrings("index_31", runtime_fields[31].name);
    try std.testing.expect(@FieldType(
        Db.ComponentsStorageType,
        "index_0",
    ) != @FieldType(
        Db.ComponentsStorageType,
        "index_31",
    ));
}
