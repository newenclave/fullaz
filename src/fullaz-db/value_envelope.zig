const std = @import("std");
const PackedInt = @import("fullaz").core.packed_int.PackedInt;

/// A fixed-capacity inline value envelope. All integer fields are little-endian.
pub const Error = error{
    BufferTooSmall,
    PayloadTooLarge,
    BadMagic,
    UnsupportedFormatVersion,
    UnknownKind,
    IncorrectKind,
    IncorrectType,
    NonZeroReserved,
    BadCapacity,
    BadEncodedSize,
    BadPayloadLength,
    BadCrc,
    NonZeroPadding,
    RevisionOverflow,
    EditorInvalidated,
};

pub const magic = "FZVE";
pub const format_version: u16 = 1;

pub const Kind = enum(u8) {
    raw = 1,
    embedded = 2,
};

pub const TypeIdentity = struct {
    registry_id: u64,
    type_id: u64,
    type_version: u32,
    metadata_format_version: u32,
};

pub const Metadata = struct {
    registry_id: u64,
    type_id: u64,
    type_version: u32,
    metadata_format_version: u32,
    instance_id: u64,
    revision: u64,
};

pub const Value = struct {
    kind: Kind,
    metadata: Metadata,
    payload: []const u8,
    encoded_size: u32,
    capacity: u32,
};

/// A mutable, caller-owned view of a validated embedded envelope.
///
/// `payloadMut()` and `advanceRevision()` mark the editor dirty before
/// changing its bytes. Call `finish()` to update the CRC; it invalidates this
/// editor. `invalidate()` also invalidates the editor without updating the
/// CRC, while retaining the dirty state for the caller to inspect.
pub const EmbeddedEditor = struct {
    const Self = @This();

    bytes: []u8,
    metadata_: Metadata,
    payload_: []u8,
    dirty: bool = false,
    open: bool = true,

    pub fn metadata(self: *const Self) Error!Metadata {
        try self.ensureOpen();
        return self.metadata_;
    }

    pub fn payloadMut(self: *Self) Error![]u8 {
        try self.ensureOpen();
        self.dirty = true;
        return self.payload_;
    }

    pub fn advanceRevision(self: *Self) Error!void {
        try self.ensureOpen();
        const revision = std.math.add(u64, self.metadata_.revision, 1) catch {
            return error.RevisionOverflow;
        };

        self.dirty = true;
        self.metadata_.revision = revision;
        envelopeMut(self.bytes).?.revision.set(revision);
    }

    pub fn isDirty(self: *const Self) bool {
        return self.dirty;
    }

    pub fn finish(self: *Self) Error!void {
        try self.ensureOpen();
        envelopeMut(self.bytes).?.crc.set(crc(self.bytes));
        self.dirty = false;
        self.invalidate();
    }

    pub fn invalidate(self: *Self) void {
        self.bytes = &.{};
        self.payload_ = &.{};
        self.open = false;
    }

    fn ensureOpen(self: *const Self) Error!void {
        if (!self.open) {
            return error.EditorInvalidated;
        }
    }
};

const U16 = PackedInt(u16, .little);
const U32 = PackedInt(u32, .little);
const U64 = PackedInt(u64, .little);

const Envelope = extern struct {
    magic: [4]u8,
    version: U16,
    kind: u8,
    reserved: [1]u8,
    registry_id: U64,
    type_id: U64,
    type_version: U32,
    metadata_format_version: U32,
    instance_id: U64,
    revision: U64,
    payload_length: U32,
    encoded_size: U32,
    capacity: U32,
    crc: U32,
};

pub const envelope_byte_size = @sizeOf(Envelope);

comptime {
    if (@alignOf(Envelope) != 1 or envelope_byte_size != 64 or
        @offsetOf(Envelope, "version") != 4 or
        @offsetOf(Envelope, "kind") != 6 or
        @offsetOf(Envelope, "reserved") != 7 or
        @offsetOf(Envelope, "registry_id") != 8 or
        @offsetOf(Envelope, "type_id") != 16 or
        @offsetOf(Envelope, "type_version") != 24 or
        @offsetOf(Envelope, "metadata_format_version") != 28 or
        @offsetOf(Envelope, "instance_id") != 32 or
        @offsetOf(Envelope, "revision") != 40 or
        @offsetOf(Envelope, "payload_length") != 48 or
        @offsetOf(Envelope, "encoded_size") != 52 or
        @offsetOf(Envelope, "capacity") != 56 or
        @offsetOf(Envelope, "crc") != 60)
    {
        @compileError("inline value envelope layout changed");
    }
}

pub fn formatRaw(bytes: []u8, metadata: Metadata, payload: []const u8) Error!void {
    try format(bytes, .raw, metadata, payload);
}

pub fn formatEmbedded(bytes: []u8, metadata: Metadata, payload: []const u8) Error!void {
    try format(bytes, .embedded, metadata, payload);
}

pub fn readRaw(bytes: []const u8, expected_type: TypeIdentity) Error!Value {
    return read(bytes, .raw, expected_type);
}

pub fn readEmbedded(bytes: []const u8, expected_type: TypeIdentity) Error!Value {
    return read(bytes, .embedded, expected_type);
}

/// Validates an envelope without imposing a caller-selected kind or type.
/// GC uses this to discover the nominal type of embedded roots.
pub fn readAny(bytes: []const u8) Error!Value {
    return readImpl(bytes, null, null);
}

/// Validates and opens an existing embedded envelope in caller-owned bytes.
/// The byte slice must remain valid until the editor is finished or invalidated.
pub fn openEmbeddedMut(bytes: []u8, expected_type: TypeIdentity) Error!EmbeddedEditor {
    const value = try read(bytes, .embedded, expected_type);
    const encoded_size: usize = @intCast(value.encoded_size);
    return .{
        .bytes = bytes,
        .metadata_ = value.metadata,
        .payload_ = bytes[envelope_byte_size..encoded_size],
    };
}

fn format(bytes: []u8, kind: Kind, metadata: Metadata, payload: []const u8) Error!void {
    if (bytes.len < envelope_byte_size) {
        return error.BufferTooSmall;
    }
    const capacity = std.math.cast(u32, bytes.len) orelse return error.PayloadTooLarge;
    const payload_length = std.math.cast(u32, payload.len) orelse return error.PayloadTooLarge;
    const encoded_size = std.math.add(u32, envelope_byte_size, payload_length) catch {
        return error.PayloadTooLarge;
    };
    if (encoded_size > capacity) {
        return error.BufferTooSmall;
    }

    @memset(bytes, 0);
    const envelope = envelopeMut(bytes).?;
    envelope.* = .{
        .magic = magic.*,
        .version = U16.init(format_version),
        .kind = @intFromEnum(kind),
        .reserved = .{0},
        .registry_id = U64.init(metadata.registry_id),
        .type_id = U64.init(metadata.type_id),
        .type_version = U32.init(metadata.type_version),
        .metadata_format_version = U32.init(metadata.metadata_format_version),
        .instance_id = U64.init(metadata.instance_id),
        .revision = U64.init(metadata.revision),
        .payload_length = U32.init(payload_length),
        .encoded_size = U32.init(encoded_size),
        .capacity = U32.init(capacity),
        .crc = U32.init(0),
    };
    @memcpy(bytes[envelope_byte_size..][0..payload.len], payload);
    envelope.crc.set(crc(bytes));
}

fn read(bytes: []const u8, expected_kind: Kind, expected_type: TypeIdentity) Error!Value {
    return readImpl(bytes, expected_kind, expected_type);
}

fn readImpl(
    bytes: []const u8,
    expected_kind: ?Kind,
    expected_type: ?TypeIdentity,
) Error!Value {
    const envelope = envelopeConst(bytes) orelse return error.BufferTooSmall;
    if (!std.mem.eql(u8, &envelope.magic, magic)) {
        return error.BadMagic;
    }
    if (envelope.version.get() != format_version) {
        return error.UnsupportedFormatVersion;
    }
    if (envelope.reserved[0] != 0) {
        return error.NonZeroReserved;
    }

    const kind = switch (envelope.kind) {
        @intFromEnum(Kind.raw) => Kind.raw,
        @intFromEnum(Kind.embedded) => Kind.embedded,
        else => return error.UnknownKind,
    };
    if (expected_kind) |kind_expected| {
        if (kind != kind_expected) {
            return error.IncorrectKind;
        }
    }

    const capacity: usize = @intCast(envelope.capacity.get());
    if (capacity != bytes.len) {
        return error.BadCapacity;
    }
    const encoded_size: usize = @intCast(envelope.encoded_size.get());
    if (encoded_size < envelope_byte_size or encoded_size > capacity) {
        return error.BadEncodedSize;
    }
    const payload_length: usize = @intCast(envelope.payload_length.get());
    if (payload_length != encoded_size - envelope_byte_size) {
        return error.BadPayloadLength;
    }
    if (envelope.crc.get() != crc(bytes)) {
        return error.BadCrc;
    }
    for (bytes[encoded_size..]) |byte| {
        if (byte != 0) {
            return error.NonZeroPadding;
        }
    }

    const metadata = Metadata{
        .registry_id = envelope.registry_id.get(),
        .type_id = envelope.type_id.get(),
        .type_version = envelope.type_version.get(),
        .metadata_format_version = envelope.metadata_format_version.get(),
        .instance_id = envelope.instance_id.get(),
        .revision = envelope.revision.get(),
    };
    if (expected_type) |type_expected| {
        if (metadata.registry_id != type_expected.registry_id or
            metadata.type_id != type_expected.type_id or
            metadata.type_version != type_expected.type_version or
            metadata.metadata_format_version != type_expected.metadata_format_version)
        {
            return error.IncorrectType;
        }
    }

    return .{
        .kind = kind,
        .metadata = metadata,
        .payload = bytes[envelope_byte_size..encoded_size],
        .encoded_size = @intCast(encoded_size),
        .capacity = @intCast(capacity),
    };
}

fn crc(bytes: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    const crc_begin = @offsetOf(Envelope, "crc");
    hasher.update(bytes[0..crc_begin]);
    hasher.update(bytes[crc_begin + @sizeOf(U32) ..]);
    return hasher.final();
}

fn envelopeConst(bytes: []const u8) ?*const Envelope {
    if (bytes.len < envelope_byte_size) {
        return null;
    }
    return @ptrCast(bytes.ptr);
}

fn envelopeMut(bytes: []u8) ?*Envelope {
    if (bytes.len < envelope_byte_size) {
        return null;
    }
    return @ptrCast(bytes.ptr);
}
