const std = @import("std");
const chain_store = @import("fullaz").storage.chain_store;
const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_block_id: ?u32 = null,
    last_block_id: ?u32 = null,
    total_sze: u32 = 0,

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }

    fn getTotalSize(self: *const Self) Error!Size {
        return self.total_sze;
    }
    fn setTotalSize(self: *Self, size: Size) Error!void {
        self.total_sze = size;
    }

    fn getFirst(self: *const Self) Error!?PageId {
        return self.first_block_id;
    }

    fn getLast(self: *const Self) Error!?PageId {
        return self.last_block_id;
    }

    fn setFirst(self: *Self, page_id: ?PageId) Error!void {
        self.first_block_id = page_id;
    }

    fn setLast(self: *Self, page_id: ?PageId) Error!void {
        self.last_block_id = page_id;
    }
};

test "ChantStore View Test" {
    const Chunk = chain_store.View(u32, u32, u32, std.builtin.Endian.little, false).Chunk;
    var buffer: [1024]u8 = undefined;
    var view = Chunk.init(buffer[0..]);

    view.formatPage(1, 42, 0);

    const sh = view.subheader();
    _ = sh;
    const data = view.getData();
    try std.testing.expect(data.len == (1024 - view.page_view.page().allHeadersSize()));
    const dataMut = view.getDataMut();
    try std.testing.expect(dataMut.len == (1024 - view.page_view.page().allHeadersSize()));
}
