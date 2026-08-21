const std = @import("std");

/// Returns a stable digest of the persistent component layout and settings.
/// Function pointers are deliberately excluded: static BPT bindings require a
/// void compare context and identify the comparator through comparator_id.
pub fn digest(comptime SchemaT: type) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("fullaz.pages.static-schema.v1");
    writeInt(&hasher, u16, @bitSizeOf(SchemaT.PageId));
    inline for (SchemaT.fields) |field| {
        const Trait = field.descriptor.Trait;
        writeBytes(&hasher, field.name);
        writeBytes(&hasher, Trait.kind_name);
        writeInt(&hasher, u32, Trait.format_version);
        writeInt(&hasher, u32, Trait.page_kind_count);
        inline for (Trait.page_roles) |role| {
            writeBytes(&hasher, role);
        }
        if (@hasDecl(Trait, "comparator_id")) {
            writeInt(&hasher, u32, Trait.comparator_id);
            writeInt(&hasher, usize, Trait.maximum_key_size);
            writeInt(&hasher, usize, Trait.maximum_value_size);
            writeBytes(&hasher, @tagName(Trait.rebalance_policy));
        }
        if (@hasDecl(Trait, "dimensions")) {
            writeInt(&hasher, usize, Trait.dimensions);
            writeInt(&hasher, usize, Trait.maximum_entries);
            writeInt(&hasher, usize, Trait.maximum_value_size);
            writeCoord(&hasher, Trait.Coord);
        }
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn writeBytes(hasher: *std.crypto.hash.Blake3, bytes: []const u8) void {
    writeInt(hasher, u32, @intCast(bytes.len));
    hasher.update(bytes);
}

fn writeInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn writeCoord(hasher: *std.crypto.hash.Blake3, comptime CoordT: type) void {
    switch (@typeInfo(CoordT)) {
        .int => |info| {
            hasher.update("int");
            writeInt(hasher, u16, info.bits);
            hasher.update(if (info.signedness == .signed) "signed" else "unsigned");
        },
        .float => |info| {
            hasher.update("float");
            writeInt(hasher, u16, info.bits);
        },
        else => @compileError("StaticDatabase schema coordinate must be numeric"),
    }
}
