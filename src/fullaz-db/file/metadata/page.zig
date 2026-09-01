const std = @import("std");
const PackedInt = @import("fullaz").core.packed_int.PackedInt;
const system_kinds = @import("../system_kinds.zig");

pub const Error = error{
    BadComponentMetadataPage,
    UnsupportedVersion,
    IdentityMismatch,
    BufferTooSmall,
};

pub const magic = [_]u8{
    @truncate(system_kinds.component_metadata),
    @truncate(system_kinds.component_metadata >> 8),
    'C',
    'M',
    'E',
    'T',
    'A',
    '2',
};
pub const format_version: u16 = 2;
const U16 = PackedInt(u16, .little);
const U32 = PackedInt(u32, .little);
const U64 = PackedInt(u64, .little);

const Envelope = extern struct {
    magic: [8]u8,
    version: U16,
    header_size: U16,
    component_id: U64,
    metadata_format_version: U32,
    payload_size: U32,
    crc: U32,
    reserved: U32,
};

pub const envelope_byte_size = @sizeOf(Envelope);

comptime {
    if (@alignOf(Envelope) != 1 or envelope_byte_size != 36 or
        @offsetOf(Envelope, "version") != 8 or
        @offsetOf(Envelope, "header_size") != 10 or
        @offsetOf(Envelope, "component_id") != 12 or
        @offsetOf(Envelope, "metadata_format_version") != 20 or
        @offsetOf(Envelope, "payload_size") != 24 or
        @offsetOf(Envelope, "crc") != 28 or
        @offsetOf(Envelope, "reserved") != 32)
    {
        @compileError("dynamic database component metadata page envelope layout changed");
    }
}

pub const State = struct {
    component_id: u64,
    metadata_format_version: u32,
};

pub const View = struct {
    state: State,
    payload: []const u8,
};

pub fn format(page: []u8, state: State, payload: []const u8) Error!void {
    try validateState(state);
    if (payload.len > page.len -| envelope_byte_size) {
        return error.BufferTooSmall;
    }

    @memset(page, 0);
    const envelope = envelopeMut(page) orelse return error.BadComponentMetadataPage;
    envelope.* = .{
        .magic = magic,
        .version = U16.init(format_version),
        .header_size = U16.init(envelope_byte_size),
        .component_id = U64.init(state.component_id),
        .metadata_format_version = U32.init(state.metadata_format_version),
        .payload_size = U32.init(@intCast(payload.len)),
        .crc = U32.init(0),
        .reserved = U32.init(0),
    };
    @memcpy(page[envelope_byte_size..][0..payload.len], payload);
    envelope.crc.set(crc(page));
}

pub fn read(page: []const u8, expected: State) Error!View {
    try validateState(expected);
    const view = try readAny(page);
    if (view.state.component_id != expected.component_id or
        view.state.metadata_format_version != expected.metadata_format_version)
    {
        return error.IdentityMismatch;
    }
    return view;
}

/// Reads a valid metadata page without requiring a particular metadata format.
/// Migrations use this to read an old revision before writing a new page.
pub fn readAny(page: []const u8) Error!View {
    const envelope = envelopeConst(page) orelse return error.BadComponentMetadataPage;
    if (!std.mem.eql(u8, &envelope.magic, &magic) or
        envelope.header_size.get() != envelope_byte_size or
        envelope.reserved.get() != 0)
    {
        return error.BadComponentMetadataPage;
    }
    if (envelope.version.get() != format_version) {
        return error.UnsupportedVersion;
    }
    if (crc(page) != envelope.crc.get()) {
        return error.BadComponentMetadataPage;
    }
    const state = State{
        .component_id = envelope.component_id.get(),
        .metadata_format_version = envelope.metadata_format_version.get(),
    };
    try validateState(state);
    const payload_size: usize = @intCast(envelope.payload_size.get());
    const payload_end = std.math.add(usize, envelope_byte_size, payload_size) catch {
        return error.BadComponentMetadataPage;
    };
    if (payload_end > page.len) {
        return error.BadComponentMetadataPage;
    }
    return .{
        .state = state,
        .payload = page[envelope_byte_size..payload_end],
    };
}

fn validateState(state: State) Error!void {
    if (state.component_id == 0 or state.metadata_format_version == 0) {
        return error.BadComponentMetadataPage;
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
