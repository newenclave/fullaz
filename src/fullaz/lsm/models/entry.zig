// Borrowed key/value pair. value is the encoded [tag][payload] blob (value.zig),

pub fn EntryImpl(comptime mut: bool) type {
    return struct {
        key: if (mut) []u8 else []const u8,
        value: if (mut) []u8 else []const u8,
    };
}

pub const Entry = EntryImpl(false);
pub const EntryMut = EntryImpl(true);
