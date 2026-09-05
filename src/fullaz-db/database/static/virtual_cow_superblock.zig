const std = @import("std");
const PackedInt = @import("fullaz").core.packed_int.PackedInt;

pub fn VirtualCowSuperblock(
    comptime MetadataT: type,
    comptime PhysicalPageIdT: type,
    comptime VirtualPageIdT: type,
) type {
    const PackedPhysicalPageId = PackedInt(PhysicalPageIdT, .little);
    const PackedVirtualPageId = PackedInt(VirtualPageIdT, .little);
    const U16 = PackedInt(u16, .little);
    const U32 = PackedInt(u32, .little);
    const U64 = PackedInt(u64, .little);

    comptime {
        if (@typeInfo(MetadataT) != .@"struct" or @typeInfo(MetadataT).@"struct".layout != .@"extern") {
            @compileError("VirtualCowSuperblock metadata must be an extern struct");
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
            root_level: U16,
            commit_generation: U64,
            physical_page_count: U64,
            next_virtual_page_id: PackedVirtualPageId,
            vpm_root_page_id: PackedPhysicalPageId,
            retired_queue_first: PackedVirtualPageId,
            retired_queue_last: PackedVirtualPageId,
            retired_queue_size: U64,
            identity: Identity,
            metadata: MetadataT,
            crc: U32,
        };

        pub const magic = "FULLZCOW";
        // Version 3 adds GC state to the static metadata payload.
        pub const version = 3;
        pub const first_superblock_page_id: PhysicalPageIdT = 0;
        pub const second_superblock_page_id: PhysicalPageIdT = 1;

        comptime {
            if (@sizeOf(Storage) > std.math.maxInt(u16)) {
                @compileError("VirtualCowSuperblock storage exceeds u16 layout-size field");
            }
        }

        pub fn format(
            page: []u8,
            page_size: usize,
            commit_generation: u64,
            physical_page_count: usize,
            root_page_id: ?PhysicalPageIdT,
            root_level: u16,
            next_virtual_page_id: VirtualPageIdT,
            retired_queue_first: ?VirtualPageIdT,
            retired_queue_last: ?VirtualPageIdT,
            retired_queue_size: u64,
            identity: Identity,
            metadata: MetadataT,
        ) Error!void {
            if (page.len < @sizeOf(Storage) or
                std.math.cast(u32, page_size) == null or
                std.math.cast(u64, physical_page_count) == null)
            {
                return error.BadSuperblock;
            }
            @memset(page, 0);
            var storage = Storage{
                .magic = magic.*,
                .version = .init(version),
                .storage_size = .init(@sizeOf(Storage)),
                .page_size = .init(@intCast(page_size)),
                .physical_page_id_bits = @bitSizeOf(PhysicalPageIdT),
                .virtual_page_id_bits = @bitSizeOf(VirtualPageIdT),
                .root_level = .init(root_level),
                .commit_generation = .init(commit_generation),
                .physical_page_count = .init(@intCast(physical_page_count)),
                .next_virtual_page_id = .init(next_virtual_page_id),
                .vpm_root_page_id = .init(root_page_id orelse 0),
                .retired_queue_first = .init(retired_queue_first orelse 0),
                .retired_queue_last = .init(retired_queue_last orelse 0),
                .retired_queue_size = .init(retired_queue_size),
                .identity = identity,
                .metadata = metadata,
                .crc = .init(0),
            };
            storage.crc.set(crc(&storage));
            @memcpy(page[0..@sizeOf(Storage)], std.mem.asBytes(&storage));
        }

        pub fn read(page: []const u8, page_size: usize, identity: Identity) Error!Storage {
            if (page.len < @sizeOf(Storage)) {
                return error.BadSuperblock;
            }
            var storage: Storage = undefined;
            @memcpy(std.mem.asBytes(&storage), page[0..@sizeOf(Storage)]);
            if (!std.mem.eql(u8, &storage.magic, magic) or
                storage.storage_size.get() != @sizeOf(Storage) or
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
            if (!std.mem.eql(u8, &storage.identity.image_id, &identity.image_id) or
                !std.mem.eql(u8, &storage.identity.schema_digest, &identity.schema_digest))
            {
                return error.IdentityMismatch;
            }
            return storage;
        }

        pub fn rootPageId(storage: *const Storage) ?PhysicalPageIdT {
            const page_id = storage.vpm_root_page_id.get();
            return if (page_id == 0) null else page_id;
        }

        pub fn retiredQueueFirst(storage: *const Storage) ?VirtualPageIdT {
            const page_id = storage.retired_queue_first.get();
            return if (page_id == 0) null else page_id;
        }

        pub fn retiredQueueLast(storage: *const Storage) ?VirtualPageIdT {
            const page_id = storage.retired_queue_last.get();
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
        .int => |integer| {
            if (integer.signedness != .unsigned) {
                @compileError("VirtualCowSuperblock " ++ name ++ " must be an unsigned integer");
            }
        },
        else => @compileError("VirtualCowSuperblock " ++ name ++ " must be an integer"),
    }
}
