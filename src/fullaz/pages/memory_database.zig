const std = @import("std");
const device = @import("../device/device.zig");
const page_cache = @import("../storage/page_cache/page_cache.zig");
const MemoryReclaimingCache = @import("memory_reclaiming_cache.zig").MemoryReclaimingCache;
const shape = @import("database_shape.zig");

fn DatabaseInitOptions(comptime ComponentOptionsT: type) type {
    const default_cache_frames: usize = 64;
    const components_default_ptr: ?*const anyopaque = if (shape.canDefaultInit(ComponentOptionsT)) blk: {
        const default_value: ComponentOptionsT = .{};
        break :blk &default_value;
    } else null;
    const field_names = [_][]const u8{ "page_size", "cache_frames", "components" };
    const field_types = [_]type{ usize, usize, ComponentOptionsT };
    const field_attrs = [_]std.builtin.Type.StructField.Attributes{
        .{},
        .{ .default_value_ptr = &default_cache_frames },
        .{ .default_value_ptr = components_default_ptr },
    };
    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

pub fn MemoryDatabase(comptime SchemaT: type) type {
    if (!@hasDecl(SchemaT, "PageId") or !@hasDecl(SchemaT, "fields")) {
        @compileError("MemoryDatabase requires a pages Schema type");
    }
    const Device = device.MemoryBlock(SchemaT.PageId);
    const RawCache = page_cache.PageCache(Device);
    const Cache = MemoryReclaimingCache(RawCache);
    const Backend = struct {
        const Self = @This();

        pub const PageId = SchemaT.PageId;
        pub const CacheType = Cache;

        allocator_value: std.mem.Allocator,
        cache_ptr: *Cache,

        fn init(allocator_value: std.mem.Allocator, cache_ptr: *Cache) Self {
            return .{
                .allocator_value = allocator_value,
                .cache_ptr = cache_ptr,
            };
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
    const Options = DatabaseInitOptions(ComponentOptions);
    const Core = struct {
        allocator: std.mem.Allocator,
        device: Device,
        raw_cache: RawCache,
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
        pub const DeviceType = Device;
        pub const RawCacheType = RawCache;
        pub const CacheType = Cache;
        pub const BackendType = Backend;
        pub const ComponentsStorageType = Components;
        pub const ComponentTransactionStatesType = TransactionStates;
        pub const ComponentInitOptionsType = ComponentOptions;
        pub const InitOptions = Options;
        pub const Error = std.mem.Allocator.Error ||
            Device.Error ||
            RawCache.Error ||
            Cache.Error ||
            shape.componentErrors(bindings, 0) ||
            error{InvalidCacheFrames};

        core_: *align(@alignOf(Core)) anyopaque,

        pub const Transaction = struct {
            const TransactionSelf = @This();

            core_: *align(@alignOf(Core)) anyopaque,
            generation_: u64,

            fn corePtr(self: *const TransactionSelf) *Core {
                return @ptrCast(self.core_);
            }

            fn activeCore(self: *const TransactionSelf) Error!*Core {
                const core_ptr = self.corePtr();
                if (!core_ptr.transaction_active or
                    core_ptr.transaction_generation != self.generation_)
                {
                    return Error.TransactionInactive;
                }
                return core_ptr;
            }

            pub fn get(
                self: *TransactionSelf,
                comptime name: []const u8,
            ) proxyType(name) {
                const core_ptr = self.activeCore() catch
                    @panic("MemoryDatabase transaction is inactive");
                const Binding = bindingType(name);
                const runtime: *runtimeType(name) = &@field(core_ptr.components, name);
                return Binding.proxy(runtime);
            }

            pub fn getConst(
                self: *const TransactionSelf,
                comptime name: []const u8,
            ) *const constProxyType(name) {
                const core_ptr = self.activeCore() catch
                    @panic("MemoryDatabase transaction is inactive");
                const Binding = bindingType(name);
                const runtime: *const runtimeType(name) = &@field(core_ptr.components, name);
                return Binding.proxyConst(runtime);
            }

            pub fn commit(self: *TransactionSelf) Error!void {
                const core_ptr = try self.activeCore();
                try core_ptr.transaction_cache_batch.commit();
                core_ptr.transaction_active = false;
            }

            pub fn rollback(self: *TransactionSelf) Error!void {
                const core_ptr = try self.activeCore();
                try core_ptr.transaction_cache_batch.discard();
                restoreTransactionStates(core_ptr, core_ptr.transaction_component_states);
                core_ptr.transaction_active = false;
            }

            pub fn deinit(self: *TransactionSelf) void {
                if (self.activeCore()) |_| {
                    self.rollback() catch @panic("Failed to roll back MemoryDatabase transaction");
                } else |_| {}
            }
        };

        fn bindingType(comptime name: []const u8) type {
            const index = comptime SchemaT.indexOf(name);
            return bindings[index];
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

        fn corePtr(self: *Self) *Core {
            return @ptrCast(self.core_);
        }

        fn coreConstPtr(self: *const Self) *const Core {
            return @ptrCast(self.core_);
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

        pub fn init(allocator: std.mem.Allocator, options: InitOptions) Error!Self {
            if (options.cache_frames == 0) {
                return Error.InvalidCacheFrames;
            }

            const core = try allocator.create(Core);
            errdefer allocator.destroy(core);
            core.allocator = allocator;
            core.device = try Device.init(allocator, options.page_size);
            errdefer core.device.deinit();
            core.raw_cache = try RawCache.init(
                &core.device,
                allocator,
                options.cache_frames,
            );
            errdefer core.raw_cache.deinit();
            core.cache = Cache.init(allocator, &core.raw_cache);
            errdefer core.cache.deinit();
            core.backend = Backend.init(allocator, &core.cache);
            core.components = undefined;
            core.transaction_active = false;
            core.transaction_generation = 0;

            var initialized_components: usize = 0;
            errdefer deinitComponentPrefix(core, initialized_components);
            inline for (SchemaT.fields, 0..) |field, index| {
                try bindings[index].initRuntime(
                    &@field(core.components, field.name),
                    &core.backend,
                    field.page_kinds,
                    @field(options.components, field.name),
                );
                initialized_components = index + 1;
            }

            return .{ .core_ = core };
        }

        /// Starts the only mutable access scope. Active transactions roll back on deinit.
        pub fn begin(self: *Self) Error!Transaction {
            const core_ptr = self.corePtr();
            if (core_ptr.transaction_active) {
                return Error.BatchActive;
            }
            core_ptr.transaction_component_states = captureTransactionStates(core_ptr);
            core_ptr.transaction_cache_batch = try core_ptr.cache.begin();
            core_ptr.transaction_generation +%= 1;
            core_ptr.transaction_active = true;
            return .{
                .core_ = core_ptr,
                .generation_ = core_ptr.transaction_generation,
            };
        }

        pub fn getConst(self: *const Self, comptime name: []const u8) *const constProxyType(name) {
            const Binding = bindingType(name);
            const core_ptr = self.coreConstPtr();
            const runtime: *const runtimeType(name) = &@field(core_ptr.components, name);
            return Binding.proxyConst(runtime);
        }

        pub const Diagnostics = struct {
            core_address: usize,
            cache_address: usize,
            device_address: usize,
            page_size: usize,
            physical_page_count: usize,
            device_page_count: usize,
            free_page_count: usize,
        };

        pub fn diagnostics(self: *const Self) Diagnostics {
            const core_ptr = self.coreConstPtr();
            return .{
                .core_address = @intFromPtr(core_ptr),
                .cache_address = @intFromPtr(&core_ptr.cache),
                .device_address = @intFromPtr(&core_ptr.device),
                .page_size = core_ptr.cache.pageSize(),
                .physical_page_count = core_ptr.cache.physical_page_count,
                .device_page_count = core_ptr.device.blocksCount(),
                .free_page_count = core_ptr.cache.free_pages.items.len,
            };
        }

        pub fn deinit(self: *Self) void {
            const core_ptr = self.corePtr();
            if (core_ptr.transaction_active) {
                @panic("MemoryDatabase.deinit called with an active transaction");
            }
            const allocator = core_ptr.allocator;
            deinitComponentPrefix(core_ptr, SchemaT.fields.len);
            core_ptr.cache.deinit();
            core_ptr.raw_cache.deinit();
            core_ptr.device.deinit();
            allocator.destroy(core_ptr);
            self.* = undefined;
        }
    };
}
