const std = @import("std");
const core = @import("../core/core.zig");

const PackedInt = core.packed_int.PackedInt;

pub fn Trailing(
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    comptime {
        const int_info = switch (@typeInfo(IndexT)) {
            .int => |info| info,
            else => @compileError("Trailing index type must be an unsigned integer"),
        };
        if (int_info.signedness != .unsigned) {
            @compileError("Trailing index type must be an unsigned integer");
        }
    }

    const PackedIndex = PackedInt(IndexT, Endian);
    const HeaderImpl = extern struct {
        entry_count: PackedIndex,
        data_end: PackedIndex,
        directory_offset: PackedIndex,
    };
    const EntryImpl = extern struct {
        offset: PackedIndex,
        length: PackedIndex,
    };
    const Buffer = if (read_only) []const u8 else []u8;

    return struct {
        const Self = @This();

        pub const Header = HeaderImpl;
        pub const Entry = EntryImpl;
        pub const Error = core.errors.SlotsError;
        pub const Reservation = struct {
            slot_id: usize,
            bytes: []u8,
        };

        buffer: Buffer,

        pub fn init(buffer: Buffer) Error!Self {
            if (buffer.len < @sizeOf(Header) or std.math.cast(IndexT, buffer.len) == null) {
                return Error.BufferTooSmall;
            }
            return .{ .buffer = buffer };
        }

        pub fn format(self: *Self) void {
            if (read_only) {
                @compileError("cannot format a read-only trailing directory");
            }
            @memset(self.buffer, 0);
            const hdr = self.headerMut();
            hdr.entry_count.set(0);
            hdr.data_end.set(@sizeOf(Header));
            hdr.directory_offset.set(@intCast(self.buffer.len));
        }

        pub fn open(buffer: Buffer) Error!Self {
            var self = try Self.init(buffer);
            try self.validateCompact();
            if (!read_only) {
                try self.relocateDirectoryToTail();
            }
            return self;
        }

        pub fn header(self: *const Self) *const Header {
            return @ptrCast(self.buffer.ptr);
        }

        pub fn headerMut(self: *Self) *Header {
            if (read_only) {
                @compileError("cannot mutate a read-only trailing directory");
            }
            return @ptrCast(self.buffer.ptr);
        }

        pub fn entryCount(self: *const Self) usize {
            return self.header().entry_count.get();
        }

        pub fn canReserve(self: *const Self, len: usize) bool {
            if (std.math.cast(IndexT, len) == null) {
                return false;
            }
            const map_bytes = std.math.mul(
                usize,
                self.entryCount(),
                @sizeOf(Entry),
            ) catch {
                return false;
            };
            const directory_offset: usize = self.header().directory_offset.get();
            const data_end: usize = self.header().data_end.get();
            if (directory_offset != self.buffer.len -| map_bytes or data_end > directory_offset) {
                return false;
            }
            const required = std.math.add(usize, len, @sizeOf(Entry)) catch {
                return false;
            };
            return required <= directory_offset - data_end;
        }

        pub fn reserve(self: *Self, len: usize) Error!Reservation {
            return self.reserveAt(self.entryCount(), len);
        }

        pub fn reserveAt(self: *Self, slot_id: usize, len: usize) Error!Reservation {
            if (read_only) {
                @compileError("cannot reserve a record in a read-only trailing directory");
            }
            const entry_count = self.entryCount();
            if (slot_id > entry_count) {
                return Error.OutOfBounds;
            }
            if (!self.canReserve(len)) {
                return Error.NotEnoughSpace;
            }

            const hdr = self.headerMut();
            const data_end: usize = hdr.data_end.get();
            const directory_offset: usize = hdr.directory_offset.get();
            const new_directory_offset = directory_offset - @sizeOf(Entry);
            const physical_index = entry_count - slot_id;
            const shifted_bytes = physical_index * @sizeOf(Entry);
            @memmove(
                self.buffer[new_directory_offset..][0..shifted_bytes],
                self.buffer[directory_offset..][0..shifted_bytes],
            );
            const map_entry = self.physicalEntryMut(new_directory_offset, physical_index);
            map_entry.offset.set(@intCast(data_end));
            map_entry.length.set(@intCast(len));
            hdr.entry_count.set(@intCast(entry_count + 1));
            hdr.data_end.set(@intCast(data_end + len));
            hdr.directory_offset.set(@intCast(new_directory_offset));
            return .{
                .slot_id = slot_id,
                .bytes = self.buffer[data_end..][0..len],
            };
        }

        pub fn entry(self: *const Self, slot_id: usize) Error!Entry {
            const entry_count = self.entryCount();
            if (slot_id >= entry_count) {
                return Error.OutOfBounds;
            }
            return self.physicalEntry(entry_count - 1 - slot_id).*;
        }

        pub fn get(self: *const Self, slot_id: usize) Error![]const u8 {
            const slot = try self.entry(slot_id);
            const offset: usize = slot.offset.get();
            const length: usize = slot.length.get();
            const end = std.math.add(usize, offset, length) catch {
                return Error.InconsistentLayout;
            };
            if (offset < @sizeOf(Header) or end > self.header().data_end.get()) {
                return Error.InconsistentLayout;
            }
            return self.buffer[offset..end];
        }

        pub fn getMut(self: *Self, slot_id: usize) Error![]u8 {
            if (read_only) {
                @compileError("cannot mutate a record in a read-only trailing directory");
            }
            const slot = try self.entry(slot_id);
            const offset: usize = slot.offset.get();
            const length: usize = slot.length.get();
            const end = std.math.add(usize, offset, length) catch {
                return Error.InconsistentLayout;
            };
            if (offset < @sizeOf(Header) or end > self.header().data_end.get()) {
                return Error.InconsistentLayout;
            }
            return self.buffer[offset..end];
        }

        pub fn compact(self: *Self) Error!usize {
            if (read_only) {
                @compileError("cannot compact a read-only trailing directory");
            }
            const entry_count = self.entryCount();
            const directory_bytes = std.math.mul(usize, entry_count, @sizeOf(Entry)) catch {
                return Error.InconsistentLayout;
            };
            const hdr = self.headerMut();
            const data_end: usize = hdr.data_end.get();
            const directory_offset: usize = hdr.directory_offset.get();
            if (directory_offset != self.buffer.len -| directory_bytes or data_end > directory_offset) {
                return Error.InconsistentLayout;
            }
            const compact_bytes = std.math.add(usize, data_end, directory_bytes) catch {
                return Error.InconsistentLayout;
            };
            @memmove(
                self.buffer[data_end..][0..directory_bytes],
                self.buffer[directory_offset..][0..directory_bytes],
            );
            hdr.directory_offset.set(@intCast(data_end));
            return compact_bytes;
        }

        fn validateCompact(self: *const Self) Error!void {
            const hdr = self.header();
            const entry_count = std.math.cast(usize, hdr.entry_count.get()) orelse {
                return Error.InconsistentLayout;
            };
            const data_end = std.math.cast(usize, hdr.data_end.get()) orelse {
                return Error.InconsistentLayout;
            };
            const directory_offset = std.math.cast(usize, hdr.directory_offset.get()) orelse {
                return Error.InconsistentLayout;
            };
            if (data_end < @sizeOf(Header) or directory_offset != data_end) {
                return Error.InconsistentLayout;
            }
            const directory_bytes = std.math.mul(usize, entry_count, @sizeOf(Entry)) catch {
                return Error.InconsistentLayout;
            };
            const directory_end = std.math.add(usize, directory_offset, directory_bytes) catch {
                return Error.InconsistentLayout;
            };
            if (directory_end > self.buffer.len or (read_only and directory_end != self.buffer.len)) {
                return Error.InconsistentLayout;
            }
            for (0..entry_count) |physical_index| {
                const map_entry = self.physicalEntry(physical_index);
                const offset = std.math.cast(usize, map_entry.offset.get()) orelse {
                    return Error.InconsistentLayout;
                };
                const length = std.math.cast(usize, map_entry.length.get()) orelse {
                    return Error.InconsistentLayout;
                };
                const entry_end = std.math.add(usize, offset, length) catch {
                    return Error.InconsistentLayout;
                };
                if (offset < @sizeOf(Header) or entry_end > data_end) {
                    return Error.InconsistentLayout;
                }
            }
        }

        fn relocateDirectoryToTail(self: *Self) Error!void {
            if (read_only) {
                @compileError("cannot relocate a read-only trailing directory");
            }
            const entry_count = self.entryCount();
            const directory_bytes = std.math.mul(usize, entry_count, @sizeOf(Entry)) catch {
                return Error.InconsistentLayout;
            };
            const hdr = self.headerMut();
            const directory_offset: usize = hdr.directory_offset.get();
            const target_offset = self.buffer.len - directory_bytes;
            @memmove(
                self.buffer[target_offset..][0..directory_bytes],
                self.buffer[directory_offset..][0..directory_bytes],
            );
            hdr.directory_offset.set(@intCast(target_offset));
        }

        fn physicalEntry(self: *const Self, physical_index: usize) *const Entry {
            const directory_offset: usize = @intCast(self.header().directory_offset.get());
            const offset = directory_offset + physical_index * @sizeOf(Entry);
            return @ptrCast(self.buffer[offset..].ptr);
        }

        fn physicalEntryMut(
            self: *Self,
            directory_offset: usize,
            physical_index: usize,
        ) *Entry {
            return @ptrCast(self.buffer[directory_offset + physical_index * @sizeOf(Entry) ..].ptr);
        }
    };
}
