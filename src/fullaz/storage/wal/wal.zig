const std = @import("std");
const device = @import("../../device/device.zig");

const PackedInt = @import("../../core/packed_int.zig").PackedInt;

pub const MemoryLog = device.MemoryLog(usize);
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
        device.interfaces.assertLogDevice(LogBackendT);
    }

    const U16 = PackedInt(u16, Endian);
    const U32 = PackedInt(u32, Endian);
    const Pid = PackedInt(PidT, Endian);

    const PageHeader = extern struct {
        kind: U16,
        pid: Pid,
        crc: U32,
    };

    const LogHeader = extern struct {
        magic: [8]u8,
        version: U16,
        header_size: U16,
        page_size: Pid,
        image_id: [16]u8,
        schema_digest: [32]u8,
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
        pub const Error = ErrorSet ||
            LogBackendT.Error ||
            std.mem.Allocator.Error ||
            error{
                BadLogHeader,
                UnsupportedLogVersion,
                WalIdentityMismatch,
            };
        pub const page_header_len: Offset = @sizeOf(PageHeader);
        pub const commit_rec_len: Offset = @sizeOf(CommitRec);
        pub const log_header_len: Offset = @sizeOf(LogHeader);
        pub const Offset = LogBackendT.Offset;
        pub const Identity = struct {
            image_id: [16]u8,
            schema_digest: [32]u8,
        };

        const magic = "FULLAZWL";
        const format_version = 1;

        allocator: std.mem.Allocator,
        backend: *LogBackendT,
        page_size: Offset,
        scratch: []u8,
        record_start: Offset = 0,
        identity: ?Identity = null,

        pub fn init(allocator: std.mem.Allocator, backend: *LogBackendT, page_size: Offset) Error!Self {
            return .{
                .allocator = allocator,
                .backend = backend,
                .page_size = page_size,
                .scratch = try allocator.alloc(u8, page_header_len + @as(usize, @intCast(page_size))),
            };
        }

        /// Opens or formats an identity-bound WAL. The header prevents a sidecar
        /// belonging to another static image from being replayed into this one.
        pub fn initWithIdentity(
            allocator: std.mem.Allocator,
            backend: *LogBackendT,
            page_size: Offset,
            identity: Identity,
        ) Error!Self {
            var self = try Self.init(allocator, backend, page_size);
            errdefer self.deinit();
            self.record_start = log_header_len;
            self.identity = identity;
            if (backend.size() == 0) {
                try self.writeLogHeader();
            } else {
                try self.validateLogHeader();
            }
            return self;
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
                .crc = U32.init(pageCrc(pid, bytes)),
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
            if (self.identity != null) {
                try self.writeLogHeader();
            }
        }

        pub fn replay(self: *Self, ctx: anytype, cb: anytype) !void {
            const committed_end = try self.scanCommittedEnd();
            const total = page_header_len + self.page_size;
            var off: Offset = self.record_start;
            while (off < committed_end) {
                if (try self.readKind(off) == kind_page) {
                    try self.backend.readAt(@intCast(off), self.scratch[0..total]);
                    const hdr: *const PageHeader = @ptrCast(self.scratch.ptr);
                    try cb(ctx, hdr.pid.get(), self.scratch[page_header_len..total]);
                    off += @as(Offset, @intCast(total));
                } else {
                    off += commit_rec_len;
                }
            }
        }

        fn readKind(self: *Self, off: Offset) Error!u16 {
            var kbuf: [2]u8 = undefined;
            try self.backend.readAt(off, &kbuf);
            return std.mem.readInt(u16, &kbuf, Endian);
        }

        fn scanCommittedEnd(self: *Self) Error!Offset {
            const size = self.backend.size();
            const total = page_header_len + self.page_size;

            var off: Offset = self.record_start;
            var committed_end: Offset = self.record_start;
            var page_count: u32 = 0;

            while ((off + 2) <= size) {
                const k = try self.readKind(off);
                if (k == kind_page) {
                    if (off + total > size) {
                        break;
                    }
                    try self.backend.readAt(off, self.scratch[0..total]);
                    const hdr: *const PageHeader = @ptrCast(self.scratch.ptr);
                    if (pageCrc(hdr.pid.get(), self.scratch[page_header_len..total]) != hdr.crc.get()) {
                        break;
                    }
                    page_count +%= 1;
                    off += @as(Offset, @intCast(total));
                } else if (k == kind_commit) {
                    if ((off + commit_rec_len) > size) {
                        break;
                    }
                    var rbuf: [commit_rec_len]u8 = undefined;
                    try self.backend.readAt(off, &rbuf);

                    const rec: *const CommitRec = @ptrCast(&rbuf);
                    if (commitCrc(rec.count.get()) != rec.crc.get() or rec.count.get() != page_count) {
                        break;
                    }
                    off += commit_rec_len;
                    committed_end = off;
                    page_count = 0;
                } else {
                    break;
                }
            }
            return committed_end;
        }

        fn crc32(bytes: []const u8) u32 {
            return std.hash.Crc32.hash(bytes);
        }

        fn pageCrc(pid: PidT, bytes: []const u8) u32 {
            const packed_pid = Pid.init(pid);
            var crc = std.hash.Crc32.init();
            crc.update(&packed_pid.bytes);
            crc.update(bytes);
            return crc.final();
        }

        fn commitCrc(count: u32) u32 {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, count, Endian);
            return std.hash.Crc32.hash(&b);
        }

        fn writeLogHeader(self: *Self) Error!void {
            const identity = self.identity orelse return Error.BadLogHeader;
            var header = LogHeader{
                .magic = magic.*,
                .version = U16.init(format_version),
                .header_size = U16.init(@sizeOf(LogHeader)),
                .page_size = Pid.init(@intCast(self.page_size)),
                .image_id = identity.image_id,
                .schema_digest = identity.schema_digest,
                .crc = U32.init(0),
            };
            header.crc.set(logHeaderCrc(std.mem.asBytes(&header)));
            try self.backend.append(std.mem.asBytes(&header));
            try self.backend.sync();
        }

        fn validateLogHeader(self: *Self) Error!void {
            if (self.backend.size() < log_header_len) {
                return Error.BadLogHeader;
            }
            var bytes: [@sizeOf(LogHeader)]u8 = undefined;
            try self.backend.readAt(0, &bytes);
            const header_ptr: *const LogHeader = @ptrCast(&bytes);
            const identity = self.identity orelse return Error.BadLogHeader;
            if (!std.mem.eql(u8, &header_ptr.magic, magic) or
                header_ptr.header_size.get() != @sizeOf(LogHeader))
            {
                return Error.BadLogHeader;
            }
            if (header_ptr.version.get() != format_version) {
                return Error.UnsupportedLogVersion;
            }
            if (header_ptr.page_size.get() != self.page_size or
                logHeaderCrc(&bytes) != header_ptr.crc.get())
            {
                return Error.BadLogHeader;
            }
            if (!std.mem.eql(u8, &header_ptr.image_id, &identity.image_id) or
                !std.mem.eql(u8, &header_ptr.schema_digest, &identity.schema_digest))
            {
                return Error.WalIdentityMismatch;
            }
        }

        fn logHeaderCrc(bytes: []const u8) u32 {
            const crc_offset = @offsetOf(LogHeader, "crc");
            var crc = std.hash.Crc32.init();
            crc.update(bytes[0..crc_offset]);
            crc.update(bytes[crc_offset + @sizeOf(U32) ..]);
            return crc.final();
        }
    };
}
