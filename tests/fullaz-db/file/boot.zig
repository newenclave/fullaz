const std = @import("std");
const boot = @import("fullaz-db").file.boot;
const tagged = @import("fullaz-db").file.tagged_fields;

fn state() boot.State {
    return .{
        .image_id = [_]u8{0x11} ** 16,
        .page_size = 512,
        .page_id_bits = 32,
        .clean = true,
        .feature_flags = 0,
        .page_count = 1,
        .free_root = null,
        .catalog_first = null,
        .catalog_last = null,
        .catalog_record_count = 0,
        .live_component_count = 0,
        .id_radix_root = null,
        .id_radix_free_leaf_root = null,
        .name_bpt_root = null,
        .next_component_id = 1,
        .next_component_page_kind = 0x0100,
        .catalog_epoch = 0,
        .generation = 0,
    };
}

fn expected(value: boot.State) boot.Expected {
    return .{
        .image_id = value.image_id,
        .page_size = value.page_size,
        .page_id_bits = value.page_id_bits,
    };
}

test "fullaz-db file boot: round-trips state and validates identity" {
    var initial = state();
    initial.id_radix_free_leaf_root = 7;
    var page = [_]u8{0} ** 512;
    var scratch = [_]u8{undefined} ** 512;
    try boot.format(&page, &scratch, initial, &.{});

    const view = try boot.read(&page, expected(initial));
    try std.testing.expectEqual(initial.page_count, view.state.page_count);
    try std.testing.expectEqual(initial.next_component_id, view.state.next_component_id);
    try std.testing.expectEqual(initial.next_component_page_kind, view.state.next_component_page_kind);
    try std.testing.expectEqual(initial.id_radix_free_leaf_root, view.state.id_radix_free_leaf_root);
    try std.testing.expect(view.state.clean);

    var wrong = expected(initial);
    wrong.image_id[0] ^= 1;
    try std.testing.expectError(error.IdentityMismatch, boot.read(&page, wrong));
}

test "fullaz-db file boot: preserves unknown payload fields during rewrite" {
    const initial = state();
    var old_page = [_]u8{0} ** 512;
    var old_scratch = [_]u8{undefined} ** 512;
    try boot.format(&old_page, &old_scratch, initial, &.{});
    const old_view = try boot.read(&old_page, expected(initial));

    var previous_payload = [_]u8{undefined} ** 512;
    @memcpy(previous_payload[0..old_view.payload.len], old_view.payload);
    var previous_writer = tagged.Writer.init(&previous_payload);
    previous_writer.len = old_view.payload.len;
    try previous_writer.append(99, 0x8000, "future");

    var new_page = [_]u8{0} ** 512;
    var new_scratch = [_]u8{undefined} ** 512;
    var updated = initial;
    updated.catalog_epoch = 1;
    try boot.format(&new_page, &new_scratch, updated, previous_writer.used());

    const new_view = try boot.read(&new_page, expected(updated));
    try std.testing.expectEqual(@as(u64, 1), new_view.state.catalog_epoch);
    var reader = tagged.Reader.init(new_view.payload);
    var found_unknown = false;
    while (try reader.next()) |field| {
        if (field.tag == 99) {
            found_unknown = true;
            try std.testing.expectEqual(@as(u16, 0x8000), field.flags);
            try std.testing.expectEqualStrings("future", field.value);
        }
    }
    try std.testing.expect(found_unknown);
}

test "fullaz-db file boot: rejects CRC, malformed state, and page mismatch" {
    const initial = state();
    var page = [_]u8{0} ** 512;
    var scratch = [_]u8{undefined} ** 512;
    try boot.format(&page, &scratch, initial, &.{});

    page[40] ^= 1;
    try std.testing.expectError(error.BadBoot, boot.read(&page, expected(initial)));

    var invalid = initial;
    invalid.next_component_id = 0;
    try std.testing.expectError(error.BadBoot, boot.format(&page, &scratch, invalid, &.{}));

    var mismatched = initial;
    mismatched.page_size = 256;
    try std.testing.expectError(error.PageSizeMismatch, boot.format(&page, &scratch, mismatched, &.{}));

    var wrong_page_size = expected(initial);
    wrong_page_size.page_size = 4096;
    try boot.format(&page, &scratch, initial, &.{});
    try std.testing.expectError(error.PageSizeMismatch, boot.read(&page, wrong_page_size));
}
