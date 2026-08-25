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

    const ReclaimStore = struct {
        const StoreSelf = @This();

        pub const PageId = DevicePageId;
        pub const Error = error{PageIdTooLarge};

        device: *DeviceT,
        state: *file.boot.State,

        pub fn getRoot(self: *const StoreSelf) ?PageId {
            const raw = self.state.free_root orelse return null;
            return std.math.cast(PageId, raw) orelse unreachable;
        }

        pub fn setRoot(self: *StoreSelf, root: ?PageId) Error!void {
            self.state.free_root = if (root) |page_id|
                std.math.cast(u64, page_id) orelse return error.PageIdTooLarge
            else
                null;
        }

        pub fn pageCount(self: *const StoreSelf) usize {
            return self.device.blocksCount();
        }

        pub fn isReserved(_: *const StoreSelf, page_id: PageId) bool {
            return page_id == 0;
        }
    };
    const Cache = page_cache.PersistentReclaimingCache(RawCache, ReclaimStore);

    const CatalogManager = struct {
        pub const PageId = DeviceT.BlockId;
        pub const Size = u64;
        pub const Error = Cache.Error;

        state: *file.boot.State,
        cache: *Cache,

        pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
            return self.cache.free(page_id);
        }

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
        pub const Error = Cache.Error;

        root: *?u64,
        cache: *Cache,

        pub fn getRoot(self: *const @This()) ?PageId {
            const raw = self.root.* orelse return null;
            return std.math.cast(PageId, raw);
        }

        pub fn setRoot(self: *@This(), value: ?PageId) Error!void {
            self.root.* = if (value) |page_id| @intCast(page_id) else null;
        }

        pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
            return self.cache.free(page_id);
        }
    };
    const Catalog = file.CatalogStore(Cache, CatalogManager);
    const CatalogIds = file.CatalogIdIndex(Cache, IndexManager);
    const CatalogNames = file.CatalogNameIndex(Cache, IndexManager);
    const Core = struct {
        allocator: std.mem.Allocator,
        device: DeviceT,
        log: Log,
        raw_cache: RawCache,
        state: file.boot.State,
        reclaim_store: ReclaimStore,
        cache: Cache,
        catalog_manager: CatalogManager,
        catalog_id_manager: IndexManager,
        catalog_name_manager: IndexManager,
        catalog: Catalog,
        catalog_ids: CatalogIds,
        catalog_names: CatalogNames,
        transaction_active: bool = false,
        transaction_batch: Cache.WriteBatch = undefined,
        state_snapshot: file.boot.State = undefined,
    };

    return struct {
        const Self = @This();

        pub const DeviceType = DeviceT;
        pub const LogDeviceType = LogDeviceT;
        pub const WalType = WalT;
        pub const RawCacheType = RawCache;
        pub const CacheType = Cache;
        pub const State = file.boot.State;
        pub const CatalogCompactionResult = struct {
            records_before: u64,
            records_retained: u64,
            historical_records_removed: u64,
            metadata_pages_reclaimed: u64,
        };
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
            Cache.Error ||
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
                RevisionExhausted,
                NameMismatch,
                NameConflict,
                ComponentInUse,
                MissingDependency,
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
            core.reclaim_store = .{ .device = &core.device, .state = &core.state };
            core.cache = Cache.init(&core.raw_cache, &core.reclaim_store);
            errdefer core.cache.deinit();
            core.catalog_manager = .{ .state = &core.state, .cache = &core.cache };
            core.catalog_id_manager = .{ .root = &core.state.id_radix_root, .cache = &core.cache };
            core.catalog_name_manager = .{ .root = &core.state.name_bpt_root, .cache = &core.cache };
            core.catalog = try Catalog.init(&core.cache, &core.catalog_manager);
            errdefer core.catalog.deinit();
            core.catalog_ids = try CatalogIds.init(&core.cache, &core.catalog_id_manager);
            errdefer core.catalog_ids.deinit();
            core.catalog_names = try CatalogNames.init(&core.cache, &core.catalog_name_manager);
            errdefer core.catalog_names.deinit();
            core.transaction_active = false;
            return core;
        }

        fn deinitCore(core: *Core, deinit_device: bool) void {
            const allocator = core.allocator;
            core.catalog_names.deinit();
            core.catalog_ids.deinit();
            core.catalog.deinit();
            core.cache.deinit();
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

        fn sameRef(left: file.CatalogRef, right: file.CatalogRef) bool {
            return left.getPageId() == right.getPageId() and
                left.getSlotId() == right.getSlotId() and
                left.getRecordRevision() == right.getRecordRevision();
        }

        fn loadCurrentById(core: *Core, component_id: u64) Error!?Catalog.LoadedRecord {
            const ref = (try core.catalog_ids.get(component_id)) orelse return null;
            return try core.catalog.load(ref);
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
            errdefer deinitCore(core, false);
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
            const core = try initCore(
                allocator,
                device,
                log_value,
                try initialState(&device, options),
                options,
            );
            errdefer deinitCore(core, false);
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
            if (core.state.free_root) |free_root| {
                _ = std.math.cast(DevicePageId, free_root) orelse return error.BadFreeList;
            }
            try core.cache.validateFreeList();
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

            fn appendLifecycleSuccessor(
                self: *Transaction,
                previous: file.catalog_record.View,
                name: []const u8,
                state: file.catalog_record.LifecycleState,
            ) Error!file.CatalogRef {
                const core = self.corePtr();
                const revision = std.math.add(u32, previous.revision, 1) catch {
                    return error.RevisionExhausted;
                };
                const dependencies = try core.allocator.alloc(u64, previous.dependency_count);
                defer core.allocator.free(dependencies);
                for (dependencies, 0..) |*dependency, index| {
                    dependency.* = (try previous.getDependency(index)).?;
                }
                const record_bytes = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(record_bytes);
                const record_scratch = try core.allocator.alloc(u8, core.device.blockSize());
                defer core.allocator.free(record_scratch);
                try file.catalog_record.format(record_bytes, record_scratch, .{
                    .component_id = previous.component_id,
                    .revision = revision,
                    .name = name,
                    .kind_name = previous.kind_name,
                    .component_format_version = previous.component_format_version,
                    .metadata_format_version = previous.metadata_format_version,
                    .page_kind_base = previous.page_kind_base,
                    .page_kind_count = previous.page_kind_count,
                    .metadata_root_pid = previous.metadata_root_pid,
                    .settings_fingerprint = previous.settings_fingerprint,
                    .dependency_ids = dependencies,
                    .state = state,
                }, previous.payload);
                return try core.catalog.append(
                    record_bytes[0..try file.catalog_record.encodedByteSize(record_bytes)],
                );
            }

            fn hasActiveDependent(self: *Transaction, component_id: u64) Error!bool {
                const core = self.corePtr();
                var iterator = try core.catalog.iterator(core.state.catalog_record_count);
                defer iterator.deinit();
                while (try iterator.next()) |entry| {
                    const current_ref = (try core.catalog_ids.get(entry.record.component_id)) orelse {
                        return error.CatalogIndexMismatch;
                    };
                    if (!sameRef(entry.ref, current_ref) or entry.record.state == .dropped) {
                        continue;
                    }
                    for (0..entry.record.dependency_count) |index| {
                        if ((try entry.record.getDependency(index)).? == component_id) {
                            return true;
                        }
                    }
                }
                return false;
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
                if (record.revision != 1 or record.state != .active) {
                    return error.RevisionMismatch;
                }
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

            /// Appends one active immutable successor with the same component name.
            pub fn replaceCatalogRevision(self: *Transaction, encoded_record: []const u8) Error!file.CatalogRef {
                try self.requireActive();
                const core = self.corePtr();
                const replacement = try file.catalog_record.read(encoded_record);
                const current_ref = (try core.catalog_ids.get(replacement.component_id)) orelse
                    return error.MissingComponent;
                var current = try core.catalog.load(current_ref);
                defer current.deinit();
                const previous = try current.view();
                const next_revision = std.math.add(u32, previous.revision, 1) catch {
                    return error.RevisionExhausted;
                };
                if (previous.state != .active or replacement.state != .active or
                    replacement.revision != next_revision)
                {
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

            pub fn renameComponent(
                self: *Transaction,
                name: []const u8,
                new_name: []const u8,
            ) Error!bool {
                try self.requireActive();
                const core = self.corePtr();
                const component_id = (try core.catalog_names.get(name)) orelse return false;
                return self.renameComponentById(component_id, new_name);
            }

            pub fn renameComponentById(
                self: *Transaction,
                component_id: u64,
                new_name: []const u8,
            ) Error!bool {
                try self.requireActive();
                const core = self.corePtr();
                var current = (try loadCurrentById(core, component_id)) orelse return false;
                defer current.deinit();
                const previous = try current.view();
                if (previous.state == .dropped or std.mem.eql(u8, previous.name, new_name)) {
                    return false;
                }
                const name_id = (try core.catalog_names.get(previous.name)) orelse
                    return error.CatalogIndexMismatch;
                if (name_id != component_id) {
                    return error.CatalogIndexMismatch;
                }
                if (try core.catalog_names.get(new_name) != null) {
                    return error.NameConflict;
                }

                var mutated = false;
                errdefer if (mutated) {
                    core.cache.markTransactionFailed();
                };
                const successor = try self.appendLifecycleSuccessor(previous, new_name, .active);
                mutated = true;
                try core.catalog_ids.set(component_id, successor);
                try core.catalog_names.set(new_name, component_id);
                if (!try core.catalog_names.remove(previous.name)) {
                    return error.CatalogIndexMismatch;
                }
                return true;
            }

            pub fn dropComponent(self: *Transaction, name: []const u8) Error!bool {
                try self.requireActive();
                const component_id = (try self.corePtr().catalog_names.get(name)) orelse return false;
                return self.dropComponentById(component_id);
            }

            pub fn dropComponentById(self: *Transaction, component_id: u64) Error!bool {
                try self.requireActive();
                const core = self.corePtr();
                var current = (try loadCurrentById(core, component_id)) orelse return false;
                defer current.deinit();
                const previous = try current.view();
                if (previous.state == .dropped) {
                    return false;
                }
                const name_id = (try core.catalog_names.get(previous.name)) orelse
                    return error.CatalogIndexMismatch;
                if (name_id != component_id) {
                    return error.CatalogIndexMismatch;
                }
                if (try self.hasActiveDependent(component_id)) {
                    return error.ComponentInUse;
                }
                if (core.state.live_component_count == 0) {
                    return error.CatalogIndexMismatch;
                }

                var mutated = false;
                errdefer if (mutated) {
                    core.cache.markTransactionFailed();
                };
                const successor = try self.appendLifecycleSuccessor(previous, previous.name, .dropped);
                mutated = true;
                try core.catalog_ids.set(component_id, successor);
                if (!try core.catalog_names.remove(previous.name)) {
                    return error.CatalogIndexMismatch;
                }
                core.state.live_component_count -= 1;
                return true;
            }

            /// Rebuilds current catalog state and reclaims unreachable historical metadata.
            /// The result becomes durable only when the surrounding transaction commits.
            pub fn compactCatalog(self: *Transaction) Error!CatalogCompactionResult {
                try self.requireActive();
                const core = self.corePtr();
                const Retained = struct {
                    component_id: u64,
                    state: file.catalog_record.LifecycleState,
                    encoded_record: []u8,
                };
                const MetadataReference = struct {
                    component_id: u64,
                    metadata_format_version: u32,
                    retained: bool,
                };

                var retained: std.ArrayList(Retained) = .empty;
                defer {
                    for (retained.items) |entry| {
                        core.allocator.free(entry.encoded_record);
                    }
                    retained.deinit(core.allocator);
                }
                var retained_ids = std.AutoHashMap(u64, void).init(core.allocator);
                defer retained_ids.deinit();
                var metadata = std.AutoHashMap(DevicePageId, MetadataReference).init(core.allocator);
                defer metadata.deinit();

                var active_count: u64 = 0;
                {
                    var iterator = try core.catalog.iterator(core.state.catalog_record_count);
                    defer iterator.deinit();
                    while (try iterator.next()) |entry| {
                        const metadata_page_id = std.math.cast(
                            DevicePageId,
                            entry.record.metadata_root_pid,
                        ) orelse return error.PageIdTooLarge;
                        const current_ref = (try core.catalog_ids.get(entry.record.component_id)) orelse
                            return error.CatalogIndexMismatch;
                        const is_retained = sameRef(entry.ref, current_ref);
                        const metadata_result = try metadata.getOrPut(metadata_page_id);
                        if (metadata_result.found_existing) {
                            const existing = metadata_result.value_ptr.*;
                            if (existing.component_id != entry.record.component_id or
                                existing.metadata_format_version != entry.record.metadata_format_version)
                            {
                                return error.CatalogIndexMismatch;
                            }
                            metadata_result.value_ptr.retained = metadata_result.value_ptr.retained or is_retained;
                        } else {
                            metadata_result.value_ptr.* = .{
                                .component_id = entry.record.component_id,
                                .metadata_format_version = entry.record.metadata_format_version,
                                .retained = is_retained,
                            };
                        }
                        if (!is_retained) {
                            continue;
                        }
                        if (retained_ids.contains(entry.record.component_id)) {
                            return error.CatalogIndexMismatch;
                        }
                        try retained_ids.put(entry.record.component_id, {});
                        if (entry.record.state == .active) {
                            const name_id = (try core.catalog_names.get(entry.record.name)) orelse
                                return error.CatalogIndexMismatch;
                            if (name_id != entry.record.component_id) {
                                return error.CatalogIndexMismatch;
                            }
                            active_count += 1;
                        } else if (try core.catalog_names.get(entry.record.name)) |name_id| {
                            if (name_id == entry.record.component_id) {
                                return error.CatalogIndexMismatch;
                            }
                        }
                        const encoded_record = try core.allocator.dupe(u8, entry.encoded_record);
                        errdefer core.allocator.free(encoded_record);
                        try retained.append(core.allocator, .{
                            .component_id = entry.record.component_id,
                            .state = entry.record.state,
                            .encoded_record = encoded_record,
                        });
                    }
                }
                if (active_count != core.state.live_component_count) {
                    return error.CatalogIndexMismatch;
                }
                if (retained.items.len == core.state.catalog_record_count) {
                    return .{
                        .records_before = core.state.catalog_record_count,
                        .records_retained = core.state.catalog_record_count,
                        .historical_records_removed = 0,
                        .metadata_pages_reclaimed = 0,
                    };
                }
                const old_catalog_pages = try core.catalog.collectPageIds(
                    core.allocator,
                    core.state.catalog_record_count,
                );
                defer core.allocator.free(old_catalog_pages);

                var candidate_state = core.state;
                candidate_state.catalog_first = null;
                candidate_state.catalog_last = null;
                candidate_state.catalog_record_count = 0;
                candidate_state.id_radix_root = null;
                candidate_state.name_bpt_root = null;
                var candidate_catalog_manager = CatalogManager{
                    .state = &candidate_state,
                    .cache = &core.cache,
                };
                var candidate_id_manager = IndexManager{
                    .root = &candidate_state.id_radix_root,
                    .cache = &core.cache,
                };
                var candidate_name_manager = IndexManager{
                    .root = &candidate_state.name_bpt_root,
                    .cache = &core.cache,
                };
                var candidate_catalog = try Catalog.init(&core.cache, &candidate_catalog_manager);
                defer candidate_catalog.deinit();
                var candidate_ids = try CatalogIds.init(&core.cache, &candidate_id_manager);
                defer candidate_ids.deinit();
                var candidate_names = try CatalogNames.init(&core.cache, &candidate_name_manager);
                defer candidate_names.deinit();

                var mutation_started = false;
                errdefer {
                    if (mutation_started) {
                        core.cache.markTransactionFailed();
                    }
                }
                for (retained.items) |entry| {
                    mutation_started = true;
                    const ref = try candidate_catalog.append(entry.encoded_record);
                    try candidate_ids.set(entry.component_id, ref);
                    if (entry.state == .active) {
                        const record = try file.catalog_record.read(entry.encoded_record);
                        try candidate_names.set(record.name, entry.component_id);
                    }
                }

                core.catalog.releaseCachedTail();
                for (retained.items) |entry| {
                    if (entry.state == .active) {
                        const record = try file.catalog_record.read(entry.encoded_record);
                        if (!try core.catalog_names.remove(record.name)) {
                            return error.CatalogIndexMismatch;
                        }
                    }
                    if (!try core.catalog_ids.remove(entry.component_id)) {
                        return error.CatalogIndexMismatch;
                    }
                }
                core.state.catalog_first = candidate_state.catalog_first;
                core.state.catalog_last = candidate_state.catalog_last;
                core.state.catalog_record_count = candidate_state.catalog_record_count;
                core.state.id_radix_root = candidate_state.id_radix_root;
                core.state.name_bpt_root = candidate_state.name_bpt_root;

                for (old_catalog_pages) |page_id| {
                    try core.cache.free(page_id);
                }

                var metadata_pages_reclaimed: u64 = 0;
                var metadata_iterator = metadata.iterator();
                while (metadata_iterator.next()) |entry| {
                    if (entry.value_ptr.retained) {
                        continue;
                    }
                    const page_id = blk: {
                        var page = try core.cache.fetch(entry.key_ptr.*);
                        defer page.deinit();
                        const view = try file.component_metadata_page.readAny(try page.data());
                        if (view.state.component_id != entry.value_ptr.component_id or
                            view.state.metadata_format_version != entry.value_ptr.metadata_format_version)
                        {
                            return error.CatalogIndexMismatch;
                        }
                        break :blk try page.pid();
                    };
                    try core.cache.free(page_id);
                    metadata_pages_reclaimed += 1;
                }

                return .{
                    .records_before = core.state_snapshot.catalog_record_count,
                    .records_retained = candidate_state.catalog_record_count,
                    .historical_records_removed = core.state_snapshot.catalog_record_count -
                        candidate_state.catalog_record_count,
                    .metadata_pages_reclaimed = metadata_pages_reclaimed,
                };
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
                var page = try core.cache.create();
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
                var source_page = try core.cache.fetch(source_page_id);
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
                var target_page = try core.cache.create();
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
                try file.ComponentMetadataIo(BindingT, Cache).store(
                    &core.cache,
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
                core.catalog = try Catalog.init(&core.cache, &core.catalog_manager);
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
            core.transaction_batch = try core.cache.begin();
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
            return loadCurrentById(self.corePtr(), component_id);
        }

        /// Loads the catalog revision currently indexed by an exact component name.
        pub fn getByName(self: *Self, name: []const u8) Error!?Catalog.LoadedRecord {
            const core = self.corePtr();
            const component_id = (try core.catalog_names.get(name)) orelse return null;
            var loaded = (try loadCurrentById(core, component_id)) orelse return error.CatalogIndexMismatch;
            errdefer loaded.deinit();
            const record = try loaded.view();
            if (record.state != .active or record.component_id != component_id or
                !std.mem.eql(u8, record.name, name))
            {
                return error.CatalogIndexMismatch;
            }
            return loaded;
        }

        fn preflightSchemaImpl(
            self: *Self,
            comptime SchemaT: type,
            comptime reject_unknown_components: bool,
        ) Error!void {
            const core = self.corePtr();
            var found = [_]bool{false} ** SchemaT.fields.len;
            var active_count: u64 = 0;
            var iterator = try core.catalog.iterator(core.state.catalog_record_count);
            defer iterator.deinit();
            while (try iterator.next()) |entry| {
                const id_ref = (try core.catalog_ids.get(entry.record.component_id)) orelse
                    return error.CatalogIndexMismatch;
                if (!sameRef(id_ref, entry.ref)) {
                    // Immutable historical revisions remain in the catalog chain.
                    continue;
                }
                if (entry.record.state == .dropped) {
                    if (try core.catalog_names.get(entry.record.name)) |name_id| {
                        if (name_id == entry.record.component_id) {
                            return error.CatalogIndexMismatch;
                        }
                    }
                    continue;
                }
                active_count += 1;
                const name_id = (try core.catalog_names.get(entry.record.name)) orelse
                    return error.CatalogIndexMismatch;
                if (name_id != entry.record.component_id) {
                    return error.CatalogIndexMismatch;
                }
                for (0..entry.record.dependency_count) |dependency_index| {
                    const dependency_id = (try entry.record.getDependency(dependency_index)).?;
                    const dependency_state = blk: {
                        var dependency = (try loadCurrentById(core, dependency_id)) orelse
                            return error.MissingDependency;
                        defer dependency.deinit();
                        break :blk (try dependency.view()).state;
                    };
                    if (dependency_state != .active) {
                        return error.MissingDependency;
                    }
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
            }
            if (active_count != core.state.live_component_count) {
                return error.CatalogIndexMismatch;
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
            var page = try core.cache.fetch(page_id);
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

        /// Returns the database-owned transactional cache with durable page reclamation.
        pub fn cache(self: *Self) *Cache {
            return &self.corePtr().cache;
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
