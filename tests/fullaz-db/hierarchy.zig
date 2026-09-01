const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const FolderTrait = struct {
    pub const kind_name: []const u8 = "test.hierarchy.folder";
    pub const format_version: u32 = 3;
    pub const page_kind_count: usize = 2;
    pub const page_roles: [page_kind_count][]const u8 = .{ "root", "children" };

    pub fn fingerprint(writer: *fullaz_db.HierarchyFingerprintWriter) void {
        writer.writeInt(u16, 0x1001);
    }

    pub fn Binding(comptime BackendT: type) type {
        _ = BackendT;
        return struct {};
    }
};

const DocumentTrait = struct {
    pub const kind_name: []const u8 = "test.hierarchy.document";
    pub const format_version: u32 = 5;
    pub const page_kind_count: usize = 1;
    pub const page_roles: [page_kind_count][]const u8 = .{"contents"};

    pub fn fingerprint(writer: *fullaz_db.HierarchyFingerprintWriter) void {
        writer.writeInt(u16, 0x1002);
    }

    pub fn Binding(comptime BackendT: type) type {
        _ = BackendT;
        return struct {};
    }
};

const hierarchy = fullaz_db.Hierarchy(.{
    .registry_id = 0x0123_4567_89ab_cdef,
    .types = &.{
        .{
            .tag = "folder",
            .type_id = 10,
            .type_version = 2,
            .metadata_format_version = 1,
            .descriptor = .{ .Trait = FolderTrait },
            .allowed_child_type_ids = &.{ 10, 20 },
        },
        .{
            .tag = "document",
            .type_id = 20,
            .type_version = 4,
            .metadata_format_version = 1,
            .descriptor = .{ .Trait = DocumentTrait },
            .allowed_child_type_ids = &.{},
        },
    },
});

const reordered_child_policy = fullaz_db.Hierarchy(.{
    .registry_id = 0x0123_4567_89ab_cdef,
    .types = &.{
        .{
            .tag = "folder",
            .type_id = 10,
            .type_version = 2,
            .metadata_format_version = 1,
            .descriptor = .{ .Trait = FolderTrait },
            .allowed_child_type_ids = &.{ 20, 10 },
        },
        .{
            .tag = "document",
            .type_id = 20,
            .type_version = 4,
            .metadata_format_version = 1,
            .descriptor = .{ .Trait = DocumentTrait },
            .allowed_child_type_ids = &.{},
        },
    },
});

const changed_version = fullaz_db.Hierarchy(.{
    .registry_id = 0x0123_4567_89ab_cdef,
    .types = &.{
        .{
            .tag = "folder",
            .type_id = 10,
            .type_version = 3,
            .metadata_format_version = 1,
            .descriptor = .{ .Trait = FolderTrait },
            .allowed_child_type_ids = &.{ 10, 20 },
        },
        .{
            .tag = "document",
            .type_id = 20,
            .type_version = 4,
            .metadata_format_version = 1,
            .descriptor = .{ .Trait = DocumentTrait },
            .allowed_child_type_ids = &.{},
        },
    },
});

test "fullaz-db hierarchy: exposes nominal lookups without page allocation" {
    const folder = hierarchy.entryByTag("folder");
    const document = hierarchy.entryByTypeId(20);

    try std.testing.expectEqual(@as(usize, 2), hierarchy.type_count);
    try std.testing.expect(hierarchy.descriptorByTag("folder").Trait == folder.descriptor.Trait);
    try std.testing.expect(hierarchy.descriptorByTypeId(20).Trait == document.descriptor.Trait);
    try std.testing.expect(hierarchy.descriptorByTag("folder").Trait == FolderTrait);
    try std.testing.expect(hierarchy.descriptorByTypeId(20).Trait == DocumentTrait);

    const identity = hierarchy.typeIdentityByTag("folder");
    const document_identity = hierarchy.typeIdentityByTypeId(20);
    try std.testing.expectEqual(hierarchy.registry_id, identity.registry_id);
    try std.testing.expectEqual(@as(u64, 10), identity.type_id);
    try std.testing.expectEqual(@as(u32, 2), identity.type_version);
    try std.testing.expectEqual(@as(u64, 20), document_identity.type_id);
    try std.testing.expect(hierarchy.allowsChild(10, 10));
    try std.testing.expect(hierarchy.allowsChild(10, 20));
    try std.testing.expect(!hierarchy.allowsChild(20, 10));
}

test "fullaz-db hierarchy: fingerprint is durable and policy-order independent" {
    const digest = hierarchy.digest();
    try std.testing.expectEqualSlices(u8, &digest, &reordered_child_policy.digest());
    try std.testing.expect(!std.mem.eql(u8, &digest, &changed_version.digest()));

    var hasher = std.crypto.hash.Blake3.init(.{});
    var writer = fullaz_db.HierarchyFingerprintWriter{ .hasher = &hasher };
    hierarchy.writeFingerprint(&writer);
    var written_digest: [32]u8 = undefined;
    hasher.final(&written_digest);
    try std.testing.expectEqualSlices(u8, &digest, &written_digest);
}

test "fullaz-db hierarchyStore: assigns one owner range followed by shared type ranges" {
    const OwnerDescriptor = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 16,
        .maximum_value_size = 96,
        .fixed_value_size = 96,
    });
    const StoreHierarchy = fullaz_db.Hierarchy(.{
        .registry_id = 0x7788,
        .types = &.{
            .{
                .tag = "folder",
                .type_id = 10,
                .type_version = 1,
                .metadata_format_version = 1,
                .descriptor = OwnerDescriptor,
                .allowed_child_type_ids = &.{ 10, 20 },
            },
            .{
                .tag = "document",
                .type_id = 20,
                .type_version = 1,
                .metadata_format_version = 1,
                .descriptor = OwnerDescriptor,
                .allowed_child_type_ids = &.{},
            },
        },
    });
    const Store = fullaz_db.hierarchyStore(StoreHierarchy, .{ .owners = &.{.{
        .tag = "files",
        .owner_id = 1,
        .descriptor = OwnerDescriptor,
        .allowed_type_ids = &.{ 10, 20 },
    }} });

    try std.testing.expectEqual(@as(usize, 6), Store.Trait.page_kind_count);
    try std.testing.expectEqualStrings("owner.files.leaf", Store.Trait.page_roles[0]);
    try std.testing.expectEqualStrings("owner.files.inode", Store.Trait.page_roles[1]);
    try std.testing.expectEqualStrings("type.folder.leaf", Store.Trait.page_roles[2]);
    try std.testing.expectEqualStrings("type.folder.inode", Store.Trait.page_roles[3]);
    try std.testing.expectEqualStrings("type.document.leaf", Store.Trait.page_roles[4]);
    try std.testing.expectEqualStrings("type.document.inode", Store.Trait.page_roles[5]);
}

test "fullaz-db hierarchyStore: composes BPT, R-tree, and SlotHeap owners" {
    const Bpt = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 11,
        .maximum_key_size = 16,
        .maximum_value_size = 128,
        .fixed_value_size = 128,
    });
    const Rtree = fullaz_db.rtree(.{
        .Coord = i32,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 96,
    });
    const Heap = fullaz_db.slotHeap(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 12,
        .maximum_key_size = 16,
        .maximum_value_size = 96,
        .maximum_level = 4,
        .size_classes = fullaz_db.SlotHeapSizeClasses{ .one = {} },
    });
    const Types = fullaz_db.Hierarchy(.{
        .registry_id = 0x7799,
        .types = &.{.{
            .tag = "node",
            .type_id = 1,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = Bpt,
            .allowed_child_type_ids = &.{1},
        }},
    });
    const Store = fullaz_db.hierarchyStore(Types, .{ .owners = &.{
        .{ .tag = "names", .owner_id = 1, .descriptor = Bpt, .allowed_type_ids = &.{1} },
        .{ .tag = "places", .owner_id = 2, .descriptor = Rtree, .allowed_type_ids = &.{1} },
        .{ .tag = "queue", .owner_id = 3, .descriptor = Heap, .allowed_type_ids = &.{1} },
    } });
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("store", Store);
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicSchemaDatabase(Schema, Device);
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        .{ .image_id = [_]u8{0x79} ** 16, .components = .{ .store = .{
            .owner_0 = .{ .compare_context = {} },
            .owner_1 = .{},
            .owner_2 = .{ .compare_context = {} },
        } } },
    );
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    var store = transaction.get("store");
    var names = store.owner("names");
    try std.testing.expect(try names.insert("one", try names.raw("node", "value")));
    const Box = fullaz.spatial.BoundingBox(i32, 2);
    try store.owner("places").insert(
        Box.initWith(.{ 1, 1 }, .{ 2, 2 }),
        try store.owner("places").raw("node", "place"),
    );
    try store.owner("queue").push("queue-key-000001", try store.owner("queue").raw("node", "value"));
    try transaction.commit();
}

test "fullaz-db hierarchyStore: BPT owner edits recursive embedded envelopes" {
    const Bpt = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 21,
        .maximum_key_size = 32,
        .maximum_value_size = 96,
        .fixed_value_size = 96,
    });
    const Types = fullaz_db.Hierarchy(.{
        .registry_id = 0x77aa,
        .types = &.{.{
            .tag = "folder",
            .type_id = 1,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = Bpt,
            .allowed_child_type_ids = &.{1},
        }},
    });
    const Store = fullaz_db.hierarchyStore(Types, .{ .owners = &.{.{
        .tag = "files",
        .owner_id = 1,
        .descriptor = Bpt,
        .allowed_type_ids = &.{1},
    }} });
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("store", Store);
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicSchemaDatabase(Schema, Device);
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        .{ .image_id = [_]u8{0x7a} ** 16, .components = .{ .store = .{ .owner_0 = .{} } } },
    );
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    var store = transaction.get("store");
    var files = store.owner("files");
    try std.testing.expect(try files.insert("raw", try files.raw("folder", "plain")));
    try std.testing.expect(try files.insert("root", try files.embed("folder")));

    var root = (try files.openEmbeddedForEdit("root", "folder")).?;
    defer root.deinit();
    try std.testing.expect(try root.insert("child", root.raw("folder", "value")));
    try std.testing.expect(try root.insert("nested", try root.embed("folder")));

    var nested = (try root.openEmbeddedForEdit("nested", "folder")).?;
    defer nested.deinit();
    try std.testing.expect(try nested.insert("leaf", nested.raw("folder", "nested value")));
    try nested.finish();
    try root.finish();
    try transaction.commit();

    const files_const = database.getConst("store").owner("files");
    try std.testing.expect(!@hasDecl(@TypeOf(files_const.*), "insert"));
    try std.testing.expectError(
        error.IncorrectKind,
        files_const.openEmbeddedBpt("raw", "folder"),
    );
    try std.testing.expectEqual(null, try files_const.openEmbeddedBpt("missing", "folder"));
    var reader = (try files_const.openEmbeddedBpt("root", "folder")).?;
    defer reader.deinit();
    try std.testing.expect(!@hasDecl(@TypeOf(reader), "insert"));
    try std.testing.expect(!@hasDecl(@TypeOf(reader).Iterator, "editValue"));
    var child = (try reader.find("child")).?;
    defer child.deinit();
    const value = try fullaz_db.value_envelope.readRaw(
        (try child.get()).?.value,
        Types.typeIdentityByTag("folder"),
    );
    try std.testing.expectEqualStrings("value", value.payload);
}

test "fullaz-db hierarchyBpt: const proxy opens an embedded BPT reader" {
    const Bpt = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 22,
        .maximum_key_size = 32,
        .maximum_value_size = 96,
        .fixed_value_size = 96,
    });
    const Types = fullaz_db.Hierarchy(.{ .registry_id = 0x77ab, .types = &.{.{
        .tag = "folder",
        .type_id = 1,
        .type_version = 1,
        .metadata_format_version = 1,
        .descriptor = Bpt,
        .allowed_child_type_ids = &.{},
    }} });
    const Tree = fullaz_db.hierarchyBpt(Types, Bpt);
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("tree", Tree);
    const Database = fullaz_db.MemoryDatabase(Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 1024,
        .components = .{ .tree = .{} },
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        var tree = transaction.get("tree");
        try std.testing.expect(try tree.insert("root", tree.embed("folder")));
        var editor = (try tree.openEmbeddedForEdit("root", "folder")).?;
        defer editor.deinit();
        try std.testing.expect(try editor.insert("child", editor.raw("folder", "value")));
        try editor.finish();
        try transaction.commit();
    }

    const tree_const = database.getConst("tree");
    try std.testing.expect(!@hasDecl(@TypeOf(tree_const.*), "insert"));
    var reader = (try tree_const.openEmbeddedBpt("root", "folder")).?;
    defer reader.deinit();
    var child = (try reader.find("child")).?;
    defer child.deinit();
    const value = try fullaz_db.value_envelope.readRaw(
        (try child.get()).?.value,
        Types.typeIdentityByTag("folder"),
    );
    try std.testing.expectEqualStrings("value", value.payload);
}

test "fullaz-db hierarchyStore: aggregate owners trace nested envelopes" {
    const Bpt = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 31,
        .maximum_key_size = 32,
        .maximum_value_size = 128,
        .fixed_value_size = 128,
    });
    const Rtree = fullaz_db.rtree(.{
        .Coord = i32,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 128,
    });
    const Heap = fullaz_db.slotHeap(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 32,
        .maximum_key_size = 16,
        .maximum_value_size = 128,
        .maximum_level = 4,
        .size_classes = fullaz_db.SlotHeapSizeClasses{ .one = {} },
    });
    const Types = fullaz_db.Hierarchy(.{
        .registry_id = 0x77bb,
        .types = &.{
            .{ .tag = "bpt", .type_id = 1, .type_version = 1, .metadata_format_version = 1, .descriptor = Bpt, .allowed_child_type_ids = &.{2} },
            .{ .tag = "rtree", .type_id = 2, .type_version = 1, .metadata_format_version = 1, .descriptor = Rtree, .allowed_child_type_ids = &.{3} },
            .{ .tag = "heap", .type_id = 3, .type_version = 1, .metadata_format_version = 1, .descriptor = Heap, .allowed_child_type_ids = &.{1} },
        },
    });
    const Store = fullaz_db.hierarchyStore(Types, .{ .owners = &.{
        .{ .tag = "files", .owner_id = 1, .descriptor = Bpt, .allowed_type_ids = &.{1} },
        .{ .tag = "places", .owner_id = 2, .descriptor = Rtree, .allowed_type_ids = &.{2} },
        .{ .tag = "queue", .owner_id = 3, .descriptor = Heap, .allowed_type_ids = &.{3} },
    } });
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("store", Store);
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicSchemaDatabase(Schema, Device);
    const Box = fullaz.spatial.BoundingBox(i32, 2);
    const point = Box.initWith(.{ 1, 1 }, .{ 2, 2 });
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        .{ .image_id = [_]u8{0x7b} ** 16, .components = .{ .store = .{
            .owner_0 = .{},
            .owner_1 = .{},
            .owner_2 = .{ .compare_context = {} },
        } } },
    );
    defer database.deinit();

    var rtree_root: u32 = undefined;
    var heap_root: u32 = undefined;
    var bpt_root: u32 = undefined;
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        var store = transaction.get("store");
        var places = store.owner("places");
        try places.insert(point, try places.embed("rtree"));
        var top_rtree = (try places.openEmbeddedHitForEdit(point, {}, struct {
            fn matches(_: void, _: Box, _: []const u8) bool {
                return true;
            }
        }.matches, "rtree")).?;
        defer top_rtree.deinit();
        try top_rtree.finish();
        var queue = store.owner("queue");
        try queue.push("queue-key-000001", try queue.embed("heap"));
        var top_heap = (try queue.openEmbeddedForEdit({}, "heap")).?;
        defer top_heap.deinit();
        try top_heap.finish();
        var files = store.owner("files");
        try std.testing.expectError(error.TypeNotAllowed, files.embed("rtree"));
        try std.testing.expect(try files.insert("chain", try files.embed("bpt")));
        var bpt = (try files.openEmbeddedForEdit("chain", "bpt")).?;
        defer bpt.deinit();
        try std.testing.expect(try bpt.insert("spatial", try bpt.embed("rtree")));
        var rtree = (try bpt.openEmbeddedForEdit("spatial", "rtree")).?;
        defer rtree.deinit();
        try rtree.insert(point, try rtree.embed("heap"));
        rtree_root = rtree.root().?;
        var heap = (try rtree.openEmbeddedForEdit(point, {}, struct {
            fn matches(_: void, _: Box, _: []const u8) bool {
                return true;
            }
        }.matches, "heap")).?;
        defer heap.deinit();
        try heap.push("top-key-00000001", try heap.embed("bpt"));
        heap_root = heap.root().?;
        var leaf = try heap.openEmbeddedForEdit("bpt");
        defer leaf.deinit();
        try std.testing.expect(try leaf.insert("value", leaf.raw("bpt", "ok")));
        bpt_root = leaf.root().?;
        try leaf.finish();
        try heap.finish();
        try rtree.finish();
        try bpt.finish();
        try transaction.commit();
    }
    try database.startGarbageCollection();
    while (try database.stepGarbageCollection(1) != .complete) {}
    inline for (.{ rtree_root, heap_root, bpt_root }) |page_id| {
        var page = try database.cache().fetch(page_id);
        page.deinit();
    }
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try std.testing.expect(try transaction.get("store").owner("files").remove("chain"));
        try transaction.commit();
    }
    try database.startGarbageCollection();
    while (try database.stepGarbageCollection(1) != .complete) {}
    inline for (.{ rtree_root, heap_root, bpt_root }) |page_id| {
        try std.testing.expectError(error.PageNotAllocated, database.cache().fetch(page_id));
    }
}

test "fullaz-db hierarchyStore: memory and static databases construct and persist" {
    const Bpt = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 41,
        .maximum_key_size = 16,
        .maximum_value_size = 96,
        .fixed_value_size = 96,
    });
    const Types = fullaz_db.Hierarchy(.{ .registry_id = 0x77cc, .types = &.{.{
        .tag = "node",
        .type_id = 1,
        .type_version = 1,
        .metadata_format_version = 1,
        .descriptor = Bpt,
        .allowed_child_type_ids = &.{},
    }} });
    const Store = fullaz_db.hierarchyStore(Types, .{ .owners = &.{.{
        .tag = "files",
        .owner_id = 1,
        .descriptor = Bpt,
        .allowed_type_ids = &.{1},
    }} });
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("store", Store);
    const Memory = fullaz_db.MemoryDatabase(Schema);
    var memory = try Memory.init(std.testing.allocator, .{
        .page_size = 1024,
        .components = .{ .store = .{ .owner_0 = .{} } },
    });
    defer memory.deinit();
    var memory_transaction = try memory.begin();
    defer memory_transaction.deinit();
    var memory_files = memory_transaction.get("store").owner("files");
    try std.testing.expect(try memory_files.insert("node", try memory_files.raw("node", "memory")));
    try memory_transaction.commit();

    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_hierarchy_store.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x7c} ** 16,
        .components = .{ .store = .{ .owner_0 = .{} } },
    };
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 1024),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        var files = transaction.get("store").owner("files");
        try std.testing.expect(try files.insert("node", try files.raw("node", "static")));
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        var found = (try database.getConst("store").owner("files").find("node")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("static", (try found.get()).?.value[64..70]);
    }
}
