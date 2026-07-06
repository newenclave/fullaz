const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");

const PackedInt = fullaz.core.packed_int.PackedInt;

const PageId = constants.PageId;
const Size = constants.Size;
const pid_none = constants.pid_none;
const E = constants.endian;

const U8 = PackedInt(u8, E);
const U32 = PackedInt(Size, E);
const Pid = PackedInt(PageId, E);

pub const Kind = enum(u8) { file = 1, dir = 2 };

const Tag = extern struct {
    kind: U8,
};

const DirEntry = extern struct {
    kind: U8,
    root: Pid,
};

const FileEntry = extern struct {
    kind: U8,
    first: Pid,
    last: Pid,
    index: Pid,
    total: U32,
};

pub const dir_len = @sizeOf(DirEntry);
pub const file_len = @sizeOf(FileEntry);

pub const FileRoots = struct {
    first: ?PageId = null,
    last: ?PageId = null,
    total: Size = 0,
    index: ?PageId = null,
};

pub const DirRoots = struct {
    root: ?PageId = null,
};

pub const Inode = union(Kind) {
    file: FileRoots,
    dir: DirRoots,

    pub fn newFile() Inode {
        return .{ .file = .{} };
    }
    pub fn newDir() Inode {
        return .{ .dir = .{} };
    }
};

pub const Error = error{ BadKind, ShortBuffer };

fn wrap(pid: ?PageId) PageId {
    return pid orelse pid_none;
}
fn unwrap(v: PageId) ?PageId {
    return if (v == pid_none) null else v;
}

pub fn encodedLen(node: Inode) usize {
    return switch (node) {
        .dir => dir_len,
        .file => file_len,
    };
}

pub fn kindOf(bytes: []const u8) Error!Kind {
    if (bytes.len < @sizeOf(Tag)) {
        return Error.ShortBuffer;
    }
    const t: *const Tag = @ptrCast(bytes.ptr);
    return switch (t.kind.get()) {
        @intFromEnum(Kind.file) => .file,
        @intFromEnum(Kind.dir) => .dir,
        else => Error.BadKind,
    };
}

pub fn encode(node: Inode, buf: []u8) Error![]const u8 {
    switch (node) {
        .dir => |d| {
            if (buf.len < dir_len) {
                return Error.ShortBuffer;
            }
            const e: *DirEntry = @ptrCast(buf.ptr);
            e.kind.set(@intFromEnum(Kind.dir));
            e.root.set(wrap(d.root));
            return buf[0..dir_len];
        },
        .file => |f| {
            if (buf.len < file_len) {
                return Error.ShortBuffer;
            }
            const e: *FileEntry = @ptrCast(buf.ptr);
            e.kind.set(@intFromEnum(Kind.file));
            e.first.set(wrap(f.first));
            e.last.set(wrap(f.last));
            e.index.set(wrap(f.index));
            e.total.set(f.total);
            return buf[0..file_len];
        },
    }
}

pub fn decode(bytes: []const u8) Error!Inode {
    switch (try kindOf(bytes)) {
        .dir => {
            if (bytes.len < dir_len) {
                return Error.ShortBuffer;
            }
            const e: *const DirEntry = @ptrCast(bytes.ptr);
            return .{ .dir = .{ .root = unwrap(e.root.get()) } };
        },
        .file => {
            if (bytes.len < file_len) {
                return Error.ShortBuffer;
            }
            const e: *const FileEntry = @ptrCast(bytes.ptr);
            return .{ .file = .{
                .first = unwrap(e.first.get()),
                .last = unwrap(e.last.get()),
                .index = unwrap(e.index.get()),
                .total = e.total.get(),
            } };
        },
    }
}
