const std = @import("std");
const sstable = @import("fullaz").sstable;

test "SSTable format records wire types" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);

    try std.testing.expect(Format.Offset == u64);
    try std.testing.expect(Format.PageId == u32);
    try std.testing.expect(Format.DataIndex == u32);
    try std.testing.expect(Format.Endian == .little);
}

test "SSTable reader and writer contracts accept minimal interfaces" {
    const Writer = struct {
        pub const Error = error{};

        pub fn add(_: *@This(), _: []const u8, _: []const u8) Error!void {}
        pub fn finish(_: *@This()) Error!void {}
        pub fn deinit(_: *@This()) void {}
    };
    const Reader = struct {
        pub const Error = error{};
        pub const ReadScratchType = struct {};

        pub fn find(_: *@This(), _: []const u8, _: *ReadScratchType) Error!?[]const u8 {
            return null;
        }
        pub fn deinit(_: *@This()) void {}
    };

    comptime sstable.interfaces.assertWriter(Writer);
    comptime sstable.interfaces.assertReader(Reader);
}
