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
        if (!@hasDecl(Trait, "format") or @TypeOf(Trait.format) != fn (*Trait.Storage) void) {
            @compileError("Page extension trait must declare format(*Storage) void: " ++ @typeName(Trait));
        }
        if (!@hasDecl(Trait, "validate") or @TypeOf(Trait.validate) != fn (*const Trait.Storage) bool) {
            @compileError("Page extension trait must declare validate(*const Storage) bool: " ++ @typeName(Trait));
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
    const field_count = descriptors_info.@"struct".fields.len;
    if (field_count == 0) {
        @compileError("Page extension Compose requires at least one field");
    }

    comptime var field_names: [field_count][]const u8 = undefined;
    comptime var field_types: [field_count]type = undefined;
    comptime var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    inline for (0..field_count) |index| {
        const descriptor = descriptors[index];
        if (@TypeOf(descriptor) != Field) {
            @compileError("Page extension descriptor must be created with field()");
        }
        if (@alignOf(descriptor.Trait.Storage) != 1) {
            @compileError("Page extension storage must have alignment 1: " ++ descriptor.name);
        }

        inline for (0..index) |previous_index| {
            if (std.mem.eql(u8, descriptor.name, descriptors[previous_index].name)) {
                @compileError("Duplicate page extension field: " ++ descriptor.name);
            }
        }

        field_names[index] = descriptor.name;
        field_types[index] = descriptor.Trait.Storage;
        field_attrs[index] = .{};
    }

    const GeneratedStorage = @Struct(
        .@"extern",
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );

    return struct {
        pub const Storage = GeneratedStorage;

        pub fn format(storage: *GeneratedStorage) void {
            inline for (0..field_count) |index| {
                const descriptor = descriptors[index];
                descriptor.Trait.format(&@field(storage.*, descriptor.name));
            }
        }

        pub fn validate(storage: *const GeneratedStorage) bool {
            inline for (0..field_count) |index| {
                const descriptor = descriptors[index];
                if (!descriptor.Trait.validate(&@field(storage.*, descriptor.name))) {
                    return false;
                }
            }
            return true;
        }

        fn storageType(comptime name: []const u8) type {
            inline for (0..field_count) |index| {
                const descriptor = descriptors[index];
                if (std.mem.eql(u8, name, descriptor.name)) {
                    return descriptor.Trait.Storage;
                }
            }
            @compileError("Unknown page extension field: " ++ name);
        }

        pub fn field(storage: *const GeneratedStorage, comptime name: []const u8) *const storageType(name) {
            return &@field(storage.*, name);
        }

        pub fn fieldMut(storage: *GeneratedStorage, comptime name: []const u8) *storageType(name) {
            return &@field(storage.*, name);
        }
    };
}
