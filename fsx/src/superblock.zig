const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");

const PackedInt = fullaz.core.packed_int.PackedInt;

const E = constants.endian;
const PageId = constants.PageId;
const pid_none = constants.pid_none;

const U16 = PackedInt(u16, E);
const U32 = PackedInt(u32, E);
const Pid = PackedInt(PageId, E);

pub const Header = extern struct {
    magic: U32,
    version: U16,
    block_size: U32,
    root_dir_root: Pid,
    freed_head: Pid,
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
            return @ptrCast(self.page.ptr);
        }

        pub fn headerMut(self: *Self) *Header {
            if (read_only) {
                @compileError("cannot mutate a read-only superblock view");
            }
            return @ptrCast(self.page.ptr);
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
            h.root_dir_root.set(pid_none);
            h.freed_head.set(pid_none);
        }

        pub fn validate(self: *const Self, block_size: u32) Error!void {
            const h = self.header();
            if (h.magic.get() != constants.magic) {
                return Error.BadMagic;
            }
            if (h.version.get() != constants.version) {
                return Error.BadVersion;
            }
            if (h.block_size.get() != block_size) {
                return Error.BadBlockSize;
            }
        }

        pub fn getRootDirRoot(self: *const Self) ?PageId {
            return unwrap(self.header().root_dir_root.get());
        }
        pub fn setRootDirRoot(self: *Self, pid: ?PageId) void {
            self.headerMut().root_dir_root.set(wrap(pid));
        }

        pub fn getFreedHead(self: *const Self) ?PageId {
            return unwrap(self.header().freed_head.get());
        }
        pub fn setFreedHead(self: *Self, pid: ?PageId) void {
            self.headerMut().freed_head.set(wrap(pid));
        }
    };
}
