const std = @import("std");
const PackedInt = @import("fullaz").core.packed_int.PackedInt;
const tagged = @import("../tagged_fields.zig");
const system_kinds = @import("../system_kinds.zig");

pub const Error = tagged.Error || error{
    BadCatalogRecord,
    UnsupportedVersion,
};

pub const legacy_format_version: u16 = 1;
pub const format_version: u16 = 2;
const U16 = PackedInt(u16, .little);
const U32 = PackedInt(u32, .little);

const Envelope = extern struct {
    version: U16,
    flags: U16,
    payload_size: U32,
};

pub const envelope_byte_size = @sizeOf(Envelope);

comptime {
    if (@alignOf(Envelope) != 1 or envelope_byte_size != 8 or
        @offsetOf(Envelope, "flags") != 2 or
        @offsetOf(Envelope, "payload_size") != 4)
    {
        @compileError("dynamic database catalog record envelope layout changed");
    }
}

pub const Tag = struct {
    pub const component_id: u16 = 1;
    pub const revision: u16 = 2;
    pub const name: u16 = 3;
    pub const kind_name: u16 = 4;
    pub const component_format_version: u16 = 5;
    pub const metadata_format_version: u16 = 6;
    pub const page_kind_base: u16 = 7;
    pub const page_kind_count: u16 = 8;
    pub const metadata_root_pid: u16 = 9;
    pub const settings_fingerprint: u16 = 10;
    pub const dependency_id: u16 = 11;
    pub const lifecycle_state: u16 = 12;
};

const singular_tags = [_]u16{
    Tag.component_id,
    Tag.revision,
    Tag.name,
    Tag.kind_name,
    Tag.component_format_version,
    Tag.metadata_format_version,
    Tag.page_kind_base,
    Tag.page_kind_count,
    Tag.metadata_root_pid,
    Tag.settings_fingerprint,
    Tag.lifecycle_state,
};
const all_known_tags = singular_tags ++ [_]u16{Tag.dependency_id};

pub const LifecycleState = enum(u8) {
    active = 1,
    dropped = 2,
};

pub const Record = struct {
    component_id: u64,
    revision: u32,
    name: []const u8,
    kind_name: []const u8,
    component_format_version: u32,
    metadata_format_version: u32,
    page_kind_base: u16,
    page_kind_count: u16,
    metadata_root_pid: u64,
    settings_fingerprint: [32]u8,
    dependency_ids: []const u64,
    state: LifecycleState = .active,
};

pub const View = struct {
    component_id: u64,
    revision: u32,
    name: []const u8,
    kind_name: []const u8,
    component_format_version: u32,
    metadata_format_version: u32,
    page_kind_base: u16,
    page_kind_count: u16,
    metadata_root_pid: u64,
    settings_fingerprint: [32]u8,
    payload: []const u8,
    dependency_count: usize,
    state: LifecycleState,

    pub fn getDependency(self: *const View, index: usize) Error!?u64 {
        if (index >= self.dependency_count) {
            return null;
        }
        var found: usize = 0;
        var reader = tagged.Reader.init(self.payload);
        while (try reader.next()) |field| {
            if (field.tag != Tag.dependency_id) {
                continue;
            }
            if (found == index) {
                return try readInt(field.value, u64);
            }
            found += 1;
        }
        return error.BadCatalogRecord;
    }
};

pub fn format(
    bytes: []u8,
    payload_scratch: []u8,
    record: Record,
    previous_payload: []const u8,
) Error!void {
    try validate(record);
    try tagged.validateKnownFields(previous_payload, &singular_tags);

    var writer = tagged.Writer.init(payload_scratch);
    try tagged.copyUnknownFieldsAfterValidation(&writer, previous_payload, &all_known_tags);
    try appendRecord(&writer, record);
    if (writer.used().len > bytes.len -| envelope_byte_size) {
        return error.BufferTooSmall;
    }

    @memset(bytes, 0);
    const envelope = envelopeMut(bytes) orelse return error.BadCatalogRecord;
    envelope.* = .{
        .version = U16.init(format_version),
        .flags = U16.init(0),
        .payload_size = U32.init(@intCast(writer.used().len)),
    };
    @memcpy(bytes[envelope_byte_size..][0..writer.used().len], writer.used());
}

pub fn read(bytes: []const u8) Error!View {
    const envelope = envelopeConst(bytes) orelse return error.BadCatalogRecord;
    const version = envelope.version.get();
    if (version != legacy_format_version and version != format_version) {
        return error.UnsupportedVersion;
    }
    if (envelope.flags.get() != 0) {
        return error.BadCatalogRecord;
    }
    if (try encodedByteSize(bytes) != bytes.len) {
        return error.BadCatalogRecord;
    }
    const payload_end = bytes.len;

    const payload = bytes[envelope_byte_size..payload_end];
    try tagged.validateKnownFields(payload, &singular_tags);
    return try decode(payload, version);
}

pub fn encodedByteSize(bytes: []const u8) Error!usize {
    const envelope = envelopeConst(bytes) orelse return error.BadCatalogRecord;
    const payload_size: usize = @intCast(envelope.payload_size.get());
    return std.math.add(usize, envelope_byte_size, payload_size) catch error.BadCatalogRecord;
}

fn appendRecord(writer: *tagged.Writer, record: Record) Error!void {
    try appendInt(writer, Tag.component_id, u64, record.component_id);
    try appendInt(writer, Tag.revision, u32, record.revision);
    try writer.append(Tag.name, 0, record.name);
    try writer.append(Tag.kind_name, 0, record.kind_name);
    try appendInt(writer, Tag.component_format_version, u32, record.component_format_version);
    try appendInt(writer, Tag.metadata_format_version, u32, record.metadata_format_version);
    try appendInt(writer, Tag.page_kind_base, u16, record.page_kind_base);
    try appendInt(writer, Tag.page_kind_count, u16, record.page_kind_count);
    try appendInt(writer, Tag.metadata_root_pid, u64, record.metadata_root_pid);
    try writer.append(Tag.settings_fingerprint, 0, &record.settings_fingerprint);
    try appendInt(writer, Tag.lifecycle_state, u8, @intFromEnum(record.state));
    for (record.dependency_ids) |dependency_id| {
        try appendInt(writer, Tag.dependency_id, u64, dependency_id);
    }
}

fn appendInt(writer: *tagged.Writer, tag: u16, comptime T: type, value: T) Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.append(tag, 0, &bytes);
}

fn decode(payload: []const u8, version: u16) Error!View {
    var result: View = undefined;
    var dependency_count: usize = 0;
    var found = [_]bool{false} ** singular_tags.len;
    result.state = .active;

    var reader = tagged.Reader.init(payload);
    while (try reader.next()) |field| {
        if (field.flags != 0 and tagged.containsKnownTag(&all_known_tags, field.tag)) {
            return error.BadCatalogRecord;
        }
        switch (field.tag) {
            Tag.component_id => {
                found[0] = true;
                result.component_id = try readInt(field.value, u64);
            },
            Tag.revision => {
                found[1] = true;
                result.revision = try readInt(field.value, u32);
            },
            Tag.name => {
                found[2] = true;
                result.name = field.value;
            },
            Tag.kind_name => {
                found[3] = true;
                result.kind_name = field.value;
            },
            Tag.component_format_version => {
                found[4] = true;
                result.component_format_version = try readInt(field.value, u32);
            },
            Tag.metadata_format_version => {
                found[5] = true;
                result.metadata_format_version = try readInt(field.value, u32);
            },
            Tag.page_kind_base => {
                found[6] = true;
                result.page_kind_base = try readInt(field.value, u16);
            },
            Tag.page_kind_count => {
                found[7] = true;
                result.page_kind_count = try readInt(field.value, u16);
            },
            Tag.metadata_root_pid => {
                found[8] = true;
                result.metadata_root_pid = try readInt(field.value, u64);
            },
            Tag.settings_fingerprint => {
                found[9] = true;
                if (field.value.len != result.settings_fingerprint.len) {
                    return error.BadCatalogRecord;
                }
                @memcpy(&result.settings_fingerprint, field.value);
            },
            Tag.lifecycle_state => {
                found[10] = true;
                if (version != format_version) {
                    return error.BadCatalogRecord;
                }
                result.state = switch (try readInt(field.value, u8)) {
                    @intFromEnum(LifecycleState.active) => .active,
                    @intFromEnum(LifecycleState.dropped) => .dropped,
                    else => return error.BadCatalogRecord,
                };
            },
            Tag.dependency_id => dependency_count += 1,
            else => {},
        }
    }
    for (found, 0..) |value, index| {
        if (index == 10 and version == legacy_format_version) {
            if (value) {
                return error.BadCatalogRecord;
            }
            continue;
        }
        if (!value) {
            return error.BadCatalogRecord;
        }
    }

    result.payload = payload;
    result.dependency_count = dependency_count;
    try validateView(result);
    return result;
}

fn readInt(bytes: []const u8, comptime T: type) Error!T {
    if (bytes.len != @sizeOf(T)) {
        return error.BadCatalogRecord;
    }
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn validate(record: Record) Error!void {
    try validateCore(
        record.component_id,
        record.revision,
        record.name,
        record.kind_name,
        record.component_format_version,
        record.metadata_format_version,
        record.page_kind_base,
        record.page_kind_count,
        record.metadata_root_pid,
    );
    for (record.dependency_ids) |dependency_id| {
        if (dependency_id == 0 or dependency_id == record.component_id) {
            return error.BadCatalogRecord;
        }
    }
    _ = record.state;
}

fn validateView(view: View) Error!void {
    try validateCore(
        view.component_id,
        view.revision,
        view.name,
        view.kind_name,
        view.component_format_version,
        view.metadata_format_version,
        view.page_kind_base,
        view.page_kind_count,
        view.metadata_root_pid,
    );
    for (0..view.dependency_count) |index| {
        const dependency_id = (try view.getDependency(index)).?;
        if (dependency_id == 0 or dependency_id == view.component_id) {
            return error.BadCatalogRecord;
        }
    }
    _ = view.state;
}

fn validateCore(
    component_id: u64,
    revision: u32,
    name: []const u8,
    kind_name: []const u8,
    component_format_version: u32,
    metadata_format_version: u32,
    page_kind_base: u16,
    page_kind_count: u16,
    metadata_root_pid: u64,
) Error!void {
    const range_end = std.math.add(u32, page_kind_base, page_kind_count) catch {
        return error.BadCatalogRecord;
    };
    if (component_id == 0 or revision == 0 or
        component_format_version == 0 or metadata_format_version == 0 or
        metadata_root_pid == 0 or
        name.len == 0 or name.len > 255 or
        kind_name.len == 0 or
        !std.unicode.utf8ValidateSlice(name) or
        !std.unicode.utf8ValidateSlice(kind_name) or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.indexOfScalar(u8, kind_name, 0) != null or
        page_kind_count == 0 or
        page_kind_base < system_kinds.first_component or
        range_end > system_kinds.invalid_sentinel)
    {
        return error.BadCatalogRecord;
    }
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
