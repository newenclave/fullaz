const std = @import("std");
const root = @import("root.zig");

/// A small command-line shell over a dispatch database. It only parses tokens
/// and delegates to the operations exposed by root.zig, so it works for both
/// the in-memory and the file-backed database.
pub fn Cli(comptime DatabaseT: type) type {
    return struct {
        const Self = @This();

        db: *DatabaseT,
        allocator: std.mem.Allocator,

        pub fn init(db: *DatabaseT, allocator: std.mem.Allocator) Self {
            return .{ .db = db, .allocator = allocator };
        }

        /// Runs one command from pre-split tokens and propagates operation errors.
        pub fn execTokens(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            try self.dispatch(tokens, writer);
        }

        /// Runs one command while keeping an interactive shell alive on errors.
        pub fn execTokensReporting(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            self.dispatch(tokens, writer) catch |err| {
                try writer.print("error: {s}\n", .{@errorName(err)});
            };
        }

        fn dispatch(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len == 0) {
                return;
            }
            const cmd = tokens[0];
            if (std.mem.eql(u8, cmd, "base")) {
                try self.cmdBase(tokens, writer);
            } else if (std.mem.eql(u8, cmd, "add")) {
                try self.cmdAdd(tokens, writer, false);
            } else if (std.mem.eql(u8, cmd, "urgent")) {
                try self.cmdAdd(tokens, writer, true);
            } else if (std.mem.eql(u8, cmd, "step")) {
                try self.cmdStep(tokens, writer);
            } else if (std.mem.eql(u8, cmd, "auto")) {
                try self.cmdAuto(tokens, writer);
            } else if (std.mem.eql(u8, cmd, "status")) {
                try self.cmdStatus(writer);
            } else if (std.mem.eql(u8, cmd, "queue")) {
                try self.cmdSequence("pending", writer);
            } else if (std.mem.eql(u8, cmd, "stack")) {
                try self.cmdSequence("suspended", writer);
            } else if (std.mem.eql(u8, cmd, "history")) {
                try self.cmdHistory(writer);
            } else if (std.mem.eql(u8, cmd, "list")) {
                try self.cmdList(writer);
            } else if (std.mem.eql(u8, cmd, "area")) {
                try self.cmdArea(tokens, writer);
            } else if (std.mem.eql(u8, cmd, "help")) {
                try writer.writeAll(help_text);
            } else {
                try writer.print("unknown command: {s}\n", .{cmd});
            }
        }

        fn parseCoord(token: []const u8) !f32 {
            return std.fmt.parseFloat(f32, token) catch return error.BadNumber;
        }

        fn parsePosition(tokens: []const []const u8) !root.Position {
            if (tokens.len < 3) {
                return error.MissingArgs;
            }
            return .{
                .latitude = try parseCoord(tokens[1]),
                .longitude = try parseCoord(tokens[2]),
            };
        }

        fn cmdBase(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len != 3) {
                return error.MissingArgs;
            }
            try root.initializeSimulation(DatabaseT, self.db, try parsePosition(tokens));
            try writer.writeAll("base configured\n");
        }

        fn cmdAdd(self: *Self, tokens: []const []const u8, writer: anytype, urgent: bool) !void {
            if (tokens.len < 4) {
                return error.MissingArgs;
            }
            const position = try parsePosition(tokens);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const description = try std.mem.join(arena.allocator(), " ", tokens[3..]);
            const id = if (urgent)
                try root.addEmergency(DatabaseT, self.db, position, description)
            else
                try root.addOrder(DatabaseT, self.db, position, description);
            try writer.print("added {s}\n", .{id[0..]});
        }

        fn cmdStep(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len > 2) {
                return error.TooManyArgs;
            }
            const count = if (tokens.len == 2)
                std.fmt.parseInt(u32, tokens[1], 10) catch return error.BadCount
            else
                1;
            if (count == 0) {
                return error.BadCount;
            }
            for (0..count) |_| {
                try root.stepSimulation(DatabaseT, self.db);
            }
            try writer.print("stepped {d}\n", .{count});
        }

        fn cmdAuto(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len != 2) {
                return error.MissingArgs;
            }
            const enabled = if (std.mem.eql(u8, tokens[1], "on"))
                true
            else if (std.mem.eql(u8, tokens[1], "off"))
                false
            else
                return error.BadAutoSetting;
            try root.setAutoOrders(DatabaseT, self.db, enabled);
            try writer.print("auto {s}\n", .{if (enabled) "on" else "off"});
        }

        fn cmdStatus(self: *Self, writer: anytype) !void {
            const snapshot = try root.snapshotSimulation(DatabaseT, self.db);
            const phase: root.Phase = @enumFromInt(snapshot.phase);
            try writer.print(
                "time: {d}s\nphase: {s}\nauto: {s}\nbase: {d:.5},{d:.5}\ncrew: {d:.5},{d:.5}\nactive: {s}\npending: {d}\nsuspended: {d}\n",
                .{
                    snapshot.model_seconds,
                    @tagName(phase),
                    if (snapshot.auto_orders != 0) "on" else "off",
                    snapshot.base[0],
                    snapshot.base[1],
                    snapshot.crew[0],
                    snapshot.crew[1],
                    activeId(snapshot.active_id),
                    snapshot.pending_count,
                    snapshot.suspended_count,
                },
            );
        }

        fn cmdSequence(self: *Self, comptime component_name: []const u8, writer: anytype) !void {
            var ids = try root.snapshotSequence(DatabaseT, self.db, component_name, self.allocator);
            defer ids.deinit(self.allocator);
            if (ids.items.len == 0) {
                try writer.writeAll("empty\n");
                return;
            }
            for (ids.items) |id| {
                try writer.print("{s}\n", .{id[0..]});
            }
        }

        fn cmdHistory(self: *Self, writer: anytype) !void {
            var history = try root.snapshotHistory(DatabaseT, self.db, self.allocator);
            defer history.deinit(self.allocator);
            if (history.items.len == 0) {
                try writer.writeAll("empty\n");
                return;
            }
            for (history.items) |entry| {
                try writer.print(
                    "{d}s  {s}  {s}  {s}\n",
                    .{
                        entry.model_seconds,
                        eventName(entry.event),
                        activeId(entry.order_id),
                        entry.description[0..entry.description_length],
                    },
                );
            }
        }

        fn cmdList(self: *Self, writer: anytype) !void {
            var orders = try root.snapshotOrders(DatabaseT, self.db, self.allocator);
            defer orders.deinit(self.allocator);
            if (orders.items.len == 0) {
                try writer.writeAll("no orders\n");
                return;
            }
            for (orders.items) |order| {
                try writer.print(
                    "{s}  {s}  {s}  {s}  [{d:.5},{d:.5}]  {d}s\n",
                    .{
                        order.id[0..],
                        orderKindName(order.kind),
                        orderStatusName(order.status),
                        order.description[0..order.description_length],
                        order.position[0],
                        order.position[1],
                        order.remaining_service_seconds,
                    },
                );
            }
        }

        fn cmdArea(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len != 4) {
                return error.MissingArgs;
            }
            const center = try parsePosition(tokens);
            const radius_m = try parseCoord(tokens[3]);
            if (!std.math.isFinite(radius_m) or radius_m < 0) {
                return error.BadRadius;
            }
            const latitude_delta = radius_m / 111_000;
            const longitude_delta = radius_m / (111_000 * @max(@abs(std.math.cos(center.latitude * std.math.pi / 180.0)), 0.01));
            var ids = try root.ordersInArea(DatabaseT, self.db, self.allocator, .{
                .latitude = center.latitude - latitude_delta,
                .longitude = center.longitude - longitude_delta,
            }, .{
                .latitude = center.latitude + latitude_delta,
                .longitude = center.longitude + longitude_delta,
            });
            defer ids.deinit(self.allocator);
            if (ids.items.len == 0) {
                try writer.writeAll("no orders\n");
                return;
            }
            for (ids.items) |id| {
                try writer.print("{s}\n", .{id[0..]});
            }
        }

        fn activeId(id: [8]u8) []const u8 {
            return if (std.mem.allEqual(u8, &id, 0)) "-" else &id;
        }

        fn orderKindName(kind: u8) []const u8 {
            return switch (kind) {
                0 => "normal",
                1 => "emergency",
                else => "unknown",
            };
        }

        fn orderStatusName(status: u8) []const u8 {
            return switch (status) {
                0 => "pending",
                1 => "active",
                2 => "suspended",
                else => "unknown",
            };
        }

        fn eventName(event: u8) []const u8 {
            return switch (event) {
                1 => "created",
                2 => "queued",
                3 => "assigned",
                4 => "suspended",
                5 => "resumed",
                6 => "arrived",
                7 => "completed",
                8 => "returning",
                9 => "at_base",
                10 => "auto_enabled",
                11 => "auto_disabled",
                else => "unknown",
            };
        }

        const help_text =
            \\commands: base add urgent step auto status queue stack history list area help quit
            \\  base <lat> <lng>                         configure the dispatch base
            \\  add <lat> <lng> <description...>          add a normal order
            \\  urgent <lat> <lng> <description...>       add an emergency order
            \\  step [count]                              advance simulation ticks
            \\  auto on|off                               enable or disable automatic orders
            \\  status                                    show simulation state
            \\  queue                                     show pending order ids
            \\  stack                                     show suspended order ids
            \\  history                                   show simulation events
            \\  list                                      show all orders
            \\  area <lat> <lng> <radius_m>               show orders in an area
            \\  help                                      show this help
            \\
        ;
    };
}
