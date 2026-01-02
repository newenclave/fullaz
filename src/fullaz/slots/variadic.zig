const std = @import("std");
const WordT = @import("../wordt.zig").WordT;

pub fn Variadic(comptime T: type, comptime Endian: std.builtin.Endian, comptime is_const: bool) type {
    const IndexType = WordT(T, Endian);

    const Entry = extern struct {
        offset: IndexType,
        length: IndexType,
    };

    const FreedEntry = extern struct {
        next_freed: IndexType,
        lenght: IndexType,
    };

    _ = FreedEntry;

    const EntrySlice = []Entry;
    const EntrySliceConst = []const Entry;

    const Header = extern struct {
        entry_count: IndexType,
        free_begin: IndexType,
        free_end: IndexType,
        freed: IndexType, // first freed offset
    };

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

        pub fn canInsert(self: *const Self, needed: usize) bool {
            return self.needSpace(needed) <= self.availableSpace();
        }

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

            const needed = self.needSpace(data.len);
            if (needed > self.availableSpace()) {
                return error.NotEnoughSpace;
            }

            const new_entry = self.allocateEntry();
            try self.insertImpl(data, new_entry);
            return new_entry.*;
        }

        pub fn getMutValue(self: *Self, entry: usize) !?[]u8 {
            if (is_const) @compileError("Cannot get mutable value from const buffer");
            const slots = self.entriesMut();
            const slot = slots[entry];
            const offset: usize = @intCast(slot.offset.get());
            const length: usize = @intCast(slot.length.get());

            if (offset + length > self.body.len) {
                return error.InvalidEntry;
            }

            std.debug.print("found data at offset: {}, length: {}\n", .{ offset, length });

            return self.body[offset..][0..length];
        }

        pub fn getConstValue(self: *const Self, entry: usize) !?[]const u8 {
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

        // private functions can be added here
        fn needSpace(_: *const Self, needed: usize) usize {
            return (needed + @sizeOf(Entry));
        }

        fn insertImpl(self: *Self, data: []const u8, entry: *Entry) !void {
            var header = self.headerMut();

            const new_end = header.free_end.get() - @as(T, @intCast(data.len));
            const start: usize = @intCast(new_end);
            @memcpy(self.body[start..][0..data.len], data);

            entry.length.set(@intCast(data.len));
            entry.offset.set(new_end);

            std.debug.print("Newend: {}, free_begin: {}, free_end: {}\n", .{ new_end, header.free_begin.get(), header.free_end.get() });

            header.free_end.set(new_end);
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

        fn getSlot(self: *const Self, index: usize) ?Entry {
            const entries = self.entriesConst();
            if (index < entries.len) {
                return entries[index];
            }
            return null;
        }
    };
}
