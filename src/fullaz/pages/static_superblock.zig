const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

pub fn StaticSuperblock(comptime MetadataT: type) type {
    const U16 = PackedInt(u16, .little);
    const U32 = PackedInt(u32, .little);
    const U64 = PackedInt(u64, .little);

    return struct {
        const Self = @This();

        pub const Error = error{
            BadSuperblock,
            UnsupportedVersion,
            IdentityMismatch,
            PageSizeMismatch,
        };
        pub const Identity = extern struct {
            image_id: [16]u8,
            schema_digest: [32]u8,
        };
        pub const Storage = extern struct {
            magic: [8]u8,
            version: U16,
            storage_size: U16,
            page_size: U32,
            page_count: U64,
            clean: u8,
            reserved: [3]u8,
            identity: Identity,
            metadata: MetadataT,
            crc: U32,
        };

        pub const magic = "FULLAZDB";
        pub const version = 1;

        pub fn format(
            page: []u8,
            page_size: usize,
            page_count: usize,
            identity: Identity,
            metadata: MetadataT,
            clean: bool,
        ) Error!void {
            if (page.len < @sizeOf(Storage) or
                std.math.cast(u32, page_size) == null or
                std.math.cast(u64, page_count) == null)
            {
                return error.BadSuperblock;
            }
            @memset(page, 0);
            var storage = Storage{
                .magic = magic.*,
                .version = U16.init(version),
                .storage_size = U16.init(@sizeOf(Storage)),
                .page_size = U32.init(@intCast(page_size)),
                .page_count = U64.init(@intCast(page_count)),
                .clean = @intFromBool(clean),
                .reserved = .{ 0, 0, 0 },
                .identity = identity,
                .metadata = metadata,
                .crc = U32.init(0),
            };
            storage.crc.set(crc(&storage));
            @memcpy(page[0..@sizeOf(Storage)], std.mem.asBytes(&storage));
        }

        pub fn read(
            page: []const u8,
            page_size: usize,
            identity: Identity,
        ) Error!Storage {
            if (page.len < @sizeOf(Storage)) {
                return error.BadSuperblock;
            }
            var storage: Storage = undefined;
            @memcpy(std.mem.asBytes(&storage), page[0..@sizeOf(Storage)]);
            if (!std.mem.eql(u8, &storage.magic, magic) or
                storage.storage_size.get() != @sizeOf(Storage) or
                storage.clean > 1 or
                !std.mem.allEqual(u8, &storage.reserved, 0) or
                crc(&storage) != storage.crc.get())
            {
                return error.BadSuperblock;
            }
            if (storage.version.get() != version) {
                return error.UnsupportedVersion;
            }
            if (storage.page_size.get() != page_size) {
                return error.PageSizeMismatch;
            }
            if (!std.mem.eql(u8, &storage.identity.image_id, &identity.image_id) or
                !std.mem.eql(u8, &storage.identity.schema_digest, &identity.schema_digest))
            {
                return error.IdentityMismatch;
            }
            return storage;
        }

        fn crc(storage: *const Storage) u32 {
            const bytes = std.mem.asBytes(storage);
            const crc_offset = @offsetOf(Storage, "crc");
            var hasher = std.hash.Crc32.init();
            hasher.update(bytes[0..crc_offset]);
            hasher.update(bytes[crc_offset + @sizeOf(U32) ..]);
            return hasher.final();
        }
    };
}
