const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const envelope_capacity = fullaz_db.value_envelope.envelope_byte_size + 2 * @sizeOf(u32);
const Branch = fullaz_db.radix(.{ .Key = u32, .value_size = envelope_capacity });
const Leaf = fullaz_db.radix(.{ .Key = u16, .value_size = 8 });
const Types = fullaz_db.Hierarchy(.{
    .registry_id = 0x7800,
    .types = &.{
        .{
            .tag = "branch",
            .type_id = 1,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = Branch,
            .allowed_child_type_ids = &.{2},
        },
        .{
            .tag = "leaf",
            .type_id = 2,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = Leaf,
            .allowed_child_type_ids = &.{},
        },
    },
});
const Store = fullaz_db.hierarchyStore(Types, .{ .owners = &.{.{
    .tag = "numbers",
    .owner_id = 1,
    .descriptor = fullaz_db.radix(.{
        .Key = u64,
        .value_size = envelope_capacity,
    }),
    .allowed_type_ids = &.{1},
}} });
const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("store", Store);
const owner_key: u64 = 10;
const branch_edge_key: u32 = 0x2000_0020;
const branch_probe_low_key: u32 = 0x4000_0040;
const branch_probe_high_key: u32 = 0xe000_0060;
const leaf_primary_key: u16 = 0x2020;
const leaf_probe_low_key: u16 = 0x4040;
const leaf_probe_high_key: u16 = 0xe060;
const branch_filler_keys = [_]u32{
    0x1000_0001,
    0x3000_0003,
    0x5000_0005,
    0x7000_0007,
    0x9000_0009,
    0xb000_000b,
};
const leaf_filler_keys = [_]u16{
    0x1001,
    0x3003,
    0x5005,
    0x7007,
    0x9009,
    0xb00b,
};
const branch_filler_value = [_]u8{0xc3} ** envelope_capacity;
const branch_probe_low_value = [_]u8{0x4a} ** envelope_capacity;
const branch_probe_high_value = [_]u8{0xe6} ** envelope_capacity;

const RootSnapshot = struct {
    branch_root: u32,
    branch_free_leaf_root: u32,
    leaf_root: u32,
    leaf_free_leaf_root: u32,
};

const MutationResult = struct {
    reused_key: u16,
    roots: RootSnapshot,
};

fn prep(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn initOptions(comptime DatabaseT: type, image_byte: u8) DatabaseT.InitOptions {
    return .{
        .image_id = [_]u8{image_byte} ** 16,
        .components = .{ .store = .{ .owner_0 = .{} } },
    };
}

fn embeddedState(
    comptime StateT: type,
    bytes: []const u8,
    expected_type: fullaz_db.value_envelope.TypeIdentity,
) !StateT {
    const value = try fullaz_db.value_envelope.readEmbedded(bytes, expected_type);
    if (value.payload.len != @sizeOf(StateT)) {
        return error.BadState;
    }
    const state: *const StateT = @ptrCast(value.payload.ptr);
    return state.*;
}

fn captureRoots(comptime DatabaseT: type, database: anytype) !RootSnapshot {
    const BranchState = Branch.Trait.Binding(DatabaseT.BackendType).State;
    const LeafState = Leaf.Trait.Binding(DatabaseT.BackendType).State;
    const owner = database.getConst("store").owner("numbers");
    var branch_entry = (try owner.find(owner_key)).?;
    const branch_state = try embeddedState(
        BranchState,
        (try branch_entry.get()).value,
        Types.typeIdentityByTag("branch"),
    );
    branch_entry.deinit();

    var branch = (try owner.openEmbedded(owner_key, "branch")).?;
    defer branch.deinit();
    var leaf_entry = (try branch.proxy().find(branch_edge_key)).?;
    const leaf_state = try embeddedState(
        LeafState,
        (try leaf_entry.get()).value,
        Types.typeIdentityByTag("leaf"),
    );
    leaf_entry.deinit();

    try std.testing.expect(!branch_state.root.isMax());
    try std.testing.expect(!branch_state.free_leaf_root.isMax());
    try std.testing.expect(branch_state.root.get() != branch_state.free_leaf_root.get());
    try std.testing.expect(!leaf_state.root.isMax());
    try std.testing.expect(!leaf_state.free_leaf_root.isMax());
    try std.testing.expect(leaf_state.root.get() != leaf_state.free_leaf_root.get());
    return .{
        .branch_root = branch_state.root.get(),
        .branch_free_leaf_root = branch_state.free_leaf_root.get(),
        .leaf_root = leaf_state.root.get(),
        .leaf_free_leaf_root = leaf_state.free_leaf_root.get(),
    };
}

fn expectRoots(
    comptime DatabaseT: type,
    database: anytype,
    expected: RootSnapshot,
) !void {
    const actual = try captureRoots(DatabaseT, database);
    try std.testing.expectEqual(expected.branch_root, actual.branch_root);
    try std.testing.expectEqual(
        expected.branch_free_leaf_root,
        actual.branch_free_leaf_root,
    );
    try std.testing.expectEqual(expected.leaf_root, actual.leaf_root);
    try std.testing.expectEqual(
        expected.leaf_free_leaf_root,
        actual.leaf_free_leaf_root,
    );
}

fn expectRadixValue(radix: anytype, key: anytype, expected: []const u8) !void {
    var entry = (try radix.find(key)).?;
    defer entry.deinit();
    try std.testing.expectEqualSlices(u8, expected, (try entry.get()).value);
}

fn populate(comptime DatabaseT: type, database: anytype) !RootSnapshot {
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        const owner = try transaction.get("store").owner("numbers");
        const branch_value = try owner.encodedEmbedded("branch");
        try owner.proxy().set(owner_key, branch_value.data());

        const branch_editor = (try owner.proxy().openValueEditor(owner_key)).?;
        var branch = try owner.openChild(branch_editor, "branch");
        defer branch.deinit();
        for (branch_filler_keys) |key| {
            try branch.proxy().set(key, &branch_filler_value);
        }
        try branch.proxy().set(branch_probe_low_key, &branch_probe_low_value);
        try branch.proxy().set(branch_probe_high_key, &branch_probe_high_value);
        const leaf_value = try branch.encodedEmbedded("leaf");
        try branch.proxy().set(branch_edge_key, leaf_value.data());

        const leaf_editor = (try branch.proxy().openValueEditor(branch_edge_key)).?;
        var leaf = try branch.openChild(leaf_editor, "leaf");
        defer leaf.deinit();
        for (leaf_filler_keys) |key| {
            try leaf.proxy().set(key, "fill0000");
        }
        try leaf.proxy().set(leaf_primary_key, "value030");
        try leaf.proxy().set(leaf_probe_low_key, "leaf-low");
        try leaf.proxy().set(leaf_probe_high_key, "leaf-hi!");
        try leaf.finish();
        try branch.finish();
        try transaction.commit();
    }
    return captureRoots(DatabaseT, database);
}

fn expectGraph(database: anytype, replacement_key: ?u16) !void {
    const owner = database.getConst("store").owner("numbers");
    var branch = (try owner.openEmbedded(owner_key, "branch")).?;
    defer branch.deinit();
    try expectRadixValue(branch.proxy(), branch_probe_low_key, &branch_probe_low_value);
    try expectRadixValue(branch.proxy(), branch_probe_high_key, &branch_probe_high_value);

    var leaf_entry = (try branch.proxy().find(branch_edge_key)).?;
    const leaf_value = (try leaf_entry.get()).value;
    var leaf = try branch.openChild(leaf_entry, leaf_value, "leaf");
    defer leaf.deinit();
    try expectRadixValue(leaf.proxy(), leaf_probe_low_key, "leaf-low");
    try expectRadixValue(leaf.proxy(), leaf_probe_high_key, "leaf-hi!");
    if (replacement_key) |key| {
        try expectRadixValue(leaf.proxy(), key, "reused30");
        if (key != leaf_primary_key) {
            try std.testing.expect((try leaf.proxy().find(leaf_primary_key)) == null);
        }
    } else {
        try expectRadixValue(leaf.proxy(), leaf_primary_key, "value030");
    }
}

fn mutateAfterReopen(comptime DatabaseT: type, database: anytype) !MutationResult {
    var reused_key: u16 = undefined;
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        const owner = try transaction.get("store").owner("numbers");
        const branch_editor = (try owner.proxy().openValueEditor(owner_key)).?;
        var branch = try owner.openChild(branch_editor, "branch");
        defer branch.deinit();
        const leaf_editor = (try branch.proxy().openValueEditor(branch_edge_key)).?;
        var leaf = try branch.openChild(leaf_editor, "leaf");
        defer leaf.deinit();
        try leaf.proxy().free(leaf_primary_key);
        reused_key = (try leaf.proxy().takeFree("reused30")) orelse
            return error.NoReusableRadixKey;
        try expectRadixValue(leaf.proxy(), reused_key, "reused30");
        try leaf.finish();
        try branch.finish();
        try transaction.commit();
    }
    return .{
        .reused_key = reused_key,
        .roots = try captureRoots(DatabaseT, database),
    };
}

test "fullaz-db hierarchyStore: populated Radix graph persists on Static" {
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/hierarchy_radix_static.img";
    const options = initOptions(Database, 0xB1);
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var initial_roots: RootSnapshot = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 1024),
            options,
        );
        defer database.deinit();
        initial_roots = try populate(Database, &database);
    }
    var mutation: MutationResult = undefined;
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, initial_roots);
        try expectGraph(&database, null);
        mutation = try mutateAfterReopen(Database, &database);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, mutation.roots);
        try expectGraph(&database, mutation.reused_key);
    }
}

test "fullaz-db hierarchyStore: populated Radix graph persists on Static WAL" {
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/hierarchy_radix_static_wal.img";
    const log_path = ".zig-cache/hierarchy_radix_static_wal.log";
    const options = initOptions(Database, 0xB2);
    prep(io, image_path);
    prep(io, log_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    var initial_roots: RootSnapshot = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        initial_roots = try populate(Database, &database);
    }
    var mutation: MutationResult = undefined;
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, initial_roots);
        try expectGraph(&database, null);
        mutation = try mutateAfterReopen(Database, &database);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, mutation.roots);
        try expectGraph(&database, mutation.reused_key);
    }
}

test "fullaz-db hierarchyStore: populated Radix graph persists on Virtual Static WAL" {
    const Device = fullaz.device.FileBlock(u64);
    const Log = fullaz.device.FileLog(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/hierarchy_radix_virtual_static_wal.img";
    const log_path = ".zig-cache/hierarchy_radix_virtual_static_wal.log";
    const options = initOptions(Database, 0xB3);
    prep(io, image_path);
    prep(io, log_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    var initial_roots: RootSnapshot = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        initial_roots = try populate(Database, &database);
    }
    var mutation: MutationResult = undefined;
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, initial_roots);
        try expectGraph(&database, null);
        mutation = try mutateAfterReopen(Database, &database);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, mutation.roots);
        try expectGraph(&database, mutation.reused_key);
    }
}

test "fullaz-db hierarchyStore: populated Radix graph persists on Virtual Static CoW" {
    const Device = fullaz.device.FileBlock(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithCow(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/hierarchy_radix_virtual_static_cow.img";
    const options = initOptions(Database, 0xB4);
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var initial_roots: RootSnapshot = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 1024),
            options,
        );
        defer database.deinit();
        initial_roots = try populate(Database, &database);
    }
    var mutation: MutationResult = undefined;
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, initial_roots);
        try expectGraph(&database, null);
        mutation = try mutateAfterReopen(Database, &database);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, mutation.roots);
        try expectGraph(&database, mutation.reused_key);
    }
}

test "fullaz-db hierarchyStore: populated Radix graph persists on Dynamic" {
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.DynamicSchemaDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/hierarchy_radix_dynamic.img";
    const options = initOptions(Database, 0xB5);
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var initial_roots: RootSnapshot = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 1024),
            options,
        );
        defer database.deinit();
        initial_roots = try populate(Database, &database);
    }
    var mutation: MutationResult = undefined;
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, initial_roots);
        try expectGraph(&database, null);
        mutation = try mutateAfterReopen(Database, &database);
    }
    {
        var database = try Database.openReadOnly(
            std.testing.allocator,
            try Device.openReadOnly(io, path, 1024),
            options,
        );
        defer database.deinit();
        try std.testing.expect(!@hasDecl(Database.ReadOnly, "begin"));
        try expectRoots(Database, &database, mutation.roots);
        try expectGraph(&database, mutation.reused_key);
    }
}

test "fullaz-db hierarchyStore: populated Radix graph persists on Dynamic WAL" {
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.DynamicSchemaDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/hierarchy_radix_dynamic_wal.img";
    const log_path = ".zig-cache/hierarchy_radix_dynamic_wal.log";
    const options = initOptions(Database, 0xB6);
    prep(io, image_path);
    prep(io, log_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    var initial_roots: RootSnapshot = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        initial_roots = try populate(Database, &database);
    }
    var mutation: MutationResult = undefined;
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try expectRoots(Database, &database, initial_roots);
        try expectGraph(&database, null);
        mutation = try mutateAfterReopen(Database, &database);
    }
    {
        var database = try Database.openReadOnly(
            std.testing.allocator,
            try Device.openReadOnly(io, image_path, 1024),
            try Log.openReadOnly(io, log_path),
            options,
        );
        defer database.deinit();
        try std.testing.expect(!@hasDecl(Database.ReadOnly, "begin"));
        try expectRoots(Database, &database, mutation.roots);
        try expectGraph(&database, mutation.reused_key);
    }
}
