const std = @import("std");
const device_interfaces = @import("fullaz").device.interfaces;
const page_cache = @import("fullaz").storage.page_cache;
const memory_policy = @import("fullaz").storage.memory_policy;
const wal = @import("fullaz").storage.wal;
const StaticDatabaseCommon = @import("common.zig").StaticDatabaseCommon;
const schema_fingerprint = @import("../../component/fingerprint.zig");
const shape = @import("../../component/shape.zig");

/// A page-zero-superblock database that owns the supplied block device and WAL log.
pub fn StaticDatabaseWithWal(comptime SchemaT: type, comptime DeviceT: type, comptime LogDeviceT: type) type {
    if (!@hasDecl(SchemaT, "PageId") or !@hasDecl(SchemaT, "fields")) {
        @compileError("StaticDatabaseWithWal requires a pages Schema type");
    }
    comptime shape.assertStaticSchema(SchemaT);
    comptime device_interfaces.assertBlockDevice(DeviceT);
    if (DeviceT.BlockId != SchemaT.PageId) {
        @compileError("StaticDatabaseWithWal DeviceT.BlockId must match SchemaT.PageId");
    }
    comptime device_interfaces.assertLogDevice(LogDeviceT);

    const WalT = wal.Wal(LogDeviceT, SchemaT.PageId, .little);
    const RawCache = page_cache.PageCacheImpl(
        DeviceT,
        memory_policy.DefaultMemoryPolicy,
        WalT,
        page_cache.RetainPidPolicy(DeviceT.BlockId),
    );
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
    const Core = struct {
        allocator: std.mem.Allocator,
        device: DeviceT,
        log: LogDeviceT,
        identity: Superblock.Identity,
        raw_cache: RawCache,
        store: Store,
        cache: Cache,
        backend: Backend,
        components: Components,
        transaction_active: bool,
        transaction_generation: u64,
        transaction_cache_batch: Cache.WriteBatch,
        transaction_component_states: TransactionStates,
    };

    return struct {
        const Self = @This();

        pub const Schema = SchemaT;
        pub const DeviceType = DeviceT;
        pub const LogDeviceType = LogDeviceT;
        pub const WalType = WalT;
        pub const RawCacheType = RawCache;
        pub const CacheType = Cache;
        pub const BackendType = Backend;
        pub const ComponentsStorageType = Components;
        pub const ComponentTransactionStatesType = TransactionStates;
        pub const ComponentInitOptionsType = ComponentOptions;
        pub const MetadataType = Metadata;
        pub const SuperblockType = Superblock;
        pub const InitOptions = Options;
        pub const Error = DeviceT.Error ||
            LogDeviceT.Error ||
            WalT.Error ||
            RawCache.Error ||
            Cache.Error ||
            Superblock.Error ||
            shape.componentErrors(bindings, 0) ||
            shape.staticMetadataErrors(bindings, 0) ||
            error{
                InvalidCacheFrames,
                DeviceNotEmpty,
                LogNotEmpty,
                InvalidImageId,
                MissingSuperblock,
                PageCountMismatch,
                DirtyDatabase,
                InvalidSuperblockPage,
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

            pub fn commit(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try requireTransactionIdle(core);
                try writeSuperblock(core, true);
                try core.transaction_cache_batch.commit();
                core.transaction_active = false;
            }

            pub fn rollback(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try requireTransactionIdle(core);
                try core.transaction_cache_batch.discard();
                restoreTransactionStates(core, core.transaction_component_states);
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

        fn writeSuperblock(core: *Core, clean: bool) Error!void {
            var page = try core.raw_cache.fetch(0);
            defer page.deinit();
            try Superblock.format(
                try page.dataMut(),
                core.device.blockSize(),
                core.device.blocksCount(),
                core.identity,
                shape.captureStaticMetadata(SchemaT, bindings, Metadata, &core.components, core.store.getRoot()),
                clean,
            );
        }

        fn initCore(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: LogDeviceT,
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
            core.log = log_value;
            errdefer core.log.deinit();
            core.identity = identity(options);
            var wal_value = try WalT.initWithIdentity(
                allocator,
                &core.log,
                @intCast(core.device.blockSize()),
                .{
                    .image_id = core.identity.image_id,
                    .schema_digest = core.identity.schema_digest,
                },
            );
            errdefer wal_value.deinit();
            core.raw_cache = try RawCache.initWal(&core.device, allocator, options.cache_frames, wal_value);
            errdefer core.raw_cache.deinit();
            core.store = .{ .device = &core.device };
            core.cache = Cache.init(&core.raw_cache, &core.store);
            errdefer core.cache.deinit();
            core.backend = Common.initBackend(allocator, &core.cache);
            core.transaction_active = false;
            core.transaction_generation = 0;
            return core;
        }

        /// Formats empty supplied device and log and takes ownership on success.
        pub fn format(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: LogDeviceT,
            options: InitOptions,
        ) Error!Self {
            if (device_value.blocksCount() != 0) {
                return error.DeviceNotEmpty;
            }
            if (log_value.size() != 0) {
                return error.LogNotEmpty;
            }
            const core = try initCore(allocator, device_value, log_value, options);
            errdefer {
                core.cache.deinit();
                core.raw_cache.deinit();
                core.log.deinit();
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
                    shape.captureStaticMetadata(SchemaT, bindings, Metadata, &core.components, null),
                    true,
                );
            }
            try core.raw_cache.flushAll();
            try core.device.sync();
            return .{ .core_ = core };
        }

        /// Opens existing supplied device and log and takes ownership on success.
        pub fn open(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: LogDeviceT,
            options: InitOptions,
        ) Error!Self {
            if (device_value.blocksCount() == 0) {
                return error.MissingSuperblock;
            }
            const core = try initCore(allocator, device_value, log_value, options);
            errdefer {
                core.cache.deinit();
                core.raw_cache.deinit();
                core.log.deinit();
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
            core.store.root = shape.restoreStaticMetadata(
                SchemaT,
                bindings,
                Metadata,
                &core.components,
                &storage.metadata,
            );
            try core.cache.validateFreeList();
            return .{ .core_ = core };
        }

        /// Starts the only mutable access scope. Active transactions roll back on deinit.
        pub fn begin(self: *Self) Error!Transaction {
            const core = self.corePtr();
            if (core.transaction_active) {
                return Error.BatchActive;
            }
            core.transaction_component_states = captureTransactionStates(core);
            core.transaction_cache_batch = try core.cache.begin();
            core.transaction_generation +%= 1;
            core.transaction_active = true;
            return .{ .core_ = core, .generation_ = core.transaction_generation };
        }

        pub fn getConst(self: *const Self, comptime name: []const u8) *const constProxyType(name) {
            const Binding = bindingType(name);
            return Binding.proxyConst(&@field(self.coreConstPtr().components, name));
        }

        /// The full in-memory device image, in page order (memory-backed devices only).
        pub fn deviceBytes(self: *const Self) []const u8 {
            return self.coreConstPtr().device.storage.items;
        }

        pub const Diagnostics = struct {
            page_size: usize,
            page_count: usize,
            free_root: ?SchemaT.PageId,
            wal_enabled: bool = true,
        };

        pub fn diagnostics(self: *const Self) Diagnostics {
            const core = self.coreConstPtr();
            return .{
                .page_size = core.device.blockSize(),
                .page_count = core.device.blocksCount(),
                .free_root = core.store.getRoot(),
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
            core.log.deinit();
            core.device.deinit();
            allocator.destroy(core);
            self.* = undefined;
        }
    };
}
