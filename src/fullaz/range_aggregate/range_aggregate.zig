//! Shared types for a B-adic range aggregate backed by one B+ tree.
//! Geometry and storage operations are implemented separately from these types.

const std = @import("std");
const PackedNumber = @import("../core/packed_int.zig").PackedNumber;
const PackedInt = @import("../core/packed_int.zig").PackedInt;
const storage_manager = @import("../core/storage_manager.zig");
const bpt_mod = @import("../bpt/bpt.zig");

pub const Geometry = @import("geometry.zig").Geometry;

/// Selects minimal buckets before decomposing a half-open query range.
pub const RangePolicy = enum {
    /// Both endpoints must be canonical grid boundaries.
    exact,
    /// Include a bucket when its center belongs to the requested range.
    center,
    /// Include every bucket that intersects the requested range.
    outward,
};

pub const QueryOptions = struct {
    policy: RangePolicy = .center,
};

pub fn State(
    comptime PageIdT: type,
    comptime CoordT: type,
    comptime Endian: std.builtin.Endian,
) type {
    comptime requireCoordinate(CoordT);
    const PackedBase = PackedInt(u32, Endian);
    const PackedCoord = PackedNumber(CoordT, Endian);
    const PackedValueSize = PackedInt(u64, Endian);
    const TreeState = bpt_mod.models.paged.State(PageIdT);
    const SettingsT = Settings(CoordT);

    return extern struct {
        const Self = @This();

        pub const Error = SettingsT.Error || error{InvalidValueSize};

        base: PackedBase,
        base_width: PackedCoord,
        level_count: u8,
        value_size: PackedValueSize,
        tree: TreeState = .{},

        /// Builds a durable state for a newly created empty aggregate.
        pub fn init(initial_settings: SettingsT) Error!Self {
            try initial_settings.validate();
            const value_size = std.math.cast(u64, initial_settings.value_size) orelse
                return error.InvalidValueSize;
            return .{
                .base = .init(initial_settings.base),
                .base_width = .init(initial_settings.base_width),
                .level_count = initial_settings.level_count,
                .value_size = .init(value_size),
            };
        }

        /// Reads and validates the settings originally persisted at creation.
        pub fn settings(self: *const Self) Error!SettingsT {
            const value_size = std.math.cast(usize, self.value_size.get()) orelse
                return error.InvalidValueSize;
            const result: SettingsT = .{
                .base = self.base.get(),
                .base_width = self.base_width.get(),
                .level_count = self.level_count,
                .value_size = value_size,
            };
            try result.validate();
            return result;
        }
    };
}

/// Projects State(...).tree for a paged B+ tree model. The parent manager must
/// own exactly the corresponding RangeAggregate State lease.
pub fn TreeStorageManager(
    comptime ParentManagerT: type,
    comptime PageIdT: type,
    comptime CoordT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return storage_manager.PagedFieldStorageManager(
        ParentManagerT,
        State(PageIdT, CoordT, Endian),
        "tree",
    );
}

pub fn RangeAggregate(
    comptime PageCacheT: type,
    comptime ParentManagerT: type,
    comptime CoordT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const StateT = State(PageCacheT.Pid, CoordT, Endian);
    const StateAccessor = storage_manager.StateAccessor(ParentManagerT.StateLeaseType, StateT);
    const TreeManagerT = TreeStorageManager(ParentManagerT, PageCacheT.Pid, CoordT, Endian);
    const KeyT = Key(CoordT, Endian);
    const GeometryT = Geometry(CoordT);
    const Info = LevelInfo(CoordT);

    const compareKeys = struct {
        fn call(_: void, left: []const u8, right: []const u8) std.math.Order {
            std.debug.assert(left.len == @sizeOf(KeyT));
            std.debug.assert(right.len == @sizeOf(KeyT));
            const left_key: *align(1) const KeyT = @ptrCast(left.ptr);
            const right_key: *align(1) const KeyT = @ptrCast(right.ptr);
            const level_order = std.math.order(left_key.level, right_key.level);
            if (level_order != .eq) {
                return level_order;
            }
            return std.math.order(left_key.value.get(), right_key.value.get());
        }
    }.call;

    const ModelT = bpt_mod.models.paged.PagedModel(
        PageCacheT,
        TreeManagerT,
        compareKeys,
        void,
    );
    const TreeT = bpt_mod.Bpt(ModelT);

    const callbacks = struct {
        fn info(comptime CallbackT: type) std.builtin.Type.Fn {
            return switch (@typeInfo(CallbackT)) {
                .@"fn" => |result| result,
                .pointer => |pointer| switch (@typeInfo(pointer.child)) {
                    .@"fn" => |result| result,
                    else => @compileError("RangeAggregate callback must be a function or function pointer"),
                },
                else => @compileError("RangeAggregate callback must be a function or function pointer"),
            };
        }

        fn Error(comptime CallbackT: type) type {
            const ReturnT = info(CallbackT).return_type orelse
                @compileError("RangeAggregate callback must have a return type");
            return switch (@typeInfo(ReturnT)) {
                .void => error{},
                .error_union => |error_union| blk: {
                    if (error_union.payload != void) {
                        @compileError("RangeAggregate callback must return void or an error union with void payload");
                    }
                    break :blk error_union.error_set;
                },
                else => @compileError("RangeAggregate callback must return void or an error union with void payload"),
            };
        }

        fn callInsert(
            callback: anytype,
            context: anytype,
            info_value: Info,
            stored: []u8,
        ) Error(@TypeOf(callback))!void {
            const ReturnT = info(@TypeOf(callback)).return_type.?;
            switch (@typeInfo(ReturnT)) {
                .void => callback(context, info_value, stored),
                .error_union => try callback(context, info_value, stored),
                else => unreachable,
            }
        }

        fn callUpdate(
            callback: anytype,
            context: anytype,
            info_value: Info,
            stored: []u8,
            input: []const u8,
        ) Error(@TypeOf(callback))!void {
            const ReturnT = info(@TypeOf(callback)).return_type.?;
            switch (@typeInfo(ReturnT)) {
                .void => callback(context, info_value, stored, input),
                .error_union => try callback(context, info_value, stored, input),
                else => unreachable,
            }
        }

        fn callAccumulate(
            callback: anytype,
            context: anytype,
            info_value: Info,
            stored: []const u8,
        ) Error(@TypeOf(callback))!void {
            const ReturnT = info(@TypeOf(callback)).return_type.?;
            switch (@typeInfo(ReturnT)) {
                .void => callback(context, info_value, stored),
                .error_union => try callback(context, info_value, stored),
                else => unreachable,
            }
        }
    };

    return struct {
        const Self = @This();

        pub const Error = StateAccessor.Error || StateT.Error || ModelT.Error || GeometryT.Error || error{
            InvalidInputSize,
            MissingValueEditor,
        };
        pub const DurableState = StateT;
        pub const Tree = TreeT;

        pub const Options = struct {
            leaf_page_kind: u16 = 0,
            inode_page_kind: u16 = 1,
            rebalance_policy: bpt_mod.RebalancePolicy = .neighbor_share,
        };

        tree_manager: TreeManagerT,
        model: ModelT,
        tree: TreeT,
        stored_settings: Settings(CoordT),

        /// Opens a previously initialized durable State. State settings fix the
        /// B+ tree's key and value sizes; Options only selects page kinds and
        /// rebalancing behavior for this process.
        pub fn init(
            self: *Self,
            cache: *PageCacheT,
            parent_manager: *ParentManagerT,
            options: Options,
        ) Error!void {
            var lease = try parent_manager.state();
            defer lease.deinit();
            const durable_state = try StateAccessor.view(&lease);
            const persisted_settings = try durable_state.settings();

            self.tree_manager = TreeManagerT.init(parent_manager);
            self.model = try ModelT.init(
                cache,
                &self.tree_manager,
                .{
                    .maximum_key_size = @sizeOf(KeyT),
                    .maximum_value_size = persisted_settings.value_size,
                    .fixed_value_size = persisted_settings.value_size,
                    .leaf_page_kind = options.leaf_page_kind,
                    .inode_page_kind = options.inode_page_kind,
                },
                {},
            );
            self.tree = TreeT.init(&self.model, options.rebalance_policy);
            self.stored_settings = persisted_settings;
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
            self.model.deinit();
            self.* = undefined;
        }

        pub fn settings(self: *const Self) Settings(CoordT) {
            return self.stored_settings;
        }

        pub fn bpt(self: *Self) *TreeT {
            return &self.tree;
        }

        pub fn insert(
            self: *Self,
            coordinate: CoordT,
            input: []const u8,
            context: anytype,
            comptime on_insert: anytype,
            comptime on_update: anytype,
        ) (Error || callbacks.Error(@TypeOf(on_insert)) || callbacks.Error(@TypeOf(on_update)))!void {
            if (input.len != self.stored_settings.value_size) {
                return error.InvalidInputSize;
            }
            try GeometryT.validateCoordinate(self.stored_settings, coordinate);
            for (0..self.stored_settings.level_count) |level| {
                const info = try GeometryT.interval(
                    self.stored_settings,
                    coordinate,
                    @intCast(level),
                );
                const key: KeyT = .{
                    .level = info.level,
                    .value = .init(info.from),
                };
                const key_bytes = std.mem.asBytes(&key);
                const inserted = try self.tree.insert(key_bytes, input);
                var editor = (try self.tree.openValueEditor(key_bytes)) orelse
                    return error.MissingValueEditor;
                defer editor.deinit();
                const stored = try editor.valueMut();
                if (inserted) {
                    try callbacks.callInsert(
                        on_insert,
                        context,
                        info,
                        stored,
                    );
                } else {
                    try callbacks.callUpdate(
                        on_update,
                        context,
                        info,
                        stored,
                        input,
                    );
                }
                try editor.finish();
            }
        }

        pub fn accumulate(
            self: *Self,
            range: Range(CoordT),
            options: QueryOptions,
            max_level: u8,
            cover_output: []Info,
            context: anytype,
            comptime on_accumulate: anytype,
        ) (Error || callbacks.Error(@TypeOf(on_accumulate)))!void {
            const aligned = try GeometryT.alignRange(
                self.stored_settings,
                range.from,
                range.to,
                options,
            );
            const cover = try GeometryT.cover(
                self.stored_settings,
                aligned,
                max_level,
                cover_output,
            );
            for (cover) |info| {
                const key: KeyT = .{
                    .level = info.level,
                    .value = .init(info.from),
                };
                var iterator = (try self.tree.find(std.mem.asBytes(&key))) orelse {
                    continue;
                };
                errdefer iterator.deinit();
                const entry = (try iterator.get()) orelse {
                    iterator.deinit();
                    continue;
                };
                try callbacks.callAccumulate(on_accumulate, context, info, entry.value);
                iterator.deinit();
            }
        }

        /// Releases pages reachable from the current root and clears that root.
        /// The caller must ensure no other user can access the aggregate while it runs.
        pub fn destroy(self: *Self) Error!void {
            return self.tree.destroy();
        }
    };
}

/// Native settings supplied at creation, not a serialized state layout.
/// A populated structure must retain the settings under which it was created.
pub fn Settings(comptime CoordT: type) type {
    comptime requireCoordinate(CoordT);
    return struct {
        const Self = @This();

        pub const Error = error{
            InvalidBase,
            InvalidBaseWidth,
            InvalidLevelCount,
            InvalidValueSize,
        };

        base: u32 = 2,
        base_width: CoordT = 1,
        /// Number of levels, starting with level zero at base_width.
        level_count: u8,
        /// Exact length of each stored aggregate, in bytes.
        value_size: usize,

        /// Checks scalar settings without changing them. Geometry must also
        /// validate level widths; the backing B+ tree must validate page capacity.
        pub fn validate(self: *const Self) Error!void {
            if (self.base < 2) {
                return error.InvalidBase;
            }
            if (self.base_width <= 0) {
                return error.InvalidBaseWidth;
            }
            if (@typeInfo(CoordT) == .float) {
                if (!std.math.isFinite(self.base_width)) {
                    return error.InvalidBaseWidth;
                }
            }
            if (self.level_count == 0) {
                return error.InvalidLevelCount;
            }
            if (self.value_size == 0) {
                return error.InvalidValueSize;
            }
        }
    };
}

/// Native half-open query bounds [from, to), not a serialized state layout.
pub fn Range(comptime CoordT: type) type {
    comptime requireCoordinate(CoordT);
    return struct {
        from: CoordT,
        to: CoordT,
    };
}

/// Native callback information for the half-open interval [from, to).
pub fn LevelInfo(comptime CoordT: type) type {
    comptime requireCoordinate(CoordT);
    return struct {
        level: u8,
        from: CoordT,
        to: CoordT,
    };
}

/// Serialized B+ tree key. Value is the canonical interval start.
/// Compare decoded fields numerically, not the serialized bytes.
pub fn Key(comptime CoordT: type, comptime Endian: std.builtin.Endian) type {
    comptime requireCoordinate(CoordT);
    const PackedCoord = PackedNumber(CoordT, Endian);
    return extern struct {
        level: u8,
        value: PackedCoord,
    };
}

fn requireCoordinate(comptime CoordT: type) void {
    switch (CoordT) {
        i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 => {},
        else => @compileError("RangeAggregate coordinate must be i8/i16/i32/i64, u8/u16/u32/u64, f32, or f64"),
    }
}
