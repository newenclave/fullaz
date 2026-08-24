const std = @import("std");
const component = @import("component.zig");

const first_component_page_kind: component.PageKind = 0x0100;
const reserved_page_kind: component.PageKind = std.math.maxInt(component.PageKind);

pub const Field = struct {
    name: []const u8,
    descriptor: component.Descriptor,
    page_kinds: component.PageKindRange,
};

fn schemaFromFields(comptime PageIdT: type, comptime configured_fields: anytype) type {
    const fields_info = @typeInfo(@TypeOf(configured_fields));
    switch (fields_info) {
        .array => |array| {
            if (array.child != Field) {
                @compileError("fullaz-db Schema fields must be Field values");
            }
        },
        else => @compileError("fullaz-db Schema fields must be an array"),
    }

    return struct {
        pub const PageId = PageIdT;
        pub const fields = configured_fields;

        pub fn contains(comptime name: []const u8) bool {
            inline for (configured_fields) |field| {
                if (comptime std.mem.eql(u8, name, field.name)) {
                    return true;
                }
            }
            return false;
        }

        pub fn indexOf(comptime name: []const u8) usize {
            inline for (configured_fields, 0..) |field, index| {
                if (comptime std.mem.eql(u8, name, field.name)) {
                    return index;
                }
            }
            @compileError("Unknown pages Schema component: " ++ name);
        }

        pub fn descriptor(comptime name: []const u8) component.Descriptor {
            const index = comptime indexOf(name);
            return configured_fields[index].descriptor;
        }

        pub fn trait(comptime name: []const u8) type {
            return descriptor(name).Trait;
        }

        pub fn pageKinds(comptime name: []const u8) component.PageKindRange {
            const index = comptime indexOf(name);
            return configured_fields[index].page_kinds;
        }

        pub fn add(
            comptime name: []const u8,
            comptime new_descriptor: component.Descriptor,
        ) type {
            validateName(name);
            comptime component.assertTrait(new_descriptor.Trait);
            inline for (configured_fields) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    @compileError("Duplicate pages Schema component: " ++ name);
                }
            }

            const base: u32 = if (configured_fields.len == 0)
                first_component_page_kind
            else
                configured_fields[configured_fields.len - 1].page_kinds.endExclusive();
            const available: usize = @as(usize, reserved_page_kind) - @as(usize, base);
            if (new_descriptor.Trait.page_kind_count > available) {
                @compileError("fullaz-db Schema page-kind space exhausted");
            }

            var next_fields: [configured_fields.len + 1]Field = undefined;
            inline for (configured_fields, 0..) |field, index| {
                next_fields[index] = field;
            }
            next_fields[configured_fields.len] = .{
                .name = name,
                .descriptor = new_descriptor,
                .page_kinds = .{
                    .base = @intCast(base),
                    .count = @intCast(new_descriptor.Trait.page_kind_count),
                },
            };
            return schemaFromFields(PageIdT, next_fields);
        }
    };
}

fn validateName(comptime name: []const u8) void {
    if (name.len == 0) {
        @compileError("fullaz-db Schema component name cannot be empty");
    }
    if (name.len > 255) {
        @compileError("fullaz-db Schema component name is too long");
    }
    if (!std.unicode.utf8ValidateSlice(name)) {
        @compileError("fullaz-db Schema component name is not valid UTF-8");
    }
    if (std.mem.indexOfScalar(u8, name, 0) != null) {
        @compileError("fullaz-db Schema component name cannot contain NUL");
    }
    for (name, 0..) |byte, index| {
        if (byte == '$' and (index == 0 or name[index - 1] == '/')) {
            @compileError("fullaz-db Schema component name uses a reserved $ path segment");
        }
    }
}

pub fn Schema(comptime options: anytype) type {
    const options_info = @typeInfo(@TypeOf(options));
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("fullaz-db Schema options must be a named struct");
    }
    if (!@hasField(@TypeOf(options), "page_id") or @TypeOf(options.page_id) != type) {
        @compileError("fullaz-db Schema options must declare page_id as a type");
    }
    const page_id_info = @typeInfo(options.page_id);
    if (page_id_info != .int or page_id_info.int.signedness != .unsigned) {
        @compileError("fullaz-db Schema page_id must be an unsigned integer");
    }
    if (options.page_id == usize or @bitSizeOf(options.page_id) % 8 != 0) {
        @compileError("fullaz-db Schema page_id must be a fixed-width byte-aligned unsigned integer");
    }

    return schemaFromFields(options.page_id, [0]Field{});
}
