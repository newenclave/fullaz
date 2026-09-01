const std = @import("std");
const bpt = @import("fullaz").bpt;
const system_kinds = @import("../system_kinds.zig");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

/// Private paged B+ tree mapping exact component names to durable IDs.
pub fn CatalogNameIndex(comptime CacheT: type, comptime ManagerT: type) type {
    const ModelT = bpt.models.PagedModel(CacheT, ManagerT, compare, void);
    const TreeT = bpt.Bpt(ModelT);

    return struct {
        const Self = @This();

        pub const Error = TreeT.Error || error{
            InvalidComponentName,
            InvalidComponentId,
            BadCatalogNameIndex,
        };

        model: ModelT,

        pub fn init(cache: *CacheT, manager: *ManagerT) Error!Self {
            return .{ .model = try ModelT.init(cache, manager, .{
                .maximum_key_size = 255,
                .maximum_value_size = @sizeOf(u64),
                .leaf_page_kind = system_kinds.component_name_bpt_leaf,
                .inode_page_kind = system_kinds.component_name_bpt_inode,
            }, {}) };
        }

        pub fn deinit(self: *Self) void {
            self.model.deinit();
            self.* = undefined;
        }

        pub fn get(self: *Self, name: []const u8) Error!?u64 {
            try validateName(name);
            var tree = TreeT.init(&self.model, .neighbor_share);
            defer tree.deinit();
            var iterator = (try tree.find(name)) orelse return null;
            defer iterator.deinit();
            const entry = (try iterator.get()) orelse return error.BadCatalogNameIndex;
            if (entry.value.len != @sizeOf(u64)) {
                return error.BadCatalogNameIndex;
            }
            const component_id = std.mem.readInt(u64, entry.value[0..@sizeOf(u64)], .little);
            if (component_id == 0) {
                return error.BadCatalogNameIndex;
            }
            return component_id;
        }

        pub fn set(self: *Self, name: []const u8, component_id: u64) Error!void {
            try validateName(name);
            if (component_id == 0) {
                return error.InvalidComponentId;
            }
            var bytes: [@sizeOf(u64)]u8 = undefined;
            std.mem.writeInt(u64, &bytes, component_id, .little);
            var tree = TreeT.init(&self.model, .neighbor_share);
            defer tree.deinit();
            if (!try tree.update(name, &bytes)) {
                _ = try tree.insert(name, &bytes);
            }
        }

        pub fn remove(self: *Self, name: []const u8) Error!bool {
            try validateName(name);
            var tree = TreeT.init(&self.model, .neighbor_share);
            defer tree.deinit();
            return tree.remove(name);
        }

        pub fn scanInodeRefs(
            self: *const Self,
            page_id: CacheT.Pid,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanInodeRefs(page_id, page, visitor);
        }

        pub fn scanLeafRefs(
            self: *const Self,
            page_id: CacheT.Pid,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanLeafRefs(page_id, page, visitor);
        }

        fn validateName(name: []const u8) Error!void {
            if (name.len == 0 or name.len > 255 or
                !std.unicode.utf8ValidateSlice(name) or
                std.mem.indexOfScalar(u8, name, 0) != null)
            {
                return error.InvalidComponentName;
            }
        }
    };
}
