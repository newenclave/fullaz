const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn prep(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

const CrashState = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    volatile_bytes: std.ArrayList(u8) = .empty,
    durable_bytes: std.ArrayList(u8) = .empty,
    sync_count: usize = 0,
    fail_sync_at: ?usize = null,

    fn init(allocator: std.mem.Allocator, block_size: usize) CrashState {
        return .{ .allocator = allocator, .block_size = block_size };
    }

    fn deinit(self: *CrashState) void {
        self.volatile_bytes.deinit(self.allocator);
        self.durable_bytes.deinit(self.allocator);
    }

    fn restoreDurable(self: *CrashState) !void {
        self.volatile_bytes.clearRetainingCapacity();
        try self.volatile_bytes.appendSlice(self.allocator, self.durable_bytes.items);
    }
};

const CrashDevice = struct {
    const Self = @This();

    pub const BlockId = u64;
    pub const append_only_dense_block_ids = true;
    pub const Error = std.mem.Allocator.Error || error{
        BadData,
        InvalidId,
        Crash,
    };

    state: *CrashState,

    pub fn deinit(_: *Self) void {}

    pub fn isOpen(_: *const Self) bool {
        return true;
    }

    pub fn isValidId(self: *const Self, block_id: BlockId) bool {
        const page_index = std.math.cast(usize, block_id) orelse return false;
        return page_index < self.blocksCount();
    }

    pub fn blockSize(self: *const Self) usize {
        return self.state.block_size;
    }

    pub fn blocksCount(self: *const Self) usize {
        return self.state.volatile_bytes.items.len / self.state.block_size;
    }

    pub fn appendBlock(self: *Self) Error!BlockId {
        const page_id = std.math.cast(BlockId, self.blocksCount()) orelse return error.InvalidId;
        try self.state.volatile_bytes.appendNTimes(self.state.allocator, 0, self.state.block_size);
        return page_id;
    }

    pub fn truncateBlocks(self: *Self, count: usize) Error!void {
        if (count > self.blocksCount()) {
            return error.InvalidId;
        }
        self.state.volatile_bytes.shrinkRetainingCapacity(
            self.state.volatile_bytes.items.len - count * self.state.block_size,
        );
    }

    pub fn readBlock(self: *const Self, block_id: BlockId, output: []u8) Error!void {
        const page_index = std.math.cast(usize, block_id) orelse return error.InvalidId;
        if (page_index >= self.blocksCount()) {
            return error.InvalidId;
        }
        const offset = page_index * self.state.block_size;
        @memcpy(output[0..self.state.block_size], self.state.volatile_bytes.items[offset..][0..self.state.block_size]);
    }

    pub fn writeBlock(self: *Self, block_id: BlockId, input: []u8) Error!void {
        const page_index = std.math.cast(usize, block_id) orelse return error.InvalidId;
        if (page_index >= self.blocksCount() or input.len < self.state.block_size) {
            return error.InvalidId;
        }
        const offset = page_index * self.state.block_size;
        @memcpy(self.state.volatile_bytes.items[offset..][0..self.state.block_size], input[0..self.state.block_size]);
    }

    pub fn sync(self: *Self) Error!void {
        self.state.sync_count += 1;
        if (self.state.fail_sync_at == self.state.sync_count) {
            return error.Crash;
        }
        self.state.durable_bytes.clearRetainingCapacity();
        try self.state.durable_bytes.appendSlice(self.state.allocator, self.state.volatile_bytes.items);
    }
};

test "fullaz-db: virtual static CoW database keeps logical roots across reopen" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithCow(Schema, Device);
    const io = std.testing.io;
    const image_path = ".zig-cache/virtual_static_cow_chain_store.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{23} ** 16,
        .components = .{ .blob = .{} },
    };
    prep(io, image_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            options,
        );
        defer database.deinit();
        const diagnostics = database.diagnostics();
        try std.testing.expectEqual(@as(u64, 0), diagnostics.commit_generation);
        try std.testing.expect(diagnostics.physical_page_count >= 4);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.virtual_page_count);

        var transaction = try database.begin();
        try transaction.get("blob").append("copy on write bytes");
        try transaction.commit();
        try std.testing.expectEqual(@as(u64, 1), database.diagnostics().commit_generation);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            options,
        );
        defer database.deinit();
        var output: [32]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(u64, 19), try blob.size());
        try std.testing.expectEqual(@as(usize, 19), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("copy on write bytes", output[0..19]);
    }
}

test "fullaz-db: virtual static CoW database falls back from a corrupt newest slot" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithCow(Schema, Device);
    const io = std.testing.io;
    const image_path = ".zig-cache/virtual_static_cow_fallback.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{29} ** 16,
        .components = .{ .blob = .{} },
    };
    prep(io, image_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        try transaction.get("blob").append("new generation");
        try transaction.commit();
        try std.testing.expectEqual(@as(u64, 1), database.diagnostics().commit_generation);
    }
    {
        var device = try Device.open(io, image_path, 512);
        defer device.deinit();
        var corrupt: [512]u8 = [_]u8{0} ** 512;
        try device.writeBlock(1, &corrupt);
        try device.sync();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            options,
        );
        defer database.deinit();
        try std.testing.expectEqual(@as(u64, 0), database.diagnostics().commit_generation);
        try std.testing.expectEqual(@as(u64, 0), try database.getConst("blob").size());
    }
}

test "fullaz-db: virtual static CoW database rejects another image identity" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithCow(Schema, Device);
    const io = std.testing.io;
    const image_path = ".zig-cache/virtual_static_cow_identity.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{37} ** 16,
        .components = .{ .blob = .{} },
    };
    prep(io, image_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            options,
        );
        defer database.deinit();
    }
    var wrong_options = options;
    wrong_options.image_id[0] ^= 1;
    try std.testing.expectError(
        error.IdentityMismatch,
        Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            wrong_options,
        ),
    );
}

test "fullaz-db: virtual static CoW database recovers the old generation when a commit sync crashes" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Database = fullaz_db.VirtualStaticDatabaseWithCow(Schema, CrashDevice);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{31} ** 16,
        .components = .{ .blob = .{} },
    };

    inline for ([_]usize{ 1, 2 }) |sync_offset| {
        var state = CrashState.init(std.testing.allocator, 512);
        defer state.deinit();
        {
            var database = try Database.format(
                std.testing.allocator,
                .{ .state = &state },
                options,
            );
            defer database.deinit();
            state.fail_sync_at = state.sync_count + sync_offset;
            var transaction = try database.begin();
            try transaction.get("blob").append("uncommitted generation");
            try std.testing.expectError(error.Crash, transaction.commit());
        }

        state.fail_sync_at = null;
        try state.restoreDurable();
        var recovered = try Database.open(
            std.testing.allocator,
            .{ .state = &state },
            options,
        );
        defer recovered.deinit();
        try std.testing.expectEqual(@as(u64, 0), recovered.diagnostics().commit_generation);
        try std.testing.expectEqual(@as(u64, 0), try recovered.getConst("blob").size());
    }
}

test "fullaz-db: virtual static CoW database reuses pages after their generation ages out" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithCow(Schema, Device);
    const io = std.testing.io;
    const image_path = ".zig-cache/virtual_static_cow_reuse.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{41} ** 16,
        .components = .{ .blob = .{} },
    };
    prep(io, image_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            options,
        );
        defer database.deinit();
        var first = try database.begin();
        try first.get("blob").append("first");
        try first.commit();
        var second = try database.begin();
        try second.get("blob").append("second");
        try second.commit();
        try std.testing.expect(database.diagnostics().quarantined_physical_pages > 0);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            options,
        );
        defer database.deinit();
        try std.testing.expect(database.diagnostics().quarantined_physical_pages > 0);
        var third = try database.begin();
        try std.testing.expect(database.diagnostics().reusable_physical_pages > 0);
        try third.rollback();
        var fourth = try database.begin();
        try std.testing.expect(database.diagnostics().reusable_physical_pages > 0);
        try fourth.get("blob").append("third");
        try fourth.commit();
        try std.testing.expect(database.diagnostics().reused_physical_pages > 0);
        var output: [32]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(u64, 16), try blob.size());
        try std.testing.expectEqual(@as(usize, 16), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("firstsecondthird", output[0..16]);
    }
}

test "fullaz-db: a crashed reused page remains invisible to the previous generation" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Database = fullaz_db.VirtualStaticDatabaseWithCow(Schema, CrashDevice);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{43} ** 16,
        .components = .{ .blob = .{} },
    };
    var state = CrashState.init(std.testing.allocator, 512);
    defer state.deinit();

    {
        var database = try Database.format(
            std.testing.allocator,
            .{ .state = &state },
            options,
        );
        defer database.deinit();
        var first = try database.begin();
        try first.get("blob").append("first");
        try first.commit();
        var second = try database.begin();
        try second.get("blob").append("second");
        try second.commit();
        try std.testing.expect(database.diagnostics().quarantined_physical_pages > 0);
        state.fail_sync_at = state.sync_count + 1;
        var third = try database.begin();
        try std.testing.expect(database.diagnostics().reusable_physical_pages > 0);
        try third.get("blob").append("third");
        try std.testing.expectError(error.Crash, third.commit());
    }

    state.fail_sync_at = null;
    try state.restoreDurable();
    var recovered = try Database.open(
        std.testing.allocator,
        .{ .state = &state },
        options,
    );
    defer recovered.deinit();
    var output: [32]u8 = undefined;
    const blob = recovered.getConst("blob");
    try std.testing.expectEqual(@as(u64, 11), try blob.size());
    try std.testing.expectEqual(@as(usize, 11), try blob.readAt(0, &output));
    try std.testing.expectEqualStrings("firstsecond", output[0..11]);
}
