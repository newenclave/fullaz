const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

const MetadataBinding = struct {
    pub const Runtime = struct { root: u64 = 0 };
    pub const DynamicMetadata = struct {
        pub const format_version: u32 = 1;
        pub const known_tags: []const u16 = &.{0x0100};
        pub const repeated_tags: []const u16 = &.{};
        pub const Error = fullaz_db.file.dynamic_metadata.Error;

        pub fn restore(runtime: *Runtime, payload: []const u8, _: usize) Error!void {
            var reader = fullaz_db.file.tagged_fields.Reader.init(payload);
            while (try reader.next()) |field| {
                if (field.tag == known_tags[0]) {
                    runtime.root = try fullaz_db.file.dynamic_metadata.readU64(field);
                    return;
                }
            }
            return error.BadMetadata;
        }

        pub fn encodeKnown(
            runtime: *const Runtime,
            writer: *fullaz_db.file.tagged_fields.Writer,
        ) Error!void {
            try fullaz_db.file.dynamic_metadata.appendU64(writer, known_tags[0], runtime.root);
        }
    };
};

const MigratingMetadataBinding = struct {
    pub const Runtime = struct { root: u64 = 0 };
    pub const DynamicMetadata = struct {
        pub const format_version: u32 = 2;
        pub const known_tags: []const u16 = &.{0x0100};
        pub const repeated_tags: []const u16 = &.{};
        pub const Error = fullaz_db.file.dynamic_metadata.Error;

        pub fn restore(runtime: *Runtime, payload: []const u8, _: usize) Error!void {
            var reader = fullaz_db.file.tagged_fields.Reader.init(payload);
            while (try reader.next()) |field| {
                if (field.tag == known_tags[0]) {
                    runtime.root = try fullaz_db.file.dynamic_metadata.readU64(field);
                    return;
                }
            }
            return error.BadMetadata;
        }

        pub fn encodeKnown(runtime: *const Runtime, writer: *fullaz_db.file.tagged_fields.Writer) Error!void {
            try fullaz_db.file.dynamic_metadata.appendU64(writer, known_tags[0], runtime.root);
        }

        pub fn migrate(
            source_format_version: u32,
            source_payload: []const u8,
            writer: *fullaz_db.file.tagged_fields.Writer,
        ) Error!void {
            if (source_format_version != 1) {
                return error.UnsupportedMigration;
            }
            var reader = fullaz_db.file.tagged_fields.Reader.init(source_payload);
            while (try reader.next()) |field| {
                if (field.tag == known_tags[0]) {
                    try fullaz_db.file.dynamic_metadata.appendU64(
                        writer,
                        known_tags[0],
                        (try fullaz_db.file.dynamic_metadata.readU64(field)) + 1,
                    );
                    break;
                }
            }
            try fullaz_db.file.dynamic_metadata.copyForwardUnknownFields(
                writer,
                source_payload,
                known_tags,
            );
        }
    };
};
const PreflightSchema = fullaz_db.Schema(.{ .page_id = u32 }).add("blob", fullaz_db.chainStore(.{}));

const ReclaimTrait = struct {
    pub const kind_name: []const u8 = "test.reclaim";
    pub const format_version: u32 = 1;
    pub const page_kind_count: usize = 1;
    pub const page_roles: [page_kind_count][]const u8 = .{"data"};

    pub fn fingerprint(_: *fullaz_db.FingerprintWriter) void {}

    pub fn Binding(comptime BackendT: type) type {
        return struct {
            pub const Runtime = struct {};
            pub const Proxy = Runtime;
            pub const ConstProxy = Runtime;
            pub const InitOptions = struct {};
            pub const TransactionState = void;
            pub const Error = fullaz_db.file.dynamic_metadata.Error;
            pub const DynamicMetadata = struct {
                pub const format_version: u32 = 1;
                pub const known_tags: []const u16 = &.{};
                pub const repeated_tags: []const u16 = &.{};
                pub const Error = fullaz_db.file.dynamic_metadata.Error;

                pub fn restore(_: *Runtime, payload: []const u8, _: usize) @This().Error!void {
                    try fullaz_db.file.tagged_fields.validateKnownFields(payload, known_tags);
                }

                pub fn encodeKnown(_: *const Runtime, _: *fullaz_db.file.tagged_fields.Writer) @This().Error!void {}
            };

            pub fn initRuntime(_: *Runtime, _: *BackendT, _: fullaz_db.PageKindRange, _: InitOptions) Error!void {}
            pub fn deinitRuntime(_: *Runtime) void {}
            pub fn captureTransactionState(_: *const Runtime) TransactionState {}
            pub fn restoreTransactionState(_: *Runtime, _: TransactionState) void {}
            pub fn proxy(runtime: *Runtime) Proxy {
                return runtime.*;
            }
            pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                return runtime;
            }
            pub fn reclaimPersistent(_: *Runtime) Error!void {}
        };
    }
};

fn encodeRecord(bytes: []u8, scratch: []u8) ![]const u8 {
    try fullaz_db.file.catalog_record.format(bytes, scratch, .{
        .component_id = 1,
        .revision = 1,
        .name = "index",
        .kind_name = "test.component",
        .component_format_version = 1,
        .metadata_format_version = 1,
        .page_kind_base = 0x0100,
        .page_kind_count = 1,
        .metadata_root_pid = 1,
        .settings_fingerprint = [_]u8{0} ** 32,
        .dependency_ids = &.{},
    }, &.{});
    return bytes[0..try fullaz_db.file.catalog_record.encodedByteSize(bytes)];
}

fn encodeLifecycleRecord(
    bytes: []u8,
    scratch: []u8,
    component_id: u64,
    name: []const u8,
    dependency_ids: []const u64,
) ![]const u8 {
    try fullaz_db.file.catalog_record.format(bytes, scratch, .{
        .component_id = component_id,
        .revision = 1,
        .name = name,
        .kind_name = "test.component",
        .component_format_version = 1,
        .metadata_format_version = 1,
        .page_kind_base = @intCast(0x0100 + component_id),
        .page_kind_count = 1,
        .metadata_root_pid = 1,
        .settings_fingerprint = [_]u8{0} ** 32,
        .dependency_ids = dependency_ids,
    }, &.{});
    return bytes[0..try fullaz_db.file.catalog_record.encodedByteSize(bytes)];
}

fn encodePreflightRecord(bytes: []u8, scratch: []u8, revision: u32) ![]const u8 {
    const Trait = PreflightSchema.trait("blob");
    try fullaz_db.file.catalog_record.format(bytes, scratch, .{
        .component_id = 1,
        .revision = revision,
        .name = "blob",
        .kind_name = Trait.kind_name,
        .component_format_version = Trait.format_version,
        .metadata_format_version = 1,
        .page_kind_base = 0x0100,
        .page_kind_count = Trait.page_kind_count,
        .metadata_root_pid = 1,
        .settings_fingerprint = fullaz_db.componentFingerprint(Trait),
        .dependency_ids = &.{},
    }, &.{});
    return bytes[0..try fullaz_db.file.catalog_record.encodedByteSize(bytes)];
}

test "fullaz-db: dynamic database formats and opens a memory block" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xA5} ** 16,
        .cache_frames = 32,
    };

    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    const formatted_diagnostics = database.diagnostics();
    try std.testing.expectEqual(@as(usize, 1024), formatted_diagnostics.page_size);
    try std.testing.expectEqual(@as(usize, 1), formatted_diagnostics.page_count);

    var moved = database;
    database = undefined;
    try std.testing.expectEqual(formatted_diagnostics.core_address, moved.diagnostics().core_address);

    var reopened = try Database.open(
        std.testing.allocator,
        try moved.takeDevice(),
        options,
    );
    defer reopened.deinit();
    const diagnostics = reopened.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.page_count);
}

test "fullaz-db: dynamic database reclaims a dropped component tombstone" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xA6} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();

    var create = try database.begin();
    var metadata_page = try database.cache().create();
    const metadata_page_id = try metadata_page.pid();
    try fullaz_db.file.component_metadata_page.format(
        try metadata_page.dataMut(),
        .{ .component_id = 1, .metadata_format_version = 1 },
        &.{},
    );
    metadata_page.deinit();
    var record_bytes: [1024]u8 = undefined;
    var record_scratch: [1024]u8 = undefined;
    try fullaz_db.file.catalog_record.format(&record_bytes, &record_scratch, .{
        .component_id = 1,
        .revision = 1,
        .name = "reclaimable",
        .kind_name = ReclaimTrait.kind_name,
        .component_format_version = ReclaimTrait.format_version,
        .metadata_format_version = 1,
        .page_kind_base = 0x0100,
        .page_kind_count = ReclaimTrait.page_kind_count,
        .metadata_root_pid = metadata_page_id,
        .settings_fingerprint = fullaz_db.componentFingerprint(ReclaimTrait),
        .dependency_ids = &.{},
    }, &.{});
    _ = try create.registerCatalogComponent(
        record_bytes[0..try fullaz_db.file.catalog_record.encodedByteSize(&record_bytes)],
    );
    try create.commit();

    var drop = try database.begin();
    try std.testing.expect(try drop.dropComponentById(1));
    try drop.commit();

    var rolled_back = try database.begin();
    _ = try rolled_back.reclaimDroppedComponentById(
        fullaz_db.Descriptor{ .Trait = ReclaimTrait },
        1,
        .{},
    );
    try rolled_back.rollback();
    {
        var dropped_record = (try database.getById(1)).?;
        defer dropped_record.deinit();
        try std.testing.expectEqual(
            fullaz_db.file.catalog_record.LifecycleState.dropped,
            (try dropped_record.view()).state,
        );
    }

    var reclaim = try database.begin();
    const result = (try reclaim.reclaimDroppedComponentById(
        fullaz_db.Descriptor{ .Trait = ReclaimTrait },
        1,
        .{},
    )).?;
    try std.testing.expectEqual(@as(u64, 1), result.component_id);
    try std.testing.expect(result.metadata_page_reclaimed);
    try reclaim.commit();

    var record = (try database.getById(1)).?;
    const view = try record.view();
    try std.testing.expectEqual(fullaz_db.file.catalog_record.LifecycleState.reclaimed, view.state);
    try std.testing.expectEqual(@as(u64, 0), view.metadata_root_pid);
    record.deinit();

    var compact = try database.begin();
    const compacted = try compact.compactCatalog();
    try std.testing.expectEqual(@as(u64, 2), compacted.historical_records_removed);
    try compact.commit();
}

test "fullaz-db: dynamic database persists and reuses reclaimed pages" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xA6} ** 16,
        .cache_frames = 16,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );

    var transaction = try database.begin();
    var page = try database.cache().create();
    const page_id = try page.pid();
    page.deinit();
    try database.cache().free(page_id);
    try transaction.commit();

    var reopened = try Database.open(
        std.testing.allocator,
        try database.takeDevice(),
        options,
    );
    defer reopened.deinit();
    var reuse_transaction = try reopened.begin();
    var reused = try reopened.cache().create();
    defer reused.deinit();
    try std.testing.expectEqual(page_id, try reused.pid());
    try reuse_transaction.commit();
}

test "fullaz-db: dynamic database rejects a cyclic persistent free list" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xA7} ** 16,
        .cache_frames = 16,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );

    var transaction = try database.begin();
    var page = try database.cache().create();
    const page_id = try page.pid();
    page.deinit();
    try database.cache().free(page_id);
    var freed_page = try database.rawCache().fetch(page_id);
    const FreedView = fullaz.page.freed.View(u32, .little, false);
    var freed_view = FreedView.init(try freed_page.dataMut());
    freed_view.formatPage(page_id);
    freed_page.deinit();
    try transaction.commit();

    try std.testing.expectError(
        error.BadFreeList,
        Database.open(std.testing.allocator, try database.takeDevice(), options),
    );
}

test "fullaz-db: dynamic database rollback restores the free-list root" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xA8} ** 16,
        .cache_frames = 16,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();

    var create_transaction = try database.begin();
    var page = try database.cache().create();
    const page_id = try page.pid();
    page.deinit();
    try create_transaction.commit();

    var rollback_transaction = try database.begin();
    try database.cache().free(page_id);
    try rollback_transaction.rollback();

    var next_transaction = try database.begin();
    var next_page = try database.cache().create();
    defer next_page.deinit();
    try std.testing.expectEqual(page_id + 1, try next_page.pid());
    try next_transaction.commit();
}

test "fullaz-db: WAL dynamic database reuses reclaimed pages after reopen" {
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.DynamicDatabaseWithWal(Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/dynamic_database_reclaiming_wal.img";
    const log_path = ".zig-cache/dynamic_database_reclaiming_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xA9} ** 16,
        .cache_frames = 16,
    };
    std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    var page_id: u32 = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        var page = try database.cache().create();
        page_id = try page.pid();
        page.deinit();
        try database.cache().free(page_id);
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        var reused = try database.cache().create();
        defer reused.deinit();
        try std.testing.expectEqual(page_id, try reused.pid());
        try transaction.commit();
    }
    var log = try Log.open(io, log_path);
    defer log.deinit();
    try std.testing.expectEqual(@as(u32, 0), log.size());
}

test "fullaz-db: WAL dynamic database persists catalog lifecycle changes" {
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.DynamicDatabaseWithWal(Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/dynamic_database_lifecycle_wal.img";
    const log_path = ".zig-cache/dynamic_database_lifecycle_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xAA} ** 16,
        .cache_frames = 16,
    };
    std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        var register = try database.begin();
        _ = try register.registerCatalogComponent(
            try encodeLifecycleRecord(&record_bytes, &record_scratch, 1, "index", &.{}),
        );
        try register.commit();
        var rename = try database.begin();
        try std.testing.expect(try rename.renameComponent("index", "primary"));
        try rename.commit();
        var drop = try database.begin();
        try std.testing.expect(try drop.dropComponent("primary"));
        try drop.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try std.testing.expect((try database.getByName("primary")) == null);
        var dropped = (try database.getById(1)).?;
        defer dropped.deinit();
        try std.testing.expectEqual(
            fullaz_db.file.catalog_record.LifecycleState.dropped,
            (try dropped.view()).state,
        );
    }
}

test "fullaz-db: WAL dynamic database compacts catalog history" {
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.DynamicDatabaseWithWal(Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/dynamic_database_compaction_wal.img";
    const log_path = ".zig-cache/dynamic_database_compaction_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xAB} ** 16,
        .cache_frames = 64,
    };
    std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        var register = try database.begin();
        _ = try register.registerCatalogComponent(
            try encodeLifecycleRecord(&record_bytes, &record_scratch, 1, "index", &.{}),
        );
        try register.commit();
        var rename = try database.begin();
        try std.testing.expect(try rename.renameComponent("index", "final"));
        try rename.commit();
        var compact = try database.begin();
        const result = try compact.compactCatalog();
        try std.testing.expectEqual(@as(u64, 1), result.records_retained);
        try compact.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        var current = (try database.getByName("final")).?;
        defer current.deinit();
        try std.testing.expectEqual(@as(u32, 2), (try current.view()).revision);
    }
}

test "fullaz-db: dynamic database commits catalog control-plane changes" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x3C} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;
    var transaction = try database.begin();
    const ref = try transaction.appendCatalogRevision(try encodeRecord(&record_bytes, &record_scratch));
    try transaction.setIdRef(1, ref);
    try transaction.setName("index", 1);
    try transaction.commit();

    var reopened = try Database.open(std.testing.allocator, try database.takeDevice(), options);
    defer reopened.deinit();
    var loaded = (try reopened.getByName("index")).?;
    defer loaded.deinit();
    try std.testing.expectEqualStrings("index", (try loaded.view()).name);
}

test "fullaz-db: dynamic database renames and drops catalog components" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x3D} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;
    {
        var transaction = try database.begin();
        _ = try transaction.registerCatalogComponent(
            try encodeLifecycleRecord(&record_bytes, &record_scratch, 1, "index", &.{}),
        );
        try transaction.commit();
    }
    {
        var transaction = try database.begin();
        try std.testing.expect(try transaction.renameComponent("index", "primary"));
        try std.testing.expect(!try transaction.renameComponent("primary", "primary"));
        try transaction.commit();
    }
    try std.testing.expect((try database.getByName("index")) == null);
    var renamed = (try database.getByName("primary")).?;
    try std.testing.expectEqual(@as(u64, 1), (try renamed.view()).component_id);
    renamed.deinit();

    {
        var transaction = try database.begin();
        try std.testing.expect(try transaction.dropComponent("primary"));
        try std.testing.expect(!try transaction.dropComponentById(1));
        try transaction.commit();
    }
    try std.testing.expect((try database.getByName("primary")) == null);
    var dropped = (try database.getById(1)).?;
    try std.testing.expectEqual(
        fullaz_db.file.catalog_record.LifecycleState.dropped,
        (try dropped.view()).state,
    );
    dropped.deinit();

    {
        var transaction = try database.begin();
        _ = try transaction.registerCatalogComponent(
            try encodeLifecycleRecord(&record_bytes, &record_scratch, 2, "primary", &.{}),
        );
        try transaction.commit();
    }
    var reused_name = (try database.getByName("primary")).?;
    try std.testing.expectEqual(@as(u64, 2), (try reused_name.view()).component_id);
    reused_name.deinit();

    var reopened = try Database.open(std.testing.allocator, try database.takeDevice(), options);
    defer reopened.deinit();
    try std.testing.expect((try reopened.getByName("index")) == null);
    var persisted = (try reopened.getByName("primary")).?;
    defer persisted.deinit();
    try std.testing.expectEqual(@as(u64, 2), (try persisted.view()).component_id);
}

test "fullaz-db: dynamic database blocks drop while an active component depends on it" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x3E} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();
    var first_bytes: [256]u8 = undefined;
    var first_scratch: [256]u8 = undefined;
    var second_bytes: [256]u8 = undefined;
    var second_scratch: [256]u8 = undefined;
    {
        var transaction = try database.begin();
        _ = try transaction.registerCatalogComponent(
            try encodeLifecycleRecord(&first_bytes, &first_scratch, 1, "base", &.{}),
        );
        _ = try transaction.registerCatalogComponent(
            try encodeLifecycleRecord(&second_bytes, &second_scratch, 2, "dependent", &.{1}),
        );
        try transaction.commit();
    }
    {
        var transaction = try database.begin();
        try std.testing.expectError(error.ComponentInUse, transaction.dropComponent("base"));
        try transaction.rollback();
    }
    {
        var transaction = try database.begin();
        try std.testing.expect(try transaction.dropComponent("dependent"));
        try std.testing.expect(try transaction.dropComponent("base"));
        try transaction.commit();
    }
}

test "fullaz-db: dynamic database compacts catalog history" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x3F} ** 16,
        .cache_frames = 64,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;
    {
        var transaction = try database.begin();
        _ = try transaction.registerCatalogComponent(
            try encodeLifecycleRecord(&record_bytes, &record_scratch, 1, "index", &.{}),
        );
        try transaction.commit();
    }
    {
        var transaction = try database.begin();
        try std.testing.expect(try transaction.renameComponent("index", "primary"));
        try std.testing.expect(try transaction.renameComponent("primary", "final"));
        try transaction.commit();
    }
    {
        var transaction = try database.begin();
        _ = try transaction.compactCatalog();
        try transaction.rollback();
    }
    {
        var transaction = try database.begin();
        const result = try transaction.compactCatalog();
        try std.testing.expectEqual(@as(u64, 3), result.records_before);
        try std.testing.expectEqual(@as(u64, 1), result.records_retained);
        try std.testing.expectEqual(@as(u64, 2), result.historical_records_removed);
        try transaction.commit();
    }
    var loaded = (try database.getByName("final")).?;
    try std.testing.expectEqual(@as(u32, 3), (try loaded.view()).revision);
    loaded.deinit();

    var reopened = try Database.open(std.testing.allocator, try database.takeDevice(), options);
    defer reopened.deinit();
    var persisted = (try reopened.getByName("final")).?;
    defer persisted.deinit();
    try std.testing.expectEqual(@as(u32, 3), (try persisted.view()).revision);
}

test "fullaz-db: dynamic database rolls back catalog control-plane changes" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x4D} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );

    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;
    var transaction = try database.begin();
    const ref = try transaction.appendCatalogRevision(try encodeRecord(&record_bytes, &record_scratch));
    try transaction.setIdRef(1, ref);
    try transaction.setName("index", 1);
    try transaction.rollback();

    var reopened = try Database.open(std.testing.allocator, try database.takeDevice(), options);
    defer reopened.deinit();
    try std.testing.expect((try reopened.getByName("index")) == null);
}

test "fullaz-db: dynamic database persists typed component metadata pages" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x6E} ** 16,
        .cache_frames = 16,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    var transaction = try database.begin();
    const metadata_page_id = try transaction.initializeMetadata(
        MetadataBinding,
        1,
        &MetadataBinding.Runtime{ .root = 42 },
    );
    try transaction.commit();

    var reopened = try Database.open(std.testing.allocator, try database.takeDevice(), options);
    defer reopened.deinit();
    var restored = MetadataBinding.Runtime{};
    try reopened.restoreMetadata(MetadataBinding, metadata_page_id, 1, &restored);
    try std.testing.expectEqual(@as(u64, 42), restored.root);
}

test "fullaz-db: dynamic database migrates metadata into an immutable catalog successor" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x6F} ** 16,
        .cache_frames = 16,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();

    var source_payload_bytes: [128]u8 = undefined;
    var source_payload = fullaz_db.file.tagged_fields.Writer.init(&source_payload_bytes);
    try fullaz_db.file.dynamic_metadata.appendU64(&source_payload, 0x0100, 41);
    try source_payload.append(0x0200, 0x8000, "future");
    var source_record_bytes: [256]u8 = undefined;
    var source_record_scratch: [256]u8 = undefined;
    var successor_record_bytes: [256]u8 = undefined;
    var successor_record_scratch: [256]u8 = undefined;
    var transaction = try database.begin();
    const source_page_id = blk: {
        var source_page = try database.rawCache().create();
        defer source_page.deinit();
        const page_id = try source_page.pid();
        try fullaz_db.file.component_metadata_page.format(
            try source_page.dataMut(),
            .{ .component_id = 1, .metadata_format_version = 1 },
            source_payload.used(),
        );
        break :blk page_id;
    };
    try fullaz_db.file.catalog_record.format(&source_record_bytes, &source_record_scratch, .{
        .component_id = 1,
        .revision = 1,
        .name = "migrating",
        .kind_name = "test.component",
        .component_format_version = 1,
        .metadata_format_version = 1,
        .page_kind_base = 0x0100,
        .page_kind_count = 1,
        .metadata_root_pid = source_page_id,
        .settings_fingerprint = [_]u8{0} ** 32,
        .dependency_ids = &.{},
    }, &.{});
    _ = try transaction.registerCatalogComponent(
        source_record_bytes[0..try fullaz_db.file.catalog_record.encodedByteSize(&source_record_bytes)],
    );
    const successor_page_id = try transaction.migrateMetadata(MigratingMetadataBinding, source_page_id, 1);
    try fullaz_db.file.catalog_record.format(&successor_record_bytes, &successor_record_scratch, .{
        .component_id = 1,
        .revision = 2,
        .name = "migrating",
        .kind_name = "test.component",
        .component_format_version = 1,
        .metadata_format_version = 2,
        .page_kind_base = 0x0100,
        .page_kind_count = 1,
        .metadata_root_pid = successor_page_id,
        .settings_fingerprint = [_]u8{0} ** 32,
        .dependency_ids = &.{},
    }, &.{});
    _ = try transaction.replaceCatalogRevision(
        successor_record_bytes[0..try fullaz_db.file.catalog_record.encodedByteSize(&successor_record_bytes)],
    );
    try transaction.commit();

    var old_page = try database.rawCache().fetch(source_page_id);
    defer old_page.deinit();
    const old_view = try fullaz_db.file.component_metadata_page.read(try old_page.data(), .{
        .component_id = 1,
        .metadata_format_version = 1,
    });
    try std.testing.expectEqual(source_payload.used().len, old_view.payload.len);
    try std.testing.expectEqualSlices(u8, source_payload.used(), old_view.payload);
    var new_page = try database.rawCache().fetch(@intCast(successor_page_id));
    defer new_page.deinit();
    const new_view = try fullaz_db.file.component_metadata_page.read(try new_page.data(), .{
        .component_id = 1,
        .metadata_format_version = 2,
    });
    var restored = MigratingMetadataBinding.Runtime{};
    try fullaz_db.file.component_metadata.restore(MigratingMetadataBinding, &restored, new_view.payload, 3);
    try std.testing.expectEqual(@as(u64, 42), restored.root);
    var source_reader = fullaz_db.file.tagged_fields.Reader.init(source_payload.used());
    _ = (try source_reader.next()).?;
    const source_unknown = (try source_reader.next()).?;
    var successor_reader = fullaz_db.file.tagged_fields.Reader.init(new_view.payload);
    _ = (try successor_reader.next()).?;
    const successor_unknown = (try successor_reader.next()).?;
    try std.testing.expectEqualSlices(u8, source_unknown.encoded, successor_unknown.encoded);
    var current = (try database.getById(1)).?;
    defer current.deinit();
    const current_view = try current.view();
    try std.testing.expectEqual(@as(u32, 2), current_view.revision);
    try std.testing.expectEqual(successor_page_id, current_view.metadata_root_pid);
}

test "fullaz-db: dynamic database preflights the complete compiled schema" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x71} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;
    var transaction = try database.begin();
    _ = try transaction.registerCatalogComponent(
        try encodePreflightRecord(&record_bytes, &record_scratch, 1),
    );
    try transaction.commit();

    var reopened = try Database.open(std.testing.allocator, try database.takeDevice(), options);
    defer reopened.deinit();
    try reopened.preflightSchema(PreflightSchema);
}

test "fullaz-db: dynamic database allocates durable component identities" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x8B} ** 16,
        .cache_frames = 8,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();

    var transaction = try database.begin();
    const first = try transaction.allocateComponent(2);
    const second = try transaction.allocateComponent(3);
    try std.testing.expectEqual(@as(u64, 1), first.component_id);
    try std.testing.expectEqual(@as(u16, 0x0100), first.page_kinds.base);
    try std.testing.expectEqual(@as(u16, 2), first.page_kinds.count);
    try std.testing.expectEqual(@as(u64, 2), second.component_id);
    try std.testing.expectEqual(@as(u16, 0x0102), second.page_kinds.base);
    try transaction.rollback();

    var retried = try database.begin();
    const after_rollback = try retried.allocateComponent(1);
    try std.testing.expectEqual(@as(u64, 1), after_rollback.component_id);
    try std.testing.expectEqual(@as(u16, 0x0100), after_rollback.page_kinds.base);
    try retried.commit();
}

test "fullaz-db: dynamic database preflight ignores historical catalog revisions" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x9A} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();
    var first_bytes: [256]u8 = undefined;
    var first_scratch: [256]u8 = undefined;
    var second_bytes: [256]u8 = undefined;
    var second_scratch: [256]u8 = undefined;
    var transaction = try database.begin();
    _ = try transaction.registerCatalogComponent(
        try encodePreflightRecord(&first_bytes, &first_scratch, 1),
    );
    _ = try transaction.replaceCatalogRevision(
        try encodePreflightRecord(&second_bytes, &second_scratch, 2),
    );
    try transaction.commit();
    try database.preflightSchema(PreflightSchema);
}

test "fullaz-db: dynamic database preserves current unknown catalog components" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const EmptySchema = fullaz_db.Schema(.{ .page_id = u32 });
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x9B} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();
    var record_bytes: [256]u8 = undefined;
    var record_scratch: [256]u8 = undefined;
    var transaction = try database.begin();
    _ = try transaction.registerCatalogComponent(
        try encodeRecord(&record_bytes, &record_scratch),
    );
    try transaction.commit();
    try database.preflightKnownSchema(EmptySchema);
    try std.testing.expectError(error.UnknownComponent, database.preflightSchema(EmptySchema));
}

test "fullaz-db: dynamic database replaces a catalog revision atomically" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x9C} ** 16,
        .cache_frames = 32,
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        options,
    );
    defer database.deinit();
    var first_bytes: [256]u8 = undefined;
    var first_scratch: [256]u8 = undefined;
    var first_transaction = try database.begin();
    _ = try first_transaction.registerCatalogComponent(
        try encodePreflightRecord(&first_bytes, &first_scratch, 1),
    );
    try first_transaction.commit();

    var second_bytes: [256]u8 = undefined;
    var second_scratch: [256]u8 = undefined;
    var second_transaction = try database.begin();
    const updated_ref = try second_transaction.replaceCatalogRevision(
        try encodePreflightRecord(&second_bytes, &second_scratch, 2),
    );
    try std.testing.expectEqual(@as(u32, 2), updated_ref.getRecordRevision());
    try std.testing.expectError(
        error.RevisionMismatch,
        second_transaction.replaceCatalogRevision(
            try encodePreflightRecord(&second_bytes, &second_scratch, 2),
        ),
    );
    try second_transaction.commit();

    var current = (try database.getByName("blob")).?;
    defer current.deinit();
    try std.testing.expectEqual(@as(u32, 2), (try current.view()).revision);
    try database.preflightSchema(PreflightSchema);
}

test "fullaz-db: dynamic schema database restores a chainStore const proxy" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.DynamicSchemaDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/dynamic_schema_chain_store.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xC1} ** 16,
        .components = .{ .blob = .{} },
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
        defer transaction.deinit();
        try transaction.get("blob").append("hello world");
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        var output: [16]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(u64, 11), try blob.size());
        try std.testing.expectEqual(@as(usize, 11), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("hello world", output[0..11]);
    }
}

test "fullaz-db: dynamic schema database reuses reclaimed BPT pages after reopen" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "index",
        fullaz_db.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 32,
            .maximum_value_size = 32,
        }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.DynamicSchemaDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/dynamic_schema_reclaiming_bpt.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xC2} ** 16,
        .components = .{ .index = .{} },
    };
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var page_count: usize = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 1024),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        try std.testing.expect(try transaction.get("index").insert("key", "value"));
        try transaction.commit();
    }
    {
        var device = try Device.open(io, path, 1024);
        defer device.deinit();
        page_count = device.blocksCount();
        try std.testing.expect(page_count > 1);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        try std.testing.expect(try transaction.get("index").remove("key"));
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        try std.testing.expect(try transaction.get("index").insert("next", "value"));
        try transaction.commit();
    }
    {
        var device = try Device.open(io, path, 1024);
        defer device.deinit();
        try std.testing.expectEqual(page_count, device.blocksCount());
    }
}

test "fullaz-db: WAL dynamic database commits and reopens" {
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.DynamicDatabaseWithWal(Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/dynamic_database_wal.img";
    const log_path = ".zig-cache/dynamic_database_wal.log";
    const options: Database.InitOptions = .{ .image_id = [_]u8{0xD1} ** 16 };
    std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        var record_bytes: [256]u8 = undefined;
        var record_scratch: [256]u8 = undefined;
        var transaction = try database.begin();
        const ref = try transaction.appendCatalogRevision(try encodeRecord(&record_bytes, &record_scratch));
        try transaction.setIdRef(1, ref);
        try transaction.setName("index", 1);
        try transaction.commit();
    }
    {
        var log = try Log.open(io, log_path);
        defer log.deinit();
        var wal = try Database.WalType.init(std.testing.allocator, &log, 1024);
        defer wal.deinit();
        var device = try Device.open(io, image_path, 1024);
        defer device.deinit();
        var boot_page: [1024]u8 = undefined;
        try device.readBlock(0, &boot_page);
        try wal.appendPage(0, &boot_page);
        try wal.sealCommit(1);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        var loaded = (try database.getByName("index")).?;
        defer loaded.deinit();
        try std.testing.expectEqualStrings("index", (try loaded.view()).name);
    }
    var log = try Log.open(io, log_path);
    defer log.deinit();
    try std.testing.expectEqual(@as(u32, 0), log.size());
}

test "fullaz-db: WAL dynamic schema database commits and reopens" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("blob", fullaz_db.chainStore(.{}));
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.DynamicSchemaDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/dynamic_schema_database_wal.img";
    const log_path = ".zig-cache/dynamic_schema_database_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xD2} ** 16,
        .components = .{ .blob = .{} },
    };
    std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 1024),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("blob").append("wal");
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 1024),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try std.testing.expectEqual(@as(u64, 3), try database.getConst("blob").size());
    }
}
