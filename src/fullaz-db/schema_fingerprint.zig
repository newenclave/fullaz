const std = @import("std");

/// Returns a stable digest of the persistent component layout and settings.
/// Component-specific persistent settings are written by each trait's
/// `fingerprint` hook. Function pointers are deliberately excluded; traits
/// identify callbacks through durable IDs instead.
pub fn digest(comptime SchemaT: type) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var writer = Writer{ .hasher = &hasher };
    hasher.update("fullaz.pages.static-schema.v1");
    writer.writeInt(u16, @bitSizeOf(SchemaT.PageId));
    inline for (SchemaT.fields) |field| {
        const Trait = field.descriptor.Trait;
        writer.writeBytes(field.name);
        writer.writeInt(u16, field.page_kinds.base);
        writer.writeInt(u16, field.page_kinds.count);
        writer.writeBytes(Trait.kind_name);
        writer.writeInt(u32, Trait.format_version);
        writer.writeInt(u32, Trait.page_kind_count);
        inline for (Trait.page_roles) |role| {
            writer.writeBytes(role);
        }
        if (!@hasDecl(Trait, "fingerprint") or
            @TypeOf(Trait.fingerprint) != fn (*Writer) void)
        {
            @compileError("fullaz-db component trait must declare fingerprint(writer: *FingerprintWriter)");
        }
        Trait.fingerprint(&writer);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

pub const Writer = struct {
    hasher: *std.crypto.hash.Blake3,

    pub fn writeBytes(self: *Writer, bytes: []const u8) void {
        self.writeInt(u32, @intCast(bytes.len));
        self.hasher.update(bytes);
    }

    pub fn writeInt(self: *Writer, comptime T: type, value: T) void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        self.hasher.update(&bytes);
    }

    pub fn writeCoord(self: *Writer, comptime CoordT: type) void {
        switch (@typeInfo(CoordT)) {
            .int => |info| {
                self.hasher.update("int");
                self.writeInt(u16, info.bits);
                self.hasher.update(if (info.signedness == .signed) "signed" else "unsigned");
            },
            .float => |info| {
                self.hasher.update("float");
                self.writeInt(u16, info.bits);
            },
            else => @compileError("StaticDatabase schema coordinate must be numeric"),
        }
    }
};
