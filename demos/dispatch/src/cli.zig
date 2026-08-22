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

        /// Runs one command from pre-split tokens, reporting errors as text.
        pub fn execTokens(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            self.dispatch(tokens, writer) catch |err| {
                try writer.print("error: {s}\n", .{@errorName(err)});
            };
        }

        fn dispatch(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len == 0) {
                return;
            }
            const cmd = tokens[0];
            if (std.mem.eql(u8, cmd, "add")) {
                try self.cmdAdd(tokens, writer);
            } else if (std.mem.eql(u8, cmd, "top")) {
                try self.cmdTop(writer);
            } else if (std.mem.eql(u8, cmd, "complete")) {
                try self.cmdComplete(writer);
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

        fn cmdAdd(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len < 6) {
                return error.MissingArgs;
            }
            const id = tokens[1];
            if (id.len != 8) {
                return error.BadId;
            }
            const lat = try parseCoord(tokens[2]);
            const lng = try parseCoord(tokens[3]);
            const radius = try parseCoord(tokens[4]);
            if (radius < 0) {
                return error.BadRadius;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const value = try std.mem.join(arena.allocator(), " ", tokens[5..]);
            if (value.len > 64) {
                return error.ValueTooLong;
            }

            try root.addOrder(DatabaseT, self.db, .{
                .id = id[0..8].*,
                .value = value,
                .low = .{ lat - radius, lng - radius },
                .high = .{ lat + radius, lng + radius },
            });
            try writer.print("added {s}\n", .{id});
        }

        fn cmdTop(self: *Self, writer: anytype) !void {
            const due = try root.nextDue(DatabaseT, self.db);
            if (due == null) {
                try writer.writeAll("queue empty\n");
            } else {
                const id = due.?;
                try writer.print("next due: {s}\n", .{id[0..]});
            }
        }

        fn cmdComplete(self: *Self, writer: anytype) !void {
            const done = try root.completeNext(DatabaseT, self.db);
            if (done == null) {
                try writer.writeAll("queue empty\n");
            } else {
                const id = done.?;
                try writer.print("completed: {s}\n", .{id[0..]});
            }
        }

        fn cmdList(self: *Self, writer: anytype) !void {
            var list = try root.snapshotOrders(DatabaseT, self.db, self.allocator);
            defer list.deinit(self.allocator);
            for (list.items) |snapshot| {
                try writer.print(
                    "{s}  {s}  [{d:.2},{d:.2}]..[{d:.2},{d:.2}]\n",
                    .{
                        snapshot.id[0..],
                        snapshot.value[0..snapshot.value_len],
                        snapshot.low[0],
                        snapshot.low[1],
                        snapshot.high[0],
                        snapshot.high[1],
                    },
                );
            }
        }

        fn cmdArea(self: *Self, tokens: []const []const u8, writer: anytype) !void {
            if (tokens.len < 4) {
                return error.MissingArgs;
            }
            const lat = try parseCoord(tokens[1]);
            const lng = try parseCoord(tokens[2]);
            const radius = try parseCoord(tokens[3]);
            if (radius < 0) {
                return error.BadRadius;
            }

            var ids = try root.ordersInArea(
                DatabaseT,
                self.db,
                self.allocator,
                .{ lat - radius, lng - radius },
                .{ lat + radius, lng + radius },
            );
            defer ids.deinit(self.allocator);

            if (ids.items.len == 0) {
                try writer.writeAll("no orders\n");
            } else {
                for (ids.items) |id| {
                    try writer.print("{s}\n", .{id[0..]});
                }
            }
        }

        const help_text =
            \\commands: add top complete list area help quit
            \\  add <id> <lat> <lng> <radius> <value...>
            \\  top                        show next due order
            \\  complete                   execute the next due order
            \\  list                       list every order with its area
            \\  area <lat> <lng> <radius>  orders whose area intersects the box
            \\
        ;
    };
}
