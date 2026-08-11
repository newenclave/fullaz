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

pub const NodeId = fullaz.spatial.orthtree.models.paged.NodeId(PageId, u16);

// One Camera type: the viewer orbits it, the superblock persists it.
pub const Camera = @import("camera.zig").Camera;

// Durable root of the point cloud plus the viewer state, at page 0.
pub const Header = extern struct {
    magic: U32,
    version: U16,
    block_size: U32,

    // NodeId is a plain struct with align 4 and no layout guarantee, so it
    // cannot be a field. Split, with pid_none standing in for null.
    root_page: Pid,
    root_slot: U16,

    // StorageManager counts entries in usize: 64 bit natively, 32 in wasm.
    // Persist the wider one so a browser-exported image opens natively.
    entries_count: U64,
    fsm_class_root: Pid,

    world_seed: U64,
    next_point_id: U32,
    cluster_count: U16,

    detail_fraction: F64,
    camera_yaw: F64,
    camera_pitch: F64,
    camera_distance: F64,
    camera_target: [3]F64,
};

pub const Error = error{ BadMagic, BadVersion, BadBlockSize, BadImage };

fn wrapPid(pid: ?PageId) PageId {
    return pid orelse pid_none;
}

fn unwrapPid(value: PageId) ?PageId {
    return if (value == pid_none) null else value;
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

        pub fn format(self: *Self, block_size: u32, seed: u64, cluster_count: u16) void {
            if (read_only) {
                @compileError("cannot format a read-only superblock view");
            }
            @memset(self.page, 0);
            var h = self.headerMut();
            h.magic.set(constants.magic);
            h.version.set(constants.version);
            h.block_size.set(block_size);
            h.root_page.set(pid_none);
            h.root_slot.set(0);
            h.entries_count.set(0);
            h.fsm_class_root.set(pid_none);
            h.world_seed.set(seed);
            h.next_point_id.set(0);
            h.cluster_count.set(cluster_count);
            h.detail_fraction.set(0);
            h.camera_yaw.set(0);
            h.camera_pitch.set(0);
            h.camera_distance.set(0);
            inline for (0..3) |i| {
                h.camera_target[i].set(0);
            }
        }

        // Runs before the model is constructed: a mismatched page reaches
        // readViewUnchecked, which is `catch unreachable`.
        pub fn validate(self: *const Self, block_size: u32) Error!void {
            const h = self.header();
            if (h.magic.get() != constants.magic) return Error.BadMagic;
            if (h.version.get() != constants.version) return Error.BadVersion;
            if (h.block_size.get() != block_size) return Error.BadBlockSize;
        }

        pub fn getRoot(self: *const Self) ?NodeId {
            const h = self.header();
            const page_id = h.root_page.get();
            if (page_id == pid_none) return null;
            return .{ .page_id = page_id, .slot_id = h.root_slot.get() };
        }

        pub fn setRoot(self: *Self, node: ?NodeId) void {
            var h = self.headerMut();
            if (node) |value| {
                h.root_page.set(value.page_id);
                h.root_slot.set(value.slot_id);
            } else {
                h.root_page.set(pid_none);
                h.root_slot.set(0);
            }
        }

        pub fn getEntriesCount(self: *const Self) Error!usize {
            return std.math.cast(usize, self.header().entries_count.get()) orelse Error.BadImage;
        }

        pub fn setEntriesCount(self: *Self, count: usize) void {
            self.headerMut().entries_count.set(@intCast(count));
        }

        pub fn getFsmClassRoot(self: *const Self) ?PageId {
            return unwrapPid(self.header().fsm_class_root.get());
        }

        pub fn setFsmClassRoot(self: *Self, pid: ?PageId) void {
            self.headerMut().fsm_class_root.set(wrapPid(pid));
        }

        pub fn getSeed(self: *const Self) u64 {
            return self.header().world_seed.get();
        }

        pub fn getNextPointId(self: *const Self) u32 {
            return self.header().next_point_id.get();
        }

        pub fn setNextPointId(self: *Self, id: u32) void {
            self.headerMut().next_point_id.set(id);
        }

        pub fn getClusterCount(self: *const Self) u16 {
            return self.header().cluster_count.get();
        }

        pub fn getDetailFraction(self: *const Self) f64 {
            return self.header().detail_fraction.get();
        }

        pub fn setDetailFraction(self: *Self, fraction: f64) void {
            self.headerMut().detail_fraction.set(fraction);
        }

        pub fn getCamera(self: *const Self) Camera {
            const h = self.header();
            return .{
                .yaw = h.camera_yaw.get(),
                .pitch = h.camera_pitch.get(),
                .distance = h.camera_distance.get(),
                .target = .{
                    h.camera_target[0].get(),
                    h.camera_target[1].get(),
                    h.camera_target[2].get(),
                },
            };
        }

        pub fn setCamera(self: *Self, camera: Camera) void {
            var h = self.headerMut();
            h.camera_yaw.set(camera.yaw);
            h.camera_pitch.set(camera.pitch);
            h.camera_distance.set(camera.distance);
            inline for (0..3) |i| {
                h.camera_target[i].set(camera.target[i]);
            }
        }
    };
}

comptime {
    if (@alignOf(Header) != 1) {
        @compileError("superblock header must be byte aligned");
    }
    if (@sizeOf(Header) > constants.block_size) {
        @compileError("superblock header does not fit in a page");
    }
}
