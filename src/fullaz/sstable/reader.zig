const std = @import("std");
const bpt = @import("../bpt/bpt.zig");
const codec = @import("../codec/codec.zig");
const core = @import("../core/core.zig");
const device = @import("../device/device.zig");
const storage = @import("../storage/storage.zig");
const sstable = @import("sstable.zig");
const Footer = @import("footer.zig").Footer;
const DataPage = @import("data_page.zig").DataPage;
const IndexBackend = sstable.IndexBackend;
const OpenOptions = sstable.OpenOptions;
const Settings = sstable.Settings;
pub fn Reader(
    comptime Format: type,
    comptime LogT: type,
    comptime cmp: anytype,
    comptime CtxT: type,
) type {
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
        pub const Error = LogT.Error || error{ BadData, InvalidId, ReadOnly };
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
        pub fn readBlock(
            self: *const @This(),
            id: BlockId,
            output: []u8,
        ) Error!void {
            if (!self.isValidId(id) or output.len < self.block_size) {
                return Error.InvalidId;
            }
            const relative = std.math.mul(
                Format.Offset,
                @as(Format.Offset, @intCast(id)),
                @as(Format.Offset, @intCast(self.block_size)),
            ) catch return Error.BadData;
            const offset = std.math.add(
                Format.Offset,
                self.start,
                relative,
            ) catch return Error.BadData;
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
                .memory => |*b| b.isValidId(id),
                .file => |*b| b.isValidId(id),
            };
        }
        pub fn isOpen(self: *const @This()) bool {
            return switch (self.*) {
                .memory => |*b| b.isOpen(),
                .file => |*b| b.isOpen(),
            };
        }
        pub fn blockSize(self: *const @This()) usize {
            return switch (self.*) {
                .memory => |*b| b.blockSize(),
                .file => |*b| b.blockSize(),
            };
        }
        pub fn blocksCount(self: *const @This()) usize {
            return switch (self.*) {
                .memory => |*b| b.blocksCount(),
                .file => |*b| b.blocksCount(),
            };
        }
        pub fn readBlock(self: *const @This(), id: BlockId, output: []u8) Error!void {
            return switch (self.*) {
                .memory => |*b| try b.readBlock(id, output),
                .file => |*b| try b.readBlock(id, output),
            };
        }
        pub fn writeBlock(self: *@This(), id: BlockId, output: []u8) Error!void {
            return switch (self.*) {
                .memory => |*b| try b.writeBlock(id, output),
                .file => |*b| try b.writeBlock(id, output),
            };
        }
        pub fn appendBlock(self: *@This()) Error!BlockId {
            return switch (self.*) {
                .memory => |*b| try b.appendBlock(),
                .file => |*b| try b.appendBlock(),
            };
        }
        pub fn truncateBlocks(self: *@This(), count: usize) Error!void {
            return switch (self.*) {
                .memory => |*b| try b.truncateBlocks(count),
                .file => |*b| try b.truncateBlocks(count),
            };
        }
        pub fn sync(self: *@This()) Error!void {
            return switch (self.*) {
                .memory => |*b| try b.sync(),
                .file => |*b| try b.sync(),
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
            state.model = IndexModel.init(
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
        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.tree.deinit();
            IndexModel.deinit();
            self.cache.deinit();
            switch (self.device) {
                .memory => |*memory| {
                    memory.deinit();
                },
                .file => {},
            }
            allocator.destroy(self);
        }
    };
    return struct {
        const Self = @This();
        pub const ReadScratchType = struct {
            data_page: []u8,
            key: []u8,
        };
        pub const Error = std.mem.Allocator.Error ||
            LogT.Error ||
            FooterType.Error ||
            DataPage(Format).Error ||
            CodedBlock.Reader.FindError ||
            BloomBits.Error ||
            MemoryIndexDevice.Error ||
            IndexCache.Error ||
            IndexModel.Error ||
            error{
                ComparatorMismatch,
                BadFileSize,
                BadIndex,
                BadScratch,
            };
        allocator: std.mem.Allocator,
        log: *LogT,
        ctx: CtxT,
        footer: FooterType.Info,
        bloom_bytes: []u8,
        index_state: *IndexState,
        pub fn init(
            allocator: std.mem.Allocator,
            log: *LogT,
            options: OpenOptions,
            ctx: CtxT,
        ) Error!Self {
            const total_size = log.size();
            if (total_size < @sizeOf(FooterType.Trailer)) {
                return Error.BadFileSize;
            }
            var trailer_bytes: [@sizeOf(FooterType.Trailer)]u8 = undefined;
            const trailer_offset = std.math.sub(
                Format.Offset,
                total_size,
                @sizeOf(FooterType.Trailer),
            ) catch return Error.BadFileSize;
            try log.readAt(trailer_offset, &trailer_bytes);
            const footer_size = try FooterType.validateTrailer(&trailer_bytes);
            const footer_size_offset = std.math.cast(
                Format.Offset,
                footer_size,
            ) orelse return Error.BadFileSize;
            const footer_offset = std.math.sub(
                Format.Offset,
                trailer_offset,
                footer_size_offset,
            ) catch return Error.BadFileSize;
            const footer_bytes = try allocator.alloc(u8, footer_size);
            defer allocator.free(footer_bytes);
            try log.readAt(footer_offset, footer_bytes);
            const footer = try FooterType.View(true).init(footer_bytes);
            const info = try footer.validate(footer_offset);
            if (info.comparator_id != options.comparator_id) {
                return Error.ComparatorMismatch;
            }
            const bloom_len = std.math.cast(
                usize,
                info.bloom_length,
            ) orelse return Error.BadFileSize;
            const bloom_bytes = try allocator.alloc(u8, bloom_len);
            errdefer allocator.free(bloom_bytes);
            try log.readAt(info.bloom_offset, bloom_bytes);
            var index_device: IndexDevice = undefined;
            if (options.index_backend == .memory) {
                var memory: ?MemoryIndexDevice = try MemoryIndexDevice.init(allocator, info.settings.index_page_bytes);
                errdefer if (memory) |*owned_memory| {
                    owned_memory.deinit();
                };
                const pages = std.math.cast(
                    usize,
                    info.index_page_count,
                ) orelse return Error.BadIndex;
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
                    .block_count = std.math.cast(
                        usize,
                        info.index_page_count,
                    ) orelse return Error.BadIndex,
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
        pub fn find(
            self: *Self,
            key: []const u8,
            scratch: *ReadScratchType,
        ) Error!?[]const u8 {
            if (scratch.data_page.len != self.footer.settings.data_page_bytes or
                scratch.key.len < self.footer.settings.max_key_bytes)
            {
                return Error.BadScratch;
            }
            const bloom = try BloomBits.initConst(
                self.bloom_bytes,
                @intCast(self.footer.bloom_bit_count),
            );
            if (!core.bloom.mightContain(
                &bloom,
                key,
                self.footer.bloom_hash_count,
            )) {
                return null;
            }
            var iterator = (try self.index_state.tree.lowerBound(key)) orelse return null;
            defer iterator.deinit();
            const entry = (try iterator.get()) orelse
                (try iterator.next()) orelse
                return null;
            if (entry.value.len != @sizeOf(Location)) {
                return Error.BadIndex;
            }
            const location: *const Location = @ptrCast(entry.value.ptr);
            const offset = location.offset.get();
            const length = std.math.cast(
                usize,
                location.length.get(),
            ) orelse return Error.BadIndex;
            if (length != scratch.data_page.len) {
                return Error.BadIndex;
            }
            const data_end = std.math.add(
                Format.Offset,
                self.footer.data_offset,
                self.footer.data_length,
            ) catch return Error.BadIndex;
            const length_offset = std.math.cast(
                Format.Offset,
                length,
            ) orelse return Error.BadIndex;
            const page_end = std.math.add(
                Format.Offset,
                offset,
                length_offset,
            ) catch return Error.BadIndex;
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
            const found = try coded_reader.find(
                key,
                scratch.key,
                cmp,
                self.ctx,
            ) orelse return null;
            return try found.value();
        }
    };
}
