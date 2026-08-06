const std = @import("std");
const requiresFnSignature = @import("../contracts/interfaces.zig").requiresFnSignature;

pub const Field = struct {
    name: [:0]const u8,
    Trait: type,
};

pub const Empty = struct {
    pub const Storage = extern struct {};
    pub const page_version: u8 = 0;
    pub const fields = [0]Field{};

    pub fn format(_: *Storage) void {}

    pub fn validate(_: *const Storage) bool {
        return true;
    }
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
        requiresFnSignature(Trait, "format", fn (*Trait.Storage) void);
        requiresFnSignature(Trait, "validate", fn (*const Trait.Storage) bool);
    }

    return .{
        .name = name,
        .Trait = Trait,
    };
}

fn composeFromFields(comptime configured_version: u8, comptime descriptors: anytype) type {
    const descriptors_info = @typeInfo(@TypeOf(descriptors));
    const field_count = switch (descriptors_info) {
        .array => |info| blk: {
            if (info.child != Field) {
                @compileError("Page extension descriptors must be Field values");
            }
            break :blk info.len;
        },
        else => @compileError("Page extension descriptors must be an array"),
    };
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
        pub const page_version = configured_version;
        pub const fields = descriptors;

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

        pub fn traitType(comptime name: []const u8) type {
            inline for (0..field_count) |index| {
                const descriptor = descriptors[index];
                if (std.mem.eql(u8, name, descriptor.name)) {
                    return descriptor.Trait;
                }
            }
            @compileError("Unknown page extension field: " ++ name);
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

pub fn Compose(comptime config: anytype) type {
    const config_info = @typeInfo(@TypeOf(config));
    if (config_info != .@"struct" or config_info.@"struct".is_tuple) {
        @compileError("Page extension Compose requires a named config struct");
    }
    if (!@hasField(@TypeOf(config), "version") or !@hasField(@TypeOf(config), "fields")) {
        @compileError("Page extension Compose config requires version and fields");
    }

    const configured_version: u8 = @intCast(config.version);
    const configured_fields = config.fields;
    const fields_info = @typeInfo(@TypeOf(configured_fields));
    if (fields_info != .@"struct" or !fields_info.@"struct".is_tuple) {
        @compileError("Page extension descriptors must be a tuple");
    }

    const field_count = fields_info.@"struct".fields.len;
    const descriptors = comptime blk: {
        var result: [field_count]Field = undefined;
        for (0..field_count) |index| {
            const descriptor = configured_fields[index];
            if (@TypeOf(descriptor) != Field) {
                @compileError("Page extension descriptor must be created with field()");
            }
            result[index] = descriptor;
        }
        break :blk result;
    };
    return composeFromFields(configured_version, descriptors);
}

fn assertExtendable(comptime Base: type) void {
    comptime {
        if (!@hasDecl(Base, "page_version") or @TypeOf(Base.page_version) != u8) {
            @compileError("Page extension Extend base must declare page_version: u8");
        }
        if (!@hasDecl(Base, "Storage") or @TypeOf(Base.Storage) != type) {
            @compileError("Page extension Extend base must declare Storage");
        }
        if (!@hasDecl(Base, "fields")) {
            @compileError("Page extension Extend base must declare fields");
        }
        const fields_info = @typeInfo(@TypeOf(Base.fields));
        if (fields_info != .array or fields_info.array.child != Field) {
            @compileError("Page extension Extend base fields must be an array of Field");
        }
        requiresFnSignature(Base, "format", fn (*Base.Storage) void);
        requiresFnSignature(Base, "validate", fn (*const Base.Storage) bool);
    }
}

pub fn Extend(comptime Base: type, comptime config: anytype) type {
    assertExtendable(Base);

    const config_info = @typeInfo(@TypeOf(config));
    if (config_info != .@"struct" or config_info.@"struct".is_tuple) {
        @compileError("Page extension Extend requires a named config struct");
    }
    if (!@hasField(@TypeOf(config), "version") or !@hasField(@TypeOf(config), "fields")) {
        @compileError("Page extension Extend config requires version and fields");
    }

    const configured_version: u8 = @intCast(config.version);
    const configured_fields = config.fields;
    const fields_info = @typeInfo(@TypeOf(configured_fields));
    if (fields_info != .@"struct" or !fields_info.@"struct".is_tuple) {
        @compileError("Page extension descriptors must be a tuple");
    }

    const base_count = Base.fields.len;
    const field_count = fields_info.@"struct".fields.len;
    const extension_fields = comptime blk: {
        var result: [field_count]Field = undefined;
        for (0..field_count) |index| {
            const descriptor = configured_fields[index];
            if (@TypeOf(descriptor) != Field) {
                @compileError("Page extension descriptor must be created with field()");
            }
            result[index] = descriptor;
        }
        break :blk result;
    };

    if (@hasField(@TypeOf(config), "namespace")) {
        const namespace: [:0]const u8 = config.namespace;
        if (namespace.len == 0) {
            @compileError("Page extension namespace cannot be empty");
        }
        const Namespace = composeFromFields(configured_version, extension_fields);
        const descriptors = comptime blk: {
            var result: [base_count + 1]Field = undefined;
            for (0..base_count) |index| {
                result[index] = Base.fields[index];
            }
            result[base_count] = field(namespace, Namespace);
            break :blk result;
        };
        return composeFromFields(configured_version, descriptors);
    }

    const descriptors = comptime blk: {
        var result: [base_count + field_count]Field = undefined;
        for (0..base_count) |index| {
            result[index] = Base.fields[index];
        }
        for (0..field_count) |index| {
            result[base_count + index] = extension_fields[index];
        }
        break :blk result;
    };
    return composeFromFields(configured_version, descriptors);
}
