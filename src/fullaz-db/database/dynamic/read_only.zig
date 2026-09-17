const std = @import("std");
const fullaz = @import("fullaz");

const device_interfaces = fullaz.device.interfaces;
const wal = fullaz.storage.wal;

pub fn RecoveredReadOnlyDevice(
    comptime DeviceT: type,
    comptime LogDeviceT: ?type,
) type {
    comptime device_interfaces.assertBlockDevice(DeviceT);
    if (LogDeviceT) |LogT| {
        comptime device_interfaces.assertLogDevice(LogT);
    }

    const Log = LogDeviceT orelse void;
    const Wal = if (LogDeviceT) |LogT|
        wal.Wal(LogT, DeviceT.BlockId, .little)
    else
        wal.NoWal;
    const LogError = if (LogDeviceT) |LogT| LogT.Error else error{};
    const WalError = if (LogDeviceT != null) Wal.Error else error{};

    return struct {
        const Self = @This();

        pub const BlockId = DeviceT.BlockId;
        pub const Error = DeviceT.Error ||
            LogError ||
            WalError ||
            std.mem.Allocator.Error ||
            error{ReadOnly};
        pub const append_only_dense_block_ids = true;

        allocator: std.mem.Allocator,
        device: DeviceT,
        log: Log,
        recovered_pages: std.AutoHashMap(BlockId, []u8),
        recovered_high_water: usize,
        logical_page_count: usize,

        pub fn init(
            allocator: std.mem.Allocator,
            device: DeviceT,
        ) Error!Self {
            if (LogDeviceT != null) {
                @compileError("WAL-backed read-only devices require initWal");
            }
            return .{
                .allocator = allocator,
                .device = device,
                .log = {},
                .recovered_pages = std.AutoHashMap(BlockId, []u8).init(allocator),
                .recovered_high_water = 0,
                .logical_page_count = device.blocksCount(),
            };
        }

        pub fn initWal(
            allocator: std.mem.Allocator,
            device: DeviceT,
            log: Log,
        ) Error!Self {
            if (LogDeviceT == null) {
                @compileError("non-WAL read-only devices require init");
            }
            var self = Self{
                .allocator = allocator,
                .device = device,
                .log = log,
                .recovered_pages = std.AutoHashMap(BlockId, []u8).init(allocator),
                .recovered_high_water = 0,
                .logical_page_count = device.blocksCount(),
            };
            errdefer self.deinit();

            var wal_value = try Wal.init(
                allocator,
                &self.log,
                @intCast(self.device.blockSize()),
            );
            defer wal_value.deinit();
            try wal_value.replay(&self, applyRecoveredPage);
            self.logical_page_count = @max(
                self.device.blocksCount(),
                self.recovered_high_water,
            );
            return self;
        }

        fn applyRecoveredPage(
            self: *Self,
            page_id: BlockId,
            bytes: []const u8,
        ) Error!void {
            const page_index = std.math.cast(usize, page_id) orelse return error.InvalidId;
            const entry = try self.recovered_pages.getOrPut(page_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = self.allocator.alloc(u8, bytes.len) catch |err| {
                    _ = self.recovered_pages.remove(page_id);
                    return err;
                };
            }
            @memcpy(entry.value_ptr.*, bytes);
            self.recovered_high_water = @max(self.recovered_high_water, page_index +| 1);
        }

        pub fn setLogicalPageCount(self: *Self, page_count: usize) Error!void {
            const available = @max(
                self.device.blocksCount(),
                self.recovered_high_water,
            );
            if (page_count > available) {
                return error.InvalidId;
            }
            self.logical_page_count = page_count;
        }

        pub fn deinit(self: *Self) void {
            var values = self.recovered_pages.valueIterator();
            while (values.next()) |bytes| {
                self.allocator.free(bytes.*);
            }
            self.recovered_pages.deinit();
            if (comptime LogDeviceT != null) {
                self.log.deinit();
            }
            self.device.deinit();
            self.* = undefined;
        }

        pub fn isValidId(self: *const Self, block_id: BlockId) bool {
            const index = std.math.cast(usize, block_id) orelse return false;
            return index < self.logical_page_count;
        }

        pub fn isOpen(self: *const Self) bool {
            return self.device.isOpen();
        }

        pub fn blockSize(self: *const Self) usize {
            return self.device.blockSize();
        }

        pub fn blocksCount(self: *const Self) usize {
            return self.logical_page_count;
        }

        pub fn readBlock(
            self: *const Self,
            block_id: BlockId,
            output: []u8,
        ) Error!void {
            const index = std.math.cast(usize, block_id) orelse return error.InvalidId;
            if (index >= self.logical_page_count) {
                return error.InvalidId;
            }
            if (self.recovered_pages.get(block_id)) |bytes| {
                const len = @min(output.len, bytes.len);
                @memcpy(output[0..len], bytes[0..len]);
                return;
            }
            if (index < self.device.blocksCount()) {
                return self.device.readBlock(block_id, output);
            }
            @memset(output[0..@min(output.len, self.blockSize())], 0);
        }

        pub fn appendBlock(_: *Self) Error!BlockId {
            return error.ReadOnly;
        }

        pub fn truncateBlocks(_: *Self, _: usize) Error!void {
            return error.ReadOnly;
        }

        pub fn writeBlock(_: *Self, _: BlockId, _: []u8) Error!void {
            return error.ReadOnly;
        }

        pub fn sync(_: *Self) Error!void {
            return error.ReadOnly;
        }
    };
}

test "read-only recovery removes a page entry when allocation fails" {
    const Device = fullaz.device.MemoryBlock(u32);
    const RecoveredDevice = RecoveredReadOnlyDevice(Device, null);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var recovered = try RecoveredDevice.init(
        failing.allocator(),
        try Device.init(std.testing.allocator, 64),
    );
    defer recovered.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        recovered.applyRecoveredPage(0, &([_]u8{0xA5} ** 64)),
    );
    try std.testing.expectEqual(@as(usize, 0), recovered.recovered_pages.count());
}
