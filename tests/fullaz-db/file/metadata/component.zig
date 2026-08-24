const std = @import("std");
const fullaz_db = @import("fullaz-db");

pub const Binding = struct {
    pub const Runtime = struct {
        root: u64 = 0,
    };
    pub const DynamicMetadata = struct {
        pub const format_version: u32 = 1;
        pub const known_tags: []const u16 = &.{0x0100};
        pub const repeated_tags: []const u16 = &.{};
        pub const Error = fullaz_db.file.dynamic_metadata.Error;

        pub fn restore(runtime: *Runtime, payload: []const u8, _: usize) Error!void {
            try fullaz_db.file.tagged_fields.validateOwnedFields(payload, known_tags, repeated_tags);
            var reader = fullaz_db.file.tagged_fields.Reader.init(payload);
            while (try reader.next()) |field| {
                if (field.tag == known_tags[0]) {
                    runtime.root = try fullaz_db.file.dynamic_metadata.readU64(field);
                    return;
                }
            }
            return error.BadMetadata;
        }

        pub fn encodeKnown(
            runtime: *const Runtime,
            writer: *fullaz_db.file.tagged_fields.Writer,
        ) Error!void {
            try fullaz_db.file.dynamic_metadata.appendU64(writer, known_tags[0], runtime.root);
        }
    };
};

test "fullaz-db component metadata: rewrites known fields and preserves unknown fields" {
    var previous_bytes: [64]u8 = undefined;
    var previous = fullaz_db.file.tagged_fields.Writer.init(&previous_bytes);
    try fullaz_db.file.dynamic_metadata.appendU64(&previous, 0x0100, 7);
    try previous.append(0x0200, 0x8000, "future");

    var destination: [64]u8 = undefined;
    var scratch: [64]u8 = undefined;
    const runtime = Binding.Runtime{ .root = 42 };
    const rewritten = try fullaz_db.file.component_metadata.rewrite(
        Binding,
        &runtime,
        &destination,
        &scratch,
        previous.used(),
    );

    var reader = fullaz_db.file.tagged_fields.Reader.init(rewritten);
    const unknown = (try reader.next()).?;
    try std.testing.expectEqual(@as(u16, 0x0200), unknown.tag);
    try std.testing.expectEqual(@as(u16, 0x8000), unknown.flags);
    try std.testing.expectEqualStrings("future", unknown.value);

    var restored = Binding.Runtime{};
    try fullaz_db.file.component_metadata.restore(Binding, &restored, rewritten, 100);
    try std.testing.expectEqual(@as(u64, 42), restored.root);
}

test "fullaz-db component metadata: rejects duplicate singular fields" {
    var bytes: [64]u8 = undefined;
    var writer = fullaz_db.file.tagged_fields.Writer.init(&bytes);
    try fullaz_db.file.dynamic_metadata.appendU64(&writer, 0x0100, 1);
    try fullaz_db.file.dynamic_metadata.appendU64(&writer, 0x0100, 2);

    var runtime = Binding.Runtime{};
    try std.testing.expectError(
        error.DuplicateKnownField,
        fullaz_db.file.component_metadata.restore(Binding, &runtime, writer.used(), 100),
    );
}
