const std = @import("std");
const bpt = @import("../bpt/bpt.zig");
const codec = @import("../codec/codec.zig");
const core = @import("../core/core.zig");
const device = @import("../device/device.zig");
const storage = @import("../storage/storage.zig");
const sstable = @import("sstable.zig");
const Footer = @import("footer.zig").Footer;
const DataPage = @import("data_page.zig").DataPage;
const errors = @import("errors.zig");

const BuildOptions = sstable.BuildOptions;
const Settings = sstable.Settings;

pub fn Writer(
    comptime Format: type,
    comptime LogT: type,
    comptime cmp: anytype,
    comptime CtxT: type,
) type {
    comptime {
        device.interfaces.assertLogDevice(LogT);
        if (LogT.Offset != Format.Offset) {
            @compileError("SSTable Writer LogT.Offset must equal Format.Offset");
        }
    }

    const PackedOffset = core.packed_int.PackedInt(Format.Offset, Format.Endian);

    const ByteCmp = struct {
        fn compare(_: void, a: u8, b: u8) core.algorithm.PartialOrder {
            return core.algorithm.cmpNum({}, a, b);
        }
    };

    const BlockWriter = codec.bounded_buffer.MemoryBlockWriter(u8);
    const BlockView = codec.bounded_buffer.MemoryBlockView(u8);
    const EntryMetadata = sstable.EntryMetadata(Format);

    const CodedBlock = codec.front_coded_block.FrontCodedBlockWithMetadata(
        Format.DataIndex,
        Format.DataIndex,
        Format.DataIndex,
        BlockWriter,
        BlockView,
        Format.Endian,
        true,
        ByteCmp.compare,
        void,
        EntryMetadata.byte_len,
    );

    const MutableDataPage = DataPage(Format).View(false);
    const FooterType = Footer(Format);
    const BloomBits = core.bitset.BitSet(u64, Format.Endian);
    const IndexDevice = device.MemoryBlock(Format.PageId);
    const IndexCache = storage.page_cache.PageCache(IndexDevice);

    const IndexStorage = struct {
        const Self = @This();

        pub const PageId = Format.PageId;
        pub const Error = errors.IndexStorage;
        pub const StateLeaseType = struct {
            const LeaseSelf = @This();

            pub const Error = errors.IndexStorage;

            storage: *Self,
            bytes: [@sizeOf(PageId)]u8,

            pub fn data(self: *const LeaseSelf) errors.IndexStorage![]const u8 {
                return &self.bytes;
            }

            pub fn dataMut(self: *LeaseSelf) errors.IndexStorage![]u8 {
                return &self.bytes;
            }

            pub fn finish(self: *LeaseSelf) void {
                const root = std.mem.readInt(PageId, &self.bytes, .little);
                self.storage.root = if (root == std.math.maxInt(PageId)) null else root;
            }

            pub fn deinit(_: *LeaseSelf) void {}
        };

        root: ?PageId = null,

        pub fn state(self: *Self) Error!StateLeaseType {
            var lease: StateLeaseType = .{
                .storage = self,
                .bytes = undefined,
            };
            std.mem.writeInt(PageId, &lease.bytes, self.root orelse std.math.maxInt(PageId), .little);
            return lease;
        }

        pub fn getRoot(self: *const Self) ?PageId {
            return self.root;
        }
        pub fn setRoot(self: *Self, root: ?PageId) Error!void {
            self.root = root;
        }
        pub fn destroyPage(_: *Self, _: PageId) Error!void {}
    };

    const IndexModel = bpt.models.PagedModel(IndexCache, IndexStorage, cmp, CtxT);
    const IndexTree = bpt.Bpt(IndexModel);
    const Location = extern struct { offset: PackedOffset, length: PackedOffset };

    const IndexState = struct {
        const Self = @This();

        const Error = std.mem.Allocator.Error ||
            IndexDevice.Error ||
            IndexCache.Error ||
            IndexModel.Error;

        device: IndexDevice,
        cache: IndexCache,
        storage: IndexStorage,
        model: IndexModel,
        tree: IndexTree,

        fn init(
            allocator: std.mem.Allocator,
            settings: Settings,
            ctx: CtxT,
        ) Error!*Self {
            const state = try allocator.create(@This());
            errdefer allocator.destroy(state);
            state.device = try IndexDevice.init(allocator, settings.index_page_bytes);
            errdefer state.device.deinit();
            state.cache = try IndexCache.init(&state.device, allocator, 8);
            errdefer state.cache.deinit();
            state.storage = .{};
            state.model = try IndexModel.init(
                &state.cache,
                &state.storage,
                .{
                    .maximum_key_size = settings.max_key_bytes,
                    .maximum_value_size = @sizeOf(Location),
                },
                ctx,
            );
            state.tree = IndexTree.init(&state.model, .force_split);
            return state;
        }
        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.tree.deinit();
            self.model.deinit();
            self.cache.deinit();
            self.device.deinit();
            allocator.destroy(self);
        }
    };
    return struct {
        const Self = @This();

        pub const Error = std.mem.Allocator.Error ||
            LogT.Error ||
            CodedBlock.Builder.Error ||
            DataPage(Format).Error ||
            FooterType.Error ||
            BloomBits.Error ||
            IndexDevice.Error ||
            IndexCache.Error ||
            IndexModel.Error ||
            errors.Writer;

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
        compact_page_bytes: []u8,
        data_page: MutableDataPage,
        index_state: *IndexState,
        bloom_bytes: []u8,
        bloom_bit_count: usize,
        bloom_hash_count: usize,
        data_offset: Format.Offset,
        data_length: Format.Offset = 0,
        data_page_count: Format.DataIndex = 0,
        entry_count: usize = 0,
        min_lsn: Format.Lsn = 0,
        max_lsn: Format.Lsn = 0,
        block_entry_count: usize = 0,
        finished: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            log: *LogT,
            options: BuildOptions,
            ctx: CtxT,
        ) Error!Self {
            try validateOptions(options);

            const bloom_params = core.bloom.Bloom.calculateBloomParams(
                options.entry_count,
                options.settings.bloom_false_positive_rate,
            );

            const bloom_bytes_len = std.math.mul(
                usize,
                bloom_params.bitset_words,
                @sizeOf(u64),
            ) catch return Error.CountOverflow;

            const block_bytes = try allocator.alloc(u8, options.settings.max_coded_block_bytes);
            errdefer allocator.free(block_bytes);

            const block_scratch = try allocator.alloc(u8, options.settings.max_key_bytes);
            errdefer allocator.free(block_scratch);

            const data_page_bytes = try allocator.alloc(u8, options.settings.data_page_bytes);
            errdefer allocator.free(data_page_bytes);

            const compact_page_bytes = try allocator.alloc(u8, options.settings.data_page_bytes);
            errdefer allocator.free(compact_page_bytes);

            const bloom_bytes = try allocator.alloc(u8, bloom_bytes_len);
            errdefer allocator.free(bloom_bytes);
            @memset(bloom_bytes, 0);

            const index_state = try IndexState.init(allocator, options.settings, ctx);
            errdefer index_state.deinit(allocator);

            var data_page = try MutableDataPage.init(data_page_bytes);
            try data_page.format();

            const block_builder = try CodedBlock.Builder.init(
                BlockWriter.init(block_bytes),
                block_scratch,
            );

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
                .compact_page_bytes = compact_page_bytes,
                .data_page = data_page,
                .index_state = index_state,
                .bloom_bytes = bloom_bytes,
                .bloom_bit_count = bloom_params.bitset_bits,
                .bloom_hash_count = bloom_params.hash_count,
                .data_offset = log.size(),
            };
        }

        pub fn add(self: *Self, key: []const u8, value: []const u8) Error!void {
            return self.addWithMetadata(key, value, .{
                .flags = .value,
                .lsn = 0,
            });
        }

        pub fn addWithMetadata(
            self: *Self,
            key: []const u8,
            value: []const u8,
            metadata: EntryMetadata,
        ) Error!void {
            if (self.finished) {
                return Error.Finished;
            }
            if (key.len > self.options.settings.max_key_bytes) {
                return Error.KeyTooLarge;
            }
            if (value.len > self.options.settings.max_value_bytes) {
                return Error.ValueTooLarge;
            }
            if (self.options.enforce_entry_count and self.entry_count >= self.options.entry_count) {
                return Error.EntryCountMismatch;
            }
            if (self.last_key.items.len != 0) {
                const order = cmp(self.ctx, self.last_key.items, key);
                if (order == .eq) {
                    return Error.DuplicateKey;
                }
                if (order != .lt) {
                    return Error.UnorderedKey;
                }
            }
            const metadata_bytes = metadata.toBytes();
            if (!self.block_builder.canAddWithMetadata(key, value, &metadata_bytes) or
                self.block_entry_count >= self.options.settings.max_entries_per_coded_block)
            {
                if (self.block_entry_count == 0) {
                    return Error.DataPageTooSmall;
                }
                try self.sealBlock();
            }
            try self.block_builder.addWithMetadata(key, value, &metadata_bytes);
            if (self.entry_count == 0) {
                self.min_lsn = metadata.lsn;
                self.max_lsn = metadata.lsn;
            } else {
                self.min_lsn = @min(self.min_lsn, metadata.lsn);
                self.max_lsn = @max(self.max_lsn, metadata.lsn);
            }
            self.block_entry_count += 1;
            self.last_key.clearRetainingCapacity();
            try self.last_key.appendSlice(self.allocator, key);
            var bloom = try BloomBits.initMutable(self.bloom_bytes, self.bloom_bit_count);
            core.bloom.add(&bloom, key, self.bloom_hash_count);
            self.entry_count += 1;
        }

        pub fn addTombstone(self: *Self, key: []const u8, lsn: Format.Lsn) Error!void {
            return self.addWithMetadata(key, "", .{
                .flags = .tombstone,
                .lsn = lsn,
            });
        }

        pub fn finish(self: *Self) Error!void {
            if (self.finished) {
                return Error.Finished;
            }
            if (self.entry_count == 0) {
                return Error.EmptyTable;
            }
            if (self.options.enforce_entry_count and self.entry_count != self.options.entry_count) {
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
                .min_lsn = self.min_lsn,
                .max_lsn = self.max_lsn,
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
                .entry_metadata_bytes = EntryMetadata.byte_len,
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
            self.allocator.free(self.compact_page_bytes);
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
            self.block_builder = try CodedBlock.Builder.init(
                BlockWriter.init(self.block_bytes),
                self.block_scratch,
            );
            self.block_entry_count = 0;
        }

        fn flushDataPage(self: *Self) Error!void {
            if (self.data_page.blockCount() == 0) {
                return;
            }
            const offset = self.log.size();
            const encoded_bytes = try self.data_page.encodedBytes();
            const compact_page = self.compact_page_bytes[0..encoded_bytes];
            try self.data_page.copyTo(compact_page);
            try self.log.append(compact_page);
            const packed_location = Location{
                .offset = PackedOffset.init(offset),
                .length = PackedOffset.init(@intCast(compact_page.len)),
            };
            if (!try self.index_state.tree.insert(
                self.data_page_last_key.items,
                std.mem.asBytes(&packed_location),
            )) {
                return Error.DuplicateKey;
            }
            self.data_length = std.math.add(
                Format.Offset,
                self.data_length,
                @intCast(compact_page.len),
            ) catch return Error.CountOverflow;
            self.data_page_count = std.math.add(
                Format.DataIndex,
                self.data_page_count,
                1,
            ) catch return Error.CountOverflow;
        }

        fn writeIndex(self: *Self) Error!struct {
            root_page_id: Format.PageId,
            page_count: Format.PageId,
        } {
            try self.index_state.cache.flushAll();
            const root = self.index_state.storage.getRoot() orelse return Error.EmptyTable;
            const page_count = std.math.cast(
                Format.PageId,
                self.index_state.device.blocksCount(),
            ) orelse return Error.CountOverflow;
            try self.log.append(self.index_state.device.storage.items);
            return .{
                .root_page_id = root,
                .page_count = page_count,
            };
        }
        fn validateOptions(options: BuildOptions) Error!void {
            const settings = options.settings;
            if (options.entry_count == 0 or
                settings.max_entries_per_coded_block == 0 or
                settings.max_coded_block_bytes == 0 or
                settings.data_page_bytes == 0 or
                settings.index_page_bytes < @sizeOf(FooterType.Header) or
                settings.max_key_bytes == 0 or
                settings.max_value_bytes == 0 or
                !(settings.bloom_false_positive_rate > 0 and
                    settings.bloom_false_positive_rate < 1))
            {
                return Error.EmptyTable;
            }
        }
    };
}
