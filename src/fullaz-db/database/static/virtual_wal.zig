const std = @import("std");
const device_interfaces = @import("fullaz").device.interfaces;
const memory_policy = @import("fullaz").storage.memory_policy;
const page_cache = @import("fullaz").storage.page_cache;
const virtual_page_map = @import("fullaz").storage.virtual_page_map;
const wal = @import("fullaz").storage.wal;
const schema_fingerprint = @import("../../component/fingerprint.zig");
const shape = @import("../../component/shape.zig");
const VirtualStaticSuperblock = @import("virtual_superblock.zig").VirtualStaticSuperblock;

/// WAL-backed static database with stable logical page IDs. The physical block
/// namespace is private to the VPM and can use a different integer type.
pub fn VirtualStaticDatabaseWithWal(comptime SchemaT: type, comptime DeviceT: type, comptime LogDeviceT: type) type {
    if (!@hasDecl(SchemaT, "PageId") or !@hasDecl(SchemaT, "fields")) {
        @compileError("VirtualStaticDatabaseWithWal requires a pages Schema type");
    }
    comptime shape.assertStaticSchema(SchemaT);
    comptime device_interfaces.assertBlockDevice(DeviceT);
    comptime device_interfaces.assertLogDevice(LogDeviceT);
    comptime assertUnsignedInteger(DeviceT.BlockId, "DeviceT.BlockId");
    comptime assertUnsignedInteger(SchemaT.PageId, "SchemaT.PageId");

    const PhysicalPageId = DeviceT.BlockId;
    const VirtualPageId = SchemaT.PageId;
    const WalT = wal.Wal(LogDeviceT, PhysicalPageId, .little);
    const RawCache = page_cache.PageCacheImpl(
        DeviceT,
        memory_policy.DefaultMemoryPolicy,
        WalT,
        page_cache.RetainPidPolicy(PhysicalPageId),
    );

    const PhysicalStore = struct {
        pub const PageId = PhysicalPageId;
        pub const Error = error{};

        device: *DeviceT,
        root: *?PageId,

        pub fn getRoot(self: *const @This()) ?PageId {
            return self.root.*;
        }

        pub fn setRoot(self: *@This(), root: ?PageId) Error!void {
            self.root.* = root;
        }

        pub fn pageCount(self: *const @This()) usize {
            return self.device.blocksCount();
        }

        pub fn isReserved(_: *const @This(), page_id: PageId) bool {
            return page_id <= @as(PageId, 2);
        }
    };
    const PhysicalCache = page_cache.PersistentReclaimingCache(RawCache, PhysicalStore);

    const VpmManager = struct {
        pub const PageId = PhysicalPageId;
        pub const Error = PhysicalCache.Error;

        pub const StateLeaseType = struct {
            pub const Error = PhysicalCache.Error;

            handle: PhysicalCache.Handle,

            pub fn data(self: *const @This()) @This().Error![]const u8 {
                return self.handle.data();
            }

            pub fn dataMut(self: *@This()) @This().Error![]u8 {
                return self.handle.dataMut();
            }

            pub fn deinit(self: *@This()) void {
                self.handle.deinit();
            }
        };

        cache: *PhysicalCache,

        pub fn state(self: *@This()) Error!StateLeaseType {
            return .{ .handle = try self.cache.fetch(@as(PageId, 1)) };
        }

        pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
            return self.cache.free(page_id);
        }
    };
    const Vpm = virtual_page_map.Paged(PhysicalCache, VpmManager, VirtualPageId);
    const VirtualCache = page_cache.VirtualPageCache(PhysicalCache, Vpm);

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
    const Superblock = VirtualStaticSuperblock(Metadata, PhysicalPageId, VirtualPageId);
    const Options = databaseOptions(ComponentOptions);
    const vpm_settings = Vpm.Settings{
        .virtual_to_physical = .{ .leaf = 0x0010, .inode = 0x0011 },
        .physical_to_virtual = .{ .leaf = 0x0012, .inode = 0x0013 },
    };
    const placeholder_magic = "FZVPLACE";

    const Core = struct {
        allocator: std.mem.Allocator,
        device: DeviceT,
        log: LogDeviceT,
        identity: Superblock.Identity,
        raw_cache: RawCache,
        physical_free_root: ?PhysicalPageId,
        physical_store: PhysicalStore,
        physical_cache: PhysicalCache,
        vpm_manager: VpmManager,
        vpm: Vpm,
        virtual_cache: VirtualCache,
        logical_free_root: ?VirtualPageId,
        logical_store: LogicalStore,
        logical_cache: LogicalCache,
        backend: Backend,
        components: Components,
        transaction_active: bool,
        transaction_generation: u64,
        transaction_cache_batch: LogicalCache.WriteBatch,
        transaction_component_states: TransactionStates,
        layers_initialized: bool,
        initialized_components: usize,
    };

    return struct {
        const Self = @This();

        pub const Schema = SchemaT;
        pub const DeviceType = DeviceT;
        pub const LogDeviceType = LogDeviceT;
        pub const WalType = WalT;
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
            LogDeviceT.Error ||
            WalT.Error ||
            RawCache.Error ||
            PhysicalCache.Error ||
            Vpm.Error ||
            VirtualCache.Error ||
            LogicalCache.Error ||
            Superblock.Error ||
            shape.componentErrors(bindings, 0) ||
            shape.staticMetadataErrors(bindings, 0) ||
            error{
                InvalidCacheFrames,
                DeviceNotEmpty,
                LogNotEmpty,
                InvalidImageId,
                MissingSuperblock,
                InvalidBootstrapPage,
                PageCountMismatch,
                VirtualPageCountMismatch,
                InvalidPlaceholderMapping,
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
                const core = self.activeCore() catch @panic("VirtualStaticDatabase transaction is inactive");
                const Binding = bindingType(name);
                return Binding.proxy(&@field(core.components, name));
            }

            pub fn getConst(self: *const TransactionSelf, comptime name: []const u8) *const constProxyType(name) {
                const core = self.activeCore() catch @panic("VirtualStaticDatabase transaction is inactive");
                const Binding = bindingType(name);
                return Binding.proxyConst(&@field(core.components, name));
            }

            pub fn commit(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try writeSuperblock(core);
                core.transaction_cache_batch.commit() catch |err| {
                    if (!core.logical_cache.transactionActive()) {
                        core.transaction_active = false;
                    }
                    return err;
                };
                core.transaction_active = false;
            }

            pub fn rollback(self: *TransactionSelf) Error!void {
                const core = try self.activeCore();
                try core.transaction_cache_batch.discard();
                restoreTransactionStates(core, core.transaction_component_states);
                core.transaction_active = false;
            }

            pub fn deinit(self: *TransactionSelf) void {
                if (self.activeCore()) |_| {
                    self.rollback() catch @panic("Failed to roll back VirtualStaticDatabase transaction");
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

        fn restoreTransactionStates(core: *Core, states: TransactionStates) void {
            inline for (SchemaT.fields, 0..) |field, index| {
                bindings[index].restoreTransactionState(
                    &@field(core.components, field.name),
                    @field(states, field.name),
                );
            }
        }

        fn writeSuperblock(core: *Core) Error!void {
            var page = try core.raw_cache.fetch(Superblock.superblock_page_id);
            defer page.deinit();
            try Superblock.format(
                try page.dataMut(),
                core.device.blockSize(),
                core.device.blocksCount(),
                core.vpm.pageCount(),
                core.physical_store.getRoot(),
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
            log_value: LogDeviceT,
            options: InitOptions,
            mode: enum { fresh, recover },
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
            core.raw_cache = switch (mode) {
                .fresh => try RawCache.initWalFresh(&core.device, allocator, options.cache_frames, wal_value),
                .recover => try RawCache.initWalRecover(&core.device, allocator, options.cache_frames, wal_value),
            };
            errdefer core.raw_cache.deinit();
            core.physical_free_root = null;
            core.physical_store = .{ .device = &core.device, .root = &core.physical_free_root };
            core.physical_cache = PhysicalCache.init(&core.raw_cache, &core.physical_store);
            errdefer core.physical_cache.deinit();
            core.vpm_manager = .{ .cache = &core.physical_cache };
            core.logical_free_root = null;
            core.logical_store = .{ .vpm = &core.vpm, .root = &core.logical_free_root };
            core.transaction_active = false;
            core.transaction_generation = 0;
            core.layers_initialized = false;
            core.initialized_components = 0;
            return core;
        }

        fn initVirtualLayers(core: *Core, mode: enum { format, open }) Error!void {
            core.vpm = switch (mode) {
                .format => try Vpm.format(&core.physical_cache, &core.vpm_manager, vpm_settings),
                .open => try Vpm.open(&core.physical_cache, &core.vpm_manager, vpm_settings),
            };
            errdefer core.vpm.deinit();
            core.virtual_cache = VirtualCache.init(&core.physical_cache, &core.vpm, .init());
            errdefer core.virtual_cache.deinit();
            core.logical_store.vpm = &core.vpm;
            core.logical_cache = LogicalCache.init(&core.virtual_cache, &core.logical_store);
            errdefer core.logical_cache.deinit();
            core.backend = Backend.init(core.allocator, &core.logical_cache);
            core.layers_initialized = true;
        }

        fn deinitCore(core: *Core) void {
            const allocator = core.allocator;
            if (core.layers_initialized) {
                deinitComponentPrefix(core, core.initialized_components);
                core.logical_cache.deinit();
                core.virtual_cache.deinit();
                core.vpm.deinit();
            }
            core.physical_cache.deinit();
            core.raw_cache.deinit();
            core.log.deinit();
            core.device.deinit();
            allocator.destroy(core);
        }

        fn readSuperblock(core: *Core) Error!Superblock.Storage {
            var page = try core.raw_cache.fetch(Superblock.superblock_page_id);
            defer page.deinit();
            return Superblock.read(try page.data(), core.device.blockSize(), core.identity);
        }

        fn bootstrapPages(core: *Core) Error!void {
            inline for (0..3) |index| {
                var page = try core.raw_cache.create();
                defer page.deinit();
                if (try page.pid() != index) {
                    return error.InvalidBootstrapPage;
                }
                if (index == @as(usize, Superblock.placeholder_page_id)) {
                    @memcpy((try page.dataMut())[0..placeholder_magic.len], placeholder_magic);
                }
            }
            try core.raw_cache.flushAll();
            try core.device.sync();
        }

        fn validatePlaceholder(core: *Core) Error!void {
            var page = try core.raw_cache.fetch(Superblock.placeholder_page_id);
            defer page.deinit();
            const bytes = try page.data();
            if (bytes.len < placeholder_magic.len or
                !std.mem.eql(u8, bytes[0..placeholder_magic.len], placeholder_magic))
            {
                return error.InvalidBootstrapPage;
            }
        }

        /// Formats empty supplied device and log. Both inputs are consumed on
        /// every result. A crash before this function returns successfully
        /// leaves an invalid bootstrap image which must be reformatted.
        pub fn format(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: LogDeviceT,
            options: InitOptions,
        ) Error!Self {
            var device = device_value;
            var log = log_value;
            var owned = true;
            defer if (owned) {
                log.deinit();
                device.deinit();
            };
            if (device.blocksCount() != 0) {
                return error.DeviceNotEmpty;
            }
            if (log.size() != 0) {
                return error.LogNotEmpty;
            }
            owned = false;
            const core = try initCore(allocator, device, log, options, .fresh);
            errdefer deinitCore(core);
            try bootstrapPages(core);
            try initVirtualLayers(core, .format);
            {
                var batch = try core.logical_cache.begin();
                errdefer batch.discard() catch {};
                if (try core.vpm.set(Superblock.placeholder_page_id) != 0) {
                    return error.InvalidPlaceholderMapping;
                }
                try initComponents(core, options);
                try writeSuperblock(core);
                try batch.commit();
            }
            return .{ .core_ = core };
        }

        /// Opens an existing virtual image. Recovery replays WAL first, but
        /// checkpointing is deferred until all persisted graph roots validate.
        pub fn open(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: LogDeviceT,
            options: InitOptions,
        ) Error!Self {
            var device = device_value;
            var log = log_value;
            var owned = true;
            defer if (owned) {
                log.deinit();
                device.deinit();
            };
            if (device.blocksCount() == 0) {
                return error.MissingSuperblock;
            }
            owned = false;
            const core = try initCore(allocator, device, log, options, .recover);
            errdefer deinitCore(core);
            const storage = try readSuperblock(core);
            const physical_page_count = std.math.cast(usize, storage.physical_page_count.get()) orelse return error.PageCountMismatch;
            if (physical_page_count < 3) {
                return error.InvalidBootstrapPage;
            }
            try core.raw_cache.normalizeRecoveredPageCount(physical_page_count);
            core.physical_free_root = Superblock.physicalFreeRoot(&storage);
            try initVirtualLayers(core, .open);
            const virtual_page_count = std.math.cast(usize, storage.virtual_page_count.get()) orelse return error.VirtualPageCountMismatch;
            if (virtual_page_count == 0 or core.vpm.pageCount() != virtual_page_count) {
                return error.VirtualPageCountMismatch;
            }
            if (try core.vpm.get(0) != Superblock.placeholder_page_id) {
                return error.InvalidPlaceholderMapping;
            }
            try validatePlaceholder(core);
            try core.physical_cache.validateFreeList();
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
            try core.raw_cache.completeRecovery();
            return .{ .core_ = core };
        }

        pub fn begin(self: *Self) Error!Transaction {
            const core = self.corePtr();
            if (core.transaction_active) {
                return error.BatchActive;
            }
            core.transaction_component_states = captureTransactionStates(core);
            core.transaction_cache_batch = try core.logical_cache.begin();
            core.transaction_generation +%= 1;
            core.transaction_active = true;
            return .{ .core_ = core, .generation_ = core.transaction_generation };
        }

        pub fn getConst(self: *const Self, comptime name: []const u8) *const constProxyType(name) {
            const Binding = bindingType(name);
            return Binding.proxyConst(&@field(self.coreConstPtr().components, name));
        }

        /// The full in-memory physical device image, in page order. This is
        /// available when `DeviceT` is an in-memory block device.
        pub fn deviceBytes(self: *const Self) []const u8 {
            return self.coreConstPtr().device.storage.items;
        }

        pub const Diagnostics = struct {
            physical_page_count: usize,
            virtual_page_count: usize,
            physical_free_root: ?PhysicalPageId,
            logical_free_root: ?VirtualPageId,
            wal_enabled: bool = true,
        };

        pub fn diagnostics(self: *const Self) Diagnostics {
            const core = self.coreConstPtr();
            return .{
                .physical_page_count = core.device.blocksCount(),
                .virtual_page_count = core.vpm.pageCount(),
                .physical_free_root = core.physical_store.getRoot(),
                .logical_free_root = core.logical_store.getRoot(),
            };
        }

        pub fn deinit(self: *Self) void {
            const core = self.corePtr();
            if (core.transaction_active) {
                @panic("VirtualStaticDatabase.deinit called with an active transaction");
            }
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
        .int => |int_info| {
            if (int_info.signedness != .unsigned) {
                @compileError("VirtualStaticDatabaseWithWal " ++ name ++ " must be unsigned");
            }
        },
        else => @compileError("VirtualStaticDatabaseWithWal " ++ name ++ " must be an integer"),
    }
}
