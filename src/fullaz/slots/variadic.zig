const std = @import("std");
const WordT = @import("../wordt.zig").WordT;

pub fn Variadic(comptime T: type, comptime Endian: std.builtin.Endian, comptime is_const: bool) type {
    const IndexType = WordT(T, Endian);

    const SLOT_INVALID: T = 0;

    const Entry = extern struct {
        offset: IndexType,
        length: IndexType,
    };

    const FreedEntry = extern struct {
        prev: IndexType,
        next: IndexType,
        lenght: IndexType,
    };

    const EntrySlice = []Entry;
    const EntrySliceConst = []const Entry;

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

    const BufferType = if (is_const) []const u8 else []u8;

    return struct {
        const Self = @This();
        body: BufferType,

        pub fn init(body: if (is_const) []const u8 else []u8) !Self {
            if (body.len < @sizeOf(Header)) {
                return error.BufferTooSmall;
            }
            return .{
                .body = body,
            };
        }

        pub fn formatHeader(self: *Self) void {
            if (is_const) @compileError("Cannot format header on const buffer");
            var header = self.headerMut();
            header.entry_count.set(0);
            header.free_begin.set(@intCast(@sizeOf(Header)));
            header.free_end.set(@intCast(self.body.len));
            header.freed.set(0);
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

        pub fn canInsert(self: *const Self, needed: usize) !bool {
            const space_needed = self.needSpace(needed, true);
            if (space_needed <= self.availableSpace()) {
                return true;
            }
            return space_needed <= try self.availableAfterCompact();
        }

        pub fn canUpdate(self: *const Self, entry: usize, needed: usize) !bool {
            const slots = self.entriesConst();
            if (entry >= slots.len) {
                return error.InvalidEntry;
            }

            const old_payload: T = slots[entry].length.get();
            const old_alloc: usize = @intCast(self.fixLength(old_payload));

            const new_alloc: usize = @intCast(self.fixLength(@intCast(needed)));

            if (new_alloc <= old_alloc) {
                return true;
            }

            const available = self.availableSpace();

            if (available + old_alloc >= new_alloc) {
                return true;
            }

            const available_after_compact = try self.availableAfterCompact();
            return available_after_compact + old_alloc >= new_alloc;
        }

        // pub fn update(self: *Self, pos: usize, data: []const u8) !void {}

        pub fn insertAt(self: *Self, pos: usize, data: []const u8) !Entry {
            if (is_const) @compileError("Cannot insert into const buffer");

            const needed = self.needSpace(data.len);
            if (needed > self.availableSpace()) {
                return error.NotEnoughSpace;
            }

            const entry = try self.allocateEntryAt(pos);

            try self.insertImpl(data, entry);
            return entry.*;
        }

        pub fn insert(self: *Self, data: []const u8) !Entry {
            if (is_const) @compileError("Cannot insert into const buffer");

            const needed = self.needSpace(data.len, true);
            if (needed > self.availableSpace()) {
                return error.NotEnoughSpace;
            }

            const new_entry = self.allocateEntry();

            try self.insertImpl(data, new_entry);
            return new_entry.*;
        }

        pub fn remove(self: *Self, entry: usize) !void {
            if (is_const) @compileError("Cannot remove from const buffer");
            const slots = self.entriesMut();

            if (entry >= slots.len) {
                return error.InvalidEntry;
            }
            var slot = slots[entry];

            std.debug.print("Removing {} {}\n", .{ slot.offset.get(), slot.length.get() });

            const fp = self.formatFreeSlot(&slot);
            try self.shrink(entry);

            var hdr = self.headerMut();
            hdr.entry_count.set(hdr.entry_count.get() - 1);
            hdr.free_begin.set(hdr.free_begin.get() - @as(T, @sizeOf(Entry)));

            try self.pushFreeSlot(&slot, fp);
            // slot.length.set(0);
            // slot.offset.set(SLOT_INVALID);
        }

        pub fn getMutValue(self: *Self, entry: usize) ![]u8 {
            if (is_const) @compileError("Cannot get mutable value from const buffer");
            const slots = self.entriesMut();

            if (entry >= slots.len) {
                return error.InvalidEntry;
            }

            const slot = slots[entry];
            return self.getMutValueByEntry(&slot);
        }

        pub fn getConstValue(self: *const Self, entry: usize) ![]const u8 {
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

        pub fn headerConst(self: *const Self) *const Header {
            return @ptrCast(&self.body[0]);
        }

        pub fn headerMut(self: *Self) *Header {
            if (is_const) @compileError("Cannot get mutable header from const buffer");
            return @ptrCast(&self.body[0]);
        }

        pub fn entriesConst(self: *const Self) EntrySliceConst {
            const header = self.headerConst();
            const first_entry_ptr: [*]const Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            return first_entry_ptr[0..header.entry_count.get()];
        }

        pub fn entriesMut(self: *Self) EntrySlice {
            if (is_const) @compileError("Cannot get mutable entries from const buffer");
            const header = self.headerConst();
            const first_entry_ptr: [*]Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            return first_entry_ptr[0..header.entry_count.get()];
        }

        pub fn compact(self: *Self) !void {
            try self.compactInPlace();
        }

        // private functions can be added here

        // this algorith requires O(n^2) because it doesn't use any place to sort slots
        fn compactInPlace(self: *Self) !void {
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

        fn needSpace(self: *const Self, needed: usize, need_entry: bool) usize {
            const entry_size: usize = if (need_entry) @sizeOf(Entry) else 0;
            return (@intCast(self.fixLength(@intCast(needed)) + entry_size));
        }

        fn getMutValueByEntry(self: *Self, entry: *const Entry) ![]u8 {
            const offset: usize = @intCast(entry.offset.get());
            const length: usize = @intCast(entry.length.get());

            if (offset + length > self.body.len) {
                return error.InvalidEntry;
            }

            return self.body[offset..][0..length];
        }

        fn formatFreeSlot(self: *Self, entry: *const Entry) *FreedEntry {
            const off: usize = @intCast(entry.offset.get());
            var free_header: *FreedEntry = @ptrCast(&self.body[off]);

            free_header.lenght.set(self.fixLength(entry.length.get()));
            free_header.next.set(0);
            free_header.prev.set(0);
            return free_header;
        }

        const FreeSlotInfo = struct {
            ptr: *FreedEntry,
            offset: T,
        };

        pub fn popFreeSlot(self: *Self, size: usize) !?FreeSlotInfo {
            const need: T = @intCast(self.fixLength(@intCast(size)));

            if (try self.findFreeSlotfor(@intCast(need))) |fs_info| {
                const fs = fs_info.ptr;

                try self.splitFreeSlot(&fs_info, size);

                const next = fs.next.get();
                const prev = fs.prev.get();

                if (next != SLOT_INVALID) {
                    var next_fs = try self.getFreeSlotByOffest(next);
                    next_fs.prev = fs.prev;
                }

                if (prev != SLOT_INVALID) {
                    var prev_fs = try self.getFreeSlotByOffest(prev);
                    prev_fs.next = fs.next;
                }

                var hdr = self.headerMut();
                if (fs_info.offset == hdr.freed.get()) {
                    hdr.freed.set(next);
                }

                fs.next.set(SLOT_INVALID);
                fs.prev.set(SLOT_INVALID);

                return fs_info;
            }

            return null;
        }

        pub fn findFreeSlotfor(self: *Self, size: usize) !?FreeSlotInfo {
            const hdr = self.headerMut();
            var current_free = hdr.freed.get();
            while (current_free != SLOT_INVALID) {
                var fs = try self.getFreeSlotByOffest(current_free);
                std.debug.print("fs len: {} -> {}\n", .{ fs.lenght.get(), size });
                if (fs.lenght.get() >= size) {
                    return .{ .ptr = fs, .offset = current_free };
                }
                current_free = fs.next.get();
            }
            return null;
        }

        pub fn splitFreeSlot(self: *Self, fs_info: *const FreeSlotInfo, len: usize) !void {
            var fs = fs_info.ptr;
            const alloc_len: T = self.fixLength(@intCast(len));
            const f_len: usize = @intCast(fs.lenght.get());
            if ((alloc_len + @sizeOf(FreedEntry) <= f_len)) {
                const new_offset: T = fs_info.offset + alloc_len;
                var new_fs = try self.getFreeSlotByOffest(new_offset);
                new_fs.lenght.set(@intCast(f_len - alloc_len));
                new_fs.next.set(fs.next.get());
                new_fs.prev.set(fs_info.offset);

                const next = fs.next.get();
                if (next != SLOT_INVALID) {
                    var next_ptr = try self.getFreeSlotByOffest(next);
                    next_ptr.prev.set(new_offset);
                }

                fs.next.set(new_offset);
                fs.lenght.set(alloc_len);
            }
        }

        fn pushFreeSlot(self: *Self, entry: *const Entry, fs: *FreedEntry) !void {
            var hdr = self.headerMut();

            fs.next = hdr.freed;
            fs.lenght.set(self.fixLength(entry.length.get()));
            fs.prev.set(0);

            const next_offset = hdr.freed.get();
            if (hdr.freed.get() != 0) {
                var next_fs = try self.getFreeSlotByOffest(next_offset);
                next_fs.prev = entry.offset;
            }
            hdr.freed = entry.offset;
        }

        pub fn getFreeSlotByOffest(self: *Self, offset: T) !*FreedEntry {
            if (offset <= self.body.len - @sizeOf(FreedEntry)) {
                return @ptrCast(&self.body[@intCast(offset)]);
            }
            return error.BadOffset;
        }

        fn insertImpl(self: *Self, data: []const u8, entry: *Entry) !void {
            var header = self.headerMut();

            const allocated_len = self.fixLength(@as(T, @intCast(data.len)));

            if (try self.popFreeSlot(allocated_len)) |fs| {
                entry.length.set(@intCast(data.len));
                entry.offset.set(fs.offset);

                const start: usize = @intCast(fs.offset);
                @memcpy(self.body[start..][0..data.len], data);
            } else {
                const new_end = header.free_end.get() - allocated_len;
                const start: usize = @intCast(new_end);
                @memcpy(self.body[start..][0..data.len], data);

                entry.length.set(@intCast(data.len));
                entry.offset.set(new_end);

                header.free_end.set(new_end);
            }
        }

        fn allocateEntry(self: *Self) *Entry {
            const header = self.headerMut();
            const entry_count = header.entry_count.get();
            const first_entry_ptr: [*]Entry = @ptrCast(&self.body[@sizeOf(Header)]);
            const new_entry_ptr = &first_entry_ptr[@intCast(entry_count)];
            header.entry_count.set(entry_count + 1);
            header.free_begin.set(header.free_begin.get() + @as(T, @sizeOf(Entry)));
            return new_entry_ptr;
        }

        fn allocateEntryAt(self: *Self, pos: usize) !*Entry {
            if (pos > self.headerConst().entry_count.get()) {
                return error.InvalidPosition;
            }
            _ = self.allocateEntry();
            var slots = self.entriesMut();
            var len = slots.len - 1;
            while (len > pos) : (len -= 1) {
                slots[len] = slots[len - 1];
            }
            return &slots[pos];
        }

        fn expand(self: *Self, pos: usize) !void {
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

        fn getEntry(self: *const Self, index: usize) ?Entry {
            const entries = self.entriesConst();
            if (index < entries.len) {
                return entries[index];
            }
            return null;
        }
    };
}
