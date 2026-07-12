const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");

const PackedInt = fullaz.core.packed_int.PackedInt;
const PackedFloat = fullaz.core.packed_int.PackedFloat;

const E = constants.endian;
const PageId = constants.PageId;
const pid_none = constants.pid_none;

const U16 = PackedInt(u16, E);
const U32 = PackedInt(u32, E);
const U64 = PackedInt(u64, E);
const Pid = PackedInt(PageId, E);
const F64 = PackedFloat(f64, E);

// Superblock. Holds the durable root of the star R-tree plus the world parameters
pub const Header = extern struct {
    magic: U32,
    version: U16,
    block_size: U32,
    rtree_root: Pid,
    world_seed: U64,
    star_id_counter: U32,
    player_x: F64,
    player_y: F64,
    cell_size: F64,
    view_w: F64,
    view_h: F64,
};

pub const Error = error{ BadMagic, BadVersion, BadBlockSize };

fn wrap(pid: ?PageId) PageId {
    return pid orelse pid_none;
}
fn unwrap(v: PageId) ?PageId {
    return if (v == pid_none) null else v;
}

pub fn View(comptime read_only: bool) type {
    return struct {
        const Self = @This();
        const Bytes = if (read_only) []const u8 else []u8;

        page: Bytes,

        pub fn init(page: Bytes) Self {
            return .{ .page = page };
        }

        pub fn header(self: *const Self) *const Header {
            return @ptrCast(@alignCast(self.page.ptr));
        }

        pub fn headerMut(self: *Self) *Header {
            if (read_only) {
                @compileError("cannot mutate a read-only superblock view");
            }
            return @ptrCast(@alignCast(self.page.ptr));
        }

        pub fn format(self: *Self, block_size: u32) void {
            if (read_only) {
                @compileError("cannot format a read-only superblock view");
            }
            @memset(self.page, 0);
            var h = self.headerMut();
            h.magic.set(constants.magic);
            h.version.set(constants.version);
            h.block_size.set(block_size);
            h.rtree_root.set(pid_none);
            h.star_id_counter.set(0);
            h.world_seed.set(0);
            h.player_x.set(0);
            h.player_y.set(0);
            h.cell_size.set(constants.cell_size);
            h.view_w.set(constants.view_w);
            h.view_h.set(constants.view_h);
        }

        pub fn validate(self: *const Self, block_size: u32) Error!void {
            const h = self.header();
            if (h.magic.get() != constants.magic) return Error.BadMagic;
            if (h.version.get() != constants.version) return Error.BadVersion;
            if (h.block_size.get() != block_size) return Error.BadBlockSize;
        }

        pub fn getRoot(self: *const Self) ?PageId {
            return unwrap(self.header().rtree_root.get());
        }
        pub fn setRoot(self: *Self, pid: ?PageId) void {
            self.headerMut().rtree_root.set(wrap(pid));
        }

        pub fn getSeed(self: *const Self) u64 {
            return self.header().world_seed.get();
        }
        pub fn setSeed(self: *Self, seed: u64) void {
            self.headerMut().world_seed.set(seed);
        }

        pub fn getStarCounter(self: *const Self) u32 {
            return self.header().star_id_counter.get();
        }
        pub fn setStarCounter(self: *Self, n: u32) void {
            self.headerMut().star_id_counter.set(n);
        }

        pub fn getPlayer(self: *const Self) [2]f64 {
            const h = self.header();
            return .{ h.player_x.get(), h.player_y.get() };
        }
        pub fn setPlayer(self: *Self, x: f64, y: f64) void {
            var h = self.headerMut();
            h.player_x.set(x);
            h.player_y.set(y);
        }

        pub fn getCellSize(self: *const Self) f64 {
            return self.header().cell_size.get();
        }
        pub fn setCellSize(self: *Self, v: f64) void {
            self.headerMut().cell_size.set(v);
        }

        pub fn getView(self: *const Self) [2]f64 {
            const h = self.header();
            return .{ h.view_w.get(), h.view_h.get() };
        }
        pub fn setView(self: *Self, w: f64, h_: f64) void {
            var h = self.headerMut();
            h.view_w.set(w);
            h.view_h.set(h_);
        }
    };
}
