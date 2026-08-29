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

/// Two deliberately small B+ trees. `tables` is a namespace catalog and
/// `values` stores keys as `table + NUL + key`.
pub const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("tables", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 32,
        .maximum_value_size = 0,
    }))
    .add("values", fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 2,
    .maximum_key_size = 64,
    .maximum_value_size = 64,
}));

pub const Row = extern struct {
    table: [32]u8,
    table_len: u8,
    key: [32]u8,
    key_len: u8,
    value: [64]u8,
    value_len: u8,
};

fn compositeKey(table: []const u8, key: []const u8, buffer: *[65]u8) ![]const u8 {
    if (table.len == 0 or table.len > 32 or key.len == 0 or key.len > 32) {
        return error.InvalidKey;
    }
    if (std.mem.indexOfScalar(u8, table, 0) != null or std.mem.indexOfScalar(u8, key, 0) != null) {
        return error.InvalidKey;
    }
    @memcpy(buffer[0..table.len], table);
    buffer[table.len] = 0;
    @memcpy(buffer[table.len + 1 ..][0..key.len], key);
    return buffer[0 .. table.len + 1 + key.len];
}

fn exists(database: anytype, name: []const u8) !bool {
    var iterator = try database.getConst("tables").find(name);
    if (iterator) |*value| {
        defer value.deinit();
        return true;
    }
    return false;
}

pub fn createTable(database: anytype, name: []const u8) !void {
    if (name.len == 0 or name.len > 32 or std.mem.indexOfScalar(u8, name, 0) != null) {
        return error.InvalidTable;
    }
    var transaction = try database.begin();
    defer transaction.deinit();
    if (!try transaction.get("tables").insert(name, "")) {
        return error.TableAlreadyExists;
    }
    try transaction.commit();
}

pub fn put(database: anytype, table: []const u8, key: []const u8, value: []const u8) !void {
    if (value.len > 64) {
        return error.ValueTooLarge;
    }
    if (!try exists(database, table)) {
        return error.TableNotFound;
    }
    var composite: [65]u8 = undefined;
    const storage_key = try compositeKey(table, key, &composite);
    var transaction = try database.begin();
    defer transaction.deinit();
    if (!try transaction.get("values").update(storage_key, value)) {
        if (!try transaction.get("values").insert(storage_key, value)) {
            return error.ValueAlreadyExists;
        }
    }
    try transaction.commit();
}

pub fn remove(database: anytype, table: []const u8, key: []const u8) !bool {
    var composite: [65]u8 = undefined;
    const storage_key = try compositeKey(table, key, &composite);
    var transaction = try database.begin();
    defer transaction.deinit();
    const removed = try transaction.get("values").remove(storage_key);
    try transaction.commit();
    return removed;
}

pub fn snapshot(database: anytype, allocator: std.mem.Allocator) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);
    var iterator = try database.getConst("values").iterator();
    if (iterator) |*value| {
        defer value.deinit();
        while (try value.next()) |entry| {
            const separator = std.mem.indexOfScalar(u8, entry.key, 0) orelse return error.InvalidStoredKey;
            const table = entry.key[0..separator];
            const key = entry.key[separator + 1 ..];
            if (table.len > 32 or key.len > 32 or entry.value.len > 64) {
                return error.InvalidStoredKey;
            }
            var row = Row{
                .table = [_]u8{0} ** 32,
                .table_len = @intCast(table.len),
                .key = [_]u8{0} ** 32,
                .key_len = @intCast(key.len),
                .value = [_]u8{0} ** 64,
                .value_len = @intCast(entry.value.len),
            };
            @memcpy(row.table[0..table.len], table);
            @memcpy(row.key[0..key.len], key);
            @memcpy(row.value[0..entry.value.len], entry.value);
            try rows.append(allocator, row);
        }
    }
    return rows;
}
