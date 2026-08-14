const std = @import("std");
const fullaz = @import("fullaz");

pub const endian: std.builtin.Endian = .little;

pub const PageId = u32;
pub const pid_none: PageId = std.math.maxInt(PageId);

pub const magic: u32 = 0x31444C43; // "CLD1"
pub const version: u16 = 2;

pub const block_size: u32 = 1024;
// Traversal pins one node page plus one entry chunk per level, so the budget is
// roughly 2 * max_tree_depth with room for the superblock and temporaries.
pub const cache_frames: usize = 128;

pub const superblock_pid: PageId = 0;

pub const Coord = f32;
pub const dims: usize = 3;
pub const Box = fullaz.spatial.BoundingBox(Coord, dims);
pub const Vec3 = [dims]Coord;

// A power of two anchored at the origin: every center() lands on an exactly
// representable coordinate, all the way down to the smallest cell.
pub const root_side: Coord = 65536.0;
pub const max_tree_depth: usize = 16;
pub const min_cell_extent: Coord = 1.0;

comptime {
    if (@as(Coord, @floatFromInt(@as(u64, 1) << max_tree_depth)) != root_side) {
        @compileError("max_tree_depth must equal log2(root_side)");
    }
}

pub const tree_settings: fullaz.spatial.orthtree.models.paged.Settings(Coord) = .{
    .max_leaf_entries = 256,
    .max_value_size = 16,
    .max_tree_depth = max_tree_depth,
    .min_cell_extent = min_cell_extent,
    .node_layout_id = 0x0C1D0001, // bump whenever the trait storage changes
    .node_page_kind = 0x30,
    .entry_page_kind = 0x31,
};

// Five per cent of the viewport height, whatever the front end measures in.
pub const default_detail_fraction: f64 = 0.05;
pub const default_camera_distance: f64 = root_side * 1.6;
pub const default_camera_yaw: f64 = 0.6;
pub const default_camera_pitch: f64 = 0.35;

pub fn worldCentre() [dims]f64 {
    return .{ root_side / 2, root_side / 2, root_side / 2 };
}

pub fn rootBox() Box {
    return Box.create(
        .{ 0, 0, 0 },
        .{ root_side, root_side, root_side },
    );
}
