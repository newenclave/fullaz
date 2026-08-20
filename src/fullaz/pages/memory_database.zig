const std = @import("std");
const component = @import("component.zig");
const device = @import("../device/device.zig");
const page_cache = @import("../storage/page_cache/page_cache.zig");
const MemoryReclaimingCache = @import("memory_reclaiming_cache.zig").MemoryReclaimingCache;

fn componentBindings(comptime SchemaT: type, comptime BackendT: type) [SchemaT.fields.len]type {
    @setEvalBranchQuota(100_000);
    var bindings: [SchemaT.fields.len]type = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        bindings[index] = component.bindingFor(field.descriptor, BackendT);
    }
    return bindings;
}

fn ComponentsStorage(comptime SchemaT: type, comptime bindings: anytype) type {
    const field_count = SchemaT.fields.len;
    comptime var field_names: [field_count][]const u8 = undefined;
    comptime var field_types: [field_count]type = undefined;
    comptime var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        field_names[index] = field.name;
        field_types[index] = bindings[index].Runtime;
        field_attrs[index] = .{};
    }
    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn ComponentTransactionStates(comptime SchemaT: type, comptime bindings: anytype) type {
    const field_count = SchemaT.fields.len;
    comptime var field_names: [field_count][]const u8 = undefined;
    comptime var field_types: [field_count]type = undefined;
    comptime var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        field_names[index] = field.name;
        field_types[index] = bindings[index].TransactionState;
        field_attrs[index] = .{};
    }
    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn canDefaultInit(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct" or type_info.@"struct".is_tuple) {
        @compileError("Pages component InitOptions must be a named struct");
    }
    inline for (type_info.@"struct".fields) |field| {
        if (field.default_value_ptr == null) {
            return false;
        }
    }
    return true;
}

fn ComponentInitOptions(comptime SchemaT: type, comptime bindings: anytype) type {
    const field_count = SchemaT.fields.len;
    comptime var field_names: [field_count][]const u8 = undefined;
    comptime var field_types: [field_count]type = undefined;
    comptime var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    inline for (SchemaT.fields, 0..) |field, index| {
        const Options = bindings[index].InitOptions;
        field_names[index] = field.name;
        field_types[index] = Options;
        field_attrs[index] = .{};
        if (canDefaultInit(Options)) {
            const default_value: Options = .{};
            field_attrs[index].default_value_ptr = &default_value;
        }
    }
    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn DatabaseInitOptions(comptime ComponentOptionsT: type) type {
    const default_cache_frames: usize = 64;
    const components_default_ptr: ?*const anyopaque = if (canDefaultInit(ComponentOptionsT)) blk: {
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

fn componentErrors(comptime bindings: anytype, comptime index: usize) type {
    if (index == bindings.len) {
        return error{};
    }
    return bindings[index].Error || componentErrors(bindings, index + 1);
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
    const bindings = componentBindings(SchemaT, Backend);
    const Components = ComponentsStorage(SchemaT, bindings);
    const TransactionStates = ComponentTransactionStates(SchemaT, bindings);
    const ComponentOptions = ComponentInitOptions(SchemaT, bindings);
    const Options = DatabaseInitOptions(ComponentOptions);
    const Core = struct {
        allocator: std.mem.Allocator,
        device: Device,
        raw_cache: RawCache,
        cache: Cache,
        backend: Backend,
        components: Components,
        transaction_active: bool,
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
            componentErrors(bindings, 0) ||
            error{InvalidCacheFrames};

        core_: *Core,

        pub const Transaction = struct {
            const TransactionSelf = @This();

            core: *Core,
            cache_batch: Cache.WriteBatch,
            component_states: TransactionStates,
            active: bool = true,

            pub fn get(
                self: *TransactionSelf,
                comptime name: []const u8,
            ) *proxyType(name) {
                std.debug.assert(self.active);
                const Binding = bindingType(name);
                const runtime: *runtimeType(name) = &@field(self.core.components, name);
                return Binding.proxy(runtime);
            }

            pub fn getConst(
                self: *const TransactionSelf,
                comptime name: []const u8,
            ) *const proxyType(name) {
                std.debug.assert(self.active);
                const Binding = bindingType(name);
                const core: *const Core = self.core;
                const runtime: *const runtimeType(name) = &@field(core.components, name);
                return Binding.proxyConst(runtime);
            }

            pub fn commit(self: *TransactionSelf) Error!void {
                if (!self.active) {
                    return Error.TransactionInactive;
                }
                try self.cache_batch.commit();
                self.core.transaction_active = false;
                self.active = false;
            }

            pub fn rollback(self: *TransactionSelf) Error!void {
                if (!self.active) {
                    return Error.TransactionInactive;
                }
                try self.cache_batch.discard();
                restoreTransactionStates(self.core, self.component_states);
                self.core.transaction_active = false;
                self.active = false;
            }

            pub fn deinit(self: *TransactionSelf) void {
                if (self.active) {
                    self.rollback() catch @panic("Failed to roll back MemoryDatabase transaction");
                }
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
            if (self.core_.transaction_active) {
                return Error.BatchActive;
            }
            const component_states = captureTransactionStates(self.core_);
            const cache_batch = try self.core_.cache.begin();
            self.core_.transaction_active = true;
            return .{
                .core = self.core_,
                .cache_batch = cache_batch,
                .component_states = component_states,
            };
        }

        pub fn getConst(self: *const Self, comptime name: []const u8) *const proxyType(name) {
            const Binding = bindingType(name);
            const core: *const Core = self.core_;
            const runtime: *const runtimeType(name) = &@field(core.components, name);
            return Binding.proxyConst(runtime);
        }

        pub fn deinit(self: *Self) void {
            const core = self.core_;
            if (core.transaction_active) {
                @panic("MemoryDatabase.deinit called with an active transaction");
            }
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
