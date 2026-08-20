const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;

const PackedInt = core.packed_int.PackedInt;

pub const AvailableStatusEnum = enum {
    enough,
    need_compact,
    not_enough,
};

pub fn Variadic(comptime T: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    return VariadicImpl(T, Endian, read_only, 1);
}

pub fn VariadicImpl(
    comptime T: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
    comptime align_value: T,
) type {
    comptime {
        const int_info = switch (@typeInfo(T)) {
            .int => |info| info,
            else => @compileError("Variadic index type must be an unsigned integer"),
        };
        if (int_info.signedness != .unsigned) {
            @compileError("Variadic index type must be an unsigned integer");
        }
        if (align_value == 0 or (align_value & (align_value - 1)) != 0) {
            @compileError("Variadic alignment must be a non-zero power of two");
        }
    }

    const IndexType = PackedInt(T, Endian);
    const Magic = PackedInt(u16, Endian);

    const SLOT_INVALID: T = 0;
    const FLAGS_MASK: T = align_value - 1;
    const OFFSET_MASK: T = ~FLAGS_MASK;

    const EntryHeader = extern struct {
        offset: IndexType,
        length: IndexType,
    };

    const FreedEntry = extern struct {
        prev: IndexType = undefined,
        next: IndexType = undefined,
        length: IndexType = undefined,
    };

    const Header = extern struct {
        magic: Magic = undefined,
        entry_count: IndexType,
        free_begin: IndexType,
        free_end: IndexType,
        freed: IndexType, // first freed offset
    };

    comptime {
        std.debug.assert(@sizeOf(Header) == @sizeOf(T) * 4 + @sizeOf(Magic));
        std.debug.assert(@offsetOf(Header, "entry_count") == @sizeOf(Magic));
        std.debug.assert(@offsetOf(Header, "free_begin") == @sizeOf(Magic) + @sizeOf(T));
        std.debug.assert(@offsetOf(Header, "free_end") == @sizeOf(Magic) + @sizeOf(T) * 2);
        std.debug.assert(@offsetOf(Header, "freed") == @sizeOf(Magic) + @sizeOf(T) * 3);
    }

    const BufferType = if (read_only) []const u8 else []u8;

    return struct {
        const Self = @This();

        pub const Entry = EntryHeader;
        pub const EntrySlice = []Entry;
        pub const ConstEntrySlice = []const Entry;
        pub const FlagsMask = FLAGS_MASK;

        pub const Error = errors.SlotsError;

        pub const AvailableStatus = AvailableStatusEnum;

        body: BufferType,

        fn slotOffset(raw_offset: T) T {
            return raw_offset & OFFSET_MASK;
        }

        fn slotFlags(raw_offset: T) T {
            return raw_offset & FLAGS_MASK;
        }

        fn encodeSlotOffset(offset: T, flags: T) T {
            std.debug.assert(slotOffset(offset) == offset);
            return offset | slotFlags(flags);
        }

        fn checkedFixedLength(len: T) ?usize {
            const minimum = @max(@as(usize, @intCast(len)), @sizeOf(FreedEntry));
            const rounded = std.math.add(usize, minimum, @as(usize, align_value) - 1) catch return null;
            const fixed = core.memory.alignDown(usize, rounded, @as(usize, align_value));
            if (fixed > std.math.maxInt(T)) {
                return null;
            }
            return fixed;
        }

        fn dataEnd(self: *const Self) usize {
            return core.memory.alignDown(usize, self.body.len, @as(usize, align_value));
        }

        pub fn init(body: BufferType) Error!Self {
            if (core.memory.alignDown(usize, body.len, @as(usize, align_value)) < @sizeOf(Header)) {
                return Error.BufferTooSmall;
            }
            return .{
                .body = body,
            };
        }

        pub fn formatHeader(self: *Self) void {
            if (read_only) {
                @compileError("Cannot format header on const buffer");
            }
            var header_ptr = self.headerMut();
            header_ptr.entry_count.set(0);
            header_ptr.free_begin.set(@intCast(@sizeOf(Header)));
            header_ptr.free_end.set(@intCast(self.dataEnd()));
            header_ptr.freed.set(0);
        }

        pub fn validate(self: *const Self) Error!void {
            const data_end = self.dataEnd();
            const header_ptr = self.header();
            const entry_count: usize = @intCast(header_ptr.entry_count.get());
            const directory_bytes = std.math.mul(usize, entry_count, @sizeOf(Entry)) catch {
                return Error.InconsistentLayout;
            };
            const expected_free_begin = std.math.add(usize, @sizeOf(Header), directory_bytes) catch {
                return Error.InconsistentLayout;
            };
            const free_begin: usize = @intCast(header_ptr.free_begin.get());
            const free_end: usize = @intCast(header_ptr.free_end.get());
            if (expected_free_begin > data_end or free_begin != expected_free_begin or
                free_end < free_begin or free_end > data_end or
                free_end != core.memory.alignDown(usize, free_end, @as(usize, align_value)))
            {
                return Error.InconsistentLayout;
            }

            const freed: usize = @intCast(header_ptr.freed.get());
            if (freed != 0 and
                (freed < free_end or freed > data_end -| @sizeOf(FreedEntry) or
                    freed != core.memory.alignDown(usize, freed, @as(usize, align_value))))
            {
                return Error.InconsistentLayout;
            }

            const first_entry_ptr: [*]const Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            const slot_entries = first_entry_ptr[0..entry_count];
            for (slot_entries, 0..) |entry, index| {
                const offset: usize = @intCast(slotOffset(entry.offset.get()));
                const length: usize = @intCast(entry.length.get());
                if (offset == SLOT_INVALID) {
                    if (length != 0) {
                        return Error.InconsistentLayout;
                    }
                    continue;
                }
                const fixed_length = checkedFixedLength(entry.length.get()) orelse {
                    return Error.InconsistentLayout;
                };
                if (offset < free_begin or offset < free_end or
                    offset != core.memory.alignDown(usize, offset, @as(usize, align_value)) or
                    fixed_length > data_end - offset)
                {
                    return Error.InconsistentLayout;
                }

                for (slot_entries[0..index]) |other| {
                    const other_offset: usize = @intCast(slotOffset(other.offset.get()));
                    if (other_offset == SLOT_INVALID) {
                        continue;
                    }
                    const other_length = checkedFixedLength(other.length.get()) orelse {
                        return Error.InconsistentLayout;
                    };
                    if (offset < other_offset + other_length and other_offset < offset + fixed_length) {
                        return Error.InconsistentLayout;
                    }
                }
            }

            const max_free_nodes = data_end / @sizeOf(FreedEntry);
            var previous_offset: T = SLOT_INVALID;
            var current_offset = header_ptr.freed.get();
            var free_nodes: usize = 0;
            while (current_offset != SLOT_INVALID) {
                free_nodes += 1;
                if (free_nodes > max_free_nodes) {
                    return Error.InconsistentLayout;
                }

                const offset: usize = @intCast(current_offset);
                if (offset < free_end or offset > data_end -| @sizeOf(FreedEntry) or
                    offset != core.memory.alignDown(usize, offset, @as(usize, align_value)))
                {
                    return Error.InconsistentLayout;
                }
                const free_entry: *const FreedEntry = @ptrCast(&self.body[offset]);
                const free_length: usize = @intCast(free_entry.length.get());
                const fixed_free_length = checkedFixedLength(free_entry.length.get()) orelse {
                    return Error.InconsistentLayout;
                };
                if (free_entry.prev.get() != previous_offset or
                    free_length < @sizeOf(FreedEntry) or
                    free_length != fixed_free_length or
                    free_length > data_end - offset)
                {
                    return Error.InconsistentLayout;
                }

                for (slot_entries) |entry| {
                    const live_offset: usize = @intCast(slotOffset(entry.offset.get()));
                    if (live_offset == SLOT_INVALID) {
                        continue;
                    }
                    const live_length = checkedFixedLength(entry.length.get()) orelse {
                        return Error.InconsistentLayout;
                    };
                    if (offset < live_offset + live_length and live_offset < offset + free_length) {
                        return Error.InconsistentLayout;
                    }
                }

                var earlier_offset = header_ptr.freed.get();
                var earlier_nodes: usize = 0;
                while (earlier_offset != current_offset) {
                    earlier_nodes += 1;
                    if (earlier_offset == SLOT_INVALID or earlier_nodes >= free_nodes) {
                        return Error.InconsistentLayout;
                    }
                    const earlier: usize = @intCast(earlier_offset);
                    const earlier_entry: *const FreedEntry = @ptrCast(&self.body[earlier]);
                    const earlier_length: usize = @intCast(earlier_entry.length.get());
                    if (offset < earlier + earlier_length and earlier < offset + free_length) {
                        return Error.InconsistentLayout;
                    }
                    earlier_offset = earlier_entry.next.get();
                }

                previous_offset = current_offset;
                current_offset = free_entry.next.get();
            }
        }

        pub fn fullSlotSize(obj_len: usize) usize {
            const min_len = @max(obj_len, @sizeOf(FreedEntry));
            return @sizeOf(Entry) + core.memory.alignUp(usize, min_len, @as(usize, align_value));
        }

        pub fn capacityFor(self: *const Self, obj_len: usize) usize {
            return self.capacitySpace() / fullSlotSize(obj_len);
        }

        pub fn availableSpace(self: *const Self) usize {
            const header_ptr = self.header();
            const free_begin = header_ptr.free_begin.get();
            const free_end = header_ptr.free_end.get();
            return @intCast(free_end - free_begin);
        }

        pub fn capacitySpace(self: *const Self) usize {
            const total_size = self.dataEnd() - @sizeOf(Header);
            return total_size;
        }

        pub fn usedSpace(self: *const Self) Error!usize {
            const slots = self.entries();
            var used = slots.len * @sizeOf(Entry);
            for (slots) |*s| {
                if (slotOffset(s.offset.get()) == SLOT_INVALID) {
                    continue;
                }
                const len: T = s.length.get();
                const fixed: T = self.fixLength(len);
                used += @as(usize, fixed);
            }
            if (used > self.capacitySpace()) {
                return Error.InconsistentLayout;
            }
            return used;
        }

        /// Returns the smallest body size that can contain the live slots.
        pub fn usedBytes(self: *const Self) Error!usize {
            return @sizeOf(Header) + try self.usedSpace();
        }

        pub fn availableAfterCompact(self: *const Self) Error!usize {
            return self.capacitySpace() - try self.usedSpace();
        }

        pub fn getMut(self: *Self, entry: usize) Error![]u8 {
            if (read_only) @compileError("Cannot get mutable value from const buffer");
            const slots = self.entriesMut();

            if (entry >= slots.len) {
                return Error.OutOfBounds;
            }

            const slot = slots[entry];
            return self.getMutByEntry(&slot);
        }

        pub fn getMutByEntry(self: *Self, slot: *const Entry) Error![]u8 {
            if (read_only) @compileError("Cannot get mutable value from const buffer");
            const offset: usize = @intCast(slotOffset(slot.offset.get()));
            const length: usize = @intCast(slot.length.get());
            if (offset + length > self.body.len) {
                return Error.OutOfBounds;
            }
            return self.body[offset..][0..length];
        }

        pub fn getByEntry(self: *const Self, slot: *const Entry) Error![]const u8 {
            const offset: usize = @intCast(slotOffset(slot.offset.get()));
            const length: usize = @intCast(slot.length.get());
            if (offset + length > self.body.len) {
                return Error.OutOfBounds;
            }
            return self.body[offset..][0..length];
        }

        pub fn get(self: *const Self, entry: usize) Error![]const u8 {
            const slots = self.entries();
            if (entry >= slots.len) {
                return Error.OutOfBounds;
            }
            const slot = slots[entry];
            const offset: usize = @intCast(slotOffset(slot.offset.get()));
            const length: usize = @intCast(slot.length.get());
            if (offset + length > self.body.len) {
                return Error.OutOfBounds;
            }
            return self.body[offset..][0..length];
        }

        pub fn free(self: *Self, entry: usize) Error!void {
            if (read_only) @compileError("Cannot remove from const buffer");
            var slots = self.entriesMut();
            if (entry >= slots.len) {
                return Error.OutOfBounds;
            }

            if (slotOffset(slots[entry].offset.get()) == SLOT_INVALID) {
                return; // already freed no op
            }

            const slot_offset = slotOffset(slots[entry].offset.get());
            const slot_length = slots[entry].length.get();

            var hdr = self.headerMut();
            if (hdr.free_end.get() == slot_offset) {
                hdr.free_end.set(slot_offset + self.fixLength(slot_length));
            } else {
                self.pushFreeSlot(slot_offset, slots[entry].length.get());
            }

            slots[entry].offset.set(SLOT_INVALID);
            slots[entry].length.set(0);
        }

        pub fn findFreeEntry(self: *const Self) ?usize {
            const slots = self.entries();
            for (slots, 0..) |s, i| {
                if (slotOffset(s.offset.get()) == SLOT_INVALID) {
                    return i;
                }
            }
            return null;
        }

        pub fn remove(self: *Self, entry: usize) Error!void {
            if (read_only) @compileError("Cannot remove from const buffer");
            const slots = self.entriesMut();
            if (entry >= slots.len) {
                return Error.OutOfBounds;
            }

            const slot_offset = slotOffset(slots[entry].offset.get());
            const slot_length = slots[entry].length.get();

            var hdr = self.headerMut();
            if (hdr.free_end.get() == slot_offset) {
                hdr.free_end.set(slot_offset + self.fixLength(slot_length));
            } else {
                self.pushFreeSlot(slot_offset, slots[entry].length.get());
            }

            try self.shrink(entry);

            hdr.entry_count.set(hdr.entry_count.get() - 1);
            const old_begin = hdr.free_begin.get();
            const new_begin = old_begin - @as(T, @sizeOf(Entry));
            hdr.free_begin.set(new_begin);
        }

        /// Removes matching live slots while preserving the order of survivors.
        /// The predicate receives the original slot id and must not retain data.
        pub fn removeIf(self: *Self, comptime predicate: anytype, context: anytype) Error!usize {
            if (read_only) {
                @compileError("Cannot remove from const buffer");
            }

            const slots = self.entriesMut();
            for (slots) |slot| {
                const offset: usize = @intCast(slotOffset(slot.offset.get()));
                if (offset == SLOT_INVALID) {
                    continue;
                }
                const length: usize = @intCast(slot.length.get());
                if (offset + length > self.body.len) {
                    return Error.OutOfBounds;
                }
            }

            var write_index: usize = 0;
            var removed: usize = 0;

            for (slots, 0..) |slot, slot_id| {
                const raw_offset = slot.offset.get();
                const slot_offset = slotOffset(raw_offset);
                if (slot_offset == SLOT_INVALID) {
                    slots[write_index] = slot;
                    write_index += 1;
                    continue;
                }

                const offset: usize = @intCast(slot_offset);
                const length: usize = @intCast(slot.length.get());
                const data: []const u8 = self.body[offset..][0..length];
                if (!predicate(context, slot_id, slotFlags(raw_offset), data)) {
                    slots[write_index] = slot;
                    write_index += 1;
                    continue;
                }

                var hdr = self.headerMut();
                if (hdr.free_end.get() == slot_offset) {
                    hdr.free_end.set(slot_offset + self.fixLength(slot.length.get()));
                } else {
                    self.pushFreeSlot(slot_offset, slot.length.get());
                }
                removed += 1;
            }

            if (removed != 0) {
                var hdr = self.headerMut();
                hdr.entry_count.set(@intCast(write_index));
                hdr.free_begin.set(hdr.free_begin.get() - @as(T, @intCast(removed * @sizeOf(Entry))));
            }
            return removed;
        }

        pub fn canUpdate(self: *const Self, entry: usize, len: usize) Error!AvailableStatus {
            const fix_len: usize = @as(usize, self.fixLength(@as(T, @intCast(len))));
            const slots = self.entries();
            if (entry >= slots.len) {
                return Error.OutOfBounds;
            }

            const old_len = @as(usize, self.fixLength(slots[entry].length.get()));
            if (fix_len <= old_len) {
                return .enough;
            }

            if (self.findFreeSlot(@as(T, @intCast(fix_len)))) |_| {
                return .enough;
            }

            const avail_after_compact = try self.availableAfterCompact() + old_len;
            if (fix_len <= avail_after_compact) {
                return .need_compact;
            }
            return .not_enough;
        }

        pub fn canInsert3(self: *const Self, a: usize, b: usize, c: usize) Error!AvailableStatus {
            const fix_a: usize = @as(usize, self.fixLength(@as(T, @intCast(a))));
            const fix_b: usize = @as(usize, self.fixLength(@as(T, @intCast(b))));
            const fix_c: usize = @as(usize, self.fixLength(@as(T, @intCast(c))));
            const entry_size = @sizeOf(Entry) * 2;
            return try self.canInsert(fix_a + fix_b + fix_c + entry_size);
        }

        pub fn canInsert2(self: *const Self, a: usize, b: usize) Error!AvailableStatus {
            const fix_a: usize = @as(usize, self.fixLength(@as(T, @intCast(a))));
            const fix_b: usize = @as(usize, self.fixLength(@as(T, @intCast(b))));
            const entry_size = @sizeOf(Entry);
            return try self.canInsert(fix_a + fix_b + entry_size);
        }

        pub fn canInsert(self: *const Self, len: usize) Error!AvailableStatus {
            const fix_len: usize = @as(usize, self.fixLength(@as(T, @intCast(len))));

            const available = self.availableSpace();

            if (fix_len + @sizeOf(Entry) <= available) {
                return .enough;
            }

            if (self.findFreeSlot(@as(T, @intCast(fix_len)))) |_| {
                if (available >= @sizeOf(Entry)) {
                    return .enough;
                }
            }

            const avail_after_compact = try self.availableAfterCompact();
            if (fix_len + @sizeOf(Entry) <= avail_after_compact) {
                return .need_compact;
            }
            return .not_enough;
        }

        pub fn canMergeWith(self: *const Self, other: *const Self) Error!AvailableStatus {
            return self.canMergeWithAdditional(other, 0);
        }

        pub fn canMergeWithAdditional(self: *const Self, other: *const Self, add_size: usize) !AvailableStatus {
            const other_slots = other.entries();
            const fixed_add_size = if (add_size == 0) 0 else @as(usize, self.fixLength(@as(T, @intCast(add_size))));
            const full_add_size = (fixed_add_size + @as(usize, if (fixed_add_size == 0) 0 else @sizeOf(Entry)));
            var needed: usize = full_add_size;

            // Add data sizes
            for (other_slots) |*s| {
                if (slotOffset(s.offset.get()) != SLOT_INVALID) {
                    needed += (self.fixLength(s.length.get()) + @sizeOf(Entry));
                }
            }

            const available = self.availableSpace();
            if (needed <= available) {
                return .enough;
            }
            const avail_after_compact = try self.availableAfterCompact();
            if (needed <= avail_after_compact) {
                return .need_compact;
            }
            return .not_enough;
        }

        pub fn insert(self: *Self, data: []const u8) Error!usize {
            if (read_only) {
                @compileError("Cannot insert into const buffer");
            }

            const len = data.len;
            const buf = self.reserveGetAt(self.entries().len, len) catch |err| {
                return err;
            };
            const buf_fixed = buf[0..len];
            @memcpy(buf_fixed, data);
            return self.entries().len - 1;
        }

        pub fn insertAt(self: *Self, pos: usize, data: []const u8) Error!void {
            if (read_only) {
                @compileError("Cannot insert into const buffer");
            }

            const len = data.len;
            const buf = self.reserveGetAt(pos, len) catch |err| {
                return err;
            };
            const buf_fixed = buf[0..len];
            @memcpy(buf_fixed, data);
        }

        // private:
        fn sliceAligned(buf: []u8, n: usize) ?[]T {
            return core.memory.sliceAligned(T, buf, n);
        }

        fn offsetGt(slots: []const Entry, a: T, b: T) bool {
            return slotOffset(slots[b].offset.get()) < slotOffset(slots[a].offset.get());
        }

        pub fn compactWithBuffer(self: *Self, raw_buffer: []u8) Error!void {
            const slots = self.entriesMut();
            if (sliceAligned(raw_buffer, slots.len)) |buffer| {
                var total_elements: usize = 0;
                for (slots, 0..) |*s, idx| {
                    if (slotOffset(s.offset.get()) != SLOT_INVALID) {
                        buffer[total_elements] = @intCast(idx);
                        total_elements += 1;
                    }
                }
                const offset_buf = buffer[0..total_elements];
                std.sort.pdq(T, offset_buf, slots, offsetGt);

                var new_end_usize = self.dataEnd();
                for (offset_buf) |idx| {
                    const uidx: usize = @intCast(idx);
                    const raw_offset = slots[uidx].offset.get();
                    const slot_offset = slotOffset(raw_offset);
                    const slot_length = slots[uidx].length.get();
                    const target_len = self.fixLength(slot_length);
                    const old_off = slot_offset;

                    new_end_usize -= target_len;

                    const src = self.body[old_off .. old_off + target_len];
                    const dst = self.body[new_end_usize .. new_end_usize + target_len];

                    @memmove(dst, src);

                    slots[uidx].offset.set(encodeSlotOffset(@intCast(new_end_usize), slotFlags(raw_offset)));
                }
                self.headerMut().free_end.set(@intCast(new_end_usize));
                self.headerMut().freed.set(0);
            } else {
                return Error.BufferTooSmall;
            }
        }

        // compact in place without any extra buffer
        // this call completes in O(n^2) time
        pub fn compactInPlace(self: *Self) Error!void {
            const slots = self.entriesMut();

            const base_end: T = @intCast(self.dataEnd());

            const old_data_beg: T = self.header().free_end.get();

            var cursor: T = base_end;
            var free_end: T = base_end;

            while (true) {
                var best_i: ?usize = null;
                var best_off: T = 0;
                var best_len: T = 0;
                var best_flen: T = 0;
                var best_flags: T = 0;

                for (slots, 0..) |*s, i| {
                    const raw_offset = s.offset.get();
                    const off = slotOffset(raw_offset);
                    const len: T = s.length.get();

                    if (off == SLOT_INVALID) {
                        continue;
                    }

                    if (off < old_data_beg) {
                        continue;
                    }

                    if (off < cursor and (best_i == null or off > best_off)) {
                        best_i = i;
                        best_off = off;
                        best_len = len;
                        best_flen = self.fixLength(len);
                        best_flags = slotFlags(raw_offset);
                    }
                }

                if (best_i == null) {
                    break;
                }

                cursor = best_off;

                free_end -= best_flen;

                const dst = self.body[@as(usize, free_end)..@as(usize, free_end + best_len)];
                const src = self.body[@as(usize, best_off)..@as(usize, best_off + best_len)];
                @memmove(dst, src);

                slots[best_i.?].offset.set(encodeSlotOffset(free_end, best_flags));
            }

            self.headerMut().free_end.set(free_end);
            self.headerMut().freed.set(0);
        }

        pub fn fixLength(_: Self, len: T) T {
            return core.memory.alignUp(
                T,
                if (len < @sizeOf(FreedEntry)) @sizeOf(FreedEntry) else len,
                align_value,
            );
        }

        pub fn header(self: *const Self) *const Header {
            return @ptrCast(&self.body[0]);
        }

        pub fn headerMut(self: *Self) *Header {
            if (read_only) @compileError("Cannot get mutable header from const buffer");
            return @ptrCast(&self.body[0]);
        }

        pub fn resizeGet(self: *Self, pos: usize, len: usize) Error![]u8 {
            if (read_only) @compileError("Cannot insert into const buffer");

            if (pos > self.entries().len) {
                return Error.OutOfBounds;
            }

            if (len >= self.body.len) {
                return Error.NotEnoughSpace;
            }
            const fixed_len = self.fixLength(@as(T, @intCast(len)));

            const slots = self.entriesMut();
            const old_len = @as(usize, self.fixLength(slots[pos].length.get()));
            if (fixed_len == old_len) {
                const offset: usize = @intCast(slotOffset(slots[pos].offset.get()));
                slots[pos].length.set(@as(T, @intCast(len)));
                return self.body[offset .. offset + len];
            }

            if (fixed_len < old_len) {
                const offset: usize = @intCast(slotOffset(slots[pos].offset.get()));
                slots[pos].length.set(@as(T, @intCast(len)));

                const remain_slot_len = old_len - fixed_len;
                if (remain_slot_len >= @as(usize, @sizeOf(FreedEntry))) {
                    const new_free_offset = @as(T, @intCast(offset + fixed_len));
                    const new_free_length = @as(T, @intCast(remain_slot_len));
                    self.pushFreeSlot(new_free_offset, new_free_length);
                }

                return self.body[offset .. offset + len];
            }

            return self.reserveGetExpand(pos, len, false);
        }

        pub fn reserveGetAt(self: *Self, pos: usize, len: usize) Error![]u8 {
            return self.reserveGetExpand(pos, len, true);
        }

        pub fn reserveGet(self: *Self, len: usize) Error![]u8 {
            const slots = self.entries();
            return self.reserveGetExpand(slots.len, len, true);
        }

        fn reserveGetExpand(self: *Self, pos: usize, len: usize, need_slot: bool) Error![]u8 {
            if (read_only) {
                @compileError("Cannot insert into const buffer");
            }

            if (pos > self.entries().len) {
                return Error.OutOfBounds;
            }

            if (len >= self.body.len) {
                return Error.NotEnoughSpace;
            }

            const fix_len: usize = @intCast(self.fixLength(@intCast(len)));

            const entry_len: usize = if (need_slot) @sizeOf(Entry) else 0;
            const available = self.availableSpace();

            if ((fix_len + entry_len) > available) {
                if (self.findFreeSlot(@intCast(fix_len))) |fs_info| {
                    const fs = fs_info.ptr;
                    const slot_len = fs.length.get();

                    const slot_offset: usize = @intCast(fs_info.offset);
                    self.popFreeSlot(fs);

                    const remain_slot_len = slot_len - @as(T, @intCast(fix_len));
                    if (remain_slot_len >= @as(T, @sizeOf(FreedEntry))) {
                        const new_free_offset = @as(T, @intCast(slot_offset)) + @as(T, @intCast(fix_len));
                        const new_free_length = remain_slot_len;
                        self.pushFreeSlot(new_free_offset, new_free_length);
                    }

                    const buf = self.body[slot_offset .. slot_offset + @as(usize, @intCast(slot_len))];
                    if (need_slot) {
                        self.increaseEntryCount();
                        self.expand(pos);
                    }

                    var slots = self.entriesMut();
                    slots[pos].length.set(@as(T, @intCast(len)));
                    const flags = if (need_slot) 0 else slotFlags(slots[pos].offset.get());
                    slots[pos].offset.set(encodeSlotOffset(@intCast(slot_offset), flags));

                    return buf[0..len];
                }
                return Error.NotEnoughSpace;
            }

            const buf = self.allocateSpace(fix_len);
            self.decreaseFreeEnd(fix_len);

            if (need_slot) {
                self.increaseEntryCount();
                self.expand(pos);
            }

            var slots = self.entriesMut();
            slots[pos].length.set(@as(T, @intCast(len)));
            const flags = if (need_slot) 0 else slotFlags(slots[pos].offset.get());
            slots[pos].offset.set(encodeSlotOffset(self.header().free_end.get(), flags));

            return buf;
        }

        pub fn size(self: *const Self) usize {
            const header_ptr = self.header();
            return @as(usize, @intCast(header_ptr.entry_count.get()));
        }

        pub fn getFlags(self: *const Self, entry: usize) Error!T {
            const slots = self.entries();
            if (entry >= slots.len) {
                return Error.OutOfBounds;
            }
            return slotFlags(slots[entry].offset.get());
        }

        pub fn setFlags(self: *Self, entry: usize, flags: T) Error!void {
            if (read_only) {
                @compileError("Cannot set flags on const buffer");
            }
            const slots = self.entriesMut();
            if (entry >= slots.len) {
                return Error.OutOfBounds;
            }
            slots[entry].offset.set(
                encodeSlotOffset(slotOffset(slots[entry].offset.get()), flags),
            );
        }

        /// Swaps two live directory entries without moving their payload bytes.
        pub fn swapEntries(self: *Self, a: usize, b: usize) Error!void {
            if (read_only) {
                @compileError("Cannot swap entries in const buffer");
            }
            var entries_mut = self.entriesMut();
            if (a >= entries_mut.len or b >= entries_mut.len) {
                return Error.OutOfBounds;
            }
            if (slotOffset(entries_mut[a].offset.get()) == SLOT_INVALID or
                slotOffset(entries_mut[b].offset.get()) == SLOT_INVALID)
            {
                return Error.InvalidIndex;
            }
            if (a == b) {
                return;
            }
            const tmp = entries_mut[a];
            entries_mut[a] = entries_mut[b];
            entries_mut[b] = tmp;
        }

        pub fn entries(self: *const Self) ConstEntrySlice {
            const header_ptr = self.header();
            const first_entry_ptr: [*]const Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            return first_entry_ptr[0..header_ptr.entry_count.get()];
        }

        pub fn entriesMut(self: *Self) EntrySlice {
            if (read_only) {
                @compileError("Cannot get mutable entries from const buffer");
            }
            const header_ptr = self.header();
            const first_entry_ptr: [*]Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            return first_entry_ptr[0..header_ptr.entry_count.get()];
        }

        fn expand(self: *Self, pos: usize) void {
            var slots = self.entriesMut();
            var len = slots.len - 1;
            while (len > pos) : (len -= 1) {
                slots[len] = slots[len - 1];
            }
        }

        fn shrink(self: *Self, pos: usize) Error!void {
            if (pos > self.header().entry_count.get()) {
                return Error.OutOfBounds;
            }
            var slots = self.entriesMut();
            for (pos..slots.len - 1) |i| {
                slots[i] = slots[i + 1];
            }
        }

        // returns buffer body[free_end - len..free_end]
        // it doesn't decrease free_end
        pub fn allocateSpace(self: *Self, len: usize) []u8 {
            const header_ptr = self.header();
            const old_end: usize = @intCast(header_ptr.free_end.get());
            const new_end: usize = old_end - len;
            return self.body[new_end..][0..len];
        }

        fn decreaseFreeEnd(self: *Self, len: usize) void {
            const header_ptr = self.headerMut();
            const shift: T = @intCast(len);
            const old_end = header_ptr.free_end.get();
            header_ptr.free_end.set(old_end - shift);
        }

        // adds an entry at the end of the entries.
        // it doesn't increase entry_count and free_beg
        fn allocateEntry(self: *Self) *Entry {
            const header_ptr = self.headerMut();
            const entry_count = header_ptr.entry_count.get();
            const first_entry_ptr: [*]Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            const new_entry_ptr = &first_entry_ptr[@intCast(entry_count)];
            return new_entry_ptr;
        }

        fn increaseEntryCount(self: *Self) void {
            const header_ptr = self.headerMut();
            const entry_count = header_ptr.entry_count.get();
            const new_free_begin: usize = @sizeOf(Entry) + @as(usize, @intCast(header_ptr.free_begin.get()));
            header_ptr.entry_count.set(entry_count + 1);
            header_ptr.free_begin.set(@as(T, @intCast(new_free_begin)));
            const old_free_end = header_ptr.free_end.get();
            if (old_free_end < new_free_begin) {
                @breakpoint();
            }
        }

        // Free slots management
        fn pushFreeSlot(self: *Self, offset: T, length: T) void {
            if (read_only) {
                @compileError("Cannot push free slot into const buffer");
            }
            var hdr = self.headerMut();
            const freed_head = hdr.freed.get();

            var freed_entry: FreedEntry = .{};
            freed_entry.prev.set(0);
            freed_entry.next.set(freed_head);
            freed_entry.length.set(self.fixLength(length));

            const freed_offset_usize: usize = @intCast(offset);
            const freed_entry_ptr: *FreedEntry = @ptrCast(&self.body[freed_offset_usize]);
            freed_entry_ptr.* = freed_entry;

            if (freed_head != 0) {
                const old_head_ptr: *FreedEntry = @ptrCast(&self.body[@intCast(freed_head)]);
                old_head_ptr.prev.set(offset);
            }

            hdr.freed.set(offset);
        }

        fn popFreeSlot(self: *Self, fs: *const FreedEntry) void {
            if (read_only) {
                @compileError("Cannot pop free slot from const buffer");
            }
            var hdr = self.headerMut();
            const prev = fs.prev.get();
            const next = fs.next.get();
            if (prev != SLOT_INVALID) {
                const prev_ptr: *FreedEntry = @ptrCast(&self.body[@intCast(prev)]);
                prev_ptr.next.set(next);
            } else {
                hdr.freed.set(next);
            }
            if (next != SLOT_INVALID) {
                const next_ptr: *FreedEntry = @ptrCast(&self.body[@intCast(next)]);
                next_ptr.prev.set(prev);
            }
        }

        const FreeSlotInfo = struct {
            ptr: *const FreedEntry,
            offset: T,
        };

        fn findFreeSlot(self: *const Self, needed: T) ?FreeSlotInfo {
            const fixed_len = self.fixLength(needed);
            var current_offset = self.header().freed.get();
            while (current_offset != SLOT_INVALID) {
                const current_ptr: *const FreedEntry = @ptrCast(&self.body[@intCast(current_offset)]);
                const current_len = current_ptr.length.get();
                if (current_len >= fixed_len) {
                    return .{
                        .ptr = current_ptr,
                        .offset = current_offset,
                    };
                }
                current_offset = current_ptr.next.get();
            }
            return null;
        }
    };
}
