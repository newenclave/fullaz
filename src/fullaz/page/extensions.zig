const std = @import("std");

pub const Field = struct {
    name: [:0]const u8,
    Trait: type,
};

pub fn field(comptime name: [:0]const u8, comptime Trait: type) Field {
    comptime {
        if (name.len == 0) {
            @compileError("Page extension field name cannot be empty");
        }
        if (!@hasDecl(Trait, "Storage")) {
            @compileError("Page extension trait must declare Storage: " ++ @typeName(Trait));
        }
        if (@TypeOf(Trait.Storage) != type) {
            @compileError("Page extension trait Storage must be a type: " ++ @typeName(Trait));
        }
    }

    return .{
        .name = name,
        .Trait = Trait,
    };
}

pub fn Compose(comptime descriptors: anytype) type {
    const descriptors_info = @typeInfo(@TypeOf(descriptors));
    if (descriptors_info != .@"struct" or !descriptors_info.@"struct".is_tuple) {
        @compileError("Page extension descriptors must be a tuple");
    }
    if (descriptors_info.@"struct".fields.len != 1) {
        @compileError("Page extension Compose currently requires exactly one field");
    }

    const descriptor = descriptors[0];
    const Trait = descriptor.Trait;
    const field_names = [_][]const u8{descriptor.name};
    const field_types = [_]type{Trait.Storage};
    const field_attrs = [_]std.builtin.Type.StructField.Attributes{.{}};
    const GeneratedStorage = @Struct(
        .@"extern",
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );

    return struct {
        pub const Storage = GeneratedStorage;

        fn storageType(comptime name: []const u8) type {
            if (!std.mem.eql(u8, name, descriptor.name)) {
                @compileError("Unknown page extension field: " ++ name);
            }
            return Trait.Storage;
        }

        pub fn field(storage: *const GeneratedStorage, comptime name: []const u8) *const storageType(name) {
            return &@field(storage.*, name);
        }

        pub fn fieldMut(storage: *GeneratedStorage, comptime name: []const u8) *storageType(name) {
            return &@field(storage.*, name);
        }
    };
}
