const std = @import("std");
const PackedInt = @import("fullaz").core.packed_int.PackedInt;

/// The virtual static format is deliberately independent from the physical
/// static superblock. Component roots and free-list references are VIDs while
/// the VPM and its allocator remain in the physical PID namespace.
pub fn VirtualStaticSuperblock(
    comptime MetadataT: type,
    comptime PhysicalPageIdT: type,
    comptime VirtualPageIdT: type,
) type {
    const U16 = PackedInt(u16, .little);
    const U32 = PackedInt(u32, .little);
    const U64 = PackedInt(u64, .little);
    const PackedPhysicalPageId = PackedInt(PhysicalPageIdT, .little);

    comptime {
        if (@typeInfo(MetadataT) != .@"struct" or @typeInfo(MetadataT).@"struct".layout != .@"extern") {
            @compileError("VirtualStaticSuperblock metadata must be an extern struct");
        }
        assertUnsignedInteger(PhysicalPageIdT, "physical page ID");
        assertUnsignedInteger(VirtualPageIdT, "virtual page ID");
    }

    return struct {
        const Self = @This();

        pub const Error = error{
            BadSuperblock,
            UnsupportedVersion,
            IdentityMismatch,
            PageSizeMismatch,
            PageIdWidthMismatch,
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
            physical_page_id_bits: u8,
            virtual_page_id_bits: u8,
            reserved: U16,
            physical_page_count: U64,
            virtual_page_count: U64,
            physical_free_root: PackedPhysicalPageId,
            vpm_state_page_id: PackedPhysicalPageId,
            placeholder_page_id: PackedPhysicalPageId,
            identity: Identity,
            metadata: MetadataT,
            crc: U32,
        };

        pub const magic = "FULLZVDB";
        pub const version = 1;
        pub const superblock_page_id: PhysicalPageIdT = 0;
        pub const vpm_state_page_id: PhysicalPageIdT = 1;
        pub const placeholder_page_id: PhysicalPageIdT = 2;

        comptime {
            if (@sizeOf(Storage) > std.math.maxInt(u16)) {
                @compileError("VirtualStaticSuperblock storage exceeds u16 layout-size field");
            }
        }

        pub fn format(
            page: []u8,
            page_size: usize,
            physical_page_count: usize,
            virtual_page_count: usize,
            physical_free_root: ?PhysicalPageIdT,
            identity: Identity,
            metadata: MetadataT,
        ) Error!void {
            if (page.len < @sizeOf(Storage) or
                std.math.cast(u32, page_size) == null or
                std.math.cast(u64, physical_page_count) == null or
                std.math.cast(u64, virtual_page_count) == null)
            {
                return error.BadSuperblock;
            }
            @memset(page, 0);
            var storage = Storage{
                .magic = magic.*,
                .version = U16.init(version),
                .storage_size = U16.init(@sizeOf(Storage)),
                .page_size = U32.init(@intCast(page_size)),
                .physical_page_id_bits = @bitSizeOf(PhysicalPageIdT),
                .virtual_page_id_bits = @bitSizeOf(VirtualPageIdT),
                .reserved = U16.init(0),
                .physical_page_count = U64.init(@intCast(physical_page_count)),
                .virtual_page_count = U64.init(@intCast(virtual_page_count)),
                .physical_free_root = PackedPhysicalPageId.init(physical_free_root orelse 0),
                .vpm_state_page_id = PackedPhysicalPageId.init(vpm_state_page_id),
                .placeholder_page_id = PackedPhysicalPageId.init(placeholder_page_id),
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
                storage.reserved.get() != 0 or
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
            if (storage.physical_page_id_bits != @bitSizeOf(PhysicalPageIdT) or
                storage.virtual_page_id_bits != @bitSizeOf(VirtualPageIdT))
            {
                return error.PageIdWidthMismatch;
            }
            if (storage.vpm_state_page_id.get() != vpm_state_page_id or
                storage.placeholder_page_id.get() != placeholder_page_id)
            {
                return error.BadSuperblock;
            }
            if (!std.mem.eql(u8, &storage.identity.image_id, &identity.image_id) or
                !std.mem.eql(u8, &storage.identity.schema_digest, &identity.schema_digest))
            {
                return error.IdentityMismatch;
            }
            return storage;
        }

        pub fn physicalFreeRoot(storage: *const Storage) ?PhysicalPageIdT {
            const page_id = storage.physical_free_root.get();
            return if (page_id == 0) null else page_id;
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

fn assertUnsignedInteger(comptime T: type, comptime name: []const u8) void {
    switch (@typeInfo(T)) {
        .int => |int_info| {
            if (int_info.signedness != .unsigned) {
                @compileError("VirtualStaticSuperblock " ++ name ++ " must be unsigned");
            }
        },
        else => @compileError("VirtualStaticSuperblock " ++ name ++ " must be an integer"),
    }
}
