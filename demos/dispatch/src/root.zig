const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const PackedInt = fullaz.core.packed_int.PackedInt;
const PackedNumber = fullaz.core.packed_int.PackedNumber;

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const U16 = PackedInt(u16, .little);
const U32 = PackedInt(u32, .little);
const U64 = PackedInt(u64, .little);
const F32 = PackedNumber(f32, .little);

pub const tick_seconds: u32 = 10;
pub const service_seconds: u32 = 120;
pub const auto_order_interval_seconds: u32 = 300;
pub const service_radius_meters: f32 = 3_000;
pub const crew_speed_meters_per_second: f32 = 30_000.0 / 3_600.0;
pub const maximum_description_size: usize = 48;

pub const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("simulation", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 11,
        .maximum_key_size = 8,
        .maximum_value_size = 96,
    }))
    .add("orders", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 12,
        .maximum_key_size = 8,
        .maximum_value_size = 96,
    }))
    .add("service_areas", fullaz_db.rtree(.{
        .Coord = f32,
        .dimensions = 2,
        .maximum_entries = 8,
        .maximum_value_size = 8,
    }))
    .add("pending", fullaz_db.slotQueue(.{ .maximum_value_size = 8 }))
    .add("suspended", fullaz_db.slotStack(.{ .maximum_value_size = 8 }))
    .add("history", fullaz_db.slotList(.{ .maximum_value_size = 64 }));

pub const MemoryDatabase = fullaz_db.MemoryDatabase(Schema);
pub const cli = @import("cli.zig");

const simulation_key = "state";
const format_version: u16 = 1;

pub const Phase = enum(u8) {
    idle = 0,
    travelling = 1,
    working = 2,
    returning = 3,
};

const OrderKind = enum(u8) { normal = 0, emergency = 1 };
const OrderStatus = enum(u8) { pending = 0, active = 1, suspended = 2 };
const Event = enum(u8) {
    created = 1,
    queued = 2,
    assigned = 3,
    suspended = 4,
    resumed = 5,
    arrived = 6,
    completed = 7,
    returning = 8,
    at_base = 9,
    auto_enabled = 10,
    auto_disabled = 11,
};

const SimulationState = extern struct {
    version: U16,
    configured: u8,
    auto_orders: u8,
    phase: u8,
    reserved: [3]u8,
    base_latitude: F32,
    base_longitude: F32,
    crew_latitude: F32,
    crew_longitude: F32,
    active_id: [8]u8,
    model_seconds: U64,
    next_order_number: U32,
    auto_remaining_seconds: U32,
    random_state: U64,
};

const OrderRecord = extern struct {
    version: U16,
    kind: u8,
    status: u8,
    latitude: F32,
    longitude: F32,
    remaining_service_seconds: U32,
    created_seconds: U64,
    description_length: u8,
    reserved: [3]u8,
    description: [maximum_description_size]u8,
};

const HistoryRecord = extern struct {
    event: u8,
    reserved: [3]u8,
    model_seconds: U64,
    order_id: [8]u8,
    description_length: u8,
    description: [40]u8,
};

comptime {
    if (@alignOf(SimulationState) != 1 or @sizeOf(SimulationState) > 96 or
        @alignOf(OrderRecord) != 1 or @sizeOf(OrderRecord) > 96 or
        @alignOf(HistoryRecord) != 1 or @sizeOf(HistoryRecord) > 64)
    {
        @compileError("dispatch durable records changed");
    }
}

pub const Position = struct {
    latitude: f32,
    longitude: f32,
};

pub const SimulationSnapshot = extern struct {
    configured: u8,
    auto_orders: u8,
    phase: u8,
    reserved: u8,
    base: [2]f32,
    crew: [2]f32,
    active_id: [8]u8,
    model_seconds: u64,
    auto_remaining_seconds: u32,
    pending_count: u32,
    suspended_count: u32,
};

pub const OrderSnapshot = extern struct {
    id: [8]u8,
    description: [maximum_description_size]u8,
    description_length: u8,
    kind: u8,
    status: u8,
    reserved: u8,
    position: [2]f32,
    remaining_service_seconds: u32,
};

pub const HistorySnapshot = extern struct {
    event: u8,
    reserved: [3]u8,
    model_seconds: u64,
    order_id: [8]u8,
    description: [40]u8,
    description_length: u8,
};

pub const PageInfo = extern struct {
    pid: u32,
    kind: u16,
    component: u8,
    role: u8,
    used: u32,
    capacity: u32,
};

fn areaBox(comptime DatabaseT: type) type {
    return Schema.trait("service_areas").Binding(DatabaseT.BackendType).Proxy.BoundingBox;
}

fn validatePosition(position: Position) !void {
    if (!std.math.isFinite(position.latitude) or !std.math.isFinite(position.longitude) or
        position.latitude < -90 or position.latitude > 90 or
        position.longitude < -180 or position.longitude > 180)
    {
        return error.InvalidPosition;
    }
}

fn emptyId() [8]u8 {
    return [_]u8{0} ** 8;
}

fn hasId(id: [8]u8) bool {
    return !std.mem.allEqual(u8, &id, 0);
}

fn decode(comptime T: type, bytes: []const u8) !T {
    if (bytes.len != @sizeOf(T)) {
        return error.BadDispatchState;
    }
    var result: T = undefined;
    @memcpy(std.mem.asBytes(&result), bytes);
    return result;
}

fn readRecord(proxy: anytype, key: []const u8, comptime T: type) !?T {
    var iterator = (try proxy.find(key)) orelse return null;
    defer iterator.deinit();
    const entry = (try iterator.get()) orelse return null;
    return try decode(T, entry.value);
}

fn readSimulation(proxy: anytype) !SimulationState {
    return (try readRecord(proxy, simulation_key, SimulationState)) orelse error.SimulationNotConfigured;
}

fn writeSimulation(proxy: anytype, state: *const SimulationState) !void {
    if (!try proxy.update(simulation_key, std.mem.asBytes(state))) {
        return error.SimulationNotConfigured;
    }
}

fn writeOrder(proxy: anytype, id: *const [8]u8, order: *const OrderRecord) !void {
    if (!try proxy.update(id, std.mem.asBytes(order))) {
        return error.OrderNotFound;
    }
}

fn positionFromState(state: *const SimulationState) Position {
    return .{
        .latitude = state.crew_latitude.get(),
        .longitude = state.crew_longitude.get(),
    };
}

fn setCrewPosition(state: *SimulationState, position: Position) void {
    state.crew_latitude.set(position.latitude);
    state.crew_longitude.set(position.longitude);
}

fn basePosition(state: *const SimulationState) Position {
    return .{
        .latitude = state.base_latitude.get(),
        .longitude = state.base_longitude.get(),
    };
}

fn orderPosition(order: *const OrderRecord) Position {
    return .{ .latitude = order.latitude.get(), .longitude = order.longitude.get() };
}

fn localDistanceMeters(base: Position, left: Position, right: Position) f32 {
    const latitude_scale: f32 = 111_000;
    const radians = base.latitude * std.math.pi / 180.0;
    const longitude_scale = latitude_scale * @max(@abs(std.math.cos(radians)), 0.01);
    const latitude_delta = (right.latitude - left.latitude) * latitude_scale;
    const longitude_delta = (right.longitude - left.longitude) * longitude_scale;
    return @sqrt(latitude_delta * latitude_delta + longitude_delta * longitude_delta);
}

fn moveToward(base: Position, current: Position, target: Position, maximum_distance: f32) Position {
    const distance = localDistanceMeters(base, current, target);
    if (distance == 0 or distance <= maximum_distance) {
        return target;
    }
    const ratio = maximum_distance / distance;
    return .{
        .latitude = current.latitude + (target.latitude - current.latitude) * ratio,
        .longitude = current.longitude + (target.longitude - current.longitude) * ratio,
    };
}

fn appendHistory(history: anytype, state: *const SimulationState, event: Event, id: [8]u8, description: []const u8) !void {
    var record = HistoryRecord{
        .event = @intFromEnum(event),
        .reserved = .{0} ** 3,
        .model_seconds = .init(state.model_seconds.get()),
        .order_id = id,
        .description_length = @intCast(@min(description.len, 40)),
        .description = [_]u8{0} ** 40,
    };
    @memcpy(record.description[0..record.description_length], description[0..record.description_length]);
    try history.append(std.mem.asBytes(&record));
}

fn removeSpatialOrder(comptime DatabaseT: type, transaction: anytype, id: [8]u8) !void {
    const Box = areaBox(DatabaseT);
    const Matches = struct {
        id: [8]u8,
        fn call(context: *const @This(), _: Box, value: []const u8) bool {
            return std.mem.eql(u8, value, &context.id);
        }
    };
    const matches = Matches{ .id = id };
    _ = try transaction.get("service_areas").remove(
        Box.initWith(
            .{ -std.math.floatMax(f32), -std.math.floatMax(f32) },
            .{ std.math.floatMax(f32), std.math.floatMax(f32) },
        ),
        &matches,
        Matches.call,
    );
}

fn assignOrder(comptime DatabaseT: type, transaction: anytype, state: *SimulationState, id: [8]u8, event: Event) !void {
    var order = (try readRecord(transaction.get("orders"), &id, OrderRecord)) orelse return error.OrderNotFound;
    order.status = @intFromEnum(OrderStatus.active);
    try writeOrder(transaction.get("orders"), &id, &order);
    state.active_id = id;
    state.phase = @intFromEnum(Phase.travelling);
    try appendHistory(transaction.get("history"), state, event, id, order.description[0..order.description_length]);
    _ = DatabaseT;
}

fn assignNext(comptime DatabaseT: type, transaction: anytype, state: *SimulationState) !void {
    const suspended = transaction.get("suspended");
    if (!try suspended.isEmpty()) {
        var top = try suspended.top();
        const id = (try top.value())[0..8].*;
        top.deinit();
        try suspended.pop();
        return assignOrder(DatabaseT, transaction, state, id, .resumed);
    }

    const pending = transaction.get("pending");
    if (!try pending.isEmpty()) {
        var front = try pending.front();
        const id = (try front.value())[0..8].*;
        front.deinit();
        try pending.dequeue();
        return assignOrder(DatabaseT, transaction, state, id, .assigned);
    }

    state.active_id = emptyId();
    if (localDistanceMeters(basePosition(state), positionFromState(state), basePosition(state)) == 0) {
        state.phase = @intFromEnum(Phase.idle);
        try appendHistory(transaction.get("history"), state, .at_base, emptyId(), "crew idle at base");
    } else {
        state.phase = @intFromEnum(Phase.returning);
        try appendHistory(transaction.get("history"), state, .returning, emptyId(), "crew returning to base");
    }
}

fn nextRandom(state: *SimulationState) u64 {
    var value = state.random_state.get();
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    state.random_state.set(value);
    return value;
}

fn automaticPosition(state: *SimulationState) Position {
    const angle = @as(f32, @floatFromInt(nextRandom(state) % 6284)) / 1000.0;
    const radius = @as(f32, @floatFromInt(nextRandom(state) % 2_700)) + 100;
    const base = basePosition(state);
    const latitude_delta = radius * std.math.sin(angle) / 111_000;
    const longitude_scale = 111_000 * @max(@abs(std.math.cos(base.latitude * std.math.pi / 180.0)), 0.01);
    return .{
        .latitude = base.latitude + latitude_delta,
        .longitude = base.longitude + radius * std.math.cos(angle) / longitude_scale,
    };
}

fn addOrderInTransaction(comptime DatabaseT: type, transaction: anytype, state: *SimulationState, position: Position, kind: OrderKind, description: []const u8) ![8]u8 {
    try validatePosition(position);
    if (description.len == 0 or description.len > maximum_description_size) {
        return error.InvalidDescription;
    }
    if (localDistanceMeters(basePosition(state), basePosition(state), position) > service_radius_meters) {
        return error.OutsideServiceArea;
    }

    const order_number = state.next_order_number.get();
    if (order_number == std.math.maxInt(u32)) {
        return error.OrderIdExhausted;
    }
    var id: [8]u8 = undefined;
    _ = try std.fmt.bufPrint(&id, "{d:0>8}", .{order_number});
    state.next_order_number.set(order_number + 1);

    var order = OrderRecord{
        .version = .init(format_version),
        .kind = @intFromEnum(kind),
        .status = @intFromEnum(if (kind == .normal) OrderStatus.pending else OrderStatus.active),
        .latitude = .init(position.latitude),
        .longitude = .init(position.longitude),
        .remaining_service_seconds = .init(service_seconds),
        .created_seconds = .init(state.model_seconds.get()),
        .description_length = @intCast(description.len),
        .reserved = .{0} ** 3,
        .description = [_]u8{0} ** maximum_description_size,
    };
    @memcpy(order.description[0..description.len], description);
    if (!try transaction.get("orders").insert(&id, std.mem.asBytes(&order))) {
        return error.OrderAlreadyExists;
    }
    const Box = areaBox(DatabaseT);
    try transaction.get("service_areas").insert(
        Box.initWith(.{ position.latitude, position.longitude }, .{ position.latitude, position.longitude }),
        &id,
    );
    try appendHistory(transaction.get("history"), state, .created, id, description);

    if (kind == .normal) {
        try transaction.get("pending").enqueue(&id);
        try appendHistory(transaction.get("history"), state, .queued, id, description);
        if (state.phase == @intFromEnum(Phase.idle) or state.phase == @intFromEnum(Phase.returning)) {
            try assignNext(DatabaseT, transaction, state);
        }
        return id;
    }

    if (hasId(state.active_id)) {
        var previous = (try readRecord(transaction.get("orders"), &state.active_id, OrderRecord)) orelse return error.OrderNotFound;
        previous.status = @intFromEnum(OrderStatus.suspended);
        try writeOrder(transaction.get("orders"), &state.active_id, &previous);
        try transaction.get("suspended").push(&state.active_id);
        try appendHistory(transaction.get("history"), state, .suspended, state.active_id, previous.description[0..previous.description_length]);
    }
    try assignOrder(DatabaseT, transaction, state, id, .assigned);
    return id;
}

/// Creates the permanent base and initial durable state. It can run only once.
pub fn initializeSimulation(comptime DatabaseT: type, database: *DatabaseT, base: Position) !void {
    try validatePosition(base);
    var transaction = try database.begin();
    defer transaction.deinit();
    if ((try readRecord(transaction.get("simulation"), simulation_key, SimulationState)) != null) {
        return error.SimulationAlreadyConfigured;
    }
    var state = SimulationState{
        .version = .init(format_version),
        .configured = 1,
        .auto_orders = 0,
        .phase = @intFromEnum(Phase.idle),
        .reserved = .{0} ** 3,
        .base_latitude = .init(base.latitude),
        .base_longitude = .init(base.longitude),
        .crew_latitude = .init(base.latitude),
        .crew_longitude = .init(base.longitude),
        .active_id = emptyId(),
        .model_seconds = .init(0),
        .next_order_number = .init(1),
        .auto_remaining_seconds = .init(auto_order_interval_seconds),
        .random_state = .init(0x9e37_79b9_7f4a_7c15),
    };
    if (!try transaction.get("simulation").insert(simulation_key, std.mem.asBytes(&state))) {
        return error.SimulationAlreadyConfigured;
    }
    try appendHistory(transaction.get("history"), &state, .at_base, emptyId(), "base configured");
    try transaction.commit();
}

pub fn addOrder(comptime DatabaseT: type, database: *DatabaseT, position: Position, description: []const u8) ![8]u8 {
    var transaction = try database.begin();
    defer transaction.deinit();
    var state = try readSimulation(transaction.get("simulation"));
    const id = try addOrderInTransaction(DatabaseT, &transaction, &state, position, .normal, description);
    try writeSimulation(transaction.get("simulation"), &state);
    try transaction.commit();
    return id;
}

pub fn addEmergency(comptime DatabaseT: type, database: *DatabaseT, position: Position, description: []const u8) ![8]u8 {
    var transaction = try database.begin();
    defer transaction.deinit();
    var state = try readSimulation(transaction.get("simulation"));
    const id = try addOrderInTransaction(DatabaseT, &transaction, &state, position, .emergency, description);
    try writeSimulation(transaction.get("simulation"), &state);
    try transaction.commit();
    return id;
}

pub fn setAutoOrders(comptime DatabaseT: type, database: *DatabaseT, enabled: bool) !void {
    var transaction = try database.begin();
    defer transaction.deinit();
    var state = try readSimulation(transaction.get("simulation"));
    state.auto_orders = @intFromBool(enabled);
    try appendHistory(transaction.get("history"), &state, if (enabled) .auto_enabled else .auto_disabled, emptyId(), if (enabled) "automatic orders enabled" else "automatic orders disabled");
    try writeSimulation(transaction.get("simulation"), &state);
    try transaction.commit();
}

/// Advances the durable model by exactly one fixed simulation tick.
pub fn stepSimulation(comptime DatabaseT: type, database: *DatabaseT) !void {
    var transaction = try database.begin();
    defer transaction.deinit();
    var state = try readSimulation(transaction.get("simulation"));
    state.model_seconds.set(state.model_seconds.get() + tick_seconds);

    if (state.auto_orders != 0) {
        const remaining = state.auto_remaining_seconds.get();
        if (remaining <= tick_seconds) {
            state.auto_remaining_seconds.set(auto_order_interval_seconds);
            _ = try addOrderInTransaction(DatabaseT, &transaction, &state, automaticPosition(&state), .normal, "automatic service request");
        } else {
            state.auto_remaining_seconds.set(remaining - tick_seconds);
        }
    }

    const phase: Phase = @enumFromInt(state.phase);
    if (phase == .travelling) {
        const id = state.active_id;
        var order = (try readRecord(transaction.get("orders"), &id, OrderRecord)) orelse return error.OrderNotFound;
        const current = positionFromState(&state);
        const target = orderPosition(&order);
        const position = moveToward(basePosition(&state), current, target, crew_speed_meters_per_second * tick_seconds);
        setCrewPosition(&state, position);
        if (localDistanceMeters(basePosition(&state), position, target) == 0) {
            state.phase = @intFromEnum(Phase.working);
            order.status = @intFromEnum(OrderStatus.active);
            try writeOrder(transaction.get("orders"), &id, &order);
            try appendHistory(transaction.get("history"), &state, .arrived, id, order.description[0..order.description_length]);
        }
    } else if (phase == .working) {
        const id = state.active_id;
        var order = (try readRecord(transaction.get("orders"), &id, OrderRecord)) orelse return error.OrderNotFound;
        const remaining = order.remaining_service_seconds.get();
        if (remaining > tick_seconds) {
            order.remaining_service_seconds.set(remaining - tick_seconds);
            try writeOrder(transaction.get("orders"), &id, &order);
        } else {
            try appendHistory(transaction.get("history"), &state, .completed, id, order.description[0..order.description_length]);
            _ = try transaction.get("orders").remove(&id);
            try removeSpatialOrder(DatabaseT, &transaction, id);
            try assignNext(DatabaseT, &transaction, &state);
        }
    } else if (phase == .returning) {
        const base = basePosition(&state);
        const position = moveToward(base, positionFromState(&state), base, crew_speed_meters_per_second * tick_seconds);
        setCrewPosition(&state, position);
        if (localDistanceMeters(base, position, base) == 0) {
            state.phase = @intFromEnum(Phase.idle);
            try appendHistory(transaction.get("history"), &state, .at_base, emptyId(), "crew idle at base");
        }
    }
    try writeSimulation(transaction.get("simulation"), &state);
    try transaction.commit();
}

pub fn snapshotSimulation(comptime DatabaseT: type, database: *const DatabaseT) !SimulationSnapshot {
    const state = try readSimulation(database.getConst("simulation"));
    return .{
        .configured = state.configured,
        .auto_orders = state.auto_orders,
        .phase = state.phase,
        .reserved = 0,
        .base = .{ state.base_latitude.get(), state.base_longitude.get() },
        .crew = .{ state.crew_latitude.get(), state.crew_longitude.get() },
        .active_id = state.active_id,
        .model_seconds = state.model_seconds.get(),
        .auto_remaining_seconds = state.auto_remaining_seconds.get(),
        .pending_count = @intCast(try database.getConst("pending").size()),
        .suspended_count = @intCast(try database.getConst("suspended").size()),
    };
}

pub fn snapshotOrders(comptime DatabaseT: type, database: *const DatabaseT, allocator: std.mem.Allocator) !std.ArrayList(OrderSnapshot) {
    const Box = areaBox(DatabaseT);
    const Collect = struct {
        db: *const DatabaseT,
        allocator: std.mem.Allocator,
        snapshots: std.ArrayList(OrderSnapshot) = .empty,

        fn handle(self: *@This(), _: Box, value: []const u8) void {
            const id = value[0..8].*;
            const order = readRecord(self.db.getConst("orders"), &id, OrderRecord) catch @panic("corrupt dispatch order");
            const record = order orelse @panic("missing spatial dispatch order");
            self.snapshots.append(self.allocator, .{
                .id = id,
                .description = record.description,
                .description_length = record.description_length,
                .kind = record.kind,
                .status = record.status,
                .reserved = 0,
                .position = .{ record.latitude.get(), record.longitude.get() },
                .remaining_service_seconds = record.remaining_service_seconds.get(),
            }) catch @panic("OOM collecting dispatch orders");
        }
    };
    var collect = Collect{ .db = database, .allocator = allocator };
    errdefer collect.snapshots.deinit(allocator);
    try database.getConst("service_areas").search(
        Box.initWith(.{ -90, -180 }, .{ 90, 180 }),
        &collect,
        Collect.handle,
    );
    std.sort.insertion(OrderSnapshot, collect.snapshots.items, {}, struct {
        fn lessThan(_: void, left: OrderSnapshot, right: OrderSnapshot) bool {
            return std.mem.order(u8, &left.id, &right.id) == .lt;
        }
    }.lessThan);
    return collect.snapshots;
}

pub fn snapshotSequence(comptime DatabaseT: type, database: *const DatabaseT, comptime component_name: []const u8, allocator: std.mem.Allocator) !std.ArrayList([8]u8) {
    var result = std.ArrayList([8]u8).empty;
    errdefer result.deinit(allocator);
    var iterator = (try database.getConst(component_name).iterator()) orelse return result;
    defer iterator.deinit();
    while (try iterator.next()) |value| {
        if (value.len != 8) {
            return error.BadDispatchState;
        }
        try result.append(allocator, value[0..8].*);
    }
    return result;
}

pub fn snapshotHistory(comptime DatabaseT: type, database: *const DatabaseT, allocator: std.mem.Allocator) !std.ArrayList(HistorySnapshot) {
    var result = std.ArrayList(HistorySnapshot).empty;
    errdefer result.deinit(allocator);
    var iterator = (try database.getConst("history").iterator()) orelse return result;
    defer iterator.deinit();
    while (try iterator.next()) |value| {
        const record = try decode(HistoryRecord, value);
        try result.append(allocator, .{
            .event = record.event,
            .reserved = .{0} ** 3,
            .model_seconds = record.model_seconds.get(),
            .order_id = record.order_id,
            .description = record.description,
            .description_length = record.description_length,
        });
    }
    return result;
}

pub fn ordersInArea(comptime DatabaseT: type, database: *const DatabaseT, allocator: std.mem.Allocator, low: Position, high: Position) !std.ArrayList([8]u8) {
    try validatePosition(low);
    try validatePosition(high);
    if (low.latitude > high.latitude or low.longitude > high.longitude) {
        return error.InvalidArea;
    }
    const Box = areaBox(DatabaseT);
    const Collect = struct {
        allocator: std.mem.Allocator,
        ids: std.ArrayList([8]u8) = .empty,
        fn handle(self: *@This(), _: Box, value: []const u8) void {
            self.ids.append(self.allocator, value[0..8].*) catch @panic("OOM collecting area orders");
        }
    };
    var collect = Collect{ .allocator = allocator };
    errdefer collect.ids.deinit(allocator);
    try database.getConst("service_areas").searchIntersecting(
        Box.initWith(.{ low.latitude, low.longitude }, .{ high.latitude, high.longitude }),
        &collect,
        Collect.handle,
    );
    return collect.ids;
}

pub fn validateSimulation(comptime DatabaseT: type, database: *const DatabaseT, allocator: std.mem.Allocator) !void {
    const state = try readSimulation(database.getConst("simulation"));
    if (state.version.get() != format_version or state.configured != 1 or state.auto_orders > 1 or state.phase > @intFromEnum(Phase.returning)) {
        return error.BadDispatchState;
    }
    try validatePosition(basePosition(&state));
    try validatePosition(positionFromState(&state));
    var pending = try snapshotSequence(DatabaseT, database, "pending", allocator);
    defer pending.deinit(allocator);
    var suspended = try snapshotSequence(DatabaseT, database, "suspended", allocator);
    defer suspended.deinit(allocator);
    for (pending.items) |id| {
        const order = (try readRecord(database.getConst("orders"), &id, OrderRecord)) orelse return error.BadDispatchState;
        if (order.status != @intFromEnum(OrderStatus.pending)) return error.BadDispatchState;
    }
    for (suspended.items) |id| {
        const order = (try readRecord(database.getConst("orders"), &id, OrderRecord)) orelse return error.BadDispatchState;
        if (order.status != @intFromEnum(OrderStatus.suspended)) return error.BadDispatchState;
        for (pending.items) |pending_id| if (std.mem.eql(u8, &id, &pending_id)) return error.BadDispatchState;
    }
    if (hasId(state.active_id)) {
        const active = (try readRecord(database.getConst("orders"), &state.active_id, OrderRecord)) orelse return error.BadDispatchState;
        if (active.status != @intFromEnum(OrderStatus.active)) return error.BadDispatchState;
        for (pending.items) |id| if (std.mem.eql(u8, &id, &state.active_id)) return error.BadDispatchState;
        for (suspended.items) |id| if (std.mem.eql(u8, &id, &state.active_id)) return error.BadDispatchState;
    } else if (state.phase == @intFromEnum(Phase.travelling) or state.phase == @intFromEnum(Phase.working)) {
        return error.BadDispatchState;
    }
}

fn classifyKind(kind: u16) ?struct { component: u8, role: u8 } {
    inline for (Schema.fields, 0..) |field, component_index| {
        var role_index: usize = 0;
        while (role_index < field.page_kinds.count) : (role_index += 1) {
            if (field.page_kinds.kindAt(role_index).? == kind) {
                return .{ .component = @intCast(component_index), .role = @intCast(role_index) };
            }
        }
    }
    return null;
}

pub fn inspectPages(device_bytes: []const u8, page_size: usize, free_pages: []const Schema.PageId, allocator: std.mem.Allocator) !std.ArrayList(PageInfo) {
    const HeaderView = fullaz.page.header.View(Schema.PageId, u16, .little, true);
    if (page_size == 0 or device_bytes.len % page_size != 0) return error.InvalidImage;
    var result = std.ArrayList(PageInfo).empty;
    errdefer result.deinit(allocator);
    for (0..device_bytes.len / page_size) |index| {
        const pid: u32 = @intCast(index);
        const page = device_bytes[index * page_size .. (index + 1) * page_size];
        var info = PageInfo{ .pid = pid, .kind = 0, .component = 0xFF, .role = 0xFF, .used = 0, .capacity = @intCast(page.len) };
        var is_free = false;
        for (free_pages) |free_pid| {
            if (free_pid == pid) {
                is_free = true;
            }
        }
        const header = HeaderView.init(page);
        const kind = header.header().kind.get();
        if (!is_free and kind != std.math.maxInt(u16)) {
            header.validateCommon() catch {
                try result.append(allocator, info);
                continue;
            };
            info.kind = kind;
            if (classifyKind(kind)) |classified| {
                info.component = classified.component;
                info.role = classified.role;
            }
            info.used = @intCast(header.allHeadersSize());
        }
        try result.append(allocator, info);
    }
    return result;
}
