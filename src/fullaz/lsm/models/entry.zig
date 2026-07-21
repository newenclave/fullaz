// Borrowed key/value/lsn view, decoded from the encoded:
//  [tag][lsn][payload] blob (value.zig).

pub fn Entry(comptime LsnT: type) type {
    return struct {
        key: []const u8,
        value: []const u8,
        lsn: LsnT,
    };
}
