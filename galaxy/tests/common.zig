const std = @import("std");
const fullaz = @import("fullaz");

pub const galaxy = @import("galaxy");
pub const dev = fullaz.device;

pub const Device = dev.MemoryBlock(u32);
pub const PageCache = fullaz.storage.page_cache.PageCache(Device);
pub const G = galaxy.Galaxy(PageCache);

pub const block_size: u32 = 4096;
pub const frames: usize = 64;

pub const Rec = struct { id: u32, x: f64, y: f64 };

// Collects every star a query visits into a growable list, decoding the id and
// position so tests can compare star *sets* across galaxies / reopens.
pub const Collector = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Rec),

    pub fn init(alloc: std.mem.Allocator) !Collector {
        return .{ .alloc = alloc, .items = try std.ArrayList(Rec).initCapacity(alloc, 0) };
    }

    pub fn deinit(self: *Collector) void {
        self.items.deinit(self.alloc);
    }

    pub fn cb(self: *Collector, mbr: anytype, value: []const u8) anyerror!void {
        const s = galaxy.starfield.Star.fromBytes(value);
        try self.items.append(self.alloc, .{ .id = s.id.get(), .x = mbr.low[0], .y = mbr.low[1] });
    }

    pub fn sortById(self: *Collector) void {
        std.mem.sort(Rec, self.items.items, {}, lessById);
    }

    fn lessById(_: void, a: Rec, b: Rec) bool {
        return a.id < b.id;
    }
};
