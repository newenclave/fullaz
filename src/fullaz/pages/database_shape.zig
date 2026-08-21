const std = @import("std");
const component = @import("component.zig");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

pub fn bindings(comptime SchemaT: type, comptime BackendT: type) [SchemaT.fields.len]type {
    @setEvalBranchQuota(100_000);
    var result: [SchemaT.fields.len]type = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        result[index] = component.bindingFor(field.descriptor, BackendT);
    }
    return result;
}

pub fn assertStaticSchema(comptime SchemaT: type) void {
    inline for (SchemaT.fields) |field| {
        const Trait = field.descriptor.Trait;
        if (comptime std.mem.eql(u8, Trait.kind_name, "fullaz.bpt.paged") and
            Trait.CompareContext != void)
        {
            @compileError("StaticDatabase BPT components require CompareContext = void");
        }
        if (comptime std.mem.eql(u8, Trait.kind_name, "fullaz.slot-heap.paged") and
            Trait.CompareContext != void)
        {
            @compileError("StaticDatabase ordered components require CompareContext = void");
        }
    }
}

pub fn runtimes(comptime SchemaT: type, comptime bindings_: anytype) type {
    const field_count = SchemaT.fields.len;
    comptime var names: [field_count][]const u8 = undefined;
    comptime var types: [field_count]type = undefined;
    comptime var attributes: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        names[index] = field.name;
        types[index] = bindings_[index].Runtime;
        attributes[index] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

pub fn transactionStates(comptime SchemaT: type, comptime bindings_: anytype) type {
    const field_count = SchemaT.fields.len;
    comptime var names: [field_count][]const u8 = undefined;
    comptime var types: [field_count]type = undefined;
    comptime var attributes: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        names[index] = field.name;
        types[index] = bindings_[index].TransactionState;
        attributes[index] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

pub fn canDefaultInit(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct" or type_info.@"struct".is_tuple) {
        @compileError("Pages component InitOptions must be a named struct");
    }
    inline for (type_info.@"struct".fields) |field| {
        if (field.default_value_ptr == null) {
            return false;
        }
    }
    return true;
}

pub fn initOptions(comptime SchemaT: type, comptime bindings_: anytype) type {
    const field_count = SchemaT.fields.len;
    comptime var names: [field_count][]const u8 = undefined;
    comptime var types: [field_count]type = undefined;
    comptime var attributes: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        const Options = bindings_[index].InitOptions;
        names[index] = field.name;
        types[index] = Options;
        attributes[index] = .{};
        if (canDefaultInit(Options)) {
            const default_value: Options = .{};
            attributes[index].default_value_ptr = &default_value;
        }
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

pub fn componentErrors(comptime bindings_: anytype, comptime index: usize) type {
    if (index == bindings_.len) {
        return error{};
    }
    return bindings_[index].Error || componentErrors(bindings_, index + 1);
}

/// Persistent roots owned by the database rather than individual page types.
/// Component metadata must be externally laid out because this structure is
/// copied directly into the static database superblock.
pub fn staticMetadata(comptime SchemaT: type, comptime bindings_: anytype) type {
    const field_count = SchemaT.fields.len + 1;
    comptime var names: [field_count][]const u8 = undefined;
    comptime var types: [field_count]type = undefined;
    comptime var attributes: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    names[0] = "free_root";
    types[0] = PackedInt(SchemaT.PageId, .little);
    attributes[0] = .{};
    inline for (SchemaT.fields, 0..) |field, index| {
        const Binding = bindings_[index];
        if (!@hasDecl(Binding, "StaticMetadata")) {
            @compileError("StaticDatabase component binding requires StaticMetadata");
        }
        component.assertStaticMetadata(Binding, Binding.StaticMetadata);
        names[index + 1] = field.name;
        types[index + 1] = Binding.StaticMetadata.Storage;
        attributes[index + 1] = .{};
    }
    return @Struct(.@"extern", null, &names, &types, &attributes);
}

pub fn captureStaticMetadata(
    comptime SchemaT: type,
    comptime bindings_: anytype,
    comptime MetadataT: type,
    runtimes_: *const runtimes(SchemaT, bindings_),
    free_root: ?SchemaT.PageId,
) MetadataT {
    var metadata: MetadataT = undefined;
    metadata.free_root = PackedInt(SchemaT.PageId, .little).init(free_root orelse 0);
    inline for (SchemaT.fields, 0..) |field, index| {
        @field(metadata, field.name) = bindings_[index].StaticMetadata.capture(
            &@field(runtimes_.*, field.name),
        );
    }
    return metadata;
}

pub fn restoreStaticMetadata(
    comptime SchemaT: type,
    comptime bindings_: anytype,
    comptime MetadataT: type,
    runtimes_: *runtimes(SchemaT, bindings_),
    metadata: *const MetadataT,
) ?SchemaT.PageId {
    inline for (SchemaT.fields, 0..) |field, index| {
        bindings_[index].StaticMetadata.restore(
            &@field(runtimes_.*, field.name),
            &@field(metadata.*, field.name),
        );
    }
    const free_root = metadata.free_root.get();
    return if (free_root == 0) null else free_root;
}

pub fn validateStaticMetadata(
    comptime SchemaT: type,
    comptime bindings_: anytype,
    comptime MetadataT: type,
    metadata: *const MetadataT,
    page_count: usize,
) staticMetadataErrors(bindings_, 0)!void {
    const free_root = metadata.free_root.get();
    if (free_root != 0) {
        const root_index = std.math.cast(usize, free_root) orelse return error.BadMetadata;
        if (root_index >= page_count) {
            return error.BadMetadata;
        }
    }
    inline for (SchemaT.fields, 0..) |field, index| {
        try bindings_[index].StaticMetadata.validate(
            &@field(metadata.*, field.name),
            page_count,
        );
    }
}

pub fn staticMetadataErrors(comptime bindings_: anytype, comptime index: usize) type {
    if (index == bindings_.len) {
        return error{BadMetadata};
    }
    return bindings_[index].StaticMetadata.Error ||
        staticMetadataErrors(bindings_, index + 1);
}
