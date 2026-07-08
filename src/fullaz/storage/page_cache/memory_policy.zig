const std = @import("std");
const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;

pub fn assertMemoryCachePolicy(comptime PolicyT: type, comptime FrameT: type) void {
    if (!@hasDecl(PolicyT, "init")) {
        @compileError("MemoryCachePolicy missing: " ++ @typeName(PolicyT) ++ ".init");
    }
    if (!@hasDecl(PolicyT, "deinit")) {
        @compileError("MemoryCachePolicy missing: " ++ @typeName(PolicyT) ++ ".deinit");
    }
    requiresFnSignature(PolicyT, "popFree", fn (*PolicyT) ?*FrameT);
    requiresFnSignature(PolicyT, "pushFree", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "selectVictim", fn (*PolicyT, bool) ?*FrameT);
    requiresFnSignature(PolicyT, "pushHead", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "unlink", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "moveToHead", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "framesSlice", fn (*const PolicyT) []FrameT);
}

pub fn DefaultMemoryPolicy(comptime FrameT: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        block_size: usize,
        maximum_pages: usize,
        bytes: std.ArrayList(u8),
        frames: std.ArrayList(FrameT),
        free_frames: ?*FrameT,
        lru_head: ?*FrameT,
        lru_tail: ?*FrameT,

        pub fn init(allocator: std.mem.Allocator, block_size: usize, maximum_pages: usize) std.mem.Allocator.Error!Self {
            var self = Self{
                .allocator = allocator,
                .block_size = block_size,
                .maximum_pages = maximum_pages,
                .bytes = try std.ArrayList(u8).initCapacity(allocator, block_size * maximum_pages),
                .frames = try std.ArrayList(FrameT).initCapacity(allocator, maximum_pages),
                .free_frames = null,
                .lru_head = null,
                .lru_tail = null,
            };
            try self.bytes.resize(allocator, block_size * maximum_pages);
            for (0..maximum_pages) |i| {
                var frame = FrameT.init();
                frame.frame_id = i;
                frame.data = self.bytes.items[i * block_size .. (i + 1) * block_size];
                try self.frames.append(allocator, frame);
                self.pushFree(&self.frames.items[i]);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.bytes.deinit(self.allocator);
            self.frames.deinit(self.allocator);
        }

        pub fn popFree(self: *Self) ?*FrameT {
            if (self.free_frames) |frame| {
                self.free_frames = frame.next;
                frame.next = null;
                return frame;
            }
            return null;
        }

        pub fn pushFree(self: *Self, frame: *FrameT) void {
            frame.next = self.free_frames;
            self.free_frames = frame;
        }

        pub fn selectVictim(self: *Self, allow_dirty: bool) ?*FrameT {
            var lu = self.lru_tail;
            while (lu) |frame| {
                if (!frame.isPinned() and (allow_dirty or !frame.isDirty())) {
                    return frame;
                }
                lu = frame.prev;
            }
            return null;
        }

        pub fn pushHead(self: *Self, frame: *FrameT) void {
            frame.next = self.lru_head;
            frame.prev = null;
            if (self.lru_head) |old_head| {
                old_head.prev = frame;
            } else {
                self.lru_tail = frame;
            }
            self.lru_head = frame;
        }

        pub fn unlink(self: *Self, frame: *FrameT) void {
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

        pub fn moveToHead(self: *Self, frame: *FrameT) void {
            self.unlink(frame);
            self.pushHead(frame);
        }

        pub fn framesSlice(self: *const Self) []FrameT {
            return self.frames.items;
        }
    };
}
