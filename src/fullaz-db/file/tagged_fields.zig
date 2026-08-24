const std = @import("std");

/// Fixed-width, little-endian tagged fields for the dynamic database format.
/// Unknown encoded fields can be copied without decoding their values.
pub const Error = error{
    BadTaggedFields,
    BufferTooSmall,
    DuplicateKnownField,
};

pub const header_size = 8;

pub const Field = struct {
    tag: u16,
    flags: u16,
    value: []const u8,
    encoded: []const u8,
};

pub const Reader = struct {
    const Self = @This();

    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Self {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Self) Error!?Field {
        if (self.offset == self.bytes.len) {
            return null;
        }
        if (self.bytes.len - self.offset < header_size) {
            return error.BadTaggedFields;
        }

        const encoded_begin = self.offset;
        const header = self.bytes[encoded_begin..][0..header_size];
        const tag = std.mem.readInt(u16, header[0..2], .little);
        const flags = std.mem.readInt(u16, header[2..4], .little);
        const value_size = std.mem.readInt(u32, header[4..8], .little);

        if (tag == 0) {
            return error.BadTaggedFields;
        }

        const value_begin = std.math.add(usize, encoded_begin, header_size) catch {
            return error.BadTaggedFields;
        };

        const value_size_usize: usize = @intCast(value_size);

        const value_end = std.math.add(usize, value_begin, value_size_usize) catch {
            return error.BadTaggedFields;
        };
        if (value_end > self.bytes.len) {
            return error.BadTaggedFields;
        }

        self.offset = value_end;
        return .{
            .tag = tag,
            .flags = flags,
            .value = self.bytes[value_begin..value_end],
            .encoded = self.bytes[encoded_begin..value_end],
        };
    }
};

pub const Writer = struct {
    const Self = @This();

    bytes: []u8,
    len: usize = 0,

    pub fn init(bytes: []u8) Self {
        return .{ .bytes = bytes };
    }

    pub fn used(self: *const Self) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn append(self: *Self, tag: u16, flags: u16, value: []const u8) Error!void {
        if (tag == 0 or std.math.cast(u32, value.len) == null) {
            return error.BadTaggedFields;
        }
        const required = std.math.add(usize, header_size, value.len) catch {
            return error.BufferTooSmall;
        };
        if (required > self.bytes.len - self.len) {
            return error.BufferTooSmall;
        }

        const destination = self.bytes[self.len..][0..required];
        std.mem.writeInt(u16, destination[0..2], tag, .little);
        std.mem.writeInt(u16, destination[2..4], flags, .little);
        std.mem.writeInt(u32, destination[4..8], @intCast(value.len), .little);
        @memcpy(destination[header_size..], value);
        self.len += required;
    }

    pub fn appendEncoded(self: *Self, encoded: []const u8) Error!void {
        var reader = Reader.init(encoded);

        _ = try reader.next() orelse return error.BadTaggedFields;

        if (reader.offset != encoded.len) {
            return error.BadTaggedFields;
        }

        if (encoded.len > self.bytes.len - self.len) {
            return error.BufferTooSmall;
        }

        @memcpy(self.bytes[self.len..][0..encoded.len], encoded);
        self.len += encoded.len;
    }
};

pub fn containsKnownTag(known_tags: []const u16, tag: u16) bool {
    for (known_tags) |known_tag| {
        if (known_tag == tag) {
            return true;
        }
    }
    return false;
}

/// Verifies that known tags are unique and detects duplicate known fields.
pub fn validateKnownFields(bytes: []const u8, known_tags: []const u16) Error!void {
    for (known_tags, 0..) |tag, index| {
        if (tag == 0) {
            return error.BadTaggedFields;
        }
        for (known_tags[0..index]) |previous| {
            if (tag == previous) {
                return error.BadTaggedFields;
            }
        }
    }

    var structural_reader = Reader.init(bytes);
    while (try structural_reader.next()) |_| {}

    for (known_tags) |known_tag| {
        var count: usize = 0;
        var reader = Reader.init(bytes);
        while (try reader.next()) |field| {
            if (field.tag == known_tag) {
                count += 1;
                if (count > 1) {
                    return error.DuplicateKnownField;
                }
            }
        }
    }
}

/// Validates a field stream with distinct singular and repeated owned tags.
pub fn validateFields(
    bytes: []const u8,
    singular_tags: []const u16,
    repeated_tags: []const u16,
) Error!void {
    for (repeated_tags) |repeated_tag| {
        if (containsKnownTag(singular_tags, repeated_tag)) {
            return error.BadTaggedFields;
        }
    }
    try validateKnownFields(bytes, singular_tags);
    for (repeated_tags, 0..) |tag, index| {
        if (tag == 0) return error.BadTaggedFields;
        for (repeated_tags[0..index]) |previous| {
            if (tag == previous) return error.BadTaggedFields;
        }
    }
}

/// Validates a field stream whose owned tags include both singular and repeated
/// fields. Repeated tags may occur any number of times; singular tags may not.
pub fn validateOwnedFields(
    bytes: []const u8,
    known_tags: []const u16,
    repeated_tags: []const u16,
) Error!void {
    for (known_tags, 0..) |tag, index| {
        if (tag == 0) {
            return error.BadTaggedFields;
        }
        for (known_tags[0..index]) |previous| {
            if (tag == previous) {
                return error.BadTaggedFields;
            }
        }
    }
    for (repeated_tags, 0..) |tag, index| {
        if (!containsKnownTag(known_tags, tag)) {
            return error.BadTaggedFields;
        }
        for (repeated_tags[0..index]) |previous| {
            if (tag == previous) {
                return error.BadTaggedFields;
            }
        }
    }

    var reader = Reader.init(bytes);
    while (try reader.next()) |field| {
        if (!containsKnownTag(known_tags, field.tag) or
            containsKnownTag(repeated_tags, field.tag))
        {
            continue;
        }
        var prior = Reader.init(bytes[0 .. reader.offset - field.encoded.len]);
        while (try prior.next()) |previous| {
            if (previous.tag == field.tag) {
                return error.DuplicateKnownField;
            }
        }
    }
}

/// Copies each structurally valid field whose tag is not owned by the caller.
/// The complete encoded field, including flags, is preserved byte-for-byte.
pub fn copyUnknownFields(
    writer: *Writer,
    previous: []const u8,
    known_tags: []const u16,
) Error!void {
    try validateKnownFields(previous, known_tags);

    var reader = Reader.init(previous);
    while (try reader.next()) |field| {
        if (!containsKnownTag(known_tags, field.tag)) {
            try writer.appendEncoded(field.encoded);
        }
    }
}

/// Copies unknown fields after the caller validates its own repeated-field
/// policy. `known_tags` includes both singular and repeated owned tags.
pub fn copyUnknownFieldsAfterValidation(
    writer: *Writer,
    previous: []const u8,
    known_tags: []const u16,
) Error!void {
    var reader = Reader.init(previous);
    while (try reader.next()) |field| {
        if (!containsKnownTag(known_tags, field.tag)) {
            try writer.appendEncoded(field.encoded);
        }
    }
}
