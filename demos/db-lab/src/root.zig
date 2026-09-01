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

const ExampleRow = struct {
    key: []const u8,
    value: []const u8,
};

const ExampleTable = struct {
    name: []const u8,
    rows: []const ExampleRow,
};

const examples = [_]ExampleTable{
    .{ .name = "users", .rows = &.{
        .{ .key = "ada", .value = "first programmer" },
        .{ .key = "linus", .value = "kernel maintainer" },
    } },
    .{ .name = "events", .rows = &.{
        .{ .key = "0001", .value = "database formatted" },
        .{ .key = "0002", .value = "table embedded" },
    } },
    .{ .name = "notes", .rows = &.{
        .{ .key = "readme", .value = "one catalog, many trees" },
    } },
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
    if (!try owner.insert(name, try owner.embed("table"))) {
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

pub fn put(database: anytype, table: []const u8, key: []const u8, value: []const u8) !void {
    if (value.len > 64) {
        return error.ValueTooLarge;
    }
    try validateTableAndKey(table, key);
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");
    var child = (try owner.openEmbeddedForEdit(table, "table")) orelse return error.TableNotFound;
    defer child.deinit();
    if (!try child.update(key, child.raw("table", value))) {
        if (!try child.insert(key, child.raw("table", value))) {
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
    var child = (try owner.openEmbeddedForEdit(table, "table")) orelse return error.TableNotFound;
    defer child.deinit();
    const removed = try child.remove(key);
    try child.finish();
    try transaction.commit();
    return removed;
}

pub fn generateExamples(database: anytype) !void {
    var transaction = try database.begin();
    defer transaction.deinit();
    const owner = transaction.get("catalog").owner("tables");

    inline for (examples) |table| {
        try insertTable(owner, table.name);
        var child = (try owner.openEmbeddedForEdit(table.name, "table")) orelse unreachable;
        defer child.deinit();
        inline for (table.rows) |row| {
            if (!try child.insert(row.key, child.raw("table", row.value))) {
                return error.ValueAlreadyExists;
            }
        }
        try child.finish();
    }
    try transaction.commit();
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
            var child = (try owner.openEmbeddedBpt(table_entry.key, "table")) orelse return error.InvalidStoredKey;
            defer child.deinit();
            var values = try child.iterator();
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
