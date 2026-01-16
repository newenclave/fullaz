const std = @import("std");

const PackedInt = @import("../packed_int.zig").PackedInt;

pub fn Variadic(comptime T: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const IndexType = PackedInt(T, Endian);

    const SLOT_INVALID: T = 0;

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
        entry_count: IndexType,
        free_begin: IndexType,
        free_end: IndexType,
        freed: IndexType, // first freed offset
    };

    comptime {
        std.debug.assert(@sizeOf(Header) == @sizeOf(T) * 4);
        std.debug.assert(@offsetOf(Header, "entry_count") == 0);
        std.debug.assert(@offsetOf(Header, "free_begin") == @sizeOf(T));
        std.debug.assert(@offsetOf(Header, "free_end") == @sizeOf(T) * 2);
        std.debug.assert(@offsetOf(Header, "freed") == @sizeOf(T) * 3);
    }

    const BufferType = if (read_only) []const u8 else []u8;

    return struct {
        const Self = @This();

        pub const Entry = EntryHeader;
        pub const EntrySlice = []Entry;
        pub const EntrySliceConst = []const Entry;

        pub const AvailableStatus = enum {
            enough,
            need_compact,
            not_enough,
        };

        body: BufferType,

        pub fn init(body: BufferType) !Self {
            if (body.len < @sizeOf(Header)) {
                return error.BufferTooSmall;
            }
            return .{
                .body = body,
            };
        }

        pub fn formatHeader(self: *Self) void {
            if (read_only) @compileError("Cannot format header on const buffer");
            var header = self.headerMut();
            header.entry_count.set(0);
            header.free_begin.set(@intCast(@sizeOf(Header)));
            header.free_end.set(@intCast(self.body.len));
            header.freed.set(0);
        }

        pub fn capacityFor(self: *const Self, obj_len: usize) usize {
            const total_size = self.body.len - @sizeOf(Header);
            return total_size / (@sizeOf(Entry) + obj_len);
        }

        pub fn availableSpace(self: *const Self) usize {
            const header = self.headerConst();
            const free_begin = header.free_begin.get();
            const free_end = header.free_end.get();
            return @intCast(free_end - free_begin);
        }

        pub fn availableAfterCompact(self: *const Self) !usize {
            const slots = self.entriesConst();
            var used = @sizeOf(Header) + slots.len * @sizeOf(Entry);
            for (slots) |*s| {
                if (s.offset.get() == SLOT_INVALID) {
                    continue;
                }
                const len: T = s.length.get();
                const fixed: T = self.fixLength(len);
                used += @as(usize, fixed);
            }
            if (used > self.body.len) {
                return error.InconsistentLayout;
            }
            return self.body.len - used;
        }

        pub fn getMut(self: *Self, entry: usize) ![]u8 {
            if (read_only) @compileError("Cannot get mutable value from const buffer");
            const slots = self.entriesMut();

            if (entry >= slots.len) {
                return error.InvalidEntry;
            }

            const slot = slots[entry];
            return self.getMutByEntry(&slot);
        }

        pub fn getMutByEntry(self: *Self, slot: *const Entry) ![]u8 {
            if (read_only) @compileError("Cannot get mutable value from const buffer");
            const offset: usize = @intCast(slot.offset.get());
            const length: usize = @intCast(slot.length.get());
            if (offset + length > self.body.len) {
                return error.InvalidEntry;
            }
            return self.body[offset..][0..length];
        }

        pub fn getByEntry(self: *const Self, slot: *const Entry) ![]const u8 {
            const offset: usize = @intCast(slot.offset.get());
            const length: usize = @intCast(slot.length.get());
            if (offset + length > self.body.len) {
                return error.InvalidEntry;
            }
            return self.body[offset..][0..length];
        }

        pub fn get(self: *const Self, entry: usize) ![]const u8 {
            const slots = self.entriesConst();
            if (entry >= slots.len) {
                return error.InvalidEntry;
            }
            const slot = slots[entry];
            const offset: usize = @intCast(slot.offset.get());
            const length: usize = @intCast(slot.length.get());
            if (offset + length > self.body.len) {
                return error.InvalidEntry;
            }
            return self.body[offset..][0..length];
        }

        pub fn free(self: *Self, entry: usize) !void {
            if (read_only) @compileError("Cannot remove from const buffer");
            var slots = self.entriesMut();
            if (entry >= slots.len) {
                return error.InvalidEntry;
            }

            if (slots[entry].offset.get() == SLOT_INVALID) {
                return; // already freed no op
            }

            const slot_offset = slots[entry].offset.get();
            const slot_length = slots[entry].length.get();

            var hdr = self.headerMut();
            if (hdr.free_end.get() == slot_offset) {
                hdr.free_end.set(slot_offset + self.fixLength(slot_length));
            } else {
                self.pushFreeSlot(slots[entry].offset.get(), slots[entry].length.get());
            }

            slots[entry].offset.set(SLOT_INVALID);
            slots[entry].length.set(0);
        }

        pub fn findFreeEntry(self: *const Self) ?usize {
            const slots = self.entriesConst();
            for (slots, 0..) |s, i| {
                if (s.offset.get() == SLOT_INVALID) {
                    return i;
                }
            }
            return null;
        }

        pub fn remove(self: *Self, entry: usize) !void {
            if (read_only) @compileError("Cannot remove from const buffer");
            const slots = self.entriesMut();
            if (entry >= slots.len) {
                return error.InvalidEntry;
            }

            const slot_offset = slots[entry].offset.get();
            const slot_length = slots[entry].length.get();

            var hdr = self.headerMut();
            if (hdr.free_end.get() == slot_offset) {
                hdr.free_end.set(slot_offset + self.fixLength(slot_length));
            } else {
                self.pushFreeSlot(slots[entry].offset.get(), slots[entry].length.get());
            }

            try self.shrink(entry);

            hdr.entry_count.set(hdr.entry_count.get() - 1);
            const old_begin = hdr.free_begin.get();
            const new_begin = old_begin - @as(T, @sizeOf(Entry));
            hdr.free_begin.set(new_begin);
        }

        pub fn canUpdate(self: *const Self, entry: usize, len: usize) !AvailableStatus {
            const fix_len: usize = @as(usize, self.fixLength(@as(T, @intCast(len))));
            const slots = self.entriesConst();
            if (entry >= slots.len) {
                @breakpoint();
                return error.InvalidEntry;
            }

            const old_len = @as(usize, slots[entry].length.get());
            if (len <= old_len) {
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

        pub fn canInsert(self: *const Self, len: usize) !AvailableStatus {
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

        pub fn canMergeWith(self: *const Self, other: *const Self) !AvailableStatus {
            return self.canMergeWithAdditional(other, 0);
        }

        pub fn canMergeWithAdditional(self: *const Self, other: *const Self, add_size: usize) !AvailableStatus {
            const other_slots = other.entriesConst();
            const fixed_add_size = if (add_size == 0) 0 else @as(usize, self.fixLength(@as(T, @intCast(add_size))));
            const full_add_size = (fixed_add_size + @as(usize, if (fixed_add_size == 0) 0 else @sizeOf(Entry)));
            var needed: usize = full_add_size;

            // Add data sizes
            for (other_slots) |*s| {
                if (s.offset.get() != SLOT_INVALID) {
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

        pub fn insert(self: *Self, data: []const u8) !usize {
            if (read_only) @compileError("Cannot insert into const buffer");

            const len = data.len;
            const buf = self.reserveGet(self.entriesConst().len, len) catch |err| {
                return err;
            };
            const buf_fixed = buf[0..len];
            @memcpy(buf_fixed, data);
            return self.entriesConst().len - 1;
        }

        pub fn insertAt(self: *Self, pos: usize, data: []const u8) !void {
            if (read_only) @compileError("Cannot insert into const buffer");

            const len = data.len;
            const buf = self.reserveGet(pos, len) catch |err| {
                return err;
            };
            const buf_fixed = buf[0..len];
            @memcpy(buf_fixed, data);
        }

        // private:

        fn sliceAligned(buf: []u8, n: usize) ?[]T {
            const p_aligned_opt = std.mem.alignPointer(buf.ptr, @alignOf(T));
            if (p_aligned_opt == null) {
                return null;
            }
            const p_aligned = p_aligned_opt.?;

            const skipped = @intFromPtr(p_aligned) - @intFromPtr(buf.ptr);
            if (skipped > buf.len) {
                return null;
            }
            const tail = buf[skipped..];

            const need_bytes = n * @sizeOf(T);
            if (need_bytes > tail.len) {
                return null;
            }

            const p_t: [*]T = @ptrCast(@alignCast(p_aligned));
            return p_t[0..n];
        }

        fn offsetGt(slots: []const Entry, a: T, b: T) bool {
            return slots[b].offset.get() < slots[a].offset.get();
        }

        pub fn compactWithBuffer(self: *Self, raw_buffer: []u8) !void {
            const slots = self.entriesMut();
            if (sliceAligned(raw_buffer, slots.len)) |buffer| {
                var total_elements: usize = 0;
                for (slots, 0..) |*s, idx| {
                    if (s.offset.get() != SLOT_INVALID) {
                        buffer[total_elements] = @intCast(idx);
                        total_elements += 1;
                    }
                }
                const offset_buf = buffer[0..total_elements];
                std.sort.pdq(T, offset_buf, slots, offsetGt);

                var new_end_usize: usize = self.body.len;
                for (offset_buf) |idx| {
                    const uidx: usize = @intCast(idx);
                    const target_len = self.fixLength(slots[uidx].length.get());
                    const old_off = slots[uidx].offset.get();

                    new_end_usize -= target_len;

                    const src = self.body[old_off .. old_off + target_len];
                    const dst = self.body[new_end_usize .. new_end_usize + target_len];

                    @memmove(dst, src);

                    slots[uidx].offset.set(@intCast(new_end_usize));
                }
                self.headerMut().free_end.set(@intCast(new_end_usize));
                self.headerMut().freed.set(0);
            } else {
                return error.BufferTooSmall;
            }
        }

        // compact in place without any extra buffer
        // this call completes in O(n^2) time
        pub fn compactInPlace(self: *Self) !void {
            const slots = self.entriesMut();

            const base_end: T = @intCast(self.body.len);

            const old_data_beg: T = self.headerConst().free_end.get();

            var cursor: T = base_end;
            var free_end: T = base_end;

            while (true) {
                var best_i: ?usize = null;
                var best_off: T = 0;
                var best_len: T = 0;
                var best_flen: T = 0;

                for (slots, 0..) |*s, i| {
                    const off: T = s.offset.get();
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

                slots[best_i.?].offset.set(free_end);
            }

            self.headerMut().free_end.set(free_end);
            self.headerMut().freed.set(0);
        }

        pub fn fixLength(_: Self, len: T) T {
            return if (len < @sizeOf(FreedEntry)) @sizeOf(FreedEntry) else len;
        }

        pub fn headerConst(self: *const Self) *const Header {
            return @ptrCast(&self.body[0]);
        }

        pub fn headerMut(self: *Self) *Header {
            if (read_only) @compileError("Cannot get mutable header from const buffer");
            return @ptrCast(&self.body[0]);
        }

        pub fn resizeGet(self: *Self, pos: usize, len: usize) ![]u8 {
            if (read_only) @compileError("Cannot insert into const buffer");

            if (pos > self.entriesConst().len) {
                return error.InvalidPosition;
            }

            if (len >= self.body.len) {
                return error.NotEnoughSpace;
            }
            const slots = self.entriesMut();
            const old_len = @as(usize, slots[pos].length.get());
            if (len == old_len) {
                const offset: usize = @intCast(slots[pos].offset.get());
                return self.body[offset .. offset + len];
            }

            if (len < old_len) {
                const offset: usize = @intCast(slots[pos].offset.get());
                slots[pos].length.set(@as(T, @intCast(len)));

                const remain_slot_len = old_len - len;
                if (remain_slot_len >= @as(usize, @sizeOf(FreedEntry))) {
                    const new_free_offset = @as(T, @intCast(offset + len));
                    const new_free_length = @as(T, @intCast(remain_slot_len));
                    self.pushFreeSlot(new_free_offset, new_free_length);
                }

                return self.body[offset .. offset + len];
            }

            return self.reserveGetExpand(pos, len, false);
        }

        pub fn reserveGet(self: *Self, pos: usize, len: usize) ![]u8 {
            return self.reserveGetExpand(pos, len, true);
        }

        fn reserveGetExpand(self: *Self, pos: usize, len: usize, need_slot: bool) ![]u8 {
            if (read_only) @compileError("Cannot insert into const buffer");

            if (pos > self.entriesConst().len) {
                return error.InvalidPosition;
            }

            if (len >= self.body.len) {
                return error.NotEnoughSpace;
            }

            const fix_len: usize = @intCast(self.fixLength(@intCast(len)));

            const entry_len: usize = if (need_slot) @sizeOf(Entry) else 0;

            if (fix_len + entry_len > self.availableSpace()) {
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
                    slots[pos].offset.set(@as(T, @intCast(slot_offset)));

                    return buf[0..len];
                }
                return error.NotEnoughSpace;
            }

            const buf = self.allocateSpace(fix_len);
            self.decreaseFreeEnd(fix_len);

            if (need_slot) {
                self.increaseEntryCount();
                self.expand(pos);
            }

            var slots = self.entriesMut();
            slots[pos].length.set(@as(T, @intCast(len)));
            slots[pos].offset.set(self.headerConst().free_end.get());

            return buf;
        }

        pub fn size(self: *const Self) usize {
            const header = self.headerConst();
            return @as(usize, @intCast(header.entry_count.get()));
        }

        pub fn entriesConst(self: *const Self) EntrySliceConst {
            const header = self.headerConst();
            const first_entry_ptr: [*]const Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            return first_entry_ptr[0..header.entry_count.get()];
        }

        pub fn entriesMut(self: *Self) EntrySlice {
            if (read_only) @compileError("Cannot get mutable entries from const buffer");
            const header = self.headerConst();
            const first_entry_ptr: [*]Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            return first_entry_ptr[0..header.entry_count.get()];
        }

        fn expand(self: *Self, pos: usize) void {
            var slots = self.entriesMut();
            var len = slots.len - 1;
            while (len > pos) : (len -= 1) {
                slots[len] = slots[len - 1];
            }
        }

        fn shrink(self: *Self, pos: usize) !void {
            if (pos > self.headerConst().entry_count.get()) {
                return error.InvalidPosition;
            }
            var slots = self.entriesMut();
            for (pos..slots.len - 1) |i| {
                slots[i] = slots[i + 1];
            }
        }

        // returns buffer body[free_end - len..free_end]
        // it doesn't decrease free_end
        pub fn allocateSpace(self: *Self, len: usize) []u8 {
            const header = self.headerConst();
            const old_end: usize = @intCast(header.free_end.get());
            const new_end: usize = old_end - len;
            return self.body[new_end..][0..len];
        }

        fn decreaseFreeEnd(self: *Self, len: usize) void {
            const header = self.headerMut();
            const shift: T = @intCast(len);
            const old_end = header.free_end.get();
            header.free_end.set(old_end - shift);
        }

        // adds an entry at the end of the entries.
        // it doesn't increase entry_count and free_beg
        fn allocateEntry(self: *Self) *Entry {
            const header = self.headerMut();
            const entry_count = header.entry_count.get();
            const first_entry_ptr: [*]Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            const new_entry_ptr = &first_entry_ptr[@intCast(entry_count)];
            return new_entry_ptr;
        }

        fn increaseEntryCount(self: *Self) void {
            const header = self.headerMut();
            const entry_count = header.entry_count.get();
            const new_free_begin: usize = @sizeOf(Entry) + @as(usize, @intCast(header.free_begin.get()));
            header.entry_count.set(entry_count + 1);
            header.free_begin.set(@as(T, @intCast(new_free_begin)));
        }

        // Free slots management
        fn pushFreeSlot(self: *Self, offset: T, length: T) void {
            if (read_only) @compileError("Cannot push free slot into const buffer");
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
            if (read_only) @compileError("Cannot pop free slot from const buffer");
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
            var current_offset = self.headerConst().freed.get();
            while (current_offset != SLOT_INVALID) {
                const current_ptr: *const FreedEntry = @ptrCast(&self.body[@intCast(current_offset)]);
                const current_len = current_ptr.length.get();
                if (current_len >= fixed_len) {
                    return .{ .ptr = current_ptr, .offset = current_offset };
                }
                current_offset = current_ptr.next.get();
            }
            return null;
        }
    };
}
