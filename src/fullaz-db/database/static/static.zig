const std = @import("std");
const device_interfaces = @import("fullaz").device.interfaces;
const page_cache = @import("fullaz").storage.page_cache;
const gc = @import("fullaz").gc;
const StaticDatabaseCommon = @import("common.zig").StaticDatabaseCommon;
const component = @import("../../component/component.zig");
const schema_fingerprint = @import("../../component/fingerprint.zig");
const shape = @import("../../component/shape.zig");

/// A page-zero-superblock database that owns the supplied block device.
pub fn StaticDatabase(comptime SchemaT: type, comptime DeviceT: type) type {
    if (!@hasDecl(SchemaT, "PageId") or !@hasDecl(SchemaT, "fields")) {
        @compileError("StaticDatabase requires a pages Schema type");
    }
    comptime shape.assertStaticSchema(SchemaT);
    comptime device_interfaces.assertBlockDevice(DeviceT);
    if (DeviceT.BlockId != SchemaT.PageId) {
        @compileError("StaticDatabase DeviceT.BlockId must match SchemaT.PageId");
    }

    const RawCache = page_cache.PageCache(DeviceT);
    const Common = StaticDatabaseCommon(SchemaT, DeviceT, RawCache);
    const Store = Common.StoreType;
    const Cache = Common.CacheType;
    const Backend = Common.BackendType;
    const bindings = Common.Bindings;
    const Components = Common.ComponentsType;
    const TransactionStates = Common.TransactionStatesType;
    const ComponentOptions = Common.ComponentOptionsType;
    const Metadata = Common.MetadataType;
    const Superblock = Common.SuperblockType;
    const Options = Common.InitOptions;
    const GcState = gc.models.paged.State(SchemaT.PageId);
    const GcStore = struct {
        pub const PageId = SchemaT.PageId;
        pub const Error = Cache.Error;
        pub const StateLeaseType = struct {
            pub const Error = error{};
            value: *GcState,
            pub fn data(self: *const @This()) @This().Error![]const u8 {
                return std.mem.asBytes(@as(*const GcState, self.value));
            }
            pub fn dataMut(self: *@This()) @This().Error![]u8 {
                return std.mem.asBytes(self.value);
            }
            pub fn finish(_: *@This()) void {}
            pub fn deinit(_: *@This()) void {}
        };
        state_value: *GcState,
        cache: *Cache,
        pub fn state(self: *@This()) Error!StateLeaseType {
            return .{ .value = self.state_value };
        }
        pub fn isReserved(_: *const @This(), page_id: PageId) bool {
            return page_id == 0;
        }
        pub fn isFree(self: *const @This(), page_id: PageId) Error!bool {
            return @constCast(self.cache).isFree(page_id);
        }
        pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
            return self.cache.free(page_id);
        }
    };
    const GcModel = gc.models.PagedWithKinds(Cache, GcStore, 0x0008, 0x0009, 0x000a, 0x000b);
    const GcCollector = gc.Gc(GcModel);
    const Core = struct {
        allocator: std.mem.Allocator,
        device: DeviceT,
        identity: Superblock.Identity,
        raw_cache: RawCache,
        store: Store,
        cache: Cache,
        backend: Backend,
        components: Components,
        gc_state: GcState,
        gc_cycle_active: bool,
        transaction_active: bool,
        transaction_generation: u64,
        transaction_cache_batch: Cache.WriteBatch,
        transaction_component_states: TransactionStates,
        transaction_gc_state: GcState,
        transaction_gc_cycle_active: bool,
    };

    return struct {
        const Self = @This();

        pub const Schema = SchemaT;
        pub const DeviceType = DeviceT;
        pub const RawCacheType = RawCache;
        pub const CacheType = Cache;
        pub const BackendType = Backend;
        pub const ComponentsStorageType = Components;
        pub const ComponentTransactionStatesType = TransactionStates;
        pub const ComponentInitOptionsType = ComponentOptions;
        pub const MetadataType = Metadata;
        pub const SuperblockType = Superblock;
        pub const GcCollectorType = GcCollector;
        pub const InitOptions = Options;
        pub const Error = DeviceT.Error ||
            RawCache.Error ||
            Cache.Error ||
            Superblock.Error ||
            GcCollector.Error ||
            shape.componentErrors(bindings, 0) ||
            shape.staticMetadataErrors(bindings, 0) ||
            error{
                InvalidCacheFrames,
                DeviceNotEmpty,
                InvalidImageId,
                MissingSuperblock,
                PageCountMismatch,
                DirtyDatabase,
                InvalidSuperblockPage,
                GarbageCollectionActive,
                BadGcState,
            };

        core_: *align(@alignOf(Core)) anyopaque,

        pub const GcSession = struct {
            raw: Transaction,
            store: GcStore = undefined,
            model: GcModel = undefined,
            collector_state: GcCollector = undefined,
            initialized: bool = false,
            active: bool = true,
            const SessionSelf = @This();
            const SessionError = Self.Error || GcCollector.Error;
            fn corePtr(self: *const SessionSelf) *Core {
                return self.raw.corePtr();
            }
            fn collector(self: *SessionSelf) SessionError!*GcCollector {
                if (!self.initialized) {
                    const core = self.corePtr();
                    self.store = .{ .state_value = &core.gc_state, .cache = &core.cache };
                    self.model = try GcModel.init(core.allocator, &core.cache, &self.store);
                    self.collector_state = GcCollector.init(&self.model);
                    self.initialized = true;
                }
                return &self.collector_state;
            }
            fn start(self: *SessionSelf, roots: []const SchemaT.PageId) SessionError!void {
                const core = self.corePtr();
                if (core.gc_cycle_active) return error.GarbageCollectionActive;
                try (try self.collector()).start(roots);
                core.gc_cycle_active = true;
            }
            fn step(self: *SessionSelf, maximum_pages: usize) SessionError!gc.StepStatus {
                const core = self.corePtr();
                if (!core.gc_cycle_active) return error.BadGcState;
                const status = try (try self.collector()).step(maximum_pages);
                if (status == .complete) core.gc_cycle_active = false;
                return status;
            }
            fn phase(self: *SessionSelf) SessionError!gc.Phase {
                _ = try self.collector();
                return self.model.phase();
            }
            fn abort(self: *SessionSelf) SessionError!void {
                const core = self.corePtr();
                if (!core.gc_cycle_active) return error.BadGcState;
                try (try self.collector()).abortCycle();
                core.gc_cycle_active = false;
            }
            fn deinitCollector(self: *SessionSelf) void {
                if (self.initialized) {
                    self.collector_state.deinit();
                    self.model.deinit();
                    self.initialized = false;
                }
            }
            fn commit(self: *SessionSelf) SessionError!void {
                self.deinitCollector();
                try self.raw.commit();
                self.active = false;
            }
            fn rollback(self: *SessionSelf) SessionError!void {
                self.deinitCollector();
                try self.raw.rollback();
                self.active = false;
            }
            fn deinit(self: *SessionSelf) void {
                if (self.active) self.rollback() catch @panic("StaticDatabase GC session rollback failed");
                self.* = undefined;
            }
        };

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
                    return Error.TransactionInactive;
                }
                return core;
            }

            pub fn get(self: *TransactionSelf, comptime name: []const u8) proxyType(name) {
                const core = self.activeCore() catch @panic("StaticDatabase transaction is inactive");
                const Binding = bindingType(name);
                return Binding.proxy(&@field(core.components, name));
            }

            pub fn getConst(self: *const TransactionSelf, comptime name: []const u8) *const constProxyType(name) {
                const core = self.activeCore() catch @panic("StaticDatabase transaction is inactive");
                const Binding = bindingType(name);
                return Binding.proxyConst(&@field(core.components, name));
            }

            /// Recursively reclaims pages owned by a component while retaining
            /// its fixed schema slot for subsequent reuse.
            pub fn reclaim(self: *TransactionSelf, comptime name: []const u8) Error!void {
                const core = try self.activeCore();
                const Binding = bindingType(name);
                comptime component.assertReclamation(Binding);
                try requireTransactionIdle(core);
                var mutated = false;
                errdefer if (mutated) {
                    core.cache.markTransactionFailed();
                };
                mutated = true;
                try Binding.reclaimPersistent(&@field(core.components, name));
            }

            pub fn commit(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try requireTransactionIdle(core);
                try writeSuperblock(core, true);
                try core.transaction_cache_batch.commit();
                try core.device.sync();
                core.transaction_active = false;
            }

            pub fn rollback(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try requireTransactionIdle(core);
                try core.transaction_cache_batch.discard();
                restoreTransactionStates(core, core.transaction_component_states);
                core.gc_state = core.transaction_gc_state;
                core.gc_cycle_active = core.transaction_gc_cycle_active;
                try writeSuperblock(core, true);
                try core.raw_cache.flush(0);
                try core.device.sync();
                core.transaction_active = false;
            }

            pub fn deinit(self: *TransactionSelf) void {
                if (self.activeCore()) |_| {
                    self.rollback() catch @panic("Failed to roll back StaticDatabase transaction");
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

        fn runtimeType(comptime name: []const u8) type {
            return bindingType(name).Runtime;
        }

        fn proxyType(comptime name: []const u8) type {
            return bindingType(name).Proxy;
        }

        fn constProxyType(comptime name: []const u8) type {
            return bindingType(name).ConstProxy;
        }

        fn identity(options: InitOptions) Superblock.Identity {
            return .{ .image_id = options.image_id, .schema_digest = schema_fingerprint.digest(SchemaT) };
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
            var initialized_count: usize = 0;
            errdefer deinitComponentPrefix(core, initialized_count);
            inline for (SchemaT.fields, 0..) |field, index| {
                try bindings[index].initRuntime(
                    &@field(core.components, field.name),
                    &core.backend,
                    field.page_kinds,
                    @field(options.components, field.name),
                );
                initialized_count = index + 1;
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

        fn restoreTransactionStates(core: *Core, states: TransactionStates) void {
            inline for (SchemaT.fields, 0..) |field, index| {
                bindings[index].restoreTransactionState(
                    &@field(core.components, field.name),
                    @field(states, field.name),
                );
            }
        }

        fn requireTransactionIdle(core: *const Core) Error!void {
            return shape.requireTransactionIdle(SchemaT, bindings, &core.components);
        }

        fn freeRoot(core: *const Core) ?SchemaT.PageId {
            const root = core.store.state_value.root;
            return if (root.isMax()) null else root.get();
        }

        fn writeSuperblock(core: *Core, clean: bool) Error!void {
            var page = try core.raw_cache.fetch(0);
            defer page.deinit();
            try Superblock.format(
                try page.dataMut(),
                core.device.blockSize(),
                core.device.blocksCount(),
                core.identity,
                shape.captureStaticMetadata(SchemaT, bindings, Metadata, &core.components, freeRoot(core), core.gc_state, core.gc_cycle_active),
                clean,
            );
        }

        fn initCore(allocator: std.mem.Allocator, device_value: DeviceT, options: InitOptions) Error!*Core {
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
            core.store = .{ .device = &core.device };
            core.cache = Cache.init(&core.raw_cache, &core.store);
            errdefer core.cache.deinit();
            core.backend = Common.initBackend(allocator, &core.cache);
            core.transaction_active = false;
            core.transaction_generation = 0;
            core.gc_state = .{};
            core.gc_cycle_active = false;
            return core;
        }

        /// Formats an empty supplied device and takes ownership of it on success.
        pub fn format(allocator: std.mem.Allocator, device_value: DeviceT, options: InitOptions) Error!Self {
            if (device_value.blocksCount() != 0) {
                return error.DeviceNotEmpty;
            }
            const core = try initCore(allocator, device_value, options);
            errdefer {
                core.cache.deinit();
                core.raw_cache.deinit();
                core.device.deinit();
                allocator.destroy(core);
            }
            try initComponents(core, options);
            errdefer deinitComponentPrefix(core, SchemaT.fields.len);
            {
                var superblock_page = try core.raw_cache.create();
                defer superblock_page.deinit();
                if (try superblock_page.pid() != 0) {
                    return error.InvalidSuperblockPage;
                }
                try Superblock.format(
                    try superblock_page.dataMut(),
                    core.device.blockSize(),
                    core.device.blocksCount(),
                    core.identity,
                    shape.captureStaticMetadata(SchemaT, bindings, Metadata, &core.components, null, .{}, false),
                    true,
                );
            }
            try core.raw_cache.flushAll();
            try core.device.sync();
            return .{ .core_ = core };
        }

        /// Opens an existing database and takes ownership of the supplied device on success.
        pub fn open(allocator: std.mem.Allocator, device_value: DeviceT, options: InitOptions) Error!Self {
            if (device_value.blocksCount() == 0) {
                return error.MissingSuperblock;
            }
            const core = try initCore(allocator, device_value, options);
            errdefer {
                core.cache.deinit();
                core.raw_cache.deinit();
                core.device.deinit();
                allocator.destroy(core);
            }
            const storage = blk: {
                var page = try core.raw_cache.fetch(0);
                defer page.deinit();
                break :blk try Superblock.read(try page.data(), core.device.blockSize(), core.identity);
            };
            if (storage.page_count.get() != core.device.blocksCount()) {
                return error.PageCountMismatch;
            }
            if (storage.clean == 0) {
                return error.DirtyDatabase;
            }
            try shape.validateStaticMetadata(
                SchemaT,
                bindings,
                Metadata,
                &storage.metadata,
                core.device.blocksCount(),
            );
            try initComponents(core, options);
            errdefer deinitComponentPrefix(core, SchemaT.fields.len);
            core.store.state_value.root.set(shape.restoreStaticMetadata(
                SchemaT,
                bindings,
                Metadata,
                &core.components,
                &storage.metadata,
            ) orelse std.math.maxInt(SchemaT.PageId));
            core.gc_state = storage.metadata.gc_state;
            core.gc_cycle_active = storage.metadata.gc_cycle_active != 0;
            try core.cache.validateFreeList();
            return .{ .core_ = core };
        }

        /// Starts the only mutable access scope. Active transactions roll back on deinit.
        pub fn begin(self: *Self) Error!Transaction {
            const core = self.corePtr();
            if (core.gc_cycle_active) return error.GarbageCollectionActive;
            return self.beginInternal();
        }

        fn beginInternal(self: *Self) Error!Transaction {
            const core = self.corePtr();
            if (core.transaction_active) {
                return Error.BatchActive;
            }
            core.transaction_component_states = captureTransactionStates(core);
            core.transaction_gc_state = core.gc_state;
            core.transaction_gc_cycle_active = core.gc_cycle_active;
            core.transaction_cache_batch = try core.cache.begin();
            core.transaction_generation +%= 1;
            core.transaction_active = true;
            writeSuperblock(core, false) catch |err| {
                core.transaction_cache_batch.discard() catch {};
                core.transaction_active = false;
                return err;
            };
            var page = try core.raw_cache.fetch(0);
            defer page.deinit();
            try core.device.writeBlock(0, @constCast(try page.data()));
            try core.device.sync();
            return .{ .core_ = core, .generation_ = core.transaction_generation };
        }

        pub fn startGarbageCollection(self: *Self) Error!void {
            var session = GcSession{ .raw = try self.beginInternal() };
            defer session.deinit();
            var roots: std.ArrayList(SchemaT.PageId) = .empty;
            defer roots.deinit(self.corePtr().allocator);
            const collector = try session.collector();
            inline for (SchemaT.fields, 0..) |field, index| {
                const Binding = bindings[index];
                comptime component.assertGc(Binding, GcCollector);
                const Capability = Binding.Gc(GcCollector);
                const runtime: *const Binding.Runtime = &@field(self.corePtr().components, field.name);
                try Capability.appendRoots(runtime, self.corePtr().allocator, &roots);
                try Capability.registerScanners(runtime, collector);
            }
            try session.start(roots.items);
            try session.commit();
        }
        pub fn stepGarbageCollection(self: *Self, maximum_pages: usize) Error!gc.StepStatus {
            var session = GcSession{ .raw = try self.beginInternal() };
            defer session.deinit();
            const collector = try session.collector();
            inline for (SchemaT.fields, 0..) |field, index| {
                const Binding = bindings[index];
                comptime component.assertGc(Binding, GcCollector);
                const Capability = Binding.Gc(GcCollector);
                const runtime: *const Binding.Runtime = &@field(self.corePtr().components, field.name);
                try Capability.registerScanners(runtime, collector);
            }
            const status = try session.step(maximum_pages);
            try session.commit();
            return status;
        }
        pub fn garbageCollectionPhase(self: *Self) Error!gc.Phase {
            var session = GcSession{ .raw = try self.beginInternal() };
            defer session.deinit();
            const phase = try session.phase();
            try session.rollback();
            return phase;
        }
        pub fn cancelGarbageCollection(self: *Self) Error!void {
            var session = GcSession{ .raw = try self.beginInternal() };
            defer session.deinit();
            try session.abort();
            try session.commit();
        }

        pub fn getConst(self: *const Self, comptime name: []const u8) *const constProxyType(name) {
            const Binding = bindingType(name);
            return Binding.proxyConst(&@field(self.coreConstPtr().components, name));
        }

        pub const Diagnostics = struct {
            page_size: usize,
            page_count: usize,
            free_root: ?SchemaT.PageId,
            wal_enabled: bool = false,
        };

        pub fn diagnostics(self: *const Self) Diagnostics {
            const core = self.coreConstPtr();
            return .{
                .page_size = core.device.blockSize(),
                .page_count = core.device.blocksCount(),
                .free_root = freeRoot(core),
            };
        }

        pub fn deinit(self: *Self) void {
            const core = self.corePtr();
            if (core.transaction_active) {
                @panic("StaticDatabase.deinit called with an active transaction");
            }
            requireTransactionIdle(core) catch
                @panic("StaticDatabase.deinit called with an active value editor");
            const allocator = core.allocator;
            deinitComponentPrefix(core, SchemaT.fields.len);
            core.cache.deinit();
            core.raw_cache.deinit();
            core.device.deinit();
            allocator.destroy(core);
            self.* = undefined;
        }
    };
}
