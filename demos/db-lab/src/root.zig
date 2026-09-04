const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const TableOwner = fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 32,
    .maximum_value_size = 96,
    .fixed_value_size = 96,
});

const Table = fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 2,
    .maximum_key_size = 32,
    .maximum_value_size = 128,
    .fixed_value_size = 128,
});

const Tables = fullaz_db.Hierarchy(.{
    .registry_id = 0x4442_4c41_4254_4142,
    .types = &.{.{
        .tag = "table",
        .type_id = 1,
        .type_version = 1,
        .metadata_format_version = 1,
        .descriptor = Table,
        .allowed_child_type_ids = &.{},
    }},
});

/// A catalog owner maps table names to distinct embedded B+ tree roots.
pub const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("catalog", fullaz_db.hierarchyStore(Tables, .{ .owners = &.{.{
    .tag = "tables",
    .owner_id = 1,
    .descriptor = TableOwner,
    .allowed_type_ids = &.{1},
}} }));

pub const Row = extern struct {
    table: [32]u8,
    table_len: u8,
    key: [32]u8,
    key_len: u8,
    value: [64]u8,
    value_len: u8,
};

pub const minimum_planet_count: usize = 32;
pub const default_planet_count: usize = 256;
pub const maximum_planet_count: usize = 512;

const generation_batch_size: usize = 8;
const example_tables = [_][]const u8{ "planets", "users", "events", "notes" };
const name_starts = [_][]const u8{
    "al",  "an",  "ar",  "bel", "cor", "da",  "de",  "el",  "es",  "fal",
    "gar", "hel", "is",  "jar", "kal", "lor", "mar", "nar", "or",  "pel",
    "qua", "ren", "sar", "tel", "ul",  "val", "wen", "xel", "yor", "zan",
};
const name_middles = [_][]const u8{
    "a",  "ae", "an", "ar", "e",  "el", "en", "er", "ev", "ia", "in",
    "ir", "o",  "ol", "on", "or", "u",  "ul", "un", "ur", "ys", "za",
};
const name_ends = [_][]const u8{
    "bar", "dun", "ea",    "eron", "eth", "ia",  "ion", "is",  "or",  "ora",
    "os",  "oth", "prime", "ra",   "ria", "ron", "ta",  "ter", "tis", "une",
    "us",  "var",
};
const world_types = [_][]const u8{
    "basalt", "desert", "ocean", "temperate", "tidal", "frozen", "iron", "storm",
};
const reference_rows = [_]struct {
    table: []const u8,
    key: []const u8,
    value: []const u8,
}{
    .{ .table = "users", .key = "ada", .value = "first programmer" },
    .{ .table = "users", .key = "linus", .value = "kernel maintainer" },
    .{ .table = "events", .key = "0001", .value = "database formatted" },
    .{ .table = "events", .key = "0002", .value = "table embedded" },
    .{ .table = "notes", .key = "readme", .value = "planets use batched writes" },
};

const PlanetRow = struct {
    key_bytes: [32]u8,
    key_len: u8,
    value_bytes: [64]u8,
    value_len: u8,

    fn key(self: *const PlanetRow) []const u8 {
        return self.key_bytes[0..self.key_len];
    }

    fn value(self: *const PlanetRow) []const u8 {
        return self.value_bytes[0..self.value_len];
    }
};

const PlanetGenerator = struct {
    state: u64 = 42,

    fn next(self: *PlanetGenerator) u64 {
        self.state = self.state *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        return self.state;
    }

    fn choose(self: *PlanetGenerator, options: []const []const u8) []const u8 {
        const option_count: u64 = @intCast(options.len);
        const index: usize = @intCast(self.next() % option_count);
        return options[index];
    }

    fn coordinate(self: *PlanetGenerator) i32 {
        return @as(i32, @intCast(self.next() % 20_001)) - 10_000;
    }
};

fn validateTableAndKey(table: []const u8, key: []const u8) !void {
    if (table.len == 0 or table.len > 32 or key.len == 0 or key.len > 32) {
        return error.InvalidKey;
    }
    if (std.mem.indexOfScalar(u8, table, 0) != null or std.mem.indexOfScalar(u8, key, 0) != null) {
        return error.InvalidKey;
    }
}

fn insertTable(owner: anytype, name: []const u8) !void {
    const value = try owner.encodedEmbedded("table");
    if (!try owner.proxy().insert(name, value.data())) {
        return error.TableAlreadyExists;
    }
}

pub fn createTable(database: anytype, name: []const u8) !void {
    if (name.len == 0 or name.len > 32 or std.mem.indexOfScalar(u8, name, 0) != null) {
        return error.InvalidTable;
    }
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");
    try insertTable(owner, name);
    try transaction.commit();
}

/// Disconnects one embedded table. Its child pages remain unreachable until a
/// typed persistent database runs structural garbage collection.
pub fn deleteTable(database: anytype, name: []const u8) !bool {
    if (name.len == 0 or name.len > 32 or std.mem.indexOfScalar(u8, name, 0) != null) {
        return error.InvalidTable;
    }
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");
    const removed = try owner.proxy().remove(name);
    try transaction.commit();
    return removed;
}

/// Recursively destroys a linked embedded table before removing its catalog
/// entry. This explicit eager-reclaim helper is not the normal delete path.
pub fn deleteTableAndReclaim(database: anytype, name: []const u8) !bool {
    if (name.len == 0 or name.len > 32 or std.mem.indexOfScalar(u8, name, 0) != null) {
        return error.InvalidTable;
    }
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");
    const editor = (try owner.proxy().openValueEditor(name)) orelse return false;
    var child = try owner.openChild(editor, "table");
    defer child.deinit();
    try child.reclaimPersistent();
    try child.finish();
    if (!try owner.proxy().remove(name)) {
        return error.TableNotFound;
    }
    try transaction.commit();
    return true;
}

pub fn put(database: anytype, table: []const u8, key: []const u8, value: []const u8) !void {
    if (value.len > 64) {
        return error.ValueTooLarge;
    }
    try validateTableAndKey(table, key);
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");
    const editor = (try owner.proxy().openValueEditor(table)) orelse return error.TableNotFound;
    var child = try owner.openChild(editor, "table");
    defer child.deinit();
    const row = try child.encodedRaw("table", value);
    const proxy = child.proxy();
    if (!try proxy.update(key, row.data())) {
        if (!try proxy.insert(key, row.data())) {
            return error.ValueAlreadyExists;
        }
    }
    try child.finish();
    try transaction.commit();
}

pub fn remove(database: anytype, table: []const u8, key: []const u8) !bool {
    try validateTableAndKey(table, key);
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");
    const editor = (try owner.proxy().openValueEditor(table)) orelse return error.TableNotFound;
    var child = try owner.openChild(editor, "table");
    defer child.deinit();
    const removed = try child.proxy().remove(key);
    try child.finish();
    try transaction.commit();
    return removed;
}

fn validatePlanetCount(count: usize) !void {
    if (count < minimum_planet_count or count > maximum_planet_count) {
        return error.InvalidExampleCount;
    }
}

fn createPlanetPlan(allocator: std.mem.Allocator, count: usize) !std.ArrayList(PlanetRow) {
    var planets: std.ArrayList(PlanetRow) = .empty;
    errdefer planets.deinit(allocator);
    try planets.ensureTotalCapacity(allocator, count);

    var generator = PlanetGenerator{};
    for (0..count) |index| {
        var row = PlanetRow{
            .key_bytes = [_]u8{0} ** 32,
            .key_len = 0,
            .value_bytes = [_]u8{0} ** 64,
            .value_len = 0,
        };
        const key = try std.fmt.bufPrint(&row.key_bytes, "planet-{d:0>3}", .{index});
        row.key_len = @intCast(key.len);

        var name_buffer: [32]u8 = undefined;
        const start = generator.choose(&name_starts);
        const middle = generator.choose(&name_middles);
        const end = generator.choose(&name_ends);
        const name = if (generator.next() % 10 < 3)
            try std.fmt.bufPrint(
                &name_buffer,
                "{s}{s}{s}{s}",
                .{ start, middle, generator.choose(&name_middles), end },
            )
        else
            try std.fmt.bufPrint(&name_buffer, "{s}{s}{s}", .{ start, middle, end });
        name_buffer[0] = std.ascii.toUpper(name_buffer[0]);

        const gravity_hundredths = 35 + generator.next() % 151;
        const value = try std.fmt.bufPrint(
            &row.value_bytes,
            "{s} {s} {d},{d},{d} g{d}.{d:0>2} d{d} t{d}",
            .{
                name,
                generator.choose(&world_types),
                generator.coordinate(),
                generator.coordinate(),
                generator.coordinate(),
                gravity_hundredths / 100,
                gravity_hundredths % 100,
                8 + generator.next() % 65,
                -145 + @as(i32, @intCast(generator.next() % 204)),
            },
        );
        row.value_len = @intCast(value.len);
        try planets.append(allocator, row);
    }
    return planets;
}

fn ensureExampleTablesAbsent(database: anytype) !void {
    const owner = database.getConst("catalog").owner("tables");
    for (example_tables) |table| {
        var found = (try owner.find(table)) orelse continue;
        found.deinit();
        return error.TableAlreadyExists;
    }
}

fn insertExampleRow(owner: anytype, table: []const u8, key: []const u8, value: []const u8) !void {
    const editor = (try owner.proxy().openValueEditor(table)) orelse unreachable;
    var child = try owner.openChild(editor, "table");
    defer child.deinit();
    const encoded = try child.encodedRaw("table", value);
    if (!try child.proxy().insert(key, encoded.data())) {
        return error.ValueAlreadyExists;
    }
    try child.finish();
}

fn createExampleTables(database: anytype) !void {
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");

    inline for (example_tables) |table| {
        try insertTable(owner, table);
    }
    inline for (reference_rows) |row| {
        try insertExampleRow(owner, row.table, row.key, row.value);
    }
    try transaction.commit();
}

fn insertPlanetBatch(database: anytype, planets: []const PlanetRow) !void {
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");
    const editor = (try owner.proxy().openValueEditor("planets")) orelse unreachable;
    var child = try owner.openChild(editor, "table");
    defer child.deinit();
    for (planets) |*planet| {
        const encoded = try child.encodedRaw("table", planet.value());
        if (!try child.proxy().insert(planet.key(), encoded.data())) {
            return error.ValueAlreadyExists;
        }
    }
    try child.finish();
    try transaction.commit();
}

pub fn generateExamplesWithCount(
    database: anytype,
    allocator: std.mem.Allocator,
    count: usize,
    committed_planets: *usize,
) !void {
    committed_planets.* = 0;
    try validatePlanetCount(count);
    var planets = try createPlanetPlan(allocator, count);
    defer planets.deinit(allocator);
    try ensureExampleTablesAbsent(database);
    try createExampleTables(database);

    var start: usize = 0;
    while (start < planets.items.len) {
        const end = @min(start + generation_batch_size, planets.items.len);
        try insertPlanetBatch(database, planets.items[start..end]);
        start = end;
        committed_planets.* = start;
    }
}

pub fn generateExamples(database: anytype, allocator: std.mem.Allocator) !void {
    var committed_planets: usize = 0;
    try generateExamplesWithCount(database, allocator, default_planet_count, &committed_planets);
}

pub fn snapshot(database: anytype, allocator: std.mem.Allocator) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);

    const owner = database.getConst("catalog").owner("tables");
    var tables = try owner.iterator();
    if (tables) |*table_iterator| {
        defer table_iterator.deinit();
        while (try table_iterator.next()) |table_entry| {
            if (table_entry.key.len > 32) {
                return error.InvalidStoredKey;
            }
            var child = (try owner.openEmbedded(table_entry.key, "table")) orelse return error.InvalidStoredKey;
            defer child.deinit();
            var values = try child.proxy().iterator();
            if (values) |*value_iterator| {
                defer value_iterator.deinit();
                while (try value_iterator.next()) |value_entry| {
                    const value = try fullaz_db.value_envelope.readRaw(
                        value_entry.value,
                        Tables.typeIdentityByTag("table"),
                    );
                    if (value_entry.key.len > 32 or value.payload.len > 64) {
                        return error.InvalidStoredKey;
                    }
                    var row = Row{
                        .table = [_]u8{0} ** 32,
                        .table_len = @intCast(table_entry.key.len),
                        .key = [_]u8{0} ** 32,
                        .key_len = @intCast(value_entry.key.len),
                        .value = [_]u8{0} ** 64,
                        .value_len = @intCast(value.payload.len),
                    };
                    @memcpy(row.table[0..table_entry.key.len], table_entry.key);
                    @memcpy(row.key[0..value_entry.key.len], value_entry.key);
                    @memcpy(row.value[0..value.payload.len], value.payload);
                    try rows.append(allocator, row);
                }
            }
        }
    }
    return rows;
}
