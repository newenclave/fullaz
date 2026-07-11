const std = @import("std");

pub const endian: std.builtin.Endian = .little;

pub const PageId = u32;

pub const magic: u32 = 0x31584c47; // "GLX1" in little-endian
pub const version: u16 = 1;

pub const default_block_size: usize = 4096;

pub const superblock_pid: PageId = 0;
pub const pid_none: PageId = std.math.maxInt(PageId);

// Paged R-tree tuning for the star index.
pub const max_entries: usize = 32;
pub const max_value_size: usize = 16;
pub const cache_frames: usize = 64;

// World / viewport defaults. Coordinates are f64 "light-years".
pub const cell_size: f64 = 1.0;
pub const view_w: f64 = 16.0;
pub const view_h: f64 = 16.0;
pub const step: f64 = 1.0;

// Starfield density.
pub const star_density: f64 = 0.15;
pub const star_jitter: u64 = 3;

// ASCII starmap dimensions (odd, so the player sits dead-center).
pub const map_cols: usize = 61;
pub const map_rows: usize = 21;
