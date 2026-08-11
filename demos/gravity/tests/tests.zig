const std = @import("std");
const gravity = @import("gravity");

fn expectPointApprox(expected: gravity.Point, actual: gravity.Point, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected[0], actual[0], tolerance);
    try std.testing.expectApproxEqAbs(expected[1], actual[1], tolerance);
}

test "gravity: mass trait calculates center of mass" {
    const bodies = [_]gravity.Body{
        .{ .position = .{ 0, 0 }, .mass = 10, .id = 1 },
        .{ .position = .{ 10, 0 }, .mass = 10, .id = 2 },
        .{ .position = .{ 10, 10 }, .mass = 20, .id = 3 },
    };
    var simulation = try gravity.Simulation.init(std.testing.allocator, &bodies);
    defer simulation.deinit();

    const root_id = simulation.model.accessor().getRoot().?;
    var root = try simulation.model.accessor().loadNode(root_id);
    defer simulation.model.accessor().deinitNode(&root);
    try std.testing.expectEqual(@as(usize, 3), root.getTrait().data.body_count);
    try std.testing.expectEqual(@as(f64, 40), root.getTrait().data.total_mass);
    try expectPointApprox(.{ 7.5, 5 }, gravity.centerOfMass(root.getTrait().data), 1e-12);
}

test "gravity: direct acceleration excludes the target body" {
    const bodies = [_]gravity.Body{
        .{ .position = .{ 0, 0 }, .mass = 10, .id = 1 },
    };
    try expectPointApprox(.{ 0, 0 }, gravity.directAcceleration(&bodies, bodies[0], .{ .softening = 0 }), 0);
}

test "gravity: acceleration points toward another mass" {
    const bodies = [_]gravity.Body{
        .{ .position = .{ 0, 0 }, .mass = 1, .id = 1 },
        .{ .position = .{ 2, 0 }, .mass = 8, .id = 2 },
    };
    try expectPointApprox(.{ 2, 0 }, gravity.directAcceleration(&bodies, bodies[0], .{ .softening = 0 }), 1e-12);
}

test "gravity: softening keeps coincident masses finite" {
    const bodies = [_]gravity.Body{
        .{ .position = .{ 0, 0 }, .mass = 1, .id = 1 },
        .{ .position = .{ 0, 0 }, .mass = 1, .id = 2 },
    };
    const acceleration = gravity.directAcceleration(&bodies, bodies[0], .{ .softening = 0.25 });
    try expectPointApprox(.{ 0, 0 }, acceleration, 0);
    try std.testing.expect(std.math.isFinite(acceleration[0]));
    try std.testing.expect(std.math.isFinite(acceleration[1]));
}

test "gravity: Barnes-Hut matches direct acceleration when theta is zero" {
    const bodies = [_]gravity.Body{
        .{ .position = .{ 1, 1 }, .mass = 2, .id = 1 },
        .{ .position = .{ 6, 2 }, .mass = 3, .id = 2 },
        .{ .position = .{ 2, 7 }, .mass = 5, .id = 3 },
        .{ .position = .{ 7, 7 }, .mass = 7, .id = 4 },
    };
    const config = gravity.Config{ .theta = 0, .softening = 0.1 };
    var simulation = try gravity.Simulation.init(std.testing.allocator, &bodies);
    defer simulation.deinit();

    for (bodies) |body| {
        const direct = gravity.directAcceleration(&bodies, body, config);
        const approximated = try gravity.barnesHutAcceleration(&simulation.tree, body, config);
        try expectPointApprox(direct, approximated, 1e-12);
    }
}

test "gravity: advance uses symplectic Euler and rebuilds the tree" {
    var bodies = [_]gravity.Body{
        .{ .position = .{ 0, 0 }, .mass = 1, .id = 1 },
        .{ .position = .{ 10, 0 }, .mass = 4, .id = 2 },
    };
    var simulation = try gravity.Simulation.init(std.testing.allocator, &bodies);
    defer simulation.deinit();

    try simulation.advance(&bodies, .{ .theta = 0, .softening = 0, .time_step = 0.1 });

    try std.testing.expectApproxEqAbs(@as(f64, 0.004), bodies[0].velocity[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0004), bodies[0].position[0], 1e-12);
    try std.testing.expectEqual(@as(usize, 2), try simulation.model.getEntriesCount());
    const bounds = (try simulation.tree.bounds()).?;
    try std.testing.expect(bounds.containsBox(&gravity.bodyBounds(bodies[0])));
    try std.testing.expect(bounds.containsBox(&gravity.bodyBounds(bodies[1])));
}

test "gravity: galaxy generation is deterministic" {
    var first = try gravity.makeGalaxy(std.testing.allocator, .{ .body_count = 8, .seed = 1234 });
    defer first.deinit(std.testing.allocator);
    var second = try gravity.makeGalaxy(std.testing.allocator, .{ .body_count = 8, .seed = 1234 });
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(first.items.len, second.items.len);
    for (first.items, second.items) |a, b| try std.testing.expectEqualDeep(a, b);
}

test "gravity: default galaxy builds an orthtree" {
    var bodies = try gravity.makeGalaxy(std.testing.allocator, .{});
    defer bodies.deinit(std.testing.allocator);
    var simulation = try gravity.Simulation.init(std.testing.allocator, bodies.items);
    defer simulation.deinit();

    try std.testing.expectEqual(@as(usize, 301), try simulation.model.getEntriesCount());
    try std.testing.expect(try simulation.nodeCount() > 1);
}

test "gravity: ten thousand bodies advance twenty steps" {
    var bodies = try gravity.makeGalaxy(std.testing.allocator, .{ .body_count = 10_000 });
    defer bodies.deinit(std.testing.allocator);
    var simulation = try gravity.Simulation.init(std.testing.allocator, bodies.items);
    defer simulation.deinit();

    for (0..20) |_| try simulation.advance(bodies.items, .{ .time_step = 0.002 });
    try std.testing.expectEqual(@as(usize, 10_001), try simulation.model.getEntriesCount());
}
