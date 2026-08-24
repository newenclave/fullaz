const std = @import("std");
const PackedInt = @import("fullaz").core.packed_int.PackedInt;
const tagged = @import("tagged_fields.zig");
const system_kinds = @import("system_kinds.zig");

pub const Error = tagged.Error || error{
    BadBoot,
    UnsupportedVersion,
    IdentityMismatch,
    PageSizeMismatch,
    PageIdWidthMismatch,
};

pub const magic = "FULLAZFD";
pub const format_version: u16 = 1;
const U16 = PackedInt(u16, .little);
const U32 = PackedInt(u32, .little);

const Envelope = extern struct {
    magic: [8]u8,
    version: U16,
    header_size: U16,
    payload_size: U32,
    crc: U32,
    reserved: U32,
};

pub const envelope_byte_size = @sizeOf(Envelope);

comptime {
    if (@alignOf(Envelope) != 1 or envelope_byte_size != 24 or
        @offsetOf(Envelope, "version") != 8 or
        @offsetOf(Envelope, "header_size") != 10 or
        @offsetOf(Envelope, "payload_size") != 12 or
        @offsetOf(Envelope, "crc") != 16 or
        @offsetOf(Envelope, "reserved") != 20)
    {
        @compileError("dynamic database boot envelope layout changed");
    }
}

pub const Tag = struct {
    pub const image_id: u16 = 1;
    pub const page_size: u16 = 2;
    pub const page_id_bits: u16 = 3;
    pub const clean: u16 = 4;
    pub const feature_flags: u16 = 5;
    pub const page_count: u16 = 6;
    pub const free_root: u16 = 7;
    pub const catalog_first: u16 = 8;
    pub const catalog_last: u16 = 9;
    pub const catalog_record_count: u16 = 10;
    pub const live_component_count: u16 = 11;
    pub const id_radix_root: u16 = 12;
    pub const name_bpt_root: u16 = 13;
    pub const next_component_id: u16 = 14;
    pub const next_component_page_kind: u16 = 15;
    pub const catalog_epoch: u16 = 16;
    pub const generation: u16 = 17;
};

const known_tags = [_]u16{
    Tag.image_id,
    Tag.page_size,
    Tag.page_id_bits,
    Tag.clean,
    Tag.feature_flags,
    Tag.page_count,
    Tag.free_root,
    Tag.catalog_first,
    Tag.catalog_last,
    Tag.catalog_record_count,
    Tag.live_component_count,
    Tag.id_radix_root,
    Tag.name_bpt_root,
    Tag.next_component_id,
    Tag.next_component_page_kind,
    Tag.catalog_epoch,
    Tag.generation,
};

pub const State = struct {
    image_id: [16]u8,
    page_size: u32,
    page_id_bits: u16,
    clean: bool,
    feature_flags: u64,
    page_count: u64,
    free_root: ?u64,
    catalog_first: ?u64,
    catalog_last: ?u64,
    catalog_record_count: u64,
    live_component_count: u64,
    id_radix_root: ?u64,
    name_bpt_root: ?u64,
    next_component_id: u64,
    next_component_page_kind: u16,
    catalog_epoch: u64,
    generation: u64,
};

pub const Expected = struct {
    image_id: [16]u8,
    page_size: u32,
    page_id_bits: u16,
};

pub const View = struct {
    state: State,
    payload: []const u8,
};

pub fn format(
    page: []u8,
    payload_scratch: []u8,
    state: State,
    previous_payload: []const u8,
) Error!void {
    try validateState(state);
    if (std.math.cast(u32, page.len) != state.page_size) {
        return error.PageSizeMismatch;
    }

    var writer = tagged.Writer.init(payload_scratch);
    try tagged.copyUnknownFields(&writer, previous_payload, &known_tags);
    try appendState(&writer, state);

    if (writer.used().len > page.len -| envelope_byte_size) {
        return error.BufferTooSmall;
    }
    @memset(page, 0);
    const envelope = envelopeMut(page) orelse return error.BadBoot;
    envelope.* = .{
        .magic = magic.*,
        .version = U16.init(format_version),
        .header_size = U16.init(envelope_byte_size),
        .payload_size = U32.init(@intCast(writer.used().len)),
        .crc = U32.init(0),
        .reserved = U32.init(0),
    };
    @memcpy(page[envelope_byte_size..][0..writer.used().len], writer.used());
    envelope.crc.set(crc(page));
}

pub fn read(page: []const u8, expected: Expected) Error!View {
    const envelope = envelopeConst(page) orelse return error.BadBoot;
    if (!std.mem.eql(u8, &envelope.magic, magic) or
        envelope.header_size.get() != envelope_byte_size or
        envelope.reserved.get() != 0)
    {
        return error.BadBoot;
    }
    if (envelope.version.get() != format_version) {
        return error.UnsupportedVersion;
    }
    if (crc(page) != envelope.crc.get()) {
        return error.BadBoot;
    }

    const payload_size: usize = @intCast(envelope.payload_size.get());
    const payload_end = std.math.add(usize, envelope_byte_size, payload_size) catch {
        return error.BadBoot;
    };
    if (payload_end > page.len) {
        return error.BadBoot;
    }
    const payload = page[envelope_byte_size..payload_end];
    try tagged.validateKnownFields(payload, &known_tags);
    const state = try decodeState(payload);

    if (!std.mem.eql(u8, &state.image_id, &expected.image_id)) {
        return error.IdentityMismatch;
    }
    if (state.page_size != expected.page_size) {
        return error.PageSizeMismatch;
    }
    if (state.page_id_bits != expected.page_id_bits) {
        return error.PageIdWidthMismatch;
    }
    if (state.page_size != page.len) {
        return error.PageSizeMismatch;
    }
    return .{ .state = state, .payload = payload };
}

fn appendState(writer: *tagged.Writer, state: State) Error!void {
    try writer.append(Tag.image_id, 0, &state.image_id);
    try appendInt(writer, Tag.page_size, u32, state.page_size);
    try appendInt(writer, Tag.page_id_bits, u16, state.page_id_bits);
    try appendInt(writer, Tag.clean, u8, @intFromBool(state.clean));
    try appendInt(writer, Tag.feature_flags, u64, state.feature_flags);
    try appendInt(writer, Tag.page_count, u64, state.page_count);
    try appendInt(writer, Tag.free_root, u64, state.free_root orelse 0);
    try appendInt(writer, Tag.catalog_first, u64, state.catalog_first orelse 0);
    try appendInt(writer, Tag.catalog_last, u64, state.catalog_last orelse 0);
    try appendInt(writer, Tag.catalog_record_count, u64, state.catalog_record_count);
    try appendInt(writer, Tag.live_component_count, u64, state.live_component_count);
    try appendInt(writer, Tag.id_radix_root, u64, state.id_radix_root orelse 0);
    try appendInt(writer, Tag.name_bpt_root, u64, state.name_bpt_root orelse 0);
    try appendInt(writer, Tag.next_component_id, u64, state.next_component_id);
    try appendInt(writer, Tag.next_component_page_kind, u16, state.next_component_page_kind);
    try appendInt(writer, Tag.catalog_epoch, u64, state.catalog_epoch);
    try appendInt(writer, Tag.generation, u64, state.generation);
}

fn appendInt(writer: *tagged.Writer, tag: u16, comptime T: type, value: T) Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.append(tag, 0, &bytes);
}

fn decodeState(payload: []const u8) Error!State {
    var state: State = undefined;
    var found = [_]bool{false} ** known_tags.len;

    var reader = tagged.Reader.init(payload);
    while (try reader.next()) |field| {
        if (field.flags != 0) {
            if (tagged.containsKnownTag(&known_tags, field.tag)) {
                return error.BadBoot;
            }
            continue;
        }
        switch (field.tag) {
            Tag.image_id => {
                found[0] = true;
                if (field.value.len != state.image_id.len) {
                    return error.BadBoot;
                }
                @memcpy(&state.image_id, field.value);
            },
            Tag.page_size => {
                found[1] = true;
                state.page_size = try readInt(field.value, u32);
            },
            Tag.page_id_bits => {
                found[2] = true;
                state.page_id_bits = try readInt(field.value, u16);
            },
            Tag.clean => {
                found[3] = true;
                const clean = try readInt(field.value, u8);
                if (clean > 1) {
                    return error.BadBoot;
                }
                state.clean = clean == 1;
            },
            Tag.feature_flags => {
                found[4] = true;
                state.feature_flags = try readInt(field.value, u64);
            },
            Tag.page_count => {
                found[5] = true;
                state.page_count = try readInt(field.value, u64);
            },
            Tag.free_root => {
                found[6] = true;
                state.free_root = decodeOptionalPid(try readInt(field.value, u64));
            },
            Tag.catalog_first => {
                found[7] = true;
                state.catalog_first = decodeOptionalPid(try readInt(field.value, u64));
            },
            Tag.catalog_last => {
                found[8] = true;
                state.catalog_last = decodeOptionalPid(try readInt(field.value, u64));
            },
            Tag.catalog_record_count => {
                found[9] = true;
                state.catalog_record_count = try readInt(field.value, u64);
            },
            Tag.live_component_count => {
                found[10] = true;
                state.live_component_count = try readInt(field.value, u64);
            },
            Tag.id_radix_root => {
                found[11] = true;
                state.id_radix_root = decodeOptionalPid(try readInt(field.value, u64));
            },
            Tag.name_bpt_root => {
                found[12] = true;
                state.name_bpt_root = decodeOptionalPid(try readInt(field.value, u64));
            },
            Tag.next_component_id => {
                found[13] = true;
                state.next_component_id = try readInt(field.value, u64);
            },
            Tag.next_component_page_kind => {
                found[14] = true;
                state.next_component_page_kind = try readInt(field.value, u16);
            },
            Tag.catalog_epoch => {
                found[15] = true;
                state.catalog_epoch = try readInt(field.value, u64);
            },
            Tag.generation => {
                found[16] = true;
                state.generation = try readInt(field.value, u64);
            },
            else => {},
        }
    }
    for (found) |value| {
        if (!value) {
            return error.BadBoot;
        }
    }
    try validateState(state);
    return state;
}

fn readInt(bytes: []const u8, comptime T: type) Error!T {
    if (bytes.len != @sizeOf(T)) {
        return error.BadBoot;
    }
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn decodeOptionalPid(value: u64) ?u64 {
    return if (value == 0) null else value;
}

fn validateState(state: State) Error!void {
    if (std.mem.allEqual(u8, &state.image_id, 0) or
        state.page_size < envelope_byte_size or
        state.page_id_bits == 0 or state.page_id_bits % 8 != 0 or
        state.page_count == 0 or
        state.live_component_count > state.catalog_record_count or
        state.next_component_id == 0 or
        state.next_component_page_kind < system_kinds.first_component or
        state.next_component_page_kind == system_kinds.invalid_sentinel)
    {
        return error.BadBoot;
    }
}

fn crc(page: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    const crc_begin = @offsetOf(Envelope, "crc");
    hasher.update(page[0..crc_begin]);
    hasher.update(page[crc_begin + @sizeOf(U32) ..]);
    return hasher.final();
}

fn envelopeConst(page: []const u8) ?*const Envelope {
    if (page.len < envelope_byte_size) {
        return null;
    }
    return @ptrCast(page.ptr);
}

fn envelopeMut(page: []u8) ?*Envelope {
    if (page.len < envelope_byte_size) {
        return null;
    }
    return @ptrCast(page.ptr);
}
