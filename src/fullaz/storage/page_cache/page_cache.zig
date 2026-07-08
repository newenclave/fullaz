const std = @import("std");
const builtin = @import("builtin");
const core = @import("../../core/core.zig");
const errors = core.errors;
const assertBlockDevice = @import("../../device/device.zig").interfaces.assertBlockDevice;
const memory_policy = @import("memory_policy.zig");
const wal_mod = @import("../wal/wal.zig");

pub fn PageCacheImpl(comptime DeviceT: type, comptime MemoryCachePolicy: fn (type) type, comptime WalPolicy: type) type {
    // Compile-time check that DeviceT is a valid block device
    comptime assertBlockDevice(DeviceT);

    const FrameType = enum {
        clean,
        dirty,
        temporary,
    };

    const Frame = struct {
        const Self = @This();
        pid: DeviceT.BlockId,
        frame_id: usize,
        ref_count: usize,
        data: []u8,
        frame_type: FrameType,
        prev: ?*Self,
        next: ?*Self,
        pub fn init() Self {
            return Self{
                .pid = undefined,
                .ref_count = 0,
                .frame_id = 0,
                .data = &[_]u8{},
                .frame_type = .clean,
                .prev = null,
                .next = null,
            };
        }
        pub fn isPinned(self: *const Self) bool {
            return self.ref_count > 0;
        }
        pub fn isDirty(self: *const Self) bool {
            return self.frame_type == .dirty;
        }
    };

    const PageHandle = struct {
        const Self = @This();
        frame: ?*Frame,

        pub const Error = errors.PageError;
        pub const Pid = DeviceT.BlockId;

        fn init(frame: *Frame) Self {
            const res = Self{
                .frame = frame,
            };
            res.frame.?.ref_count += 1;
            return res;
        }

        pub fn deinit(self: *Self) void {
            if (self.frame) |frame_const| {
                var frame = frame_const;
                if (frame.ref_count <= 0) {
                    @panic("Deinit called on PageHandle with ref_count 0");
                }
                frame.ref_count -= 1;
                self.frame = null;
            }
        }

        pub fn markDirty(self: *Self) Error!void {
            if (self.frame == null) {
                return Error.InvalidHandle;
            }
            if (self.frame.?.frame_type != .temporary) {
                self.frame.?.frame_type = .dirty;
            }
        }

        pub fn pid(self: *const Self) Error!Pid {
            if (self.frame == null) {
                return Error.InvalidHandle;
            }
            return self.frame.?.pid;
        }

        pub fn getData(self: *const Self) Error![]const u8 {
            if (self.frame == null) {
                return Error.InvalidHandle;
            }
            return self.frame.?.data;
        }

        pub fn getDataMut(self: *Self) Error![]u8 {
            if (self.frame == null) {
                return Error.InvalidHandle;
            }
            try self.markDirty();
            return self.frame.?.data;
        }

        pub fn clone(self: *const Self) Error!Self {
            if (self.frame == null) {
                return Error.InvalidHandle;
            }
            return Self.init(self.frame.?);
        }

        pub fn take(self: *Self) Error!Self {
            if (self.frame == null) {
                return Error.InvalidHandle;
            }
            const res = Self.init(self.frame.?);
            self.deinit();
            return res;
        }
    };

    const Policy = MemoryCachePolicy(Frame);
    comptime memory_policy.assertMemoryCachePolicy(Policy, Frame);

    return struct {
        const Self = @This();

        pub const UnderlyingDevice = DeviceT;
        pub const Pid = UnderlyingDevice.BlockId;

        const FrameHashMap = std.AutoHashMap(Pid, *Frame);

        pub const Handle = PageHandle;

        // Extract device error set from method signatures
        const DeviceError = DeviceT.Error;
        const WalErrors = if (WalPolicy.enabled) WalPolicy.Error else error{};

        pub const Error = errors.CacheError || DeviceError || std.mem.Allocator.Error || WalErrors;

        device: *UnderlyingDevice = undefined,
        allocator: std.mem.Allocator = undefined,
        policy: Policy = undefined,
        frames_cache: FrameHashMap = undefined,
        locked: bool = false,
        appended_in_batch: usize = 0,
        wal: WalPolicy = undefined,

        pub const WriteBatch = struct {
            cache: *Self,

            pub fn commit(self: *WriteBatch) Error!void {
                return self.cache.commitBatch();
            }

            pub fn discard(self: *WriteBatch) Error!void {
                return self.cache.discardBatch();
            }
        };

        pub fn init(underlying_device: *UnderlyingDevice, allocator: std.mem.Allocator, init_maximum_pages: usize) Error!Self {
            if (WalPolicy.enabled) {
                @compileError("WAL-enabled page cache must be created with initWal");
            }
            return Self{
                .device = underlying_device,
                .allocator = allocator,
                .policy = try Policy.init(allocator, underlying_device.blockSize(), init_maximum_pages),
                .frames_cache = FrameHashMap.init(allocator),
                .wal = .{},
            };
        }

        pub fn initWal(underlying_device: *UnderlyingDevice, allocator: std.mem.Allocator, init_maximum_pages: usize, wal: WalPolicy) Error!Self {
            if (!WalPolicy.enabled) {
                @compileError("initWal requires a WAL policy; use init for NoWal");
            }
            var self = Self{
                .device = underlying_device,
                .allocator = allocator,
                .policy = try Policy.init(allocator, underlying_device.blockSize(), init_maximum_pages),
                .frames_cache = FrameHashMap.init(allocator),
                .wal = wal,
            };
            // trying to recore from the WAL
            try self.recover();
            return self;
        }

        fn recover(self: *Self) Error!void {
            const applyRedo = struct {
                fn f(cache: *Self, pid: Pid, bytes: []const u8) Error!void {
                    while (cache.device.blocksCount() <= @as(usize, @intCast(pid))) {
                        _ = try cache.device.appendBlock();
                    }
                    try cache.device.writeBlock(pid, @constCast(bytes));
                }
            }.f;
            try self.wal.replay(self, applyRedo);
            try self.device.sync();
            try self.wal.checkpoint();
        }

        pub fn deinit(self: *Self) void {
            if (self.locked) {
                // roll it back if batch is still active
                self.discardBatch() catch {};
            }
            for (self.policy.framesSlice()) |*frame| {
                if (frame.ref_count != 0) {
                    if (builtin.mode == .Debug) {
                        std.debug.panic("Deinit called on PageCache with pinned pages. pid: {} fid: {} ref_count: {}\n", .{
                            frame.pid,
                            frame.frame_id,
                            frame.ref_count,
                        });
                    }
                }
                if (frame.frame_type == .dirty) {
                    // Write back dirty page
                    _ = self.device.writeBlock(frame.pid, frame.data) catch {};
                    frame.frame_type = .clean;
                }
            }

            self.policy.deinit();
            self.frames_cache.deinit();
            if (WalPolicy.enabled) {
                self.wal.deinit();
            }
        }

        pub fn pageSize(self: *const Self) usize {
            return self.device.blockSize();
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            const ff = try self.acquireFrame();
            ff.frame_type = .temporary;
            self.policy.pushHead(ff);
            return PageHandle.init(ff);
        }

        pub fn fetch(self: *Self, page_id: Pid) Error!Handle {
            if (self.frames_cache.get(page_id)) |frame| {
                self.policy.moveToHead(frame);
                return PageHandle.init(frame);
            }

            const ff = try self.acquireFrame();
            ff.pid = page_id;
            ff.frame_type = .clean;
            self.device.readBlock(page_id, ff.data) catch |err| {
                self.policy.pushFree(ff);
                return err;
            };
            self.policy.pushHead(ff);
            self.frames_cache.put(page_id, ff) catch |err| {
                self.policy.unlink(ff);
                self.policy.pushFree(ff);
                return err;
            };
            return PageHandle.init(ff);
        }

        pub fn create(self: *Self) Error!Handle {
            const ff = try self.acquireFrame();
            ff.frame_type = .dirty;

            ff.pid = self.device.appendBlock() catch |err| {
                self.policy.pushFree(ff);
                return err;
            };

            // New page, zeroed
            @memset(ff.data, 0);
            if (self.locked) {
                self.appended_in_batch += 1;
            }
            self.policy.pushHead(ff);
            errdefer {
                self.policy.unlink(ff);
                self.policy.pushFree(ff);
                // Note: block is already appended to device, can't easily undo
            }
            try self.frames_cache.put(ff.pid, ff);
            return PageHandle.init(ff);
        }

        pub fn availableFrames(self: *const Self) usize {
            var count: usize = 0;
            for (self.policy.framesSlice()) |*frame| {
                if (frame.ref_count == 0) {
                    count += 1;
                }
            }
            return count;
        }

        pub fn flush(self: *Self, pid: Pid) Error!void {
            if (self.frames_cache.get(pid)) |frame| {
                if (frame.frame_type == .dirty) {
                    try self.device.writeBlock(frame.pid, frame.data);
                    frame.frame_type = .clean;
                }
            }
        }

        pub fn flushAll(self: *Self) Error!void {
            var it = self.frames_cache.iterator();
            while (it.next()) |entry| {
                const frame = entry.value_ptr.*;
                if (frame.frame_type == .dirty) {
                    try self.device.writeBlock(frame.pid, frame.data);
                    frame.frame_type = .clean;
                }
            }
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            if (self.locked) {
                return Error.BatchActive;
            }
            // flush all posible dirty pages before starting a batch.
            // so we have a clean state.
            try self.flushAll();
            self.locked = true;
            self.appended_in_batch = 0;
            return WriteBatch{ .cache = self };
        }

        fn commitBatch(self: *Self) Error!void {
            if (WalPolicy.enabled) {
                // Write-ahead: log every dirty page + a commit record,
                // fsync the log (the commit point),
                // apply to home and fsync it,
                // and drop the now-redundant log.
                var count: u32 = 0;
                var it = self.frames_cache.iterator();
                while (it.next()) |entry| {
                    const frame = entry.value_ptr.*;
                    if (frame.frame_type == .dirty) {
                        try self.wal.appendPage(frame.pid, frame.data);
                        count += 1;
                    }
                }
                try self.wal.sealCommit(count);
                try self.flushAll();
                try self.device.sync();
                try self.wal.checkpoint();
            } else {
                try self.flushAll();
            }
            self.appended_in_batch = 0;
            self.locked = false;
        }

        fn discardBatch(self: *Self) Error!void {
            // Drop every dirty frame without writing it.
            const fslice = self.policy.framesSlice();
            for (fslice) |*frame| {
                if (frame.frame_type == .dirty) {
                    frame.frame_type = .clean;
                    self.policy.unlink(frame);
                    _ = self.frames_cache.remove(frame.pid);
                    self.policy.pushFree(frame);
                }
            }
            // Undo the blocks that create() eagerly appended during the batch.
            //      file device does not extend the file on appendBlock, but the memoryBlock does.
            try self.device.truncateBlocks(self.appended_in_batch);
            self.appended_in_batch = 0;
            self.locked = false;
        }

        fn acquireFrame(self: *Self) Error!*Frame {
            if (self.policy.popFree()) |ff| {
                return ff;
            }
            if (self.policy.selectVictim(!self.locked)) |victim| {
                try self.evict(victim);
                return victim;
            }
            return if (self.locked) Error.BatchTooLarge else Error.NoFreeFrames;
        }

        fn evict(self: *Self, frame: *Frame) Error!void {
            self.policy.unlink(frame);
            if (frame.frame_type == .dirty) {
                try self.device.writeBlock(frame.pid, frame.data);
                frame.frame_type = .clean;
            }
            if (frame.frame_type != .temporary) {
                _ = self.frames_cache.remove(frame.pid);
            }
        }
    };
}

pub fn PageCache(comptime DeviceT: type) type {
    return PageCacheImpl(DeviceT, memory_policy.DefaultMemoryPolicy, wal_mod.NoWal);
}
