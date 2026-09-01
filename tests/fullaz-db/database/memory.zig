const std = @import("std");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const CompareContext = struct {
    descending: bool,
};

fn compareWithContext(
    context: CompareContext,
    left: []const u8,
    right: []const u8,
) std.math.Order {
    const order = compare({}, left, right);
    if (!context.descending) {
        return order;
    }
    return order.invert();
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
            pub const ConstProxy = Runtime;
            pub const InitOptions = struct {};
            pub const TransactionState = void;
            pub const Error = error{SyntheticFailure};

            pub fn initRuntime(
                runtime: *Runtime,
                backend: *BackendT,
                page_kinds: fullaz_db.PageKindRange,
                init_options: InitOptions,
            ) Error!void {
                runtime.* = .{};
                _ = backend;
                _ = page_kinds;
                _ = init_options;
            }

            pub fn deinitRuntime(_: *Runtime) void {}

            pub fn requireTransactionIdle(_: *const Runtime) Error!void {}

            pub fn captureTransactionState(_: *const Runtime) TransactionState {}

            pub fn restoreTransactionState(_: *Runtime, _: TransactionState) void {}

            pub fn proxy(runtime: *Runtime) Proxy {
                return runtime.*;
            }

            pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
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
                pub const ConstProxy = Runtime;
                pub const InitOptions = struct {
                    state: *LifecycleState,
                };
                pub const TransactionState = void;
                pub const Error = error{SyntheticFailure};

                pub fn initRuntime(
                    runtime: *Runtime,
                    backend: *BackendT,
                    page_kinds: fullaz_db.PageKindRange,
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

                pub fn requireTransactionIdle(_: *const Runtime) Error!void {}

                pub fn captureTransactionState(_: *const Runtime) TransactionState {}

                pub fn restoreTransactionState(_: *Runtime, _: TransactionState) void {}

                pub fn proxy(runtime: *Runtime) Proxy {
                    return runtime.*;
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
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
        ) std.math.Order {
            return std.mem.order(u8, left, right);
        }
    };
}

fn stressDescriptor(comptime index: usize) fullaz_db.Descriptor {
    const Context = StressContext(index);
    const Comparator = StressComparator(Context);
    return fullaz_db.bpt(.{
        .compare = Comparator.compare,
        .CompareContext = Context,
        .comparator_id = index + 1,
        .maximum_key_size = 8,
        .maximum_value_size = 8,
    });
}

test "fullaz-db: empty memory database owns a pointer-stable backend" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Db = fullaz_db.MemoryDatabase(Schema);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .cache_frames = 4,
    });
    const diagnostics_before = database.diagnostics();

    var moved = database;
    database = undefined;
    defer moved.deinit();

    const diagnostics_after = moved.diagnostics();
    try std.testing.expectEqual(diagnostics_before.core_address, diagnostics_after.core_address);
    try std.testing.expectEqual(diagnostics_before.cache_address, diagnostics_after.cache_address);
    try std.testing.expectEqual(diagnostics_before.device_address, diagnostics_after.device_address);
    try std.testing.expectEqual(@as(usize, 4096), diagnostics_after.page_size);
}

test "fullaz-db: memory database rejects zero cache frames" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Db = fullaz_db.MemoryDatabase(Schema);

    try std.testing.expectError(
        error.InvalidCacheFrames,
        Db.init(std.testing.allocator, .{
            .page_size = 4096,
            .cache_frames = 0,
        }),
    );
}

test "fullaz-db: memory database generates exact runtime storage fields" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 64,
            .maximum_value_size = 128,
        }))
        .add("secondary", fullaz_db.bpt(.{
        .compare = compareWithContext,
        .CompareContext = CompareContext,
        .comparator_id = 2,
        .maximum_key_size = 32,
        .maximum_value_size = 48,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
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

test "fullaz-db: memory database generates conditional component option defaults" {
    const MixedSchema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 64,
            .maximum_value_size = 128,
        }))
        .add("secondary", fullaz_db.bpt(.{
        .compare = compareWithContext,
        .CompareContext = CompareContext,
        .comparator_id = 2,
        .maximum_key_size = 32,
        .maximum_value_size = 48,
    }));
    const MixedDb = fullaz_db.MemoryDatabase(MixedSchema);
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

    const DefaultSchema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 3,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const DefaultDb = fullaz_db.MemoryDatabase(DefaultSchema);
    const default_init_fields = @typeInfo(DefaultDb.InitOptions).@"struct".fields;
    try std.testing.expect(default_init_fields[2].default_value_ptr != null);
    const default_options = DefaultDb.InitOptions{ .page_size = 4096 };
    try std.testing.expectEqual(@as(usize, 64), default_options.cache_frames);
}

test "fullaz-db: memory database composes exact component errors" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("synthetic", .{ .Trait = SyntheticTrait });
    const Db = fullaz_db.MemoryDatabase(Schema);
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

test "fullaz-db: memory database rolls back the initialized component prefix" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("first", .{ .Trait = LifecycleTrait('a', false) })
        .add("second", .{ .Trait = LifecycleTrait('b', true) });
    const Db = fullaz_db.MemoryDatabase(Schema);
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

test "fullaz-db: memory database deinitializes components in reverse order" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("first", .{ .Trait = LifecycleTrait('a', false) })
        .add("second", .{ .Trait = LifecycleTrait('b', false) })
        .add("third", .{ .Trait = LifecycleTrait('c', false) });
    const Db = fullaz_db.MemoryDatabase(Schema);
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

test "fullaz-db: memory database returns an exact typed BPT proxy" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("index").Binding(Db.BackendType);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .cache_frames = 8,
    });
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    const tree = transaction.get("index");
    try std.testing.expect(@TypeOf(tree) == Binding.Proxy);
    try std.testing.expect(!@hasDecl(Binding.ConstProxy, "insert"));
    try std.testing.expect(!@hasField(Binding.ConstProxy.Iterator, "node"));
    try std.testing.expect(!@hasField(Binding.ConstProxy.Iterator, "model"));
    try std.testing.expect(try tree.insert("hello", "world"));
    try transaction.commit();
    try std.testing.expectError(error.TransactionInactive, tree.insert("outside", "transaction"));

    var found = (try database.getConst("index").find("hello")).?;
    const entry = (try found.get()).?;
    try std.testing.expectEqualStrings("world", entry.value);
    found.deinit();

    var next_transaction = try database.begin();
    defer next_transaction.deinit();
    try std.testing.expectError(error.TransactionInactive, tree.insert("stale", "proxy"));
    try std.testing.expect(try next_transaction.get("index").insert("inside", "transaction"));
    try next_transaction.rollback();

    const database_const: *const Db = &database;
    const tree_const = database_const.getConst("index");
    try std.testing.expect(@TypeOf(tree_const) == *const Binding.ConstProxy);
}

test "fullaz-db: BPT value editors gate terminal operations and preserve cancellation" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 16,
        .maximum_value_size = 16,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("index").Binding(Db.BackendType);

    try std.testing.expect(@hasDecl(Binding.Proxy.Iterator, "editValue"));
    try std.testing.expect(!@hasDecl(Binding.ConstProxy.Iterator, "editValue"));
    try std.testing.expect(@hasDecl(Binding.Proxy, "openValueEditor"));
    try std.testing.expect(!@hasDecl(Binding.ConstProxy, "openValueEditor"));

    var database = try Db.init(std.testing.allocator, .{ .page_size = 512, .cache_frames = 8 });
    defer database.deinit();

    {
        var transaction = try database.begin();
        try std.testing.expect(try transaction.get("index").insert("key", "first"));
        try transaction.commit();
    }

    var transaction = try database.begin();
    const index = transaction.get("index");
    var editor = (try index.openValueEditor("key")).?;
    @memcpy(try editor.valueMut(), "final");
    try std.testing.expectError(error.ValueEditorActive, transaction.commit());
    try editor.finish();
    try transaction.commit();
    try std.testing.expectError(error.TransactionInactive, editor.valueMut());

    {
        var found = (try database.getConst("index").find("key")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("final", (try found.get()).?.value);
    }

    var cancelled = try database.begin();
    const cancelled_index = cancelled.get("index");
    {
        var iterator = (try cancelled_index.find("key")).?;
        defer iterator.deinit();
        var cancelled_editor = (try iterator.editValue()).?;
        @memcpy(try cancelled_editor.valueMut(), "wrong");
        cancelled_editor.deinit();
    }
    try cancelled.rollback();

    var found = (try database.getConst("index").find("key")).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("final", (try found.get()).?.value);
}

test "fullaz-db: BPT splits byte-skewed variable values on 512-byte pages" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 8,
        .maximum_value_size = 64,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 512,
        .cache_frames = 256,
    });
    defer database.deinit();

    var value: [64]u8 = undefined;
    @memset(&value, 'x');
    var prng = std.Random.DefaultPrng.init(0xD15A_7C4);
    const random = prng.random();

    for (0..7000) |index| {
        var key_buffer: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{index});
        const value_len = random.intRangeAtMost(usize, 1, value.len);
        var transaction = try database.begin();
        defer transaction.deinit();
        try std.testing.expect(
            try transaction.get("index").insert(key, value[0..value_len]),
        );
        try transaction.commit();
    }

    var iterator = (try database.getConst("index").iterator()).?;
    defer iterator.deinit();
    var count: usize = 0;
    while (try iterator.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 7000), count);
}

test "fullaz-db: memory database transaction commits or restores pages and roots" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("index").Binding(Db.BackendType);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .cache_frames = 4,
    });
    defer database.deinit();

    var rolled_back = try database.begin();
    var stale = rolled_back;
    const rolled_back_tree = rolled_back.get("index");
    try std.testing.expect(@TypeOf(rolled_back_tree) == Binding.Proxy);
    try std.testing.expect(try rolled_back_tree.insert("discarded", "value"));
    try std.testing.expectError(error.BatchActive, database.begin());
    try rolled_back.rollback();

    const rolled_back_diagnostics = database.diagnostics();
    try std.testing.expectEqual(@as(usize, 0), rolled_back_diagnostics.physical_page_count);
    try std.testing.expectEqual(@as(usize, 0), rolled_back_diagnostics.device_page_count);
    try std.testing.expectEqual(null, try database.getConst("index").find("discarded"));

    var committed = try database.begin();
    defer committed.deinit();
    try std.testing.expectError(error.TransactionInactive, stale.commit());
    try std.testing.expect(try committed.get("index").insert("committed", "value"));
    try committed.commit();

    const committed_diagnostics = database.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), committed_diagnostics.physical_page_count);
    try std.testing.expectEqual(@as(usize, 1), committed_diagnostics.device_page_count);
    var found = (try database.getConst("index").find("committed")).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("value", (try found.get()).?.value);
}

test "fullaz-db: read facade releases a low-level iterator after allocation failure" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});

    var database = try Db.init(failing.allocator(), .{
        .page_size = 4096,
        .cache_frames = 4,
    });
    defer database.deinit();
    var transaction = try database.begin();
    defer transaction.deinit();
    try std.testing.expect(try transaction.get("index").insert("key", "value"));
    try transaction.commit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, database.getConst("index").find("key"));
}

test "fullaz-db: transaction restores a failed root leaf split" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 8,
        .maximum_value_size = 0,
        .rebalance_policy = .force_split,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 84,
        .cache_frames = 2,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        const tree = transaction.get("index");
        try std.testing.expect(try tree.insert("00000001", ""));
        try std.testing.expect(try tree.insert("00000002", ""));
        try std.testing.expect(try tree.insert("00000003", ""));
        try transaction.commit();
    }

    const diagnostics_before = database.diagnostics();
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try std.testing.expectError(
            error.BatchTooLarge,
            transaction.get("index").insert("00000004", ""),
        );
    }

    const diagnostics_after = database.diagnostics();
    try std.testing.expectEqual(diagnostics_before.physical_page_count, diagnostics_after.physical_page_count);
    try std.testing.expectEqual(diagnostics_before.device_page_count, diagnostics_after.device_page_count);
    try std.testing.expectEqual(diagnostics_before.free_page_count, diagnostics_after.free_page_count);
    inline for ([_][]const u8{ "00000001", "00000002", "00000003" }) |key| {
        var found = (try database.getConst("index").find(key)).?;
        found.deinit();
    }
    try std.testing.expectEqual(null, try database.getConst("index").find("00000004"));
}

test "fullaz-db: transaction restores a failed cascading split" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 8,
        .maximum_value_size = 0,
        .rebalance_policy = .force_split,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const keys = [_][]const u8{
        "00000001", "00000002", "00000003",
        "00000004", "00000005", "00000006",
    };

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 84,
        .cache_frames = 3,
    });
    defer database.deinit();

    for (keys) |key| {
        var transaction = try database.begin();
        defer transaction.deinit();
        try std.testing.expect(try transaction.get("index").insert(key, ""));
        try transaction.commit();
    }

    const diagnostics_before = database.diagnostics();
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try std.testing.expectError(
            error.BatchTooLarge,
            transaction.get("index").insert("00000007", ""),
        );
        try std.testing.expectError(error.TransactionRollbackOnly, transaction.commit());
    }

    const diagnostics_after = database.diagnostics();
    try std.testing.expectEqual(diagnostics_before.physical_page_count, diagnostics_after.physical_page_count);
    try std.testing.expectEqual(diagnostics_before.device_page_count, diagnostics_after.device_page_count);
    try std.testing.expectEqual(diagnostics_before.free_page_count, diagnostics_after.free_page_count);
    var iterator = (try database.getConst("index").iterator()).?;
    defer iterator.deinit();
    for (keys) |key| {
        const entry = (try iterator.next()).?;
        try std.testing.expectEqualStrings(key, entry.key);
    }
    try std.testing.expectEqual(null, try iterator.next());
    try std.testing.expectEqual(null, try database.getConst("index").find("00000007"));
}

test "fullaz-db: two BPT components share one cache and keep independent roots" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 8,
            .maximum_value_size = 16,
        }))
        .add("secondary", fullaz_db.bpt(.{
        .compare = compareWithContext,
        .CompareContext = CompareContext,
        .comparator_id = 2,
        .maximum_key_size = 8,
        .maximum_value_size = 16,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    var database = try Db.init(std.testing.allocator, .{
        .page_size = 160,
        .cache_frames = 8,
        .components = .{
            .secondary = .{ .compare_context = .{ .descending = true } },
        },
    });
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    const index = transaction.get("index");
    const secondary = transaction.get("secondary");
    try std.testing.expect(try index.insert("shared", "primary"));
    try std.testing.expect(try secondary.insert("shared", "secondary"));
    try transaction.commit();

    try std.testing.expect(
        Schema.pageKinds("index").endExclusive() <= Schema.pageKinds("secondary").base,
    );
    try std.testing.expectEqual(@as(usize, 2), database.diagnostics().physical_page_count);

    {
        var found = (try database.getConst("index").find("shared")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("primary", (try found.get()).?.value);
    }
    {
        var found = (try database.getConst("secondary").find("shared")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("secondary", (try found.get()).?.value);
    }
}

test "fullaz-db: BPT deletion returns pages to the shared reuse pool" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 8,
        .maximum_value_size = 0,
        .rebalance_policy = .force_split,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
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
    var transaction = try database.begin();
    defer transaction.deinit();
    const tree = transaction.get("index");

    for (keys) |key| {
        try std.testing.expect(try tree.insert(key, ""));
    }
    const physical_pages = database.diagnostics().physical_page_count;
    try std.testing.expect(physical_pages > 1);
    try std.testing.expectEqual(physical_pages, database.diagnostics().device_page_count);

    var index = keys.len;
    while (index > 0) {
        index -= 1;
        try std.testing.expect(try tree.remove(keys[index]));
    }
    try std.testing.expectEqual(physical_pages, database.diagnostics().free_page_count);

    try std.testing.expect(try tree.insert("99999999", ""));
    try std.testing.expectEqual(physical_pages, database.diagnostics().physical_page_count);
    try std.testing.expectEqual(physical_pages, database.diagnostics().device_page_count);
    try std.testing.expectEqual(physical_pages - 1, database.diagnostics().free_page_count);
    try transaction.commit();
}

test "fullaz-db: failed BPT initialization rolls back the complete backend" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);

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

test "fullaz-db: memory database generates thirty-two distinct components" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
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
    const Db = fullaz_db.MemoryDatabase(Schema);
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
