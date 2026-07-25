const std = @import("std");
const algo = @import("../core/algorithm.zig");
const errors = @import("../core/errors.zig");
const page = @import("../page/front_coded_block.zig");

pub fn FrontCodedBlock2(
    comptime CountT: type,
    comptime IndexT: type,
    comptime BlockSizeT: type,
    comptime BlockWriterT: type,
    comptime BlockViewT: type,
    comptime endian: std.builtin.Endian,
    comptime cmp: anytype,
    comptime Ctx: type,
) type {
    const PageFrontCodedBlock = page.FrontCodedBlock(
        CountT,
        IndexT,
        BlockSizeT,
        endian,
    );

    const BlockHeader = PageFrontCodedBlock.Header;
    const BlockEntryHeader = PageFrontCodedBlock.EntryHeader;

    const KeyType = []const u8;
    const ValueType = []const u8;
    const BufferType = []u8;

    const EntryImpl = struct {
        const Self = @This();
        pub const Error = errors.SpaceError;
        pub const Index = IndexT;

        entry: ValueType,

        pub fn init(entry: ValueType) Error!Self {
            if (entry.len < @sizeOf(BlockEntryHeader)) {
                return Error.BufferTooSmall;
            }

            const res = Self{
                .entry = entry,
            };

            if (res.size() > entry.len) {
                return Error.BufferTooSmall;
            }

            return res;
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn size(self: *const Self) usize {
            const hdr = self.entryHeader();
            return @sizeOf(BlockEntryHeader) + hdr.suffix_len.get() + hdr.value_len.get();
        }

        pub fn shared(self: *const Self) IndexT {
            return self.entryHeader().shared_len.get();
        }

        pub fn suffix(self: *const Self) []const u8 {
            const key_pos = @sizeOf(BlockEntryHeader);
            const key_len = self.entryHeader().suffix_len.get();
            return self.entry[key_pos .. key_pos + key_len];
        }

        pub fn value(self: *const Self) []const u8 {
            const hdr = self.entryHeader();
            const key_len = hdr.suffix_len.get();
            const value_pos = @sizeOf(BlockEntryHeader) + key_len;
            const value_len = hdr.value_len.get();
            return self.entry[value_pos .. value_pos + value_len];
        }

        fn entryHeader(self: *const Self) *const BlockEntryHeader {
            return @ptrCast(self.entry.ptr);
        }

        pub fn updateKey(self: *const Self, scratch: BufferType) Error!ValueType {
            const cur_suffix = self.suffix();
            const cur_shared = self.shared();
            if (cur_shared > scratch.len) {
                return Error.BufferTooSmall;
            }
            if ((cur_suffix.len + cur_shared) > scratch.len) {
                return Error.BufferTooSmall;
            }
            const new_len = cur_shared + cur_suffix.len;
            const new_tail = scratch[cur_shared..new_len];

            @memcpy(new_tail, cur_suffix);
            return scratch[0..new_len];
        }
    };

    const IteratorImpl = struct {
        const Self = @This();
        pub const BlockView = BlockViewT;

        pub const Error = errors.SpaceError;

        block_view: BlockView,
        current_pos: usize = 0,
        entry_index: usize = 0,
        entry_count: usize = 0,
        used_bytes: usize = 0,
        scratch: BufferType,
        scratch_len: usize = 0,

        // block_view is a full block with the header and all the entries.
        // scratch is a buffer that can be used to store the built entry's key.
        pub fn init(block_view: BlockViewT, scratch: BufferType) Error!Self {
            var res = Self{
                .block_view = block_view,
                .current_pos = @sizeOf(BlockHeader), // first entry starts after the header
                .scratch = scratch,
            };

            const hdr = res.header();
            res.entry_count = hdr.entry_count.get();
            res.used_bytes = hdr.used_bytes.get();

            if (res.used_bytes < @sizeOf(BlockHeader)) {
                return Error.BufferTooSmall;
            }

            if (res.used_bytes > res.block_view.len()) {
                return Error.BufferTooSmall;
            }

            if (res.entry_count == 0) {
                return res;
            }

            const cur = try res.current();
            const new_scratch = try cur.updateKey(res.scratch);
            res.scratch_len = new_scratch.len;

            return res;
        }

        pub fn deinit(self: *Self) void {
            self.block_view.deinit();
        }

        fn header(self: *const Self) *const BlockHeader {
            return @ptrCast(self.block_view.at(0, @sizeOf(BlockHeader)).ptr);
        }

        pub fn done(self: *const Self) bool {
            return self.entry_index >= self.entry_count;
        }

        pub fn scratchKey(self: *const Self) []const u8 {
            return self.scratch[0..self.scratch_len];
        }

        pub fn value(self: *const Self) Error!ValueType {
            const entry = try self.current();
            return entry.value();
        }

        fn current(self: *const Self) Error!EntryImpl {
            if (self.done()) {
                return Error.BufferTooSmall;
            }
            if (self.current_pos >= self.used_bytes) {
                return Error.BufferTooSmall;
            }
            const entry_slice = self.block_view.at(self.current_pos, self.used_bytes - self.current_pos);
            return EntryImpl.init(entry_slice);
        }

        pub fn next(self: *Self) Error!void {
            const entry = try self.current();
            self.current_pos += entry.size();
            self.entry_index += 1;
            if (!self.done()) {
                const cur = try self.current();
                const ns = try cur.updateKey(self.scratch);
                self.scratch_len = ns.len;
            }
        }
    };

    const ReaderImpl = struct {
        const Self = @This();
        pub const BlockView = BlockViewT;
        pub const Error = errors.SpaceError;

        pub const Iterator = IteratorImpl;

        block_view: BlockView,

        pub fn init(block_view: BlockView) Error!Self {
            if (block_view.len() < @sizeOf(BlockHeader)) {
                return Error.BufferTooSmall;
            }

            return .{
                .block_view = block_view,
            };
        }

        pub fn deinit(self: *Self) void {
            self.block_view.deinit();
        }

        pub fn iterator(self: *const Self, scratch: BufferType) Error!IteratorImpl {
            return IteratorImpl.init(self.block_view, scratch);
        }

        fn header(self: *const Self) *const BlockHeader {
            return @ptrCast(self.block_view.at(0, @sizeOf(BlockHeader)).ptr);
        }

        pub fn entryCount(self: *const Self) usize {
            return self.header().entry_count.get();
        }
        pub fn usedBytes(self: *const Self) usize {
            return self.header().used_bytes.get();
        }
        pub fn maxKeyLen(self: *const Self) usize {
            return self.header().max_key_len.get();
        }

        pub fn firstEntry(self: *const Self) []const u8 {
            const entry_ptr: *const BlockEntryHeader = @ptrCast(self.block_view.at(@sizeOf(BlockHeader), @sizeOf(BlockEntryHeader)).ptr);
            const suffix_len = entry_ptr.suffix_len.get();
            const value_len = entry_ptr.value_len.get();
            return @ptrCast(self.block_view.at(@sizeOf(BlockHeader), @sizeOf(BlockEntryHeader) + suffix_len + value_len).ptr);
        }
    };

    const BuilderImpl = struct {
        const Self = @This();
        pub const BlockWriter = BlockWriterT;
        pub const Error = errors.SpaceError;

        block_writer: BlockWriter,
        scratch: BufferType,
        scratch_len: usize = 0,
        ctx: Ctx,

        pub fn initWithContext(block_writer: BlockWriter, scratch: BufferType, ctx: Ctx) Error!Self {
            if (@sizeOf(BlockHeader) > block_writer.remaining()) {
                return Error.BufferTooSmall;
            }

            var res = Self{
                .block_writer = block_writer,
                .scratch = scratch,
                .scratch_len = 0,
                .ctx = ctx,
            };
            errdefer res.deinit();

            try res.block_writer.extend(@sizeOf(BlockHeader));

            const hdr: *BlockHeader = res.headerMut();
            hdr.format();
            hdr.entry_count.set(0);
            hdr.used_bytes.set(0);
            hdr.max_key_len.set(0);

            return res;
        }

        fn appendEntry(self: *Self, shared: IndexT, suffix: KeyType, value: ValueType) Error!void {
            // std.debug.print(
            //     "appendEntry: shared = {}, suffix.len = {s}, value.len = {}\n",
            //     .{ shared, suffix, value.len },
            // );

            const current_used = self.block_writer.used();
            const expected_len = expectedBlockLen(suffix, value);
            if (current_used.len + expected_len > self.block_writer.buf.len) {
                return Error.BufferTooSmall;
            }
            try self.block_writer.extend(expected_len);
            const new_block = self.block_writer.atMut(current_used.len, expected_len);

            const entry_hdr: *BlockEntryHeader = @ptrCast(new_block[0..@sizeOf(BlockEntryHeader)].ptr);
            entry_hdr.format();

            entry_hdr.shared_len.set(@intCast(shared));
            entry_hdr.suffix_len.set(@intCast(suffix.len));
            entry_hdr.value_len.set(@intCast(value.len));

            const value_offset = @sizeOf(BlockEntryHeader) + suffix.len;
            const key_block = new_block[@sizeOf(BlockEntryHeader)..value_offset];

            const value_block = new_block[value_offset .. value_offset + value.len];
            @memcpy(key_block, suffix);
            @memcpy(value_block, value);
        }

        pub fn init(block_writer: BlockWriter, scratch: BufferType) Error!Self {
            if (Ctx != void) {
                @compileError("BuilderImpl: a non-void context requires initWithContext");
            }
            return Self.initWithContext(block_writer, scratch, {});
        }

        pub fn sizeAfterAdd(self: *const Self, key: KeyType, value: ValueType) usize {
            const shared = algo.commonPrefixLength(
                u8,
                self.scratch[0..self.scratch_len],
                key,
                cmp,
                self.ctx,
            ) catch unreachable;
            const suffix = key[shared..];
            return self.block_writer.used().len + expectedBlockLen(suffix, value);
        }

        pub fn canAdd(self: *const Self, key: KeyType, value: ValueType) bool {
            const max_key_len = @max(self.header().max_key_len.get(), key.len);

            if (self.scratch.len < max_key_len) {
                return false;
            }
            const shared = algo.commonPrefixLength(
                u8,
                self.scratch[0..self.scratch_len],
                key,
                cmp,
                self.ctx,
            ) catch unreachable;
            const suffix = key[shared..];
            return self.block_writer.remaining() >= expectedBlockLen(suffix, value);
        }

        pub fn add(self: *Self, key: KeyType, value: ValueType) Error!void {
            const max_key_len = @max(self.header().max_key_len.get(), key.len);

            if (self.scratch.len < max_key_len) {
                return Error.BufferTooSmall;
            }

            const shared = algo.commonPrefixLength(
                u8,
                self.scratch[0..self.scratch_len],
                key,
                cmp,
                self.ctx,
            ) catch unreachable;

            try appendEntry(self, @intCast(shared), key[shared..], value);

            const hdr = self.headerMut();
            const current_entries = hdr.entry_count.get();
            const used_bytes = self.block_writer.used().len;

            hdr.entry_count.set(@intCast(current_entries + 1));
            hdr.used_bytes.set(@intCast(used_bytes));
            hdr.max_key_len.set(@intCast(max_key_len));

            @memcpy(self.scratch[0..key.len], key);
            self.scratch_len = key.len;
        }

        pub fn reader(self: *const Self) Error!ReaderImpl {
            return ReaderImpl.init(BlockViewT.init(self.block_writer.used()));
        }

        pub fn deinit(self: *Self) void {
            self.block_writer.deinit();
        }

        fn header(self: *const Self) *const BlockHeader {
            const ptr = self.block_writer.at(0, @sizeOf(BlockHeader)).ptr;
            const hdr_ptr: *const BlockHeader = @ptrCast(ptr);
            return hdr_ptr;
        }

        fn headerMut(self: *const Self) *BlockHeader {
            const ptr = self.block_writer.atMut(0, @sizeOf(BlockHeader)).ptr;
            const hdr_ptr: *BlockHeader = @ptrCast(ptr);
            return hdr_ptr;
        }

        fn expectedBlockLen(suffix: KeyType, value: ValueType) usize {
            return @sizeOf(BlockEntryHeader) + suffix.len + value.len;
        }
    };

    return struct {
        pub const Header = BlockHeader;
        pub const EntryHeader = BlockEntryHeader;
        pub const Builder = BuilderImpl;
        pub const Reader = ReaderImpl;
    };
}
