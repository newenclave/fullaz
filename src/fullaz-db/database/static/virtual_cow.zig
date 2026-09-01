const std = @import("std");
const device_interfaces = @import("fullaz").device.interfaces;
const memory_policy = @import("fullaz").storage.memory_policy;
const page_cache = @import("fullaz").storage.page_cache;
const slot_queue = @import("fullaz").storage.slot_queue;
const virtual_page_map = @import("fullaz").storage.virtual_page_map;
const PackedInt = @import("fullaz").core.packed_int.PackedInt;
const schema_fingerprint = @import("../../component/fingerprint.zig");
const shape = @import("../../component/shape.zig");
const system_kinds = @import("../../file/system_kinds.zig");
const VirtualCowSuperblock = @import("virtual_cow_superblock.zig").VirtualCowSuperblock;

/// A crash-consistent static database using append-only data pages and
/// alternating, checksummed superblock slots instead of a redo WAL.
pub fn VirtualStaticDatabaseWithCow(comptime SchemaT: type, comptime DeviceT: type) type {
    if (!@hasDecl(SchemaT, "PageId") or !@hasDecl(SchemaT, "fields")) {
        @compileError("VirtualStaticDatabaseWithCow requires a pages Schema type");
    }
    comptime shape.assertStaticSchema(SchemaT);
    comptime device_interfaces.assertBlockDevice(DeviceT);
    comptime assertUnsignedInteger(DeviceT.BlockId, "DeviceT.BlockId");
    comptime assertUnsignedInteger(SchemaT.PageId, "SchemaT.PageId");

    const PhysicalPageId = DeviceT.BlockId;
    const VirtualPageId = SchemaT.PageId;
    const PhysicalPool = struct {
        allocator: std.mem.Allocator,
        free_pages: std.ArrayList(PhysicalPageId) = .empty,

        pub const Error = std.mem.Allocator.Error;

        fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *@This()) void {
            self.free_pages.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn take(self: *@This()) ?PhysicalPageId {
            return self.free_pages.pop();
        }

        pub fn put(self: *@This(), page_id: PhysicalPageId) Error!void {
            try self.free_pages.append(self.allocator, page_id);
        }

        fn addSlice(self: *@This(), page_ids: []const PhysicalPageId) Error!void {
            try self.free_pages.appendSlice(self.allocator, page_ids);
        }

        fn remove(self: *@This(), page_id: PhysicalPageId) void {
            for (self.free_pages.items, 0..) |candidate, index| {
                if (candidate == page_id) {
                    _ = self.free_pages.swapRemove(index);
                    return;
                }
            }
            unreachable;
        }
    };
    const RetirementCollector = struct {
        allocator: std.mem.Allocator,
        pending: std.ArrayList(PhysicalPageId) = .empty,
        quarantine: std.ArrayList(PhysicalPageId) = .empty,

        pub const Error = std.mem.Allocator.Error;

        fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *@This()) void {
            self.pending.deinit(self.allocator);
            self.quarantine.deinit(self.allocator);
            self.* = undefined;
        }

        fn begin(self: *@This()) void {
            std.debug.assert(self.pending.items.len == 0);
        }

        fn retire(self: *@This(), page_id: PhysicalPageId) Error!void {
            if (std.mem.indexOfScalar(PhysicalPageId, self.pending.items, page_id) != null) {
                return;
            }
            try self.pending.append(self.allocator, page_id);
        }

        fn discard(self: *@This()) void {
            self.pending.clearRetainingCapacity();
        }
    };
    const RetiringPidPolicy = struct {
        pub const PageId = PhysicalPageId;
        pub const Error = RetirementCollector.Error;
        pub const RemapContextType = *RetirementCollector;

        pub fn init() @This() {
            return .{};
        }

        pub fn prepareRemap(
            _: *@This(),
            collector: RemapContextType,
            old_page_id: PageId,
            _: PageId,
        ) Error!void {
            try collector.retire(old_page_id);
        }

        pub fn discard(_: *@This()) void {}

        pub fn written(_: *@This()) void {}
    };
    const RawCache = page_cache.PageCacheImpl(
        DeviceT,
        memory_policy.DefaultMemoryPolicy,
        @import("fullaz").storage.wal.NoWal,
        RetiringPidPolicy,
    );
    const PhysicalCache = page_cache.ReusablePageCache(RawCache, PhysicalPool);
    const Vpm = virtual_page_map.CowPaged(PhysicalCache, VirtualPageId);
    const VirtualCache = page_cache.VirtualPageCacheImpl(
        PhysicalCache,
        Vpm,
        page_cache.CopyOnWritePolicy,
    );

    const LogicalStore = struct {
        pub const PageId = VirtualPageId;
        pub const Error = error{};

        vpm: *Vpm,
        root: *?PageId,

        pub fn getRoot(self: *const @This()) ?PageId {
            return self.root.*;
        }

        pub fn setRoot(self: *@This(), root: ?PageId) Error!void {
            self.root.* = root;
        }

        pub fn pageCount(self: *const @This()) usize {
            return self.vpm.pageCount();
        }

        pub fn isReserved(_: *const @This(), page_id: PageId) bool {
            return page_id == 0;
        }
    };
    const LogicalCache = page_cache.PersistentReclaimingCache(VirtualCache, LogicalStore);
    const RetiredPage = extern struct {
        generation: PackedInt(u64, .little),
        page_id: PackedInt(PhysicalPageId, .little),
    };
    const RetiredQueueStore = struct {
        pub const PageId = VirtualPageId;
        pub const Size = u64;
        pub const Error = LogicalCache.Error;

        cache: *LogicalCache,
        first: *?PageId,
        last: *?PageId,
        total_size: *Size,

        pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
            return self.cache.free(page_id);
        }

        pub fn getFirst(self: *const @This()) Error!?PageId {
            return self.first.*;
        }

        pub fn setFirst(self: *@This(), page_id: ?PageId) Error!void {
            self.first.* = page_id;
        }

        pub fn getLast(self: *const @This()) Error!?PageId {
            return self.last.*;
        }

        pub fn setLast(self: *@This(), page_id: ?PageId) Error!void {
            self.last.* = page_id;
        }

        pub fn getTotalSize(self: *const @This()) Error!Size {
            return self.total_size.*;
        }

        pub fn setTotalSize(self: *@This(), size: Size) Error!void {
            self.total_size.* = size;
        }
    };
    const RetiredQueue = slot_queue.SlotQueue(LogicalCache, RetiredQueueStore, .little);
    const RetiredQueueState = struct {
        first: ?VirtualPageId,
        last: ?VirtualPageId,
        size: u64,
    };

    const Backend = struct {
        const Self = @This();

        pub const PageId = VirtualPageId;
        pub const CacheType = LogicalCache;

        allocator_value: std.mem.Allocator,
        cache_ptr: *CacheType,

        fn init(allocator_value: std.mem.Allocator, cache_ptr: *CacheType) Self {
            return .{ .allocator_value = allocator_value, .cache_ptr = cache_ptr };
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.allocator_value;
        }

        pub fn cache(self: *Self) *CacheType {
            return self.cache_ptr;
        }

        pub fn cacheConst(self: *const Self) *const CacheType {
            return self.cache_ptr;
        }
    };
    const bindings = shape.bindings(SchemaT, Backend);
    const Components = shape.runtimes(SchemaT, bindings);
    const TransactionStates = shape.transactionStates(SchemaT, bindings);
    const ComponentOptions = shape.initOptions(SchemaT, bindings);
    const Metadata = shape.staticMetadata(SchemaT, bindings);
    const Superblock = VirtualCowSuperblock(Metadata, PhysicalPageId, VirtualPageId);
    const Options = databaseOptions(ComponentOptions);

    const Slot = enum { first, second };

    const Core = struct {
        allocator: std.mem.Allocator,
        device: DeviceT,
        identity: Superblock.Identity,
        raw_cache: RawCache,
        physical_pool: PhysicalPool,
        retirements: RetirementCollector,
        physical_cache: PhysicalCache,
        vpm: Vpm,
        virtual_cache: VirtualCache,
        logical_free_root: ?VirtualPageId,
        logical_store: LogicalStore,
        logical_cache: LogicalCache,
        retired_queue_first: ?VirtualPageId,
        retired_queue_last: ?VirtualPageId,
        retired_queue_size: u64,
        retired_queue_store: RetiredQueueStore,
        retired_queue: RetiredQueue,
        transaction_retired_queue_state: RetiredQueueState,
        promoted_retired_pages: std.ArrayList(PhysicalPageId),
        backend: Backend,
        components: Components,
        transaction_active: bool,
        transaction_generation: u64,
        transaction_cache_batch: LogicalCache.WriteBatch,
        transaction_component_states: TransactionStates,
        active_slot: Slot,
        commit_generation: u64,
        poisoned: bool,
        layers_initialized: bool,
        initialized_components: usize,
    };

    return struct {
        const Self = @This();

        pub const Schema = SchemaT;
        pub const DeviceType = DeviceT;
        pub const RawCacheType = RawCache;
        pub const PhysicalCacheType = PhysicalCache;
        pub const VirtualPageMapType = Vpm;
        pub const CacheType = LogicalCache;
        pub const BackendType = Backend;
        pub const ComponentsStorageType = Components;
        pub const ComponentTransactionStatesType = TransactionStates;
        pub const ComponentInitOptionsType = ComponentOptions;
        pub const MetadataType = Metadata;
        pub const SuperblockType = Superblock;
        pub const InitOptions = Options;
        pub const Error = std.mem.Allocator.Error ||
            DeviceT.Error ||
            RawCache.Error ||
            Vpm.Error ||
            VirtualCache.Error ||
            LogicalCache.Error ||
            RetiredQueue.Error ||
            Superblock.Error ||
            shape.componentErrors(bindings, 0) ||
            shape.staticMetadataErrors(bindings, 0) ||
            error{
                InvalidCacheFrames,
                DeviceNotEmpty,
                InvalidImageId,
                MissingSuperblock,
                InvalidBootstrapPage,
                PageCountMismatch,
                VirtualPageCountMismatch,
                InvalidPlaceholderMapping,
                InvalidRetiredPage,
                RecoveryRequired,
                CommitGenerationExhausted,
            };

        core_: *align(@alignOf(Core)) anyopaque,

        pub const Transaction = struct {
            const TransactionSelf = @This();

            core_: *align(@alignOf(Core)) anyopaque,
            generation_: u64,

            fn corePtr(self: *const TransactionSelf) *Core {
                return @ptrCast(self.core_);
            }

            fn activeCore(self: *const TransactionSelf) Error!*Core {
                const core = self.corePtr();
                if (!core.transaction_active or core.transaction_generation != self.generation_) {
                    return error.TransactionInactive;
                }
                return core;
            }

            pub fn get(self: *TransactionSelf, comptime name: []const u8) proxyType(name) {
                const core = self.activeCore() catch @panic("VirtualStaticDatabaseWithCow transaction is inactive");
                const Binding = bindingType(name);
                return Binding.proxy(&@field(core.components, name));
            }

            pub fn getConst(self: *const TransactionSelf, comptime name: []const u8) *const constProxyType(name) {
                const core = self.activeCore() catch @panic("VirtualStaticDatabaseWithCow transaction is inactive");
                const Binding = bindingType(name);
                return Binding.proxyConst(&@field(core.components, name));
            }

            pub fn commit(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try requireTransactionIdle(core);
                if (core.commit_generation == std.math.maxInt(u64)) {
                    core.poisoned = true;
                    return error.CommitGenerationExhausted;
                }
                try persistRetirements(core, core.commit_generation + 1);
                try core.transaction_cache_batch.commit();
                core.transaction_active = false;
                core.device.sync() catch |err| {
                    core.poisoned = true;
                    return err;
                };
                const next_slot = alternateSlot(core.active_slot);
                writeSuperblock(core, next_slot, core.commit_generation + 1) catch |err| {
                    core.poisoned = true;
                    return err;
                };
                try core.raw_cache.flush(slotPageId(next_slot));
                core.device.sync() catch |err| {
                    core.poisoned = true;
                    return err;
                };
                core.active_slot = next_slot;
                core.commit_generation += 1;
                core.promoted_retired_pages.clearRetainingCapacity();
            }

            pub fn rollback(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try requireTransactionIdle(core);
                core.retired_queue.deinit();
                try core.transaction_cache_batch.discard();
                restoreRetiredQueueState(core);
                try initRetiredQueue(core);
                for (core.promoted_retired_pages.items) |page_id| {
                    core.physical_pool.remove(page_id);
                }
                core.promoted_retired_pages.clearRetainingCapacity();
                core.retirements.discard();
                restoreTransactionStates(core, core.transaction_component_states);
                core.transaction_active = false;
            }

            pub fn deinit(self: *TransactionSelf) void {
                if (self.activeCore()) |_| {
                    self.rollback() catch @panic("Failed to roll back VirtualStaticDatabaseWithCow transaction");
                } else |_| {}
            }
        };

        fn corePtr(self: *Self) *Core {
            return @ptrCast(self.core_);
        }

        fn coreConstPtr(self: *const Self) *const Core {
            return @ptrCast(self.core_);
        }

        fn bindingType(comptime name: []const u8) type {
            return bindings[comptime SchemaT.indexOf(name)];
        }

        fn proxyType(comptime name: []const u8) type {
            return bindingType(name).Proxy;
        }

        fn constProxyType(comptime name: []const u8) type {
            return bindingType(name).ConstProxy;
        }

        fn identity(options: InitOptions) Superblock.Identity {
            return .{
                .image_id = options.image_id,
                .schema_digest = schema_fingerprint.digest(SchemaT),
            };
        }

        fn deinitComponentPrefix(core: *Core, initialized_count: usize) void {
            inline for (0..SchemaT.fields.len) |reverse_index| {
                const index = SchemaT.fields.len - 1 - reverse_index;
                if (index < initialized_count) {
                    const field = SchemaT.fields[index];
                    bindings[index].deinitRuntime(&@field(core.components, field.name));
                }
            }
        }

        fn initComponents(core: *Core, options: InitOptions) Error!void {
            core.components = undefined;
            core.initialized_components = 0;
            errdefer {
                deinitComponentPrefix(core, core.initialized_components);
                core.initialized_components = 0;
            }
            inline for (SchemaT.fields, 0..) |field, index| {
                try bindings[index].initRuntime(
                    &@field(core.components, field.name),
                    &core.backend,
                    field.page_kinds,
                    @field(options.components, field.name),
                );
                core.initialized_components = index + 1;
            }
        }

        fn captureTransactionStates(core: *const Core) TransactionStates {
            var states: TransactionStates = undefined;
            inline for (SchemaT.fields, 0..) |field, index| {
                @field(states, field.name) = bindings[index].captureTransactionState(
                    &@field(core.components, field.name),
                );
            }
            return states;
        }

        fn requireTransactionIdle(core: *const Core) Error!void {
            return shape.requireTransactionIdle(SchemaT, bindings, &core.components);
        }

        fn restoreTransactionStates(core: *Core, states: TransactionStates) void {
            inline for (SchemaT.fields, 0..) |field, index| {
                bindings[index].restoreTransactionState(
                    &@field(core.components, field.name),
                    @field(states, field.name),
                );
            }
        }

        fn slotPageId(slot: Slot) PhysicalPageId {
            return switch (slot) {
                .first => Superblock.first_superblock_page_id,
                .second => Superblock.second_superblock_page_id,
            };
        }

        fn alternateSlot(slot: Slot) Slot {
            return switch (slot) {
                .first => .second,
                .second => .first,
            };
        }

        fn writeSuperblock(core: *Core, slot: Slot, generation: u64) Error!void {
            const snapshot = core.vpm.currentSnapshot();
            var page = try core.raw_cache.fetch(slotPageId(slot));
            defer page.deinit();
            try Superblock.format(
                try page.dataMut(),
                core.device.blockSize(),
                generation,
                core.device.blocksCount(),
                snapshot.root_page_id,
                snapshot.root_level,
                snapshot.next_virtual_page_id,
                core.retired_queue_first,
                core.retired_queue_last,
                core.retired_queue_size,
                core.identity,
                shape.captureStaticMetadata(
                    SchemaT,
                    bindings,
                    Metadata,
                    &core.components,
                    core.logical_store.getRoot(),
                ),
            );
        }

        fn initCore(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            options: InitOptions,
        ) Error!*Core {
            if (options.cache_frames == 0) {
                return error.InvalidCacheFrames;
            }
            if (std.mem.allEqual(u8, &options.image_id, 0)) {
                return error.InvalidImageId;
            }
            const core = try allocator.create(Core);
            errdefer allocator.destroy(core);
            core.allocator = allocator;
            core.device = device_value;
            errdefer core.device.deinit();
            core.identity = identity(options);
            core.raw_cache = try RawCache.init(&core.device, allocator, options.cache_frames);
            errdefer core.raw_cache.deinit();
            core.physical_pool = PhysicalPool.init(allocator);
            errdefer core.physical_pool.deinit();
            core.retirements = RetirementCollector.init(allocator);
            errdefer core.retirements.deinit();
            core.physical_cache = PhysicalCache.init(&core.raw_cache, &core.physical_pool, allocator);
            errdefer core.physical_cache.deinit();
            core.logical_free_root = null;
            core.retired_queue_first = null;
            core.retired_queue_last = null;
            core.retired_queue_size = 0;
            core.transaction_retired_queue_state = .{
                .first = null,
                .last = null,
                .size = 0,
            };
            core.promoted_retired_pages = .empty;
            errdefer core.promoted_retired_pages.deinit(allocator);
            core.transaction_active = false;
            core.transaction_generation = 0;
            core.active_slot = .first;
            core.commit_generation = 0;
            core.poisoned = false;
            core.layers_initialized = false;
            core.initialized_components = 0;
            return core;
        }

        fn initVirtualLayers(core: *Core, snapshot: Vpm.Snapshot) Error!void {
            core.vpm = try Vpm.init(&core.physical_cache, snapshot, &core.retirements);
            errdefer core.vpm.deinit();
            core.virtual_cache = VirtualCache.init(
                &core.physical_cache,
                &core.vpm,
                .init(&core.retirements),
            );
            errdefer core.virtual_cache.deinit();
            core.logical_store = .{ .vpm = &core.vpm, .root = &core.logical_free_root };
            core.logical_cache = LogicalCache.init(&core.virtual_cache, &core.logical_store);
            errdefer core.logical_cache.deinit();
            core.retired_queue_store = .{
                .cache = &core.logical_cache,
                .first = &core.retired_queue_first,
                .last = &core.retired_queue_last,
                .total_size = &core.retired_queue_size,
            };
            try initRetiredQueue(core);
            errdefer core.retired_queue.deinit();
            core.backend = Backend.init(core.allocator, &core.logical_cache);
            core.layers_initialized = true;
        }

        fn deinitCore(core: *Core) void {
            const allocator = core.allocator;
            if (core.layers_initialized) {
                deinitComponentPrefix(core, core.initialized_components);
                core.retired_queue.deinit();
                core.logical_cache.deinit();
                core.virtual_cache.deinit();
                core.vpm.deinit();
            }
            core.physical_cache.deinit();
            core.retirements.deinit();
            core.promoted_retired_pages.deinit(allocator);
            core.physical_pool.deinit();
            core.raw_cache.deinit();
            core.device.deinit();
            allocator.destroy(core);
        }

        fn bootstrapSuperblockPages(core: *Core) Error!void {
            inline for ([_]PhysicalPageId{
                Superblock.first_superblock_page_id,
                Superblock.second_superblock_page_id,
            }) |page_id| {
                var page = try core.raw_cache.create();
                defer page.deinit();
                if (try page.pid() != page_id) {
                    return error.InvalidBootstrapPage;
                }
            }
            try core.raw_cache.flushAll();
            try core.device.sync();
        }

        fn readSuperblock(core: *Core, slot: Slot) Error!Superblock.Storage {
            var page = try core.raw_cache.fetch(slotPageId(slot));
            defer page.deinit();
            return Superblock.read(try page.data(), core.device.blockSize(), core.identity);
        }

        const SelectedSuperblock = struct {
            slot: Slot,
            storage: Superblock.Storage,
            previous: ?Superblock.Storage,
        };

        fn readValidSuperblock(core: *Core, slot: Slot) Error!?Superblock.Storage {
            return readSuperblock(core, slot) catch |err| switch (err) {
                error.BadSuperblock,
                error.UnsupportedVersion,
                => null,
                else => return err,
            };
        }

        fn selectSuperblock(core: *Core) Error!SelectedSuperblock {
            const first = try readValidSuperblock(core, .first);
            const second = try readValidSuperblock(core, .second);
            if (first) |first_storage| {
                if (second) |second_storage| {
                    return if (first_storage.commit_generation.get() >= second_storage.commit_generation.get())
                        .{
                            .slot = .first,
                            .storage = first_storage,
                            .previous = second_storage,
                        }
                    else
                        .{
                            .slot = .second,
                            .storage = second_storage,
                            .previous = first_storage,
                        };
                }
                return .{
                    .slot = .first,
                    .storage = first_storage,
                    .previous = null,
                };
            }
            if (second) |second_storage| {
                return .{
                    .slot = .second,
                    .storage = second_storage,
                    .previous = null,
                };
            }
            return error.MissingSuperblock;
        }

        fn rebuildPhysicalPools(
            core: *Core,
            active: Superblock.Storage,
            previous: ?Superblock.Storage,
        ) Error!void {
            const page_count = core.physical_cache.pageCount();
            const states = try core.allocator.alloc(u8, page_count);
            defer core.allocator.free(states);
            @memset(states, 0);
            const Reachability = struct {
                states: []u8,
                bit: u8,

                fn visit(self: *@This(), page_id: PhysicalPageId) void {
                    self.states[@intCast(page_id)] |= self.bit;
                }
            };
            var active_reachability = Reachability{ .states = states, .bit = 1 };
            try core.vpm.scanSnapshot(
                .{
                    .root_page_id = Superblock.rootPageId(&active),
                    .root_level = active.root_level.get(),
                    .next_virtual_page_id = active.next_virtual_page_id.get(),
                },
                &active_reachability,
                Reachability.visit,
            );
            if (previous) |storage| {
                var previous_reachability = Reachability{ .states = states, .bit = 2 };
                try core.vpm.scanSnapshot(
                    .{
                        .root_page_id = Superblock.rootPageId(&storage),
                        .root_level = storage.root_level.get(),
                        .next_virtual_page_id = storage.next_virtual_page_id.get(),
                    },
                    &previous_reachability,
                    Reachability.visit,
                );
            }
            for (states, 0..) |state, page_index| {
                if (page_index < 2) {
                    continue;
                }
                const page_id: PhysicalPageId = @intCast(page_index);
                switch (state) {
                    0 => try core.physical_pool.put(page_id),
                    2 => try core.retirements.quarantine.append(core.allocator, page_id),
                    1, 3 => {},
                    else => unreachable,
                }
            }
        }

        fn initRetiredQueue(core: *Core) Error!void {
            core.retired_queue = try RetiredQueue.init(
                &core.logical_cache,
                &core.retired_queue_store,
                .{ .chunk_page_kind = system_kinds.retired_page_queue },
            );
        }

        fn restoreRetiredQueueState(core: *Core) void {
            core.retired_queue_first = core.transaction_retired_queue_state.first;
            core.retired_queue_last = core.transaction_retired_queue_state.last;
            core.retired_queue_size = core.transaction_retired_queue_state.size;
        }

        fn parseRetiredPage(bytes: []const u8) Error!RetiredPage {
            if (bytes.len != @sizeOf(RetiredPage)) {
                return error.InvalidRetiredPage;
            }
            var record: RetiredPage = undefined;
            @memcpy(std.mem.asBytes(&record), bytes);
            return record;
        }

        /// Makes pages that are no longer reachable by either superblock slot
        /// available to this transaction, and removes their durable records.
        fn promoteRetiredPages(core: *Core) Error!void {
            while (true) {
                const record = blk: {
                    var front = core.retired_queue.front() catch |err| switch (err) {
                        error.EmptySet => return,
                        else => return err,
                    };
                    defer front.deinit();
                    break :blk try parseRetiredPage(try front.value());
                };
                if (record.generation.get() >= core.commit_generation) {
                    return;
                }
                if (record.page_id.get() < 2 or record.page_id.get() >= core.physical_cache.pageCount()) {
                    return error.InvalidRetiredPage;
                }
                try core.promoted_retired_pages.append(core.allocator, record.page_id.get());
                errdefer _ = core.promoted_retired_pages.pop();
                try core.retired_queue.dequeue();
                try core.physical_pool.put(record.page_id.get());
            }
        }

        /// Queue mutation can fork queue and VPM pages, creating further
        /// retirements. Process the collector to a fixed point before flushing.
        fn persistRetirements(core: *Core, generation: u64) Error!void {
            var index: usize = 0;
            while (index < core.retirements.pending.items.len) : (index += 1) {
                const record = RetiredPage{
                    .generation = .init(generation),
                    .page_id = .init(core.retirements.pending.items[index]),
                };
                try core.retired_queue.enqueue(std.mem.asBytes(&record));
            }
            core.retirements.pending.clearRetainingCapacity();
        }

        /// Formats an empty supplied device. A crash before this function
        /// returns successfully leaves an incomplete image that must be reformatted.
        pub fn format(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            options: InitOptions,
        ) Error!Self {
            var device = device_value;
            var owned = true;
            defer if (owned) {
                device.deinit();
            };
            if (device.blocksCount() != 0) {
                return error.DeviceNotEmpty;
            }
            owned = false;
            const core = try initCore(allocator, device, options);
            errdefer deinitCore(core);
            try bootstrapSuperblockPages(core);
            try initVirtualLayers(core, .{
                .root_page_id = null,
                .root_level = 0,
                .next_virtual_page_id = 0,
            });
            {
                var batch = try core.logical_cache.begin();
                errdefer batch.discard() catch {};
                var placeholder = try core.virtual_cache.create();
                defer placeholder.deinit();
                if (try placeholder.pid() != 0) {
                    return error.InvalidPlaceholderMapping;
                }
                try initComponents(core, options);
                try batch.commit();
            }
            try core.device.sync();
            try writeSuperblock(core, .first, 0);
            try core.raw_cache.flush(slotPageId(.first));
            try core.device.sync();
            try writeSuperblock(core, .second, 0);
            try core.raw_cache.flush(slotPageId(.second));
            try core.device.sync();
            return .{ .core_ = core };
        }

        pub fn open(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            options: InitOptions,
        ) Error!Self {
            var device = device_value;
            var owned = true;
            defer if (owned) {
                device.deinit();
            };
            if (device.blocksCount() < 2) {
                return error.MissingSuperblock;
            }
            owned = false;
            const core = try initCore(allocator, device, options);
            errdefer deinitCore(core);
            const selected = try selectSuperblock(core);
            const storage = selected.storage;
            const physical_page_count = std.math.cast(usize, storage.physical_page_count.get()) orelse return error.PageCountMismatch;
            if (physical_page_count < 2) {
                return error.InvalidBootstrapPage;
            }
            try core.raw_cache.normalizeRecoveredPageCount(physical_page_count);
            const virtual_page_count = std.math.cast(usize, storage.next_virtual_page_id.get()) orelse return error.VirtualPageCountMismatch;
            if (virtual_page_count == 0) {
                return error.InvalidPlaceholderMapping;
            }
            try initVirtualLayers(core, .{
                .root_page_id = Superblock.rootPageId(&storage),
                .root_level = storage.root_level.get(),
                .next_virtual_page_id = storage.next_virtual_page_id.get(),
            });
            if (core.vpm.pageCount() != virtual_page_count or (try core.vpm.get(0)) < 2) {
                return error.InvalidPlaceholderMapping;
            }
            try shape.validateStaticMetadata(SchemaT, bindings, Metadata, &storage.metadata, virtual_page_count);
            try initComponents(core, options);
            core.logical_free_root = shape.restoreStaticMetadata(
                SchemaT,
                bindings,
                Metadata,
                &core.components,
                &storage.metadata,
            );
            try core.logical_cache.validateFreeList();
            core.retired_queue_first = Superblock.retiredQueueFirst(&storage);
            core.retired_queue_last = Superblock.retiredQueueLast(&storage);
            core.retired_queue_size = storage.retired_queue_size.get();
            core.active_slot = selected.slot;
            core.commit_generation = storage.commit_generation.get();
            return .{ .core_ = core };
        }

        pub fn begin(self: *Self) Error!Transaction {
            const core = self.corePtr();
            if (core.poisoned) {
                return error.RecoveryRequired;
            }
            if (core.transaction_active) {
                return error.BatchActive;
            }
            core.transaction_component_states = captureTransactionStates(core);
            core.transaction_retired_queue_state = .{
                .first = core.retired_queue_first,
                .last = core.retired_queue_last,
                .size = core.retired_queue_size,
            };
            core.retirements.begin();
            core.transaction_cache_batch = try core.logical_cache.begin();
            promoteRetiredPages(core) catch |err| {
                core.retired_queue.deinit();
                core.transaction_cache_batch.discard() catch {};
                restoreRetiredQueueState(core);
                initRetiredQueue(core) catch @panic("Failed to restore retired queue after begin failure");
                for (core.promoted_retired_pages.items) |page_id| {
                    core.physical_pool.remove(page_id);
                }
                core.promoted_retired_pages.clearRetainingCapacity();
                core.retirements.discard();
                return err;
            };
            core.transaction_generation +%= 1;
            core.transaction_active = true;
            return .{ .core_ = core, .generation_ = core.transaction_generation };
        }

        pub fn getConst(self: *const Self, comptime name: []const u8) *const constProxyType(name) {
            const Binding = bindingType(name);
            return Binding.proxyConst(&@field(self.coreConstPtr().components, name));
        }

        pub const Diagnostics = struct {
            physical_page_count: usize,
            virtual_page_count: usize,
            logical_free_root: ?VirtualPageId,
            commit_generation: u64,
            active_slot: Slot,
            reused_physical_pages: u64,
            reusable_physical_pages: usize,
            quarantined_physical_pages: usize,
            wal_enabled: bool = false,
        };

        pub fn diagnostics(self: *const Self) Diagnostics {
            const core = self.coreConstPtr();
            return .{
                .physical_page_count = core.device.blocksCount(),
                .virtual_page_count = core.vpm.pageCount(),
                .logical_free_root = core.logical_store.getRoot(),
                .commit_generation = core.commit_generation,
                .active_slot = core.active_slot,
                .reused_physical_pages = core.physical_cache.reusedPageCount(),
                .reusable_physical_pages = core.physical_pool.free_pages.items.len,
                .quarantined_physical_pages = std.math.cast(usize, core.retired_queue_size) orelse std.math.maxInt(usize),
            };
        }

        pub fn deinit(self: *Self) void {
            const core = self.corePtr();
            if (core.transaction_active) {
                @panic("VirtualStaticDatabaseWithCow.deinit called with an active transaction");
            }
            requireTransactionIdle(core) catch
                @panic("VirtualStaticDatabaseWithCow.deinit called with an active value editor");
            deinitCore(core);
            self.* = undefined;
        }
    };
}

fn databaseOptions(comptime ComponentOptionsT: type) type {
    const default_cache_frames: usize = 64;
    const components_default_ptr: ?*const anyopaque = if (shape.canDefaultInit(ComponentOptionsT)) blk: {
        const default_value: ComponentOptionsT = .{};
        break :blk &default_value;
    } else null;
    const names = [_][]const u8{ "image_id", "cache_frames", "components" };
    const types = [_]type{ [16]u8, usize, ComponentOptionsT };
    const attributes = [_]std.builtin.Type.StructField.Attributes{
        .{ .default_value_ptr = &([_]u8{0} ** 16) },
        .{ .default_value_ptr = &default_cache_frames },
        .{ .default_value_ptr = components_default_ptr },
    };
    return @Struct(.auto, null, &names, &types, &attributes);
}

fn assertUnsignedInteger(comptime T: type, comptime name: []const u8) void {
    switch (@typeInfo(T)) {
        .int => |integer| {
            if (integer.signedness != .unsigned) {
                @compileError("VirtualStaticDatabaseWithCow " ++ name ++ " must be unsigned");
            }
        },
        else => @compileError("VirtualStaticDatabaseWithCow " ++ name ++ " must be an integer"),
    }
}
