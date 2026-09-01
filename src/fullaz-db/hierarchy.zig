const std = @import("std");
const component = @import("component/component.zig");
const fingerprint = @import("component/fingerprint.zig");

pub const RegistryId = u64;
pub const TypeId = u64;
pub const TypeVersion = u32;
pub const MetadataFormatVersion = u32;
pub const FingerprintWriter = fingerprint.Writer;
pub const TypeIdentity = @import("value_envelope.zig").TypeIdentity;

/// One named embedded type in a finite hierarchy registry.
///
/// Child relationships use durable numeric IDs rather than Zig type references,
/// so a type may name itself as an allowed child.
pub const Type = struct {
    tag: []const u8,
    type_id: TypeId,
    type_version: TypeVersion,
    metadata_format_version: MetadataFormatVersion,
    descriptor: component.Descriptor,
    allowed_child_type_ids: []const TypeId,
};

/// One top-level structure owned by a hierarchy store.
///
/// Owner tags and IDs are durable aggregate-layout identities. They are kept
/// separate from embedded type tags and IDs, which identify value envelopes.
pub const Owner = struct {
    tag: []const u8,
    owner_id: u64,
    descriptor: component.Descriptor,
    allowed_type_ids: []const TypeId,
};

pub const StoreOptions = struct {
    owners: []const Owner,
};

pub const Options = struct {
    registry_id: RegistryId,
    types: []const Type,
};

pub const Entry = struct {
    tag: []const u8,
    descriptor: component.Descriptor,
    type_identity: TypeIdentity,
    allowed_child_type_ids: []const TypeId,
};

/// Creates a compile-time registry of nominal embedded types.
///
/// The registry deliberately has no page-kind allocation. A hierarchy store
/// assigns one shared structural range for its owners and these nominal types.
/// Types refer to permitted child types by `TypeId`, not by embedding recursive
/// Zig types.
pub fn Hierarchy(comptime options: Options) type {
    comptime validate(options);
    const entries = comptime buildEntries(options);

    return struct {
        pub const registry_id = options.registry_id;
        pub const type_count = entries.len;
        pub const types = entries;

        pub fn entryByTag(comptime tag: []const u8) Entry {
            return entries[indexOfTag(tag)];
        }

        pub fn entryByTypeId(comptime type_id: TypeId) Entry {
            return entries[indexOfTypeId(type_id)];
        }

        pub fn descriptorByTag(comptime tag: []const u8) component.Descriptor {
            return entryByTag(tag).descriptor;
        }

        pub fn descriptorByTypeId(comptime type_id: TypeId) component.Descriptor {
            return entryByTypeId(type_id).descriptor;
        }

        pub fn typeIdentityByTag(comptime tag: []const u8) TypeIdentity {
            return entryByTag(tag).type_identity;
        }

        pub fn typeIdentityByTypeId(comptime type_id: TypeId) TypeIdentity {
            return entryByTypeId(type_id).type_identity;
        }

        pub fn allowsChild(comptime parent_type_id: TypeId, comptime child_type_id: TypeId) bool {
            const parent = entryByTypeId(parent_type_id);
            inline for (parent.allowed_child_type_ids) |allowed_type_id| {
                if (allowed_type_id == child_type_id) {
                    return true;
                }
            }
            return false;
        }

        /// Writes the durable hierarchy definition in a canonical format.
        pub fn writeFingerprint(writer: *FingerprintWriter) void {
            // v2 makes page-kind allocation an aggregate-store concern.
            writer.writeBytes("fullaz.embedded-hierarchy.v2.nominal-registry");
            writer.writeInt(RegistryId, registry_id);
            writer.writeInt(u32, @intCast(type_count));
            inline for (entries) |entry| {
                writeEntryFingerprint(writer, entry);
            }
        }

        pub fn digest() [32]u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            var writer = FingerprintWriter{ .hasher = &hasher };
            writeFingerprint(&writer);
            var result: [32]u8 = undefined;
            hasher.final(&result);
            return result;
        }

        pub fn indexOfTag(comptime tag: []const u8) usize {
            inline for (entries, 0..) |entry, index| {
                if (std.mem.eql(u8, tag, entry.tag)) {
                    return index;
                }
            }
            @compileError("Unknown fullaz-db Hierarchy type tag: " ++ tag);
        }

        fn indexOfTypeId(comptime type_id: TypeId) usize {
            inline for (entries, 0..) |entry, index| {
                if (type_id == entry.type_identity.type_id) {
                    return index;
                }
            }
            @compileError("Unknown fullaz-db Hierarchy type ID");
        }
    };
}

fn validate(comptime options: Options) void {
    if (options.registry_id == 0) {
        @compileError("fullaz-db Hierarchy registry_id cannot be zero");
    }
    if (options.types.len == 0) {
        @compileError("fullaz-db Hierarchy must contain at least one type");
    }
    if (options.types.len > std.math.maxInt(u32)) {
        @compileError("fullaz-db Hierarchy type count exceeds durable fingerprint capacity");
    }

    inline for (options.types, 0..) |configured_type, type_index| {
        validateTag(configured_type.tag);
        if (configured_type.type_id == 0) {
            @compileError("fullaz-db Hierarchy type_id cannot be zero");
        }
        if (configured_type.type_version == 0) {
            @compileError("fullaz-db Hierarchy type_version cannot be zero");
        }
        if (configured_type.metadata_format_version == 0) {
            @compileError("fullaz-db Hierarchy metadata_format_version cannot be zero");
        }
        comptime component.assertTrait(configured_type.descriptor.Trait);
        comptime validateDescriptorFingerprint(configured_type.descriptor);

        inline for (options.types[0..type_index]) |previous| {
            if (std.mem.eql(u8, configured_type.tag, previous.tag)) {
                @compileError("Duplicate fullaz-db Hierarchy type tag");
            }
            if (configured_type.type_id == previous.type_id) {
                @compileError("Duplicate fullaz-db Hierarchy type ID");
            }
        }
        inline for (configured_type.allowed_child_type_ids, 0..) |child_type_id, child_index| {
            inline for (configured_type.allowed_child_type_ids[0..child_index]) |previous_child_type_id| {
                if (child_type_id == previous_child_type_id) {
                    @compileError("Duplicate fullaz-db Hierarchy allowed child type ID");
                }
            }

            var known_child = false;
            inline for (options.types) |candidate| {
                known_child = known_child or child_type_id == candidate.type_id;
            }
            if (!known_child) {
                @compileError("Unknown fullaz-db Hierarchy allowed child type ID");
            }
        }
    }
}

fn validateTag(comptime tag: []const u8) void {
    if (tag.len == 0) {
        @compileError("fullaz-db Hierarchy type tag cannot be empty");
    }
    if (!std.unicode.utf8ValidateSlice(tag) or std.mem.indexOfScalar(u8, tag, 0) != null) {
        @compileError("fullaz-db Hierarchy type tag must be valid UTF-8 without NUL bytes");
    }
}

fn validateDescriptorFingerprint(comptime descriptor: component.Descriptor) void {
    const TraitT = descriptor.Trait;
    if (!@hasDecl(TraitT, "fingerprint") or
        @TypeOf(TraitT.fingerprint) != fn (*FingerprintWriter) void)
    {
        @compileError("fullaz-db Hierarchy type descriptor must declare fingerprint(writer: *FingerprintWriter)");
    }
}

fn buildEntries(comptime options: Options) [options.types.len]Entry {
    var entries: [options.types.len]Entry = undefined;
    inline for (options.types, 0..) |configured_type, index| {
        entries[index] = .{
            .tag = configured_type.tag,
            .descriptor = configured_type.descriptor,
            .type_identity = .{
                .registry_id = options.registry_id,
                .type_id = configured_type.type_id,
                .type_version = configured_type.type_version,
                .metadata_format_version = configured_type.metadata_format_version,
            },
            .allowed_child_type_ids = configured_type.allowed_child_type_ids,
        };
    }
    return entries;
}

fn writeEntryFingerprint(writer: *FingerprintWriter, comptime entry: Entry) void {
    writer.writeBytes(entry.tag);
    writer.writeInt(TypeId, entry.type_identity.type_id);
    writer.writeInt(TypeVersion, entry.type_identity.type_version);
    writer.writeInt(MetadataFormatVersion, entry.type_identity.metadata_format_version);
    writeDescriptorFingerprint(writer, entry.descriptor);

    const sorted_child_ids = comptime sortedTypeIds(entry.allowed_child_type_ids);
    writer.writeInt(u32, @intCast(sorted_child_ids.len));
    inline for (sorted_child_ids) |child_type_id| {
        writer.writeInt(TypeId, child_type_id);
    }
}

fn writeDescriptorFingerprint(writer: *FingerprintWriter, comptime descriptor: component.Descriptor) void {
    const TraitT = descriptor.Trait;
    writer.writeBytes(TraitT.kind_name);
    writer.writeInt(u32, TraitT.format_version);
    writer.writeInt(u32, @intCast(TraitT.page_kind_count));
    inline for (TraitT.page_roles) |role| {
        writer.writeBytes(role);
    }
    TraitT.fingerprint(writer);
}

fn sortedTypeIds(comptime type_ids: []const TypeId) [type_ids.len]TypeId {
    var result: [type_ids.len]TypeId = undefined;
    inline for (type_ids, 0..) |type_id, index| {
        result[index] = type_id;
    }

    var index: usize = 1;
    while (index < result.len) : (index += 1) {
        const value = result[index];
        var insert_at = index;
        while (insert_at > 0 and value < result[insert_at - 1]) : (insert_at -= 1) {
            result[insert_at] = result[insert_at - 1];
        }
        result[insert_at] = value;
    }
    return result;
}
