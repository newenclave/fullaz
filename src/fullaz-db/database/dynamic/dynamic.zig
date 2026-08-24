const std = @import("std");
const device_interfaces = @import("fullaz").device.interfaces;
const page_cache = @import("fullaz").storage.page_cache;
const memory_policy = @import("fullaz").storage.memory_policy;
const wal = @import("fullaz").storage.wal;
const component = @import("../../component/component.zig");
const PageKindRange = component.PageKindRange;
const file = @import("../../file/file.zig");

/// A page-zero boot database with persistent, dynamically cataloged components.
pub fn DynamicDatabase(comptime DeviceT: type) type {
    return DynamicDatabaseImpl(DeviceT, null);
}

/// A WAL-backed page-zero boot database with persistent, dynamically cataloged components.
pub fn DynamicDatabaseWithWal(comptime DeviceT: type, comptime LogDeviceT: type) type {
    comptime device_interfaces.assertLogDevice(LogDeviceT);
    return DynamicDatabaseImpl(DeviceT, LogDeviceT);
}

fn DynamicDatabaseImpl(comptime DeviceT: type, comptime LogDeviceT: ?type) type {
    comptime device_interfaces.assertBlockDevice(DeviceT);

    const WalT = if (LogDeviceT) |LogT| wal.Wal(LogT, DeviceT.BlockId, .little) else wal.NoWal;
    const RawCache = page_cache.PageCacheImpl(DeviceT, memory_policy.DefaultMemoryPolicy, WalT);
    const DevicePageId = DeviceT.BlockId;
    const Log = LogDeviceT orelse void;
    const LogError = if (LogDeviceT) |LogT| LogT.Error else error{};
    const WalError = if (LogDeviceT != null) WalT.Error else error{};

    const CatalogManager = struct {
        pub const PageId = DeviceT.BlockId;
        pub const Size = u64;
        pub const Error = error{};

        state: *file.boot.State,

        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}

        pub fn getTotalSize(self: *const @This()) Error!Size {
            return self.state.catalog_record_count;
        }

        pub fn setTotalSize(self: *@This(), value: Size) Error!void {
            self.state.catalog_record_count = value;
        }

        pub fn getFirst(self: *const @This()) Error!?PageId {
            const raw = self.state.catalog_first orelse return null;
            return std.math.cast(PageId, raw);
        }

        pub fn setFirst(self: *@This(), value: ?PageId) Error!void {
            self.state.catalog_first = if (value) |page_id| @intCast(page_id) else null;
        }

        pub fn getLast(self: *const @This()) Error!?PageId {
            const raw = self.state.catalog_last orelse return null;
            return std.math.cast(PageId, raw);
        }

        pub fn setLast(self: *@This(), value: ?PageId) Error!void {
            self.state.catalog_last = if (value) |page_id| @intCast(page_id) else null;
        }
    };
    const IndexManager = struct {
        pub const PageId = DeviceT.BlockId;
        pub const Error = error{};

        root: *?u64,

        pub fn getRoot(self: *const @This()) ?PageId {
            const raw = self.root.* orelse return null;
            return std.math.cast(PageId, raw);
        }

        pub fn setRoot(self: *@This(), value: ?PageId) Error!void {
            self.root.* = if (value) |page_id| @intCast(page_id) else null;
        }

        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    };
    const Catalog = file.CatalogStore(RawCache, CatalogManager);
    const CatalogIds = file.CatalogIdIndex(RawCache, IndexManager);
    const CatalogNames = file.CatalogNameIndex(RawCache, IndexManager);
    const Core = struct {
        allocator: std.mem.Allocator,
        device: DeviceT,
        log: Log,
        raw_cache: RawCache,
        state: file.boot.State,
        catalog_manager: CatalogManager,
        catalog_id_manager: IndexManager,
        catalog_name_manager: IndexManager,
        catalog: Catalog,
        catalog_ids: CatalogIds,
        catalog_names: CatalogNames,
        transaction_active: bool = false,
        transaction_batch: RawCache.WriteBatch = undefined,
        state_snapshot: file.boot.State = undefined,
    };

    return struct {
        const Self = @This();

        pub const DeviceType = DeviceT;
        pub const LogDeviceType = LogDeviceT;
        pub const WalType = WalT;
        pub const RawCacheType = RawCache;
        pub const State = file.boot.State;
        pub const CatalogStoreType = Catalog;
        pub const CatalogIdIndexType = CatalogIds;
        pub const CatalogNameIndexType = CatalogNames;
        pub const InitOptions = struct {
            image_id: [16]u8,
            cache_frames: usize = 64,
        };
        pub const Error = std.mem.Allocator.Error ||
            DeviceT.Error ||
            LogError ||
            WalError ||
            RawCache.Error ||
            file.boot.Error ||
            Catalog.Error ||
            CatalogIds.Error ||
            CatalogNames.Error ||
            file.component_metadata.Error ||
            file.component_metadata_page.Error ||
            file.schema_preflight.Error ||
            error{
                InvalidCacheFrames,
                InvalidImageId,
                PageSizeTooLarge,
                DeviceNotEmpty,
                LogNotEmpty,
                MissingBoot,
                PageCountMismatch,
                DirtyDatabase,
                InvalidBootPage,
                PageIdTooLarge,
                DuplicateComponent,
                MissingComponent,
                CatalogIndexMismatch,
                ComponentIdExhausted,
                PageKindExhausted,
                RevisionMismatch,
                NameMismatch,
            };

        core_: *align(@alignOf(Core)) anyopaque,

        fn corePtr(self: *Self) *Core {
            return @ptrCast(self.core_);
        }

        fn coreConstPtr(self: *const Self) *const Core {
            return @ptrCast(self.core_);
        }

        fn pageSize(device: *const DeviceT) Error!u32 {
            return std.math.cast(u32, device.blockSize()) orelse error.PageSizeTooLarge;
        }

        fn expected(device: *const DeviceT, options: InitOptions) Error!file.boot.Expected {
            return .{
                .image_id = options.image_id,
                .page_size = try pageSize(device),
                .page_id_bits = @bitSizeOf(DevicePageId),
            };
        }

        fn initialState(device: *const DeviceT, options: InitOptions) Error!State {
            return .{
                .image_id = options.image_id,
                .page_size = try pageSize(device),
                .page_id_bits = @bitSizeOf(DevicePageId),
                .clean = true,
                .feature_flags = 0,
                .page_count = device.blocksCount(),
                .free_root = null,
                .catalog_first = null,
                .catalog_last = null,
                .catalog_record_count = 0,
                .live_component_count = 0,
                .id_radix_root = null,
                .name_bpt_root = null,
                .next_component_id = 1,
                .next_component_page_kind = file.system_kinds.first_component,
                .catalog_epoch = 0,
                .generation = 0,
            };
        }

        fn initCore(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: Log,
            state: State,
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
            if (comptime LogDeviceT) |_| {
                core.log = log_value;
                errdefer core.log.deinit();
                var wal_value = try WalT.init(allocator, &core.log, @intCast(core.device.blockSize()));
                errdefer wal_value.deinit();
                core.raw_cache = try RawCache.initWal(&core.device, allocator, options.cache_frames, wal_value);
            } else {
                core.raw_cache = try RawCache.init(&core.device, allocator, options.cache_frames);
            }
            errdefer core.raw_cache.deinit();
            core.state = state;
            core.catalog_manager = .{ .state = &core.state };
            core.catalog_id_manager = .{ .root = &core.state.id_radix_root };
            core.catalog_name_manager = .{ .root = &core.state.name_bpt_root };
            core.catalog = try Catalog.init(&core.raw_cache, &core.catalog_manager);
            errdefer core.catalog.deinit();
            core.catalog_ids = try CatalogIds.init(&core.raw_cache, &core.catalog_id_manager);
            errdefer core.catalog_ids.deinit();
            core.catalog_names = try CatalogNames.init(&core.raw_cache, &core.catalog_name_manager);
            errdefer core.catalog_names.deinit();
            core.transaction_active = false;
            return core;
        }

        fn deinitCore(core: *Core, deinit_device: bool) void {
            const allocator = core.allocator;
            core.catalog_names.deinit();
            core.catalog_ids.deinit();
            core.catalog.deinit();
            core.raw_cache.deinit();
            if (comptime LogDeviceT != null) {
                core.log.deinit();
            }
            if (deinit_device) {
                core.device.deinit();
            }
            allocator.destroy(core);
        }

        fn writeBoot(core: *Core) Error!void {
            var page = try core.raw_cache.fetch(0);
            defer page.deinit();
            const scratch = try core.allocator.alloc(u8, core.device.blockSize());
            defer core.allocator.free(scratch);
            try file.boot.format(try page.dataMut(), scratch, core.state, &.{});
        }

        fn formatImpl(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: Log,
            options: InitOptions,
        ) Error!Self {
            if (device_value.blocksCount() != 0) {
                return error.DeviceNotEmpty;
            }
            if (std.mem.allEqual(u8, &options.image_id, 0)) {
                return error.InvalidImageId;
            }

            var device = device_value;
            const boot_page_id = try device.appendBlock();
            errdefer device.deinit();
            if (boot_page_id != 0) {
                return error.InvalidBootPage;
            }
            const state = try initialState(&device, options);
            const core = try initCore(allocator, device, log_value, state, options);
            errdefer deinitCore(core, true);
            try writeBoot(core);
            try core.raw_cache.flushAll();
            try core.device.sync();
            return .{ .core_ = core };
        }

        fn openImpl(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: Log,
            options: InitOptions,
        ) Error!Self {
            if (device_value.blocksCount() == 0) {
                return error.MissingBoot;
            }
            if (std.mem.allEqual(u8, &options.image_id, 0)) {
                return error.InvalidImageId;
            }

            var device = device_value;
            errdefer device.deinit();
            const core = try initCore(allocator, device, log_value, undefined, options);
            errdefer deinitCore(core, true);
            const view = blk: {
                var page = try core.raw_cache.fetch(0);
                defer page.deinit();
                break :blk try file.boot.read(try page.data(), try expected(&core.device, options));
            };
            if (view.state.page_count != core.device.blocksCount()) {
                return error.PageCountMismatch;
            }
            if (!view.state.clean) {
                return error.DirtyDatabase;
            }
            core.state = view.state;
            core.catalog_manager.state = &core.state;
            core.catalog_id_manager.root = &core.state.id_radix_root;
            core.catalog_name_manager.root = &core.state.name_bpt_root;
            return .{ .core_ = core };
        }

        fn formatWithoutWal(allocator: std.mem.Allocator, device_value: DeviceT, options: InitOptions) Error!Self {
            return formatImpl(allocator, device_value, {}, options);
        }

        fn openWithoutWal(allocator: std.mem.Allocator, device_value: DeviceT, options: InitOptions) Error!Self {
            return openImpl(allocator, device_value, {}, options);
        }

        fn formatWithWal(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: Log,
            options: InitOptions,
        ) Error!Self {
            if (log_value.size() != 0) {
                return error.LogNotEmpty;
            }
            return formatImpl(allocator, device_value, log_value, options);
        }

        fn openWithWal(
            allocator: std.mem.Allocator,
            device_value: DeviceT,
            log_value: Log,
            options: InitOptions,
        ) Error!Self {
            return openImpl(allocator, device_value, log_value, options);
        }

        /// Formats an empty device and takes ownership on success.
        pub const format = if (LogDeviceT == null) formatWithoutWal else formatWithWal;
        /// Opens an existing database and takes ownership of the supplied device on success.
        pub const open = if (LogDeviceT == null) openWithoutWal else openWithWal;

        pub const Diagnostics = struct {
            core_address: usize,
            device_address: usize,
            cache_address: usize,
            page_size: usize,
            page_count: usize,
        };

        pub const Transaction = struct {
            core_: *align(@alignOf(Core)) anyopaque,
            active: bool = true,

            fn corePtr(self: *Transaction) *Core {
                return @ptrCast(self.core_);
            }

            fn requireActive(self: *const Transaction) Error!void {
                if (!self.active) {
                    return error.TransactionInactive;
                }
            }

            pub const ComponentAllocation = struct {
                component_id: u64,
                page_kinds: PageKindRange,
            };

            /// Reserves one durable ID and an unreusable page-kind range.
            pub fn allocateComponent(self: *Transaction, page_kind_count: usize) Error!ComponentAllocation {
                try self.requireActive();
                const core = self.corePtr();
                const count = std.math.cast(component.PageKind, page_kind_count) orelse
                    return error.PageKindExhausted;
                if (count == 0 or core.state.next_component_id == std.math.maxInt(u64)) {
                    return if (count == 0) error.PageKindExhausted else error.ComponentIdExhausted;
                }
                const range_end = std.math.add(
                    u32,
                    core.state.next_component_page_kind,
                    count,
                ) catch return error.PageKindExhausted;
                if (range_end >= file.system_kinds.invalid_sentinel) {
                    return error.PageKindExhausted;
                }
                const allocation = ComponentAllocation{
                    .component_id = core.state.next_component_id,
                    .page_kinds = .{
                        .base = core.state.next_component_page_kind,
                        .count = count,
                    },
                };
                core.state.next_component_id += 1;
                core.state.next_component_page_kind = @intCast(range_end);
                return allocation;
            }

            pub fn appendCatalogRevision(self: *Transaction, encoded_record: []const u8) Error!file.CatalogRef {
                try self.requireActive();
                return self.corePtr().catalog.append(encoded_record);
            }

            /// Registers an initial live component record and both of its indexes.
            pub fn registerCatalogComponent(self: *Transaction, encoded_record: []const u8) Error!file.CatalogRef {
                try self.requireActive();
                const core = self.corePtr();
                const record = try file.catalog_record.read(encoded_record);
                if (try core.catalog_ids.get(record.component_id) != null or
                    try core.catalog_names.get(record.name) != null)
                {
                    return error.DuplicateComponent;
                }
                const ref = try core.catalog.append(encoded_record);
                try core.catalog_ids.set(record.component_id, ref);
                try core.catalog_names.set(record.name, record.component_id);
                core.state.live_component_count += 1;
                return ref;
            }

            /// Appends one immutable successor revision and atomically retargets
            /// the ID and name indexes to it. Rename/drop remain out of scope.
            pub fn replaceCatalogRevision(self: *Transaction, encoded_record: []const u8) Error!file.CatalogRef {
                try self.requireActive();
                const core = self.corePtr();
                const replacement = try file.catalog_record.read(encoded_record);
                const current_ref = (try core.catalog_ids.get(replacement.component_id)) orelse
                    return error.MissingComponent;
                var current = try core.catalog.load(current_ref);
                defer current.deinit();
                const previous = try current.view();
                if (replacement.revision != previous.revision + 1) {
                    return error.RevisionMismatch;
                }
                if (!std.mem.eql(u8, replacement.name, previous.name)) {
                    return error.NameMismatch;
                }
                const name_id = (try core.catalog_names.get(replacement.name)) orelse
                    return error.CatalogIndexMismatch;
                if (name_id != replacement.component_id) {
                    return error.CatalogIndexMismatch;
                }
                const ref = try core.catalog.append(encoded_record);
                try core.catalog_ids.set(replacement.component_id, ref);
                try core.catalog_names.set(replacement.name, replacement.component_id);
                return ref;
            }

            pub fn setIdRef(self: *Transaction, component_id: u64, ref: file.CatalogRef) Error!void {
                try self.requireActive();
                try self.corePtr().catalog_ids.set(component_id, ref);
            }

            pub fn setName(self: *Transaction, name: []const u8, component_id: u64) Error!void {
                try self.requireActive();
                try self.corePtr().catalog_names.set(name, component_id);
            }

            /// Creates and initializes one typed component metadata page inside
            /// this transaction. The returned PID belongs in its catalog record.
            pub fn initializeMetadata(
                self: *Transaction,
                comptime BindingT: type,
                component_id: u64,
                runtime: *const BindingT.Runtime,
            ) Error!u64 {
                try self.requireActive();
                const core = self.corePtr();
                var page = try core.raw_cache.create();
                defer page.deinit();
                const page_id = try page.pid();
                const payload_buffer = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(payload_buffer);
                const rewrite_scratch = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(rewrite_scratch);
                const payload = try file.component_metadata.rewrite(
                    BindingT,
                    runtime,
                    payload_buffer,
                    rewrite_scratch,
                    &.{},
                );
                try file.component_metadata_page.format(
                    try page.dataMut(),
                    .{
                        .component_id = component_id,
                        .metadata_format_version = BindingT.DynamicMetadata.format_version,
                    },
                    payload,
                );
                return std.math.cast(u64, page_id) orelse error.PageIdTooLarge;
            }

            /// Reads an old metadata page and creates an immutable successor
            /// page at the binding's current metadata format version.
            pub fn migrateMetadata(
                self: *Transaction,
                comptime BindingT: type,
                source_metadata_page_id: u64,
                component_id: u64,
            ) Error!u64 {
                try self.requireActive();
                const core = self.corePtr();
                const source_page_id = std.math.cast(DevicePageId, source_metadata_page_id) orelse
                    return error.PageIdTooLarge;
                var source_page = try core.raw_cache.fetch(source_page_id);
                defer source_page.deinit();
                const source = try file.component_metadata_page.readAny(try source_page.data());
                if (source.state.component_id != component_id) {
                    return error.IdentityMismatch;
                }
                const payload_buffer = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(payload_buffer);
                const rewrite_scratch = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(rewrite_scratch);
                const payload = try file.component_metadata.migrate(
                    BindingT,
                    source.state.metadata_format_version,
                    source.payload,
                    payload_buffer,
                    rewrite_scratch,
                );
                var target_page = try core.raw_cache.create();
                defer target_page.deinit();
                const target_page_id = try target_page.pid();
                try file.component_metadata_page.format(
                    try target_page.dataMut(),
                    .{
                        .component_id = component_id,
                        .metadata_format_version = BindingT.DynamicMetadata.format_version,
                    },
                    payload,
                );
                return std.math.cast(u64, target_page_id) orelse error.PageIdTooLarge;
            }

            /// Rewrites one existing typed metadata page, retaining fields this
            /// build does not know how to decode.
            pub fn storeMetadata(
                self: *Transaction,
                comptime BindingT: type,
                metadata_page_id: u64,
                component_id: u64,
                runtime: *const BindingT.Runtime,
            ) Error!void {
                try self.requireActive();
                const core = self.corePtr();
                const page_id = std.math.cast(DevicePageId, metadata_page_id) orelse
                    return error.PageIdTooLarge;
                const payload_buffer = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(payload_buffer);
                const rewrite_scratch = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(rewrite_scratch);
                try file.ComponentMetadataIo(BindingT, RawCache).store(
                    &core.raw_cache,
                    page_id,
                    .{
                        .component_id = component_id,
                        .metadata_format_version = BindingT.DynamicMetadata.format_version,
                    },
                    runtime,
                    payload_buffer,
                    rewrite_scratch,
                );
            }

            pub fn commit(self: *Transaction) Error!void {
                try self.requireActive();
                const core = self.corePtr();
                core.state.page_count = core.device.blocksCount();
                core.state.catalog_epoch +%= 1;
                core.state.generation +%= 1;
                core.state.clean = true;
                try writeBoot(core);
                try core.transaction_batch.commit();
                core.transaction_active = false;
                self.active = false;
                try core.device.sync();
            }

            pub fn rollback(self: *Transaction) Error!void {
                try self.requireActive();
                const core = self.corePtr();
                core.catalog.deinit();
                try core.transaction_batch.discard();
                core.state = core.state_snapshot;
                core.state.clean = true;
                core.catalog = try Catalog.init(&core.raw_cache, &core.catalog_manager);
                try writeBoot(core);
                try core.raw_cache.flushAll();
                try core.device.sync();
                core.transaction_active = false;
                self.active = false;
            }

            pub fn deinit(self: *Transaction) void {
                if (self.active) {
                    self.rollback() catch @panic("DynamicDatabase transaction rollback failed");
                }
                self.* = undefined;
            }
        };

        /// Starts the only mutable control-plane transaction.
        pub fn begin(self: *Self) Error!Transaction {
            const core = self.corePtr();
            if (core.transaction_active) {
                return error.BatchActive;
            }
            core.state_snapshot = core.state;
            core.transaction_batch = try core.raw_cache.begin();
            core.transaction_active = true;
            core.state.clean = false;
            writeBoot(core) catch |err| {
                core.transaction_batch.discard() catch {};
                core.state = core.state_snapshot;
                core.transaction_active = false;
                return err;
            };
            var page = try core.raw_cache.fetch(0);
            defer page.deinit();
            try core.device.writeBlock(0, @constCast(try page.data()));
            try core.device.sync();
            return .{ .core_ = core };
        }

        /// Loads the catalog revision currently indexed by a component ID.
        pub fn getById(self: *Self, component_id: u64) Error!?Catalog.LoadedRecord {
            const core = self.corePtr();
            const ref = (try core.catalog_ids.get(component_id)) orelse return null;
            return try core.catalog.load(ref);
        }

        /// Loads the catalog revision currently indexed by an exact component name.
        pub fn getByName(self: *Self, name: []const u8) Error!?Catalog.LoadedRecord {
            const core = self.corePtr();
            const component_id = (try core.catalog_names.get(name)) orelse return null;
            return try self.getById(component_id);
        }

        fn preflightSchemaImpl(
            self: *Self,
            comptime SchemaT: type,
            comptime reject_unknown_components: bool,
        ) Error!void {
            const core = self.corePtr();
            var found = [_]bool{false} ** SchemaT.fields.len;
            var iterator = try core.catalog.iterator(core.state.catalog_record_count);
            defer iterator.deinit();
            while (try iterator.next()) |entry| {
                const id_ref = (try core.catalog_ids.get(entry.record.component_id)) orelse
                    return error.CatalogIndexMismatch;
                if (id_ref.getPageId() != entry.ref.getPageId() or
                    id_ref.getSlotId() != entry.ref.getSlotId() or
                    id_ref.getRecordRevision() != entry.ref.getRecordRevision())
                {
                    // Immutable historical revisions remain in the catalog chain.
                    continue;
                }
                const index = file.schema_preflight.validateRecord(SchemaT, entry.record) catch |err| {
                    if (err == error.UnknownComponent and !reject_unknown_components) {
                        continue;
                    }
                    return err;
                };
                if (comptime SchemaT.fields.len == 0) {
                    return error.UnknownComponent;
                } else {
                    if (found[index]) {
                        return error.DuplicateComponent;
                    }
                    found[index] = true;
                }

                const name_id = (try core.catalog_names.get(entry.record.name)) orelse
                    return error.CatalogIndexMismatch;
                if (name_id != entry.record.component_id) {
                    return error.CatalogIndexMismatch;
                }
            }
            for (found) |present| {
                if (!present) {
                    return error.MissingComponent;
                }
            }
        }

        /// Performs a complete strict catalog and index scan against a compiled
        /// schema before any typed component runtimes are constructed.
        pub fn preflightSchema(self: *Self, comptime SchemaT: type) Error!void {
            return self.preflightSchemaImpl(SchemaT, true);
        }

        /// Validates compiled components while preserving structurally valid
        /// current catalog components that this build does not recognize.
        pub fn preflightKnownSchema(self: *Self, comptime SchemaT: type) Error!void {
            return self.preflightSchemaImpl(SchemaT, false);
        }

        /// Restores a known binding's runtime metadata from its catalog page.
        pub fn restoreMetadata(
            self: *Self,
            comptime BindingT: type,
            metadata_page_id: u64,
            component_id: u64,
            runtime: *BindingT.Runtime,
        ) Error!void {
            const core = self.corePtr();
            const page_id = std.math.cast(DevicePageId, metadata_page_id) orelse return error.PageIdTooLarge;
            var page = try core.raw_cache.fetch(page_id);
            defer page.deinit();
            const view = try file.component_metadata_page.read(try page.data(), .{
                .component_id = component_id,
                .metadata_format_version = BindingT.DynamicMetadata.format_version,
            });
            try file.component_metadata.restore(BindingT, runtime, view.payload, core.raw_cache.pageCount());
        }

        /// Returns the database-owned raw page cache. Its address remains stable
        /// for the lifetime of this database because the control-plane core is heap-owned.
        pub fn rawCache(self: *Self) *RawCache {
            return &self.corePtr().raw_cache;
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            const core = self.coreConstPtr();
            return .{
                .core_address = @intFromPtr(core),
                .device_address = @intFromPtr(&core.device),
                .cache_address = @intFromPtr(&core.raw_cache),
                .page_size = core.device.blockSize(),
                .page_count = core.device.blocksCount(),
            };
        }

        /// Transfers device ownership out and invalidates the database.
        pub fn takeDevice(self: *Self) Error!DeviceT {
            const core = self.corePtr();
            try core.raw_cache.flushAll();
            try core.device.sync();
            const device = core.device;
            deinitCore(core, false);
            self.* = undefined;
            return device;
        }

        pub fn deinit(self: *Self) void {
            if (self.corePtr().transaction_active) {
                @panic("DynamicDatabase.deinit called with an active transaction");
            }
            deinitCore(self.corePtr(), true);
            self.* = undefined;
        }
    };
}
