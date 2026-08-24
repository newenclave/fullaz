const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const Binding = struct {
    pub const Runtime = struct {
        root: u64 = 0,
    };
    pub const DynamicMetadata = struct {
        pub const format_version: u32 = 1;
        pub const known_tags: []const u16 = &.{0x0100};
        pub const repeated_tags: []const u16 = &.{};
        pub const Error = fullaz_db.file.dynamic_metadata.Error;

        pub fn restore(runtime: *Runtime, payload: []const u8, _: usize) Error!void {
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

test "fullaz-db component metadata I/O: initializes, updates, and loads a page" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Io = fullaz_db.file.ComponentMetadataIo(Binding, Cache);
    const state = fullaz_db.file.component_metadata_page.State{
        .component_id = 1,
        .metadata_format_version = 1,
    };

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 2);
    defer cache.deinit();

    var allocated = try cache.create();
    const page_id = try allocated.pid();
    allocated.deinit();

    var payload_buffer: [256]u8 = undefined;
    var rewrite_scratch: [256]u8 = undefined;
    const initial = Binding.Runtime{ .root = 7 };
    try Io.initialize(&cache, page_id, state, &initial, &payload_buffer, &rewrite_scratch);

    const updated = Binding.Runtime{ .root = 42 };
    try Io.store(&cache, page_id, state, &updated, &payload_buffer, &rewrite_scratch);

    var restored = Binding.Runtime{};
    try Io.load(&cache, page_id, state, &restored);
    try std.testing.expectEqual(@as(u64, 42), restored.root);
}
