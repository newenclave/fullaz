const std = @import("std");
const device = @import("../../device/device.zig");

const PackedInt = @import("../../core/packed_int.zig").PackedInt;

pub const MemoryLog = device.MemoryLog;
pub const FileLog = device.FileLog;

pub const ErrorSet = error{BadPageSize};

const kind_page: u16 = 1;
const kind_commit: u16 = 2;

pub const NoWal = struct {
    pub const enabled = false;
};

// redo-only WAL (write-ahead log).
pub fn Wal(comptime LogBackendT: type, comptime PidT: type, comptime Endian: std.builtin.Endian) type {
    comptime {
        device.interfaces.assertIsLogBackend(LogBackendT);
    }

    const U16 = PackedInt(u16, Endian);
    const U32 = PackedInt(u32, Endian);
    const Pid = PackedInt(PidT, Endian);

    const PageHeader = extern struct {
        kind: U16,
        pid: Pid,
        crc: U32,
    };

    const CommitRec = extern struct {
        kind: U16,
        count: U32,
        crc: U32,
    };

    return struct {
        const Self = @This();

        pub const enabled = true;
        pub const Error = ErrorSet || LogBackendT.Error || std.mem.Allocator.Error;
        pub const page_header_len: usize = @sizeOf(PageHeader);
        pub const commit_rec_len: usize = @sizeOf(CommitRec);

        allocator: std.mem.Allocator,
        backend: *LogBackendT,
        page_size: usize,
        scratch: []u8,

        pub fn init(allocator: std.mem.Allocator, backend: *LogBackendT, page_size: usize) Error!Self {
            return .{
                .allocator = allocator,
                .backend = backend,
                .page_size = page_size,
                .scratch = try allocator.alloc(u8, page_header_len + page_size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.scratch);
        }

        pub fn appendPage(self: *Self, pid: PidT, bytes: []const u8) Error!void {
            if (bytes.len != self.page_size) {
                return Error.BadPageSize;
            }
            var hdr: PageHeader = .{
                .kind = U16.init(kind_page),
                .pid = Pid.init(pid),
                .crc = U32.init(std.hash.Crc32.hash(bytes)),
            };
            try self.backend.append(std.mem.asBytes(&hdr));
            try self.backend.append(bytes);
        }

        pub fn sealCommit(self: *Self, count: u32) Error!void {
            var rec: CommitRec = .{
                .kind = U16.init(kind_commit),
                .count = U32.init(count),
                .crc = U32.init(commitCrc(count)),
            };
            try self.backend.append(std.mem.asBytes(&rec));
            try self.backend.sync();
        }

        pub fn checkpoint(self: *Self) Error!void {
            try self.backend.reset();
        }

        pub fn replay(self: *Self, ctx: anytype, cb: anytype) !void {
            const committed_end = try self.scanCommittedEnd();
            const total = page_header_len + self.page_size;
            var off: usize = 0;
            while (off < committed_end) {
                if (try self.readKind(off) == kind_page) {
                    try self.backend.readAt(off, self.scratch[0..total]);
                    const hdr: *const PageHeader = @ptrCast(self.scratch.ptr);
                    try cb(ctx, hdr.pid.get(), self.scratch[page_header_len..total]);
                    off += total;
                } else {
                    off += commit_rec_len;
                }
            }
        }

        fn readKind(self: *Self, off: usize) Error!u16 {
            var kbuf: [2]u8 = undefined;
            try self.backend.readAt(off, &kbuf);
            return std.mem.readInt(u16, &kbuf, Endian);
        }

        fn scanCommittedEnd(self: *Self) Error!usize {
            const size = self.backend.size();
            const total = page_header_len + self.page_size;

            var off: usize = 0;
            var committed_end: usize = 0;

            while ((off + 2) <= size) {
                const k = try self.readKind(off);
                if (k == kind_page) {
                    if (off + total > size) {
                        break;
                    }
                    try self.backend.readAt(off, self.scratch[0..total]);
                    const hdr: *const PageHeader = @ptrCast(self.scratch.ptr);
                    if (crc32(self.scratch[page_header_len..total]) != hdr.crc.get()) {
                        break;
                    }
                    off += total;
                } else if (k == kind_commit) {
                    if ((off + commit_rec_len) > size) {
                        break;
                    }
                    var rbuf: [commit_rec_len]u8 = undefined;
                    try self.backend.readAt(off, &rbuf);

                    const rec: *const CommitRec = @ptrCast(&rbuf);
                    if (commitCrc(rec.count.get()) != rec.crc.get()) {
                        break;
                    }
                    off += commit_rec_len;
                    committed_end = off;
                } else {
                    break;
                }
            }
            return committed_end;
        }

        fn crc32(bytes: []const u8) u32 {
            return std.hash.Crc32.hash(bytes);
        }

        fn commitCrc(count: u32) u32 {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, count, Endian);
            return std.hash.Crc32.hash(&b);
        }
    };
}
