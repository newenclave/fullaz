const std = @import("std");
const bpt = @import("../bpt/bpt.zig");
const codec = @import("../codec/codec.zig");
const core = @import("../core/core.zig");
const device = @import("../device/device.zig");
const storage = @import("../storage/storage.zig");

pub const interfaces = @import("interfaces.zig");

pub const Footer = @import("footer.zig").Footer;
pub const DataPage = @import("data_page.zig").DataPage;

pub const IndexBackend = enum {
    file,
    memory,
};

pub const Settings = struct {
    max_entries_per_coded_block: usize = 16,
    max_coded_block_bytes: usize = 128 * 1024,
    data_page_bytes: usize = 500 * 1024,
    index_page_bytes: usize = 16 * 1024,
    max_key_bytes: usize = 4 * 1024,
    max_value_bytes: usize = 128 * 1024,
    bloom_false_positive_rate: f64 = 0.01,
};

pub const BuildOptions = struct {
    entry_count: usize,
    comparator_id: u32,
    settings: Settings = .{},
};

pub const OpenOptions = struct {
    comparator_id: u32,
    index_backend: IndexBackend = .file,
};

pub fn SstableFormat(
    comptime OffsetT: type,
    comptime PageIdT: type,
    comptime DataIndexT: type,
    comptime endian: std.builtin.Endian,
) type {
    comptime {
        interfaces.assertUnsignedInt(OffsetT, "OffsetT");
        interfaces.assertUnsignedInt(PageIdT, "PageIdT");
        interfaces.assertUnsignedInt(DataIndexT, "DataIndexT");
    }

    return struct {
        pub const Offset = OffsetT;
        pub const PageId = PageIdT;
        pub const DataIndex = DataIndexT;
        pub const Endian = endian;
    };
}

pub fn Writer(comptime Format: type, comptime LogT: type, comptime cmp: anytype, comptime CtxT: type) type {
    const PackedOffset = core.packed_int.PackedInt(Format.Offset, Format.Endian);
    const ByteCmp = struct {
        fn compare(_: void, a: u8, b: u8) core.algorithm.Order {
            return core.algorithm.cmpNum({}, a, b);
        }
    };
    const BlockWriter = codec.bounded_buffer.MemoryBlockWriter(u8);
    const BlockView = codec.bounded_buffer.MemoryBlockView(u8);
    const CodedBlock = codec.front_coded_block.FrontCodedBlock(
        Format.DataIndex,
        Format.DataIndex,
        Format.DataIndex,
        BlockWriter,
        BlockView,
        Format.Endian,
        true,
        ByteCmp.compare,
        void,
    );
    const MutableDataPage = DataPage(Format).View(false);
    const FooterType = Footer(Format);
    const BloomBits = core.bitset.BitSet(u64, Format.Endian);
    const IndexDevice = device.MemoryBlock(Format.PageId);
    const IndexCache = storage.page_cache.PageCache(IndexDevice);

    const IndexStorage = struct {
        pub const PageId = Format.PageId;
        pub const Error = error{};

        root: ?PageId = null,

        pub fn getRoot(self: *const @This()) ?PageId {
            return self.root;
        }

        pub fn setRoot(self: *@This(), root: ?PageId) Error!void {
            self.root = root;
        }

        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    };
    const IndexModel = bpt.models.PagedModel(IndexCache, IndexStorage, cmp, CtxT);
    const IndexTree = bpt.Bpt(IndexModel);
    const Location = extern struct {
        offset: PackedOffset,
        length: PackedOffset,
    };
    const IndexState = struct {
        device: IndexDevice,
        cache: IndexCache,
        storage: IndexStorage,
        model: IndexModel,
        tree: IndexTree,

        fn init(allocator: std.mem.Allocator, settings: Settings, ctx: CtxT) (std.mem.Allocator.Error || IndexDevice.Error || IndexCache.Error)!*@This() {
            const state = try allocator.create(@This());
            errdefer allocator.destroy(state);

            state.device = try IndexDevice.init(allocator, settings.index_page_bytes);
            errdefer state.device.deinit();
            state.cache = try IndexCache.init(&state.device, allocator, 8);
            errdefer state.cache.deinit();
            state.storage = .{};
            state.model = IndexModel.init(&state.cache, &state.storage, .{
                .maximum_key_size = settings.max_key_bytes,
                .maximum_value_size = @sizeOf(Location),
            }, ctx);
            state.tree = IndexTree.init(&state.model, .force_split);
            return state;
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.tree.deinit();
            IndexModel.deinit();
            self.cache.deinit();
            self.device.deinit();
            allocator.destroy(self);
        }
    };

    return struct {
        const Self = @This();

        pub const Error = std.mem.Allocator.Error || LogT.Error || CodedBlock.Builder.Error || DataPage(Format).Error ||
            FooterType.Error || BloomBits.Error || IndexDevice.Error || IndexCache.Error || IndexModel.Error ||
            error{
                EmptyTable,
                Finished,
                EntryCountMismatch,
                DuplicateKey,
                UnorderedKey,
                KeyTooLarge,
                ValueTooLarge,
                DataPageTooSmall,
                CountOverflow,
            };

        allocator: std.mem.Allocator,
        log: *LogT,
        options: BuildOptions,
        ctx: CtxT,
        block_bytes: []u8,
        block_scratch: []u8,
        block_builder: CodedBlock.Builder,
        last_key: std.ArrayList(u8),
        data_page_last_key: std.ArrayList(u8),
        data_page_bytes: []u8,
        data_page: MutableDataPage,
        index_state: *IndexState,
        bloom_bytes: []u8,
        bloom_bit_count: usize,
        bloom_hash_count: usize,
        data_offset: Format.Offset,
        data_length: Format.Offset = 0,
        data_page_count: Format.DataIndex = 0,
        entry_count: usize = 0,
        block_entry_count: usize = 0,
        finished: bool = false,

        pub fn init(allocator: std.mem.Allocator, log: *LogT, options: BuildOptions, ctx: CtxT) Error!Self {
            try validateOptions(options);
            const bloom_params = core.bloom.Bloom.calculateBloomParams(
                options.entry_count,
                options.settings.bloom_false_positive_rate,
            );
            const bloom_bytes_len = std.math.mul(usize, bloom_params.bitset_words, @sizeOf(u64)) catch return Error.CountOverflow;

            const block_bytes = try allocator.alloc(u8, options.settings.max_coded_block_bytes);
            errdefer allocator.free(block_bytes);
            const block_scratch = try allocator.alloc(u8, options.settings.max_key_bytes);
            errdefer allocator.free(block_scratch);
            const data_page_bytes = try allocator.alloc(u8, options.settings.data_page_bytes);
            errdefer allocator.free(data_page_bytes);
            const bloom_bytes = try allocator.alloc(u8, bloom_bytes_len);
            errdefer allocator.free(bloom_bytes);
            @memset(bloom_bytes, 0);
            const index_state = try IndexState.init(allocator, options.settings, ctx);
            errdefer index_state.deinit(allocator);

            var data_page = try MutableDataPage.init(data_page_bytes);
            try data_page.format();
            const block_builder = try CodedBlock.Builder.init(BlockWriter.init(block_bytes), block_scratch);
            return .{
                .allocator = allocator,
                .log = log,
                .options = options,
                .ctx = ctx,
                .block_bytes = block_bytes,
                .block_scratch = block_scratch,
                .block_builder = block_builder,
                .last_key = .empty,
                .data_page_last_key = .empty,
                .data_page_bytes = data_page_bytes,
                .data_page = data_page,
                .index_state = index_state,
                .bloom_bytes = bloom_bytes,
                .bloom_bit_count = bloom_params.bitset_bits,
                .bloom_hash_count = bloom_params.hash_count,
                .data_offset = log.size(),
            };
        }

        pub fn add(self: *Self, key: []const u8, value: []const u8) Error!void {
            if (self.finished) {
                return Error.Finished;
            }
            if (key.len > self.options.settings.max_key_bytes) {
                return Error.KeyTooLarge;
            }
            if (value.len > self.options.settings.max_value_bytes) {
                return Error.ValueTooLarge;
            }
            if (self.entry_count >= self.options.entry_count) {
                return Error.EntryCountMismatch;
            }
            if (self.last_key.items.len != 0) {
                switch (cmp(self.ctx, self.last_key.items, key)) {
                    .lt => {},
                    .eq => return Error.DuplicateKey,
                    .gt => return Error.UnorderedKey,
                    .unordered => return Error.UnorderedKey,
                }
            }

            if (!self.block_builder.canAdd(key, value) or
                self.block_entry_count >= self.options.settings.max_entries_per_coded_block)
            {
                if (self.block_entry_count == 0) {
                    return Error.DataPageTooSmall;
                }
                try self.sealBlock();
            }
            try self.block_builder.add(key, value);
            self.block_entry_count += 1;
            self.last_key.clearRetainingCapacity();
            try self.last_key.appendSlice(self.allocator, key);
            var bloom = try BloomBits.initMutable(self.bloom_bytes, self.bloom_bit_count);
            core.bloom.add(&bloom, key, self.bloom_hash_count);
            self.entry_count += 1;
        }

        pub fn finish(self: *Self) Error!void {
            if (self.finished) {
                return Error.Finished;
            }
            if (self.entry_count == 0) {
                return Error.EmptyTable;
            }
            if (self.entry_count != self.options.entry_count) {
                return Error.EntryCountMismatch;
            }
            try self.sealBlock();
            try self.flushDataPage();

            const bloom_offset = self.log.size();
            try self.log.append(self.bloom_bytes);
            const index_offset = self.log.size();
            const index = try self.writeIndex();
            const footer_bytes = try self.allocator.alloc(u8, self.options.settings.index_page_bytes);
            defer self.allocator.free(footer_bytes);
            var footer = try FooterType.View(false).init(footer_bytes);
            try footer.format(.{
                .comparator_id = self.options.comparator_id,
                .entry_count = @intCast(self.entry_count),
                .data_offset = self.data_offset,
                .data_length = self.data_length,
                .data_page_count = self.data_page_count,
                .bloom_offset = bloom_offset,
                .bloom_length = @intCast(self.bloom_bytes.len),
                .bloom_bit_count = @intCast(self.bloom_bit_count),
                .bloom_hash_count = @intCast(self.bloom_hash_count),
                .index_offset = index_offset,
                .index_page_size = @intCast(self.options.settings.index_page_bytes),
                .index_page_count = index.page_count,
                .index_root_page_id = index.root_page_id,
                .settings = self.options.settings,
            });
            try self.log.append(footer_bytes);
            var trailer_bytes: [@sizeOf(FooterType.Trailer)]u8 = undefined;
            try FooterType.formatTrailer(&trailer_bytes, footer_bytes.len);
            try self.log.append(&trailer_bytes);
            try self.log.sync();
            self.finished = true;
        }

        pub fn deinit(self: *Self) void {
            self.index_state.deinit(self.allocator);
            self.last_key.deinit(self.allocator);
            self.data_page_last_key.deinit(self.allocator);
            self.block_builder.deinit();
            self.allocator.free(self.block_bytes);
            self.allocator.free(self.block_scratch);
            self.allocator.free(self.data_page_bytes);
            self.allocator.free(self.bloom_bytes);
        }

        fn sealBlock(self: *Self) Error!void {
            if (self.block_entry_count == 0) {
                return;
            }
            const coded_block = self.block_builder.usedBytes();
            if (!self.data_page.canAppend(self.last_key.items, coded_block)) {
                try self.flushDataPage();
                try self.data_page.format();
                if (!self.data_page.canAppend(self.last_key.items, coded_block)) {
                    return Error.DataPageTooSmall;
                }
            }
            try self.data_page.append(self.last_key.items, coded_block);
            self.data_page_last_key.clearRetainingCapacity();
            try self.data_page_last_key.appendSlice(self.allocator, self.last_key.items);
            self.block_builder.deinit();
            self.block_builder = try CodedBlock.Builder.init(BlockWriter.init(self.block_bytes), self.block_scratch);
            self.block_entry_count = 0;
        }

        fn flushDataPage(self: *Self) Error!void {
            if (self.data_page.blockCount() == 0) {
                return;
            }
            const offset = self.log.size();
            try self.log.append(self.data_page_bytes);
            const packed_location = Location{
                .offset = PackedOffset.init(offset),
                .length = PackedOffset.init(@intCast(self.data_page_bytes.len)),
            };
            if (!try self.index_state.tree.insert(self.data_page_last_key.items, std.mem.asBytes(&packed_location))) {
                return Error.DuplicateKey;
            }
            self.data_length = std.math.add(Format.Offset, self.data_length, @intCast(self.data_page_bytes.len)) catch {
                return Error.CountOverflow;
            };
            self.data_page_count = std.math.add(Format.DataIndex, self.data_page_count, 1) catch {
                return Error.CountOverflow;
            };
        }

        fn writeIndex(self: *Self) Error!struct { root_page_id: Format.PageId, page_count: Format.PageId } {
            try self.index_state.cache.flushAll();
            const root = self.index_state.storage.getRoot() orelse return Error.EmptyTable;
            const page_count = std.math.cast(Format.PageId, self.index_state.device.blocksCount()) orelse return Error.CountOverflow;
            try self.log.append(self.index_state.device.storage.items);
            return .{ .root_page_id = root, .page_count = page_count };
        }

        fn validateOptions(options: BuildOptions) Error!void {
            const settings = options.settings;
            if (options.entry_count == 0 or settings.max_entries_per_coded_block == 0 or
                settings.max_coded_block_bytes == 0 or settings.data_page_bytes == 0 or
                settings.index_page_bytes < @sizeOf(FooterType.Header) or settings.max_key_bytes == 0 or
                settings.max_value_bytes == 0 or
                !(settings.bloom_false_positive_rate > 0 and settings.bloom_false_positive_rate < 1))
            {
                return Error.EmptyTable;
            }
        }
    };
}

pub fn Reader(comptime Format: type, comptime LogT: type, comptime cmp: anytype, comptime CtxT: type) type {
    const PackedOffset = core.packed_int.PackedInt(Format.Offset, Format.Endian);
    const BlockView = codec.bounded_buffer.MemoryBlockView(u8);
    const CodedBlock = codec.front_coded_block.FrontCodedBlock(
        Format.DataIndex,
        Format.DataIndex,
        Format.DataIndex,
        codec.bounded_buffer.MemoryBlockWriter(u8),
        BlockView,
        Format.Endian,
        true,
        cmp,
        CtxT,
    );
    const FooterType = Footer(Format);
    const DataPageConst = DataPage(Format).View(true);
    const BloomBits = core.bitset.BitSet(u64, Format.Endian);
    const Location = extern struct { offset: PackedOffset, length: PackedOffset };

    const IndexStorage = struct {
        pub const PageId = Format.PageId;
        pub const Error = error{};
        root: ?PageId,
        pub fn getRoot(self: *const @This()) ?PageId {
            return self.root;
        }
        pub fn setRoot(self: *@This(), root: ?PageId) Error!void {
            self.root = root;
        }
        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    };

    const LogBlock = struct {
        pub const BlockId = Format.PageId;
        pub const Error = LogT.Error ||
            error{
                BadData,
                InvalidId,
                ReadOnly,
            };
        log: *LogT,
        start: Format.Offset,
        block_size: usize,
        block_count: usize,

        pub fn isValidId(self: *const @This(), id: BlockId) bool {
            return @as(usize, @intCast(id)) < self.block_count;
        }
        pub fn isOpen(_: *const @This()) bool {
            return true;
        }
        pub fn blockSize(self: *const @This()) usize {
            return self.block_size;
        }
        pub fn blocksCount(self: *const @This()) usize {
            return self.block_count;
        }
        pub fn readBlock(self: *const @This(), id: BlockId, output: []u8) Error!void {
            if (!self.isValidId(id) or output.len < self.block_size) {
                return Error.InvalidId;
            }
            const relative = std.math.mul(
                Format.Offset,
                @as(Format.Offset, @intCast(id)),
                @as(Format.Offset, @intCast(self.block_size)),
            ) catch return Error.BadData;
            const offset = std.math.add(Format.Offset, self.start, relative) catch return Error.BadData;
            try self.log.readAt(offset, output[0..self.block_size]);
        }
        pub fn writeBlock(_: *@This(), _: BlockId, _: []u8) Error!void {
            return Error.ReadOnly;
        }
        pub fn appendBlock(_: *@This()) Error!BlockId {
            return Error.ReadOnly;
        }
        pub fn truncateBlocks(_: *@This(), _: usize) Error!void {
            return Error.ReadOnly;
        }
        pub fn sync(_: *@This()) Error!void {}
    };
    const MemoryIndexDevice = device.MemoryBlock(Format.PageId);
    const IndexDevice = union(IndexBackend) {
        pub const BlockId = Format.PageId;
        pub const Error = MemoryIndexDevice.Error || LogBlock.Error;
        file: LogBlock,
        memory: MemoryIndexDevice,

        pub fn isValidId(self: *const @This(), id: BlockId) bool {
            return switch (self.*) {
                .memory => |*block| block.isValidId(id),
                .file => |*block| block.isValidId(id),
            };
        }
        pub fn isOpen(self: *const @This()) bool {
            return switch (self.*) {
                .memory => |*block| block.isOpen(),
                .file => |*block| block.isOpen(),
            };
        }
        pub fn blockSize(self: *const @This()) usize {
            return switch (self.*) {
                .memory => |*block| block.blockSize(),
                .file => |*block| block.blockSize(),
            };
        }
        pub fn blocksCount(self: *const @This()) usize {
            return switch (self.*) {
                .memory => |*block| block.blocksCount(),
                .file => |*block| block.blocksCount(),
            };
        }
        pub fn readBlock(self: *const @This(), id: BlockId, output: []u8) Error!void {
            return switch (self.*) {
                .memory => |*block| try block.readBlock(id, output),
                .file => |*block| try block.readBlock(id, output),
            };
        }
        pub fn writeBlock(self: *@This(), id: BlockId, output: []u8) Error!void {
            return switch (self.*) {
                .memory => |*block| try block.writeBlock(id, output),
                .file => |*block| try block.writeBlock(id, output),
            };
        }
        pub fn appendBlock(self: *@This()) Error!BlockId {
            return switch (self.*) {
                .memory => |*block| try block.appendBlock(),
                .file => |*block| try block.appendBlock(),
            };
        }
        pub fn truncateBlocks(self: *@This(), count: usize) Error!void {
            return switch (self.*) {
                .memory => |*block| try block.truncateBlocks(count),
                .file => |*block| try block.truncateBlocks(count),
            };
        }
        pub fn sync(self: *@This()) Error!void {
            return switch (self.*) {
                .memory => |*block| try block.sync(),
                .file => |*block| try block.sync(),
            };
        }
    };
    const IndexCache = storage.page_cache.PageCache(IndexDevice);
    const IndexModel = bpt.models.PagedModel(IndexCache, IndexStorage, cmp, CtxT);
    const IndexTree = bpt.Bpt(IndexModel);
    const IndexState = struct {
        const Self = @This();

        device: IndexDevice,
        cache: IndexCache,
        storage: IndexStorage,
        model: IndexModel,
        tree: IndexTree,

        fn init(
            allocator: std.mem.Allocator,
            index_device: IndexDevice,
            root: Format.PageId,
            settings: Settings,
            ctx: CtxT,
        ) (std.mem.Allocator.Error || IndexCache.Error)!*Self {
            const state = try allocator.create(@This());
            errdefer allocator.destroy(state);
            state.device = index_device;
            state.storage = .{ .root = root };
            state.cache = try IndexCache.init(&state.device, allocator, 8);
            errdefer state.cache.deinit();
            state.model = IndexModel.init(&state.cache, &state.storage, .{
                .maximum_key_size = settings.max_key_bytes,
                .maximum_value_size = @sizeOf(Location),
            }, ctx);
            state.tree = IndexTree.init(&state.model, .force_split);
            return state;
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.tree.deinit();
            IndexModel.deinit();
            self.cache.deinit();
            switch (self.device) {
                .memory => |*memory| memory.deinit(),
                .file => {},
            }
            allocator.destroy(self);
        }
    };

    return struct {
        const Self = @This();
        pub const ReadScratchType = struct { data_page: []u8, key: []u8 };
        pub const Error = std.mem.Allocator.Error || LogT.Error || FooterType.Error || DataPage(Format).Error ||
            CodedBlock.Reader.FindError || BloomBits.Error || MemoryIndexDevice.Error || IndexCache.Error || IndexModel.Error ||
            error{ ComparatorMismatch, BadFileSize, BadIndex, BadScratch };

        allocator: std.mem.Allocator,
        log: *LogT,
        ctx: CtxT,
        footer: FooterType.Info,
        bloom_bytes: []u8,
        index_state: *IndexState,

        pub fn init(allocator: std.mem.Allocator, log: *LogT, options: OpenOptions, ctx: CtxT) Error!Self {
            const total_size = log.size();
            if (total_size < @sizeOf(FooterType.Trailer)) {
                return Error.BadFileSize;
            }
            var trailer_bytes: [@sizeOf(FooterType.Trailer)]u8 = undefined;
            const trailer_offset = std.math.sub(Format.Offset, total_size, @sizeOf(FooterType.Trailer)) catch return Error.BadFileSize;
            try log.readAt(trailer_offset, &trailer_bytes);
            const footer_size = try FooterType.validateTrailer(&trailer_bytes);
            const footer_size_offset = std.math.cast(Format.Offset, footer_size) orelse return Error.BadFileSize;
            const footer_offset = std.math.sub(Format.Offset, trailer_offset, footer_size_offset) catch return Error.BadFileSize;
            const footer_bytes = try allocator.alloc(u8, footer_size);
            defer allocator.free(footer_bytes);
            try log.readAt(footer_offset, footer_bytes);
            const footer = try FooterType.View(true).init(footer_bytes);
            const info = try footer.validate(footer_offset);
            if (info.comparator_id != options.comparator_id) {
                return Error.ComparatorMismatch;
            }
            const bloom_len = std.math.cast(usize, info.bloom_length) orelse return Error.BadFileSize;
            const bloom_bytes = try allocator.alloc(u8, bloom_len);
            errdefer allocator.free(bloom_bytes);
            try log.readAt(info.bloom_offset, bloom_bytes);

            var index_device: IndexDevice = undefined;
            if (options.index_backend == .memory) {
                var memory: ?MemoryIndexDevice = try MemoryIndexDevice.init(allocator, info.settings.index_page_bytes);
                errdefer if (memory) |*owned_memory| {
                    owned_memory.deinit();
                };
                const pages = std.math.cast(usize, info.index_page_count) orelse return Error.BadIndex;
                for (0..pages) |_| {
                    _ = try memory.?.appendBlock();
                }
                try log.readAt(info.index_offset, memory.?.storage.items);
                index_device = .{ .memory = memory.? };
                memory = null;
            } else {
                index_device = .{ .file = .{
                    .log = log,
                    .start = info.index_offset,
                    .block_size = info.settings.index_page_bytes,
                    .block_count = std.math.cast(usize, info.index_page_count) orelse return Error.BadIndex,
                } };
            }
            errdefer switch (index_device) {
                .memory => |*memory| memory.deinit(),
                .file => {},
            };
            const index_state = try IndexState.init(
                allocator,
                index_device,
                info.index_root_page_id,
                info.settings,
                ctx,
            );
            return .{
                .allocator = allocator,
                .log = log,
                .ctx = ctx,
                .footer = info,
                .bloom_bytes = bloom_bytes,
                .index_state = index_state,
            };
        }

        pub fn deinit(self: *Self) void {
            self.index_state.deinit(self.allocator);
            self.allocator.free(self.bloom_bytes);
        }

        pub fn find(self: *Self, key: []const u8, scratch: *ReadScratchType) Error!?[]const u8 {
            if (scratch.data_page.len != self.footer.settings.data_page_bytes or scratch.key.len < self.footer.settings.max_key_bytes) {
                return Error.BadScratch;
            }
            const bloom = try BloomBits.initConst(self.bloom_bytes, @intCast(self.footer.bloom_bit_count));
            if (!core.bloom.mightContain(&bloom, key, self.footer.bloom_hash_count)) {
                return null;
            }
            var iterator = (try self.index_state.tree.lowerBound(key)) orelse return null;
            defer iterator.deinit();
            const entry = (try iterator.get()) orelse (try iterator.next()) orelse return null;
            if (entry.value.len != @sizeOf(Location)) {
                return Error.BadIndex;
            }
            const location: *const Location = @ptrCast(entry.value.ptr);
            const offset = location.offset.get();
            const length = std.math.cast(usize, location.length.get()) orelse return Error.BadIndex;
            if (length != scratch.data_page.len) {
                return Error.BadIndex;
            }
            const data_end = std.math.add(Format.Offset, self.footer.data_offset, self.footer.data_length) catch return Error.BadIndex;
            const length_offset = std.math.cast(Format.Offset, length) orelse return Error.BadIndex;
            const page_end = std.math.add(Format.Offset, offset, length_offset) catch return Error.BadIndex;
            if (offset < self.footer.data_offset or page_end > data_end) {
                return Error.BadIndex;
            }
            try self.log.readAt(offset, scratch.data_page);
            const page = try DataPageConst.init(scratch.data_page);
            try page.validate();
            const block_index = try page.lowerBound(key, cmp, self.ctx);
            if (block_index == page.blockCount()) {
                return null;
            }
            const coded = try page.codedBlock(block_index);
            var coded_reader = try CodedBlock.Reader.init(BlockView.init(coded));
            defer coded_reader.deinit();
            const found = try coded_reader.find(key, scratch.key, cmp, self.ctx) orelse return null;
            return try found.value();
        }
    };
}
