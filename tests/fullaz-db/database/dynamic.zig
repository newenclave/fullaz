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

fn slotCompare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const ReclaimPageSnapshot = struct {
    page_id: u32,
    bytes: []u8,
};

fn collectPersistentFreePages(
    database: anytype,
    image_id: [16]u8,
) !std.ArrayList(u32) {
    var pages: std.ArrayList(u32) = .empty;
    errdefer pages.deinit(std.testing.allocator);

    var boot_page = try database.rawCache().fetch(0);
    defer boot_page.deinit();
    const boot = try fullaz_db.file.boot.read(try boot_page.data(), .{
        .image_id = image_id,
        .page_size = @intCast(database.diagnostics().page_size),
        .page_id_bits = @bitSizeOf(u32),
    });
    const FreedView = fullaz.page.freed.View(u32, .little, true);
    const nil = std.math.maxInt(u32);
    var current = boot.state.free_root;
    while (current) |raw_page_id| {
        const page_id = std.math.cast(u32, raw_page_id) orelse return error.BadFreeList;
        try std.testing.expect(page_id != 0);
        try std.testing.expect(@as(usize, page_id) < database.diagnostics().page_count);
        try std.testing.expect(std.mem.indexOfScalar(u32, pages.items, page_id) == null);
        try pages.append(std.testing.allocator, page_id);

        var page = try database.rawCache().fetch(page_id);
        defer page.deinit();
        const freed = FreedView.init(try page.data());
        try std.testing.expectEqual(std.math.maxInt(u16), freed.header().kind.get());
        const next = freed.header().next.get();
        current = if (next == nil) null else next;
    }
    return pages;
}

fn collectComponentPages(
    database: anytype,
    page_kinds: fullaz_db.PageKindRange,
) !std.ArrayList(u32) {
    var pages: std.ArrayList(u32) = .empty;
    errdefer pages.deinit(std.testing.allocator);
    const HeaderView = fullaz.page.header.View(u32, u16, .little, true);
    const end = page_kinds.endExclusive();

    for (1..database.diagnostics().page_count) |index| {
        const page_id: u32 = @intCast(index);
        var page = try database.rawCache().fetch(page_id);
        defer page.deinit();
        const header = HeaderView.init(try page.data());
        header.validateCommon() catch continue;
        if (header.header().self_pid.get() != page_id) {
            continue;
        }
        const kind = header.header().kind.get();
        if (kind >= page_kinds.base and @as(u32, kind) < end) {
            try pages.append(std.testing.allocator, page_id);
        }
    }
    return pages;
}

fn snapshotPages(database: anytype, page_ids: []const u32) !std.ArrayList(ReclaimPageSnapshot) {
    var snapshots: std.ArrayList(ReclaimPageSnapshot) = .empty;
    errdefer {
        for (snapshots.items) |snapshot| {
            std.testing.allocator.free(snapshot.bytes);
        }
        snapshots.deinit(std.testing.allocator);
    }
    for (page_ids) |page_id| {
        var page = try database.cache().fetch(page_id);
        defer page.deinit();
        try snapshots.append(std.testing.allocator, .{
            .page_id = page_id,
            .bytes = try std.testing.allocator.dupe(u8, try page.data()),
        });
    }
    return snapshots;
}

fn deinitSnapshots(snapshots: *std.ArrayList(ReclaimPageSnapshot)) void {
    for (snapshots.items) |snapshot| {
        std.testing.allocator.free(snapshot.bytes);
    }
    snapshots.deinit(std.testing.allocator);
}

fn expectSnapshotPages(database: anytype, snapshots: []const ReclaimPageSnapshot) !void {
    for (snapshots) |snapshot| {
        var page = try database.cache().fetch(snapshot.page_id);
        defer page.deinit();
        try std.testing.expectEqualSlices(u8, snapshot.bytes, try page.data());
    }
}

fn expectCurrentLifecycle(
    database: anytype,
    component_id: u64,
    revision: u32,
    state: fullaz_db.file.catalog_record.LifecycleState,
    metadata_page_id: u64,
) !void {
    var loaded = (try database.getById(component_id)).?;
    defer loaded.deinit();
    const record = try loaded.view();
    try std.testing.expectEqual(revision, record.revision);
    try std.testing.expectEqual(state, record.state);
    try std.testing.expectEqual(metadata_page_id, record.metadata_root_pid);
}

fn reclaimDroppedComponentLifecycle(
    comptime descriptor: fullaz_db.Descriptor,
    component_id: u64,
    name: []const u8,
    page_kinds: fullaz_db.PageKindRange,
    expected_page_count: usize,
    image_id: [16]u8,
    path: []const u8,
) !void {
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.DynamicDatabase(Device);
    const options: Database.InitOptions = .{
        .image_id = image_id,
        .cache_frames = 64,
    };
    const io = std.testing.io;

    var database = try Database.open(
        std.testing.allocator,
        try Device.open(io, path, 1024),
        options,
    );
    defer database.deinit();

    var current = (try database.getById(component_id)).?;
    const metadata_page_id = (try current.view()).metadata_root_pid;
    current.deinit();
    var component_pages = try collectComponentPages(&database, page_kinds);
    defer component_pages.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected_page_count, component_pages.items.len);

    var owned_pages: std.ArrayList(u32) = .empty;
    defer owned_pages.deinit(std.testing.allocator);
    try owned_pages.appendSlice(std.testing.allocator, component_pages.items);
    try owned_pages.append(std.testing.allocator, @intCast(metadata_page_id));
    var snapshots = try snapshotPages(&database, owned_pages.items);
    defer deinitSnapshots(&snapshots);

    var drop = try database.begin();
    try std.testing.expect(try drop.dropComponentById(component_id));
    try drop.commit();
    try expectCurrentLifecycle(&database, component_id, 2, .dropped, metadata_page_id);
    try std.testing.expectEqual(null, try database.getByName(name));

    var free_before = try collectPersistentFreePages(&database, image_id);
    defer free_before.deinit(std.testing.allocator);
    var rollback = try database.begin();
    _ = try rollback.reclaimDroppedComponentById(descriptor, component_id, .{});
    try rollback.rollback();
    try expectCurrentLifecycle(&database, component_id, 2, .dropped, metadata_page_id);
    var free_after_rollback = try collectPersistentFreePages(&database, image_id);
    defer free_after_rollback.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, free_before.items, free_after_rollback.items);
    try expectSnapshotPages(&database, snapshots.items);

    const page_count_before_reclaim = database.diagnostics().page_count;
    var reclaim = try database.begin();
    const result = (try reclaim.reclaimDroppedComponentById(descriptor, component_id, .{})).?;
    try std.testing.expectEqual(component_id, result.component_id);
    try std.testing.expect(result.metadata_page_reclaimed);
    try reclaim.commit();
    try expectCurrentLifecycle(&database, component_id, 3, .reclaimed, 0);
    try std.testing.expectEqual(null, try database.getByName(name));

    var free_after_reclaim = try collectPersistentFreePages(&database, image_id);
    defer free_after_reclaim.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, @intCast(metadata_page_id)), free_after_reclaim.items[0]);
    for (owned_pages.items) |page_id| {
        try std.testing.expect(std.mem.indexOfScalar(u32, free_after_reclaim.items, page_id) != null);
        try std.testing.expectError(error.PageNotAllocated, database.cache().fetch(page_id));
    }

    var reuse = try database.begin();
    var reused: std.ArrayList(u32) = .empty;
    defer reused.deinit(std.testing.allocator);
    for (0..owned_pages.items.len) |_| {
        var page = try database.cache().create();
        const page_id = try page.pid();
        for (try page.data()) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
        page.deinit();
        try reused.append(std.testing.allocator, page_id);
    }
    try std.testing.expectEqual(reused.items[0], @as(u32, @intCast(metadata_page_id)));
    for (reused.items) |page_id| {
        try std.testing.expect(std.mem.indexOfScalar(u32, owned_pages.items, page_id) != null);
        try database.cache().free(page_id);
    }
    try reuse.commit();
    try std.testing.expectEqual(page_count_before_reclaim, database.diagnostics().page_count);
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

test "fullaz-db: dynamic database reclaims every built-in multi-page component" {
    const BptDescriptor = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 4,
        .maximum_value_size = 256,
        .rebalance_policy = .force_split,
    });
    const RtreeDescriptor = fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    });
    const SlotHeapDescriptor = fullaz_db.slotHeap(.{
        .compare = slotCompare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 4,
        .maximum_value_size = 256,
        .maximum_level = 1,
        .size_classes = fullaz_db.SlotHeapSizeClasses{ .one = {} },
    });
    const ChainStoreDescriptor = fullaz_db.chainStore(.{});
    const WeightedSequenceDescriptor = fullaz_db.weightedSequence(.{ .maximum_chunk_size = 256 });
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("index", BptDescriptor)
        .add("spatial", RtreeDescriptor)
        .add("heap", SlotHeapDescriptor)
        .add("blob", ChainStoreDescriptor)
        .add("sequence", WeightedSequenceDescriptor);
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.DynamicSchemaDatabase(Schema, Device);
    const RtreeBinding = Schema.trait("spatial").Binding(Database.BackendType);
    const Box = RtreeBinding.Proxy.BoundingBox;
    const io = std.testing.io;
    const path = ".zig-cache/dynamic_builtin_reclaim_matrix.img";
    const image_id = [_]u8{0xC3} ** 16;
    const options: Database.InitOptions = .{
        .image_id = image_id,
        .cache_frames = 64,
        .components = .{
            .index = .{},
            .spatial = .{},
            .heap = .{},
            .blob = .{},
            .sequence = .{},
        },
    };
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var bpt_value: [256]u8 = undefined;
    @memset(&bpt_value, 0xB1);
    var heap_value: [256]u8 = undefined;
    @memset(&heap_value, 0xA1);
    var bytes: [1024]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 1024),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        defer transaction.deinit();
        const index = transaction.get("index");
        for ([_][]const u8{ "0001", "0002", "0003", "0004" }) |key| {
            try std.testing.expect(try index.insert(key, &bpt_value));
        }
        const spatial = transaction.get("spatial");
        for (0..5) |entry_index| {
            var value: [4]u8 = undefined;
            std.mem.writeInt(u32, &value, @intCast(entry_index), .little);
            const coordinate: i64 = @intCast(entry_index * 10);
            try spatial.insert(
                Box.initWith(.{ coordinate, 0 }, .{ coordinate + 1, 1 }),
                &value,
            );
        }
        const heap = transaction.get("heap");
        for ([_][]const u8{ "0004", "0003", "0002", "0001" }) |key| {
            try heap.push(key, &heap_value);
        }
        try transaction.get("blob").append(&bytes);
        try transaction.get("sequence").append(&bytes);
        try transaction.commit();
    }

    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            options,
        );
        defer database.deinit();
        for ([_][]const u8{ "0001", "0002", "0003", "0004" }) |key| {
            var iterator = (try database.getConst("index").find(key)).?;
            defer iterator.deinit();
            const entry = (try iterator.get()).?;
            try std.testing.expectEqualStrings(key, entry.key);
            try std.testing.expectEqualSlices(u8, &bpt_value, entry.value);
        }
        const Collector = struct {
            seen: [5]bool = [_]bool{false} ** 5,

            fn callback(self: *@This(), _: Box, value: []const u8) void {
                const value_id = std.mem.readInt(u32, value[0..4], .little);
                self.seen[value_id] = true;
            }
        };
        var collector = Collector{};
        try database.getConst("spatial").search(
            Box.initWith(.{ -1, -1 }, .{ 100, 2 }),
            &collector,
            Collector.callback,
        );
        for (collector.seen) |seen| {
            try std.testing.expect(seen);
        }
        try std.testing.expectEqual(@as(u64, 4), try database.getConst("heap").count());
        {
            var transaction = try database.begin();
            defer transaction.deinit();
            const heap = transaction.get("heap");
            for ([_][]const u8{ "0001", "0002", "0003", "0004" }) |key| {
                var top = try heap.top();
                try std.testing.expectEqualSlices(u8, key, try top.key());
                try std.testing.expectEqualSlices(u8, &heap_value, try top.value());
                top.deinit();
                try heap.pop();
            }
            try transaction.rollback();
        }
        var output: [1024]u8 = undefined;
        try std.testing.expectEqual(@as(u64, 1024), try database.getConst("blob").size());
        try std.testing.expectEqual(@as(usize, 1024), try database.getConst("blob").readAt(0, &output));
        try std.testing.expectEqualSlices(u8, &bytes, &output);
        try std.testing.expectEqual(@as(u64, 1024), try database.getConst("sequence").size());
        try std.testing.expectEqual(@as(usize, 1024), try database.getConst("sequence").readAt(0, &output));
        try std.testing.expectEqualSlices(u8, &bytes, &output);
    }

    try reclaimDroppedComponentLifecycle(
        BptDescriptor,
        1,
        "index",
        Schema.pageKinds("index"),
        3,
        image_id,
        path,
    );
    try reclaimDroppedComponentLifecycle(
        RtreeDescriptor,
        2,
        "spatial",
        Schema.pageKinds("spatial"),
        3,
        image_id,
        path,
    );
    try reclaimDroppedComponentLifecycle(
        SlotHeapDescriptor,
        3,
        "heap",
        Schema.pageKinds("heap"),
        4,
        image_id,
        path,
    );
    try reclaimDroppedComponentLifecycle(
        ChainStoreDescriptor,
        4,
        "blob",
        Schema.pageKinds("blob"),
        2,
        image_id,
        path,
    );
    try reclaimDroppedComponentLifecycle(
        WeightedSequenceDescriptor,
        5,
        "sequence",
        Schema.pageKinds("sequence"),
        3,
        image_id,
        path,
    );
    {
        const RawDatabase = fullaz_db.DynamicDatabase(Device);
        var database = try RawDatabase.open(
            std.testing.allocator,
            try Device.open(io, path, 1024),
            .{ .image_id = image_id, .cache_frames = 64 },
        );
        defer database.deinit();
        for (1..6) |component_id| {
            try expectCurrentLifecycle(&database, @intCast(component_id), 3, .reclaimed, 0);
        }
        var free_pages = try collectPersistentFreePages(&database, image_id);
        defer free_pages.deinit(std.testing.allocator);
        try std.testing.expect(free_pages.items.len > 0);
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
