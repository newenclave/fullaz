const std = @import("std");
const fullaz = @import("fullaz");
const PersistentReclaimingCache = fullaz.storage.page_cache.PersistentReclaimingCache;
const StaticSuperblock = @import("superblock.zig").StaticSuperblock;
const shape = @import("../../component/shape.zig");

/// Shared type construction for static database variants.
pub fn StaticDatabaseCommon(comptime SchemaT: type, comptime DeviceT: type, comptime RawCacheT: type) type {
    return struct {
        pub const FreeListState = fullaz.storage.free_list.State(SchemaT.PageId, .little);
        pub const StoreType = struct {
            pub const PageId = SchemaT.PageId;
            pub const Error = error{};
            pub const StateLeaseType = struct {
                pub const Error = error{};

                value: *FreeListState,

                pub fn data(self: *const @This()) @This().Error![]const u8 {
                    return std.mem.asBytes(@as(*const FreeListState, self.value));
                }

                pub fn dataMut(self: *@This()) @This().Error![]u8 {
                    return std.mem.asBytes(self.value);
                }

                pub fn finish(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
            };

            device: *DeviceT,
            state_value: FreeListState = .{},

            pub fn state(self: *@This()) Error!StateLeaseType {
                return .{ .value = &self.state_value };
            }

            pub fn pageCount(self: *const @This()) usize {
                return self.device.blocksCount();
            }

            pub fn isReserved(_: *const @This(), page_id: PageId) bool {
                return page_id == 0;
            }
        };
        pub const CacheType = PersistentReclaimingCache(RawCacheT, StoreType);
        pub const BackendType = struct {
            const Self = @This();

            pub const PageId = SchemaT.PageId;
            pub const CacheType = Cache;

            allocator_value: std.mem.Allocator,
            cache_ptr: *Self.CacheType,

            fn init(allocator_value: std.mem.Allocator, cache_ptr: *Self.CacheType) Self {
                return .{ .allocator_value = allocator_value, .cache_ptr = cache_ptr };
            }

            pub fn allocator(self: *const Self) std.mem.Allocator {
                return self.allocator_value;
            }

            pub fn cache(self: *Self) *Self.CacheType {
                return self.cache_ptr;
            }

            pub fn cacheConst(self: *const Self) *const Self.CacheType {
                return self.cache_ptr;
            }
        };
        pub const Bindings = shape.bindings(SchemaT, BackendType);
        pub const ComponentsType = shape.runtimes(SchemaT, Bindings);
        pub const TransactionStatesType = shape.transactionStates(SchemaT, Bindings);
        pub const ComponentOptionsType = shape.initOptions(SchemaT, Bindings);
        pub const MetadataType = shape.staticMetadata(SchemaT, Bindings);
        pub const SuperblockType = StaticSuperblock(MetadataType);
        pub const InitOptions = databaseOptions(ComponentOptionsType);

        comptime {
            if (@sizeOf(FreeListState) != @sizeOf(@FieldType(MetadataType, "free_root"))) {
                @compileError("static database free-list state width changed");
            }
        }

        pub fn initBackend(allocator_value: std.mem.Allocator, cache_ptr: *CacheType) BackendType {
            return BackendType.init(allocator_value, cache_ptr);
        }

        const Cache = CacheType;
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
