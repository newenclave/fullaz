const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/core.zig");
const errors = core.errors;
const assertBlockDevice = @import("../device/device.zig").interfaces.assertBlockDevice;

pub fn PageCache(comptime DeviceT: type) type {
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
        fn init() Self {
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

    return struct {
        const Self = @This();

        pub const UnderlyingDevice = DeviceT;
        pub const Pid = UnderlyingDevice.BlockId;

        const FrameHashMap = std.AutoHashMap(Pid, *Frame);

        pub const Handle = PageHandle;

        // Extract device error set from method signatures
        const DeviceError = DeviceT.Error;

        pub const Error = errors.CacheError || DeviceError || std.mem.Allocator.Error;

        device: *UnderlyingDevice = undefined,
        allocator: std.mem.Allocator = undefined,
        maximum_pages: usize = 0,
        cache: std.ArrayList(u8) = undefined,
        frames: std.ArrayList(Frame) = undefined,
        frames_cache: FrameHashMap = undefined,

        free_frames: ?*Frame = null,
        lru_head: ?*Frame = null,
        lru_tail: ?*Frame = null,

        // Placeholder for page cache implementation
        pub fn init(underlying_device: *UnderlyingDevice, allocator: std.mem.Allocator, maximum_pages: usize) Error!Self {
            var res = Self{
                .device = underlying_device,
                .allocator = allocator,
                .maximum_pages = maximum_pages,
                .cache = try std.ArrayList(u8).initCapacity(allocator, underlying_device.blockSize() * maximum_pages),
                .frames = try std.ArrayList(Frame).initCapacity(allocator, maximum_pages),
                .frames_cache = FrameHashMap.init(allocator),
                .free_frames = null,
                .lru_head = null,
                .lru_tail = null,
            };
            try res.cache.resize(allocator, underlying_device.blockSize() * maximum_pages);
            for (0..maximum_pages) |i| {
                var frame = Frame.init();
                frame.frame_id = i;
                try res.frames.append(allocator, frame);
                res.pushFreeFrame(&res.frames.items[i]);
            }
            return res;
        }

        pub fn deinit(self: *Self) void {
            for (self.frames.items) |*frame| {
                if (frame.ref_count != 0) {
                    if (builtin.mode == .Debug) {
                        std.debug.panic("Deinit called on PageCache with pinned pages. pid: {} fid: {} ref_count: {}\n", .{ frame.pid, frame.frame_id, frame.ref_count });
                    }
                }
                if (frame.frame_type == .dirty) {
                    // Write back dirty page
                    _ = self.device.writeBlock(frame.pid, frame.data) catch {};
                    frame.frame_type = .clean;
                }
            }

            self.cache.deinit(self.allocator);
            self.frames.deinit(self.allocator);
            self.frames_cache.deinit();
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            if (try self.findPopFreeFrame()) |ff| {
                ff.frame_type = .temporary;
                const page_offset: usize = ff.frame_id * self.device.blockSize();
                const page_len = self.device.blockSize();

                ff.data = self.cache.items[page_offset .. page_offset + page_len];
                self.pushUsedFrame(ff);

                return PageHandle.init(ff);
            }
            return Error.NoFreeFrames;
        }

        pub fn fetch(self: *Self, page_id: Pid) Error!Handle {
            if (self.frames_cache.get(page_id)) |frame| {
                self.moveToHead(frame);
                return PageHandle.init(frame);
            }

            if (try self.findPopFreeFrame()) |ff| {
                ff.pid = page_id;
                ff.frame_type = .clean;

                const page_offset: usize = ff.frame_id * self.device.blockSize();
                const page_len = self.device.blockSize();

                ff.data = self.cache.items[page_offset .. page_offset + page_len];
                self.device.readBlock(page_id, ff.data) catch |err| {
                    self.pushFreeFrame(ff);
                    return err;
                };
                self.pushUsedFrame(ff);
                self.frames_cache.put(page_id, ff) catch |err| {
                    self.removeFromLruList(ff);
                    self.pushFreeFrame(ff);
                    return err;
                };
                return PageHandle.init(ff);
            }

            return Error.NoFreeFrames;
        }

        pub fn create(self: *Self) Error!Handle {
            if (try self.findPopFreeFrame()) |ff| {
                ff.frame_type = .dirty;
                const page_offset: usize = ff.frame_id * self.device.blockSize();
                const page_len = self.device.blockSize();

                ff.pid = self.device.appendBlock() catch |err| {
                    self.pushFreeFrame(ff);
                    return err;
                };

                ff.data = self.cache.items[page_offset .. page_offset + page_len];
                // New page, zeroed
                @memset(ff.data, 0);
                self.pushUsedFrame(ff);
                errdefer {
                    self.removeFromLruList(ff);
                    self.pushFreeFrame(ff);
                    // Note: block is already appended to device, can't easily undo
                }
                try self.frames_cache.put(ff.pid, ff);
                return PageHandle.init(ff);
            }
            return Error.NoFreeFrames;
        }

        pub fn availableFrames(self: *const Self) usize {
            var count: usize = 0;
            for (self.frames.items) |*frame| {
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

        fn evict(self: *Self, frame: *Frame) Error!void {
            self.removeFromLruList(frame);
            if (frame.frame_type == .dirty) {
                try self.device.writeBlock(frame.pid, frame.data);
                frame.frame_type = .clean;
            }
            if (frame.frame_type != .temporary) {
                _ = self.frames_cache.remove(frame.pid);
            }
        }

        fn findPopFreeFrame(self: *Self) Error!?*Frame {
            var result_frame: ?*Frame = null;

            if (self.popFreeFrame()) |ff| {
                result_frame = ff;
            } else if (self.findLastUsedFrame()) |lu| {
                try self.evict(lu);
                result_frame = lu;
            }
            return result_frame;
        }

        fn popFreeFrame(self: *Self) ?*Frame {
            if (self.free_frames) |frame| {
                self.free_frames = frame.next;
                frame.next = null;
                return frame;
            }
            return null;
        }

        fn pushFreeFrame(self: *Self, frame: *Frame) void {
            frame.next = self.free_frames;
            self.free_frames = frame;
        }

        fn pushUsedFrame(self: *Self, frame: *Frame) void {
            frame.next = self.lru_head;
            frame.prev = null;
            if (self.lru_head) |old_head| {
                old_head.prev = frame;
            } else {
                self.lru_tail = frame;
            }
            self.lru_head = frame;
        }

        fn findLastUsedFrame(self: *Self) ?*Frame {
            var lu = self.lru_tail;
            while (lu) |frame| {
                if (frame.ref_count == 0) {
                    return frame;
                }
                lu = frame.prev;
            }
            return null;
        }

        fn removeFromLruList(self: *Self, frame: *Frame) void {
            if (frame.prev) |prev| {
                prev.next = frame.next;
            } else {
                self.lru_head = frame.next;
            }
            if (frame.next) |next| {
                next.prev = frame.prev;
            } else {
                self.lru_tail = frame.prev;
            }
            frame.prev = null;
            frame.next = null;
        }

        fn moveToHead(self: *Self, frame: *Frame) void {
            self.removeFromLruList(frame);
            self.pushUsedFrame(frame);
        }
    };
}
