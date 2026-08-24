const std = @import("std");
const device_interfaces = @import("fullaz").device.interfaces;
const shape = @import("../../component/shape.zig");
const DynamicDatabase = @import("dynamic.zig").DynamicDatabase;
const DynamicDatabaseWithWal = @import("dynamic.zig").DynamicDatabaseWithWal;
const catalog_record = @import("../../file/catalog/record.zig");
const schema_fingerprint = @import("../../component/fingerprint.zig");

/// A compiled schema layered on the dynamic database catalog.
pub fn DynamicSchemaDatabase(comptime SchemaT: type, comptime DeviceT: type) type {
    return DynamicSchemaDatabaseImpl(SchemaT, DeviceT, DynamicDatabase(DeviceT), null);
}

/// A compiled schema layered on the WAL-backed dynamic database catalog.
pub fn DynamicSchemaDatabaseWithWal(comptime SchemaT: type, comptime DeviceT: type, comptime LogDeviceT: type) type {
    return DynamicSchemaDatabaseImpl(
        SchemaT,
        DeviceT,
        DynamicDatabaseWithWal(DeviceT, LogDeviceT),
        LogDeviceT,
    );
}

fn DynamicSchemaDatabaseImpl(
    comptime SchemaT: type,
    comptime DeviceT: type,
    comptime DatabaseT: type,
    comptime LogDeviceT: ?type,
) type {
    if (!@hasDecl(SchemaT, "PageId") or !@hasDecl(SchemaT, "fields")) {
        @compileError("DynamicSchemaDatabase requires a pages Schema type");
    }
    comptime device_interfaces.assertBlockDevice(DeviceT);
    if (DeviceT.BlockId != SchemaT.PageId) {
        @compileError("DynamicSchemaDatabase DeviceT.BlockId must match SchemaT.PageId");
    }

    const Database = DatabaseT;
    const Log = LogDeviceT orelse void;
    const RawCache = Database.RawCacheType;
    const Cache = Database.CacheType;
    const Backend = struct {
        const Self = @This();

        pub const PageId = SchemaT.PageId;
        pub const CacheType = Cache;

        allocator_value: std.mem.Allocator,
        cache_ptr: *Cache,

        pub fn init(allocator_value: std.mem.Allocator, cache_ptr: *Cache) Self {
            return .{ .allocator_value = allocator_value, .cache_ptr = cache_ptr };
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.allocator_value;
        }

        pub fn cache(self: *Self) *Cache {
            return self.cache_ptr;
        }

        pub fn cacheConst(self: *const Self) *const Cache {
            return self.cache_ptr;
        }
    };
    const Bindings = shape.bindings(SchemaT, Backend);
    const Components = shape.runtimes(SchemaT, Bindings);
    const TransactionStates = shape.transactionStates(SchemaT, Bindings);
    const ComponentOptions = shape.initOptions(SchemaT, Bindings);
    const component_default: ?*const anyopaque = if (shape.canDefaultInit(ComponentOptions)) blk: {
        const value: ComponentOptions = .{};
        break :blk &value;
    } else null;
    const default_cache_frames: usize = 64;
    const DatabaseInitOptions = @Struct(
        .auto,
        null,
        &[_][]const u8{ "image_id", "cache_frames", "components" },
        &[_]type{ [16]u8, usize, ComponentOptions },
        &[_]std.builtin.Type.StructField.Attributes{
            .{ .default_value_ptr = &([_]u8{0} ** 16) },
            .{ .default_value_ptr = &default_cache_frames },
            .{ .default_value_ptr = component_default },
        },
    );
    const Core = struct {
        allocator: std.mem.Allocator,
        database: Database,
        backend: Backend,
        components: Components,
        initialized_count: usize = 0,
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
        pub const InitOptions = DatabaseInitOptions;
        pub const Error = Database.Error ||
            Cache.Error ||
            catalog_record.Error ||
            shape.componentErrors(Bindings, 0) ||
            error{MetadataFormatVersionMismatch};

        core_: *align(@alignOf(Core)) anyopaque,

        fn corePtr(self: *Self) *Core {
            return @ptrCast(self.core_);
        }

        fn coreConstPtr(self: *const Self) *const Core {
            return @ptrCast(self.core_);
        }

        fn bindingType(comptime name: []const u8) type {
            return Bindings[comptime SchemaT.indexOf(name)];
        }

        fn constProxyType(comptime name: []const u8) type {
            return bindingType(name).ConstProxy;
        }

        fn proxyType(comptime name: []const u8) type {
            return bindingType(name).Proxy;
        }

        fn captureTransactionStates(core: *const Core) TransactionStates {
            var states: TransactionStates = undefined;
            inline for (SchemaT.fields, 0..) |field, index| {
                @field(states, field.name) = Bindings[index].captureTransactionState(
                    &@field(core.components, field.name),
                );
            }
            return states;
        }

        fn restoreTransactionStates(core: *Core, states: TransactionStates) void {
            inline for (SchemaT.fields, 0..) |field, index| {
                Bindings[index].restoreTransactionState(
                    &@field(core.components, field.name),
                    @field(states, field.name),
                );
            }
        }

        pub const Transaction = struct {
            const TransactionSelf = @This();

            core: *Core,
            raw: Database.Transaction,
            states: TransactionStates,
            active: bool = true,

            fn requireActive(self: *const TransactionSelf) Error!void {
                if (!self.active) {
                    return error.TransactionInactive;
                }
            }

            /// Returns the exact mutable proxy type declared by the named binding.
            pub fn get(self: *TransactionSelf, comptime name: []const u8) proxyType(name) {
                self.requireActive() catch @panic("DynamicSchemaDatabase transaction is inactive");
                const Binding = bindingType(name);
                return Binding.proxy(&@field(self.core.components, name));
            }

            pub fn commit(self: *TransactionSelf) Error!void {
                try self.requireActive();
                inline for (SchemaT.fields, 0..) |field, index| {
                    var loaded = (try self.core.database.getByName(field.name)) orelse
                        return error.MissingComponent;
                    defer loaded.deinit();
                    const record = try loaded.view();
                    try self.raw.storeMetadata(
                        Bindings[index],
                        record.metadata_root_pid,
                        record.component_id,
                        &@field(self.core.components, field.name),
                    );
                }
                try self.raw.commit();
                self.active = false;
            }

            pub fn rollback(self: *TransactionSelf) Error!void {
                try self.requireActive();
                try self.raw.rollback();
                restoreTransactionStates(self.core, self.states);
                self.active = false;
            }

            pub fn deinit(self: *TransactionSelf) void {
                if (self.active) {
                    self.rollback() catch @panic("DynamicSchemaDatabase transaction rollback failed");
                }
                self.raw.deinit();
                self.* = undefined;
            }
        };

        fn deinitComponents(core: *Core) void {
            inline for (0..SchemaT.fields.len) |reverse_index| {
                const index = SchemaT.fields.len - 1 - reverse_index;
                if (index < core.initialized_count) {
                    const field = SchemaT.fields[index];
                    Bindings[index].deinitRuntime(&@field(core.components, field.name));
                }
            }
            core.initialized_count = 0;
        }

        fn deinitCore(core: *Core) void {
            const allocator = core.allocator;
            deinitComponents(core);
            core.database.deinit();
            allocator.destroy(core);
        }

        fn initCore(allocator: std.mem.Allocator, database: Database) Error!*Core {
            const core = try allocator.create(Core);
            errdefer allocator.destroy(core);
            core.allocator = allocator;
            core.database = database;
            core.backend = Backend.init(allocator, core.database.cache());
            core.initialized_count = 0;
            return core;
        }

        fn initFormattedComponents(core: *Core, options: InitOptions) Error!void {
            core.components = undefined;
            errdefer deinitComponents(core);

            var transaction = try core.database.begin();
            defer transaction.deinit();
            inline for (SchemaT.fields, 0..) |field, index| {
                const Binding = Bindings[index];
                const allocation = try transaction.allocateComponent(field.descriptor.Trait.page_kind_count);
                try Binding.initRuntime(
                    &@field(core.components, field.name),
                    &core.backend,
                    allocation.page_kinds,
                    @field(options.components, field.name),
                );
                core.initialized_count = index + 1;

                const metadata_page_id = try transaction.initializeMetadata(
                    Binding,
                    allocation.component_id,
                    &@field(core.components, field.name),
                );
                const page_size = core.database.cache().pageSize();
                const record_bytes = try core.allocator.alloc(u8, page_size);
                defer core.allocator.free(record_bytes);
                const record_scratch = try core.allocator.alloc(u8, page_size);
                defer core.allocator.free(record_scratch);
                try catalog_record.format(record_bytes, record_scratch, .{
                    .component_id = allocation.component_id,
                    .revision = 1,
                    .name = field.name,
                    .kind_name = field.descriptor.Trait.kind_name,
                    .component_format_version = field.descriptor.Trait.format_version,
                    .metadata_format_version = Binding.DynamicMetadata.format_version,
                    .page_kind_base = allocation.page_kinds.base,
                    .page_kind_count = allocation.page_kinds.count,
                    .metadata_root_pid = metadata_page_id,
                    .settings_fingerprint = schema_fingerprint.componentDigest(field.descriptor.Trait),
                    .dependency_ids = &.{},
                }, &.{});
                const encoded_size = try catalog_record.encodedByteSize(record_bytes);
                _ = try transaction.registerCatalogComponent(record_bytes[0..encoded_size]);
            }
            try transaction.commit();
        }

        fn initOpenedComponents(core: *Core, options: InitOptions) Error!void {
            core.components = undefined;
            errdefer deinitComponents(core);
            inline for (SchemaT.fields, 0..) |field, index| {
                const Binding = Bindings[index];
                var loaded = (try core.database.getByName(field.name)).?;
                defer loaded.deinit();
                const record = try loaded.view();
                if (record.metadata_format_version != Binding.DynamicMetadata.format_version) {
                    return error.MetadataFormatVersionMismatch;
                }
                try Binding.initRuntime(
                    &@field(core.components, field.name),
                    &core.backend,
                    .{ .base = record.page_kind_base, .count = record.page_kind_count },
                    @field(options.components, field.name),
                );
                core.initialized_count = index + 1;
                try core.database.restoreMetadata(
                    Binding,
                    record.metadata_root_pid,
                    record.component_id,
                    &@field(core.components, field.name),
                );
            }
        }

        fn formatImpl(allocator: std.mem.Allocator, database_value: Database, options: InitOptions) Error!Self {
            var database = database_value;
            errdefer database.deinit();
            const core = try initCore(allocator, database);
            database = undefined;
            errdefer deinitCore(core);
            try initFormattedComponents(core, options);
            return .{ .core_ = core };
        }

        fn openImpl(allocator: std.mem.Allocator, database_value: Database, options: InitOptions) Error!Self {
            var database = database_value;
            errdefer database.deinit();
            try database.preflightSchema(SchemaT);
            const core = try initCore(allocator, database);
            database = undefined;
            errdefer deinitCore(core);
            try initOpenedComponents(core, options);
            return .{ .core_ = core };
        }

        fn formatWithoutWal(allocator: std.mem.Allocator, device: DeviceT, options: InitOptions) Error!Self {
            return formatImpl(allocator, try Database.format(allocator, device, .{
                .image_id = options.image_id,
                .cache_frames = options.cache_frames,
            }), options);
        }

        fn openWithoutWal(allocator: std.mem.Allocator, device: DeviceT, options: InitOptions) Error!Self {
            return openImpl(allocator, try Database.open(allocator, device, .{
                .image_id = options.image_id,
                .cache_frames = options.cache_frames,
            }), options);
        }

        fn formatWithWal(
            allocator: std.mem.Allocator,
            device: DeviceT,
            log: Log,
            options: InitOptions,
        ) Error!Self {
            return formatImpl(allocator, try Database.format(allocator, device, log, .{
                .image_id = options.image_id,
                .cache_frames = options.cache_frames,
            }), options);
        }

        fn openWithWal(
            allocator: std.mem.Allocator,
            device: DeviceT,
            log: Log,
            options: InitOptions,
        ) Error!Self {
            return openImpl(allocator, try Database.open(allocator, device, log, .{
                .image_id = options.image_id,
                .cache_frames = options.cache_frames,
            }), options);
        }

        /// Formats an empty device and initializes every compiled component in one catalog transaction.
        pub const format = if (LogDeviceT == null) formatWithoutWal else formatWithWal;
        /// Opens and strictly validates the catalog before restoring component runtimes.
        pub const open = if (LogDeviceT == null) openWithoutWal else openWithWal;

        pub fn getConst(self: *const Self, comptime name: []const u8) *const constProxyType(name) {
            const Binding = bindingType(name);
            return Binding.proxyConst(&@field(self.coreConstPtr().components, name));
        }

        /// Starts the only mutable access scope. Active transactions roll back on deinit.
        /// Catalog rename and drop operations belong to the raw control plane:
        /// this facade's runtimes are bound to compile-time schema field names.
        pub fn begin(self: *Self) Error!Transaction {
            const core = self.corePtr();
            var raw = try core.database.begin();
            errdefer raw.deinit();
            return .{
                .core = core,
                .raw = raw,
                .states = captureTransactionStates(core),
            };
        }

        pub fn deinit(self: *Self) void {
            deinitCore(self.corePtr());
            self.* = undefined;
        }
    };
}
