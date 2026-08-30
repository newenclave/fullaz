const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;
const Variadic = @import("../slots/variadic.zig").Variadic;
const errors = @import("errors.zig");

pub fn DataPage(comptime Format: type) type {
    const PackedDataIndex = PackedInt(Format.DataIndex, Format.Endian);
    const PackedU16 = PackedInt(u16, Format.Endian);
    const PackedU32 = PackedInt(u32, Format.Endian);
    const MutableSlots = Variadic(Format.DataIndex, Format.Endian, false);
    const magic: u32 = 0x5353_4450;
    const version: u16 = 1;

    const HeaderImpl = extern struct {
        magic: PackedU32,
        version: PackedU16,
        header_size: PackedU16,
        page_size: PackedDataIndex,
        block_count: PackedDataIndex,
    };

    return struct {
        const Self = @This();

        pub const Header = HeaderImpl;
        pub const Error = MutableSlots.Error || errors.DataPage;

        pub fn pageSizeFromHeader(header_bytes: []const u8) Error!usize {
            if (header_bytes.len != @sizeOf(Header)) {
                return Error.BadHeaderSize;
            }
            const hdr: *const Header = @ptrCast(header_bytes.ptr);
            if (hdr.magic.get() != magic) {
                return Error.BadMagic;
            }
            if (hdr.version.get() != version) {
                return Error.BadVersion;
            }
            if (hdr.header_size.get() != @sizeOf(Header)) {
                return Error.BadHeaderSize;
            }
            return hdr.page_size.get();
        }

        pub fn View(comptime read_only: bool) type {
            const Slots = Variadic(Format.DataIndex, Format.Endian, read_only);

            return struct {
                const ViewSelf = @This();
                const Bytes = if (read_only) []const u8 else []u8;

                bytes: Bytes,

                pub fn init(bytes: Bytes) Error!ViewSelf {
                    if (bytes.len < @sizeOf(Header) + @sizeOf(Slots.Entry)) {
                        return Error.BufferTooSmall;
                    }
                    return .{ .bytes = bytes };
                }

                pub fn header(self: *const ViewSelf) *const Header {
                    return @ptrCast(self.bytes.ptr);
                }

                pub fn headerMut(self: *ViewSelf) *Header {
                    if (read_only) {
                        @compileError("cannot mutate a read-only SSTable data page view");
                    }
                    return @ptrCast(self.bytes.ptr);
                }

                pub fn format(self: *ViewSelf) Error!void {
                    if (read_only) {
                        @compileError("cannot format a read-only SSTable data page view");
                    }
                    const page_size = std.math.cast(
                        Format.DataIndex,
                        self.bytes.len,
                    ) orelse return Error.BadPageSize;

                    @memset(self.bytes, 0);
                    const hdr = self.headerMut();
                    hdr.magic.set(magic);
                    hdr.version.set(version);
                    hdr.header_size.set(@intCast(@sizeOf(Header)));
                    hdr.page_size.set(page_size);
                    hdr.block_count.set(0);

                    var slot_dir = try self.slots();
                    slot_dir.formatHeader();
                }

                pub fn validate(self: *const ViewSelf) Error!void {
                    const hdr = self.header();
                    if (hdr.magic.get() != magic) {
                        return Error.BadMagic;
                    }
                    if (hdr.version.get() != version) {
                        return Error.BadVersion;
                    }
                    if (hdr.header_size.get() != @sizeOf(Header)) {
                        return Error.BadHeaderSize;
                    }
                    if (hdr.page_size.get() != self.bytes.len) {
                        return Error.BadPageSize;
                    }

                    const slot_dir = try self.slots();
                    if (hdr.block_count.get() != slot_dir.size()) {
                        return Error.BadBlockCount;
                    }
                    for (0..slot_dir.size()) |block_index| {
                        _ = try self.record(block_index);
                    }
                }

                pub fn blockCount(self: *const ViewSelf) usize {
                    return self.header().block_count.get();
                }

                /// Returns the compact serialized size of this page.
                pub fn encodedBytes(self: *const ViewSelf) Error!usize {
                    const slot_dir = try self.slots();
                    return @sizeOf(Header) + try slot_dir.usedBytes();
                }

                /// Rewrites this page into an exactly sized output buffer.
                pub fn copyTo(self: *const ViewSelf, output: []u8) Error!void {
                    if (output.len != try self.encodedBytes()) {
                        return Error.BadPageSize;
                    }
                    var compact = try Self.View(false).init(output);
                    try compact.format();
                    for (0..self.blockCount()) |block_index| {
                        try compact.append(
                            try self.fenceKey(block_index),
                            try self.codedBlock(block_index),
                        );
                    }
                }

                pub fn canAppend(
                    self: *const ViewSelf,
                    fence_key: []const u8,
                    coded_block: []const u8,
                ) bool {
                    const record_len = recordLen(fence_key, coded_block) catch {
                        return false;
                    };
                    const slot_dir = self.slots() catch {
                        return false;
                    };
                    return Slots.fullSlotSize(record_len) <= slot_dir.availableSpace();
                }

                pub fn append(
                    self: *ViewSelf,
                    fence_key: []const u8,
                    coded_block: []const u8,
                ) Error!void {
                    if (read_only) {
                        @compileError("cannot append to a read-only SSTable data page view");
                    }
                    const record_len = try recordLen(fence_key, coded_block);
                    const hdr = self.headerMut();
                    const block_count = hdr.block_count.get();
                    if (block_count == std.math.maxInt(Format.DataIndex)) {
                        return Error.BadBlockCount;
                    }

                    var slot_dir = try self.slots();
                    const record_bytes = try slot_dir.reserveGet(record_len);
                    const fence_len: *PackedDataIndex = @ptrCast(record_bytes.ptr);
                    fence_len.set(@intCast(fence_key.len));
                    @memcpy(record_bytes[@sizeOf(PackedDataIndex) .. @sizeOf(PackedDataIndex) + fence_key.len], fence_key);
                    @memcpy(record_bytes[@sizeOf(PackedDataIndex) + fence_key.len ..], coded_block);
                    hdr.block_count.set(block_count + 1);
                }

                pub fn fenceKey(self: *const ViewSelf, block_index: usize) Error![]const u8 {
                    const record_bytes = try self.record(block_index);
                    const fence_len = try recordFenceLen(record_bytes);
                    return record_bytes[@sizeOf(PackedDataIndex) .. @sizeOf(PackedDataIndex) + fence_len];
                }

                pub fn codedBlock(self: *const ViewSelf, block_index: usize) Error![]const u8 {
                    const record_bytes = try self.record(block_index);
                    const fence_len = try recordFenceLen(record_bytes);
                    return record_bytes[@sizeOf(PackedDataIndex) + fence_len ..];
                }

                pub fn lowerBound(
                    self: *const ViewSelf,
                    key: []const u8,
                    comptime cmp: anytype,
                    ctx: anytype,
                ) Error!usize {
                    var lo: usize = 0;
                    var hi = self.blockCount();
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        const order = cmp(ctx, try self.fenceKey(mid), key);
                        if (order == .lt) {
                            lo = mid + 1;
                        } else if (order == .eq or order == .gt) {
                            hi = mid;
                        } else {
                            return Error.Unordered;
                        }
                    }
                    return lo;
                }

                fn slots(self: *const ViewSelf) Error!Slots {
                    return Slots.init(self.bytes[@sizeOf(Header)..]);
                }

                fn record(self: *const ViewSelf, block_index: usize) Error![]const u8 {
                    const slot_dir = try self.slots();
                    return slot_dir.get(block_index) catch Error.BadBlockRecord;
                }
            };
        }

        fn recordLen(fence_key: []const u8, coded_block: []const u8) Error!usize {
            const base = @sizeOf(PackedDataIndex);
            const fence_end = std.math.add(
                usize,
                base,
                fence_key.len,
            ) catch return Error.BadBlockRecord;
            const total = std.math.add(
                usize,
                fence_end,
                coded_block.len,
            ) catch return Error.BadBlockRecord;
            if (std.math.cast(Format.DataIndex, total) == null) {
                return Error.BadBlockRecord;
            }
            return total;
        }

        fn recordFenceLen(record: []const u8) Error!usize {
            if (record.len < @sizeOf(PackedDataIndex)) {
                return Error.BadBlockRecord;
            }
            const packed_fence_len = PackedDataIndex.fromSlice(
                record,
            ) catch return Error.BadBlockRecord;
            const fence_len = std.math.cast(
                usize,
                packed_fence_len.get(),
            ) orelse return Error.BadBlockRecord;
            if (fence_len > record.len - @sizeOf(PackedDataIndex)) {
                return Error.BadBlockRecord;
            }
            return fence_len;
        }
    };
}
