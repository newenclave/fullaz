const std = @import("std");
const common = @import("common.zig");

const cloud = common.cloud;
const ascii = cloud.ascii;
const lod = cloud.lod;

const testing = std.testing;

fn splatAt(x: f64, y: f64, depth: f64, count: u32) lod.Splat {
    return .{
        .x = x,
        .y = y,
        .depth = depth,
        .radius = 1,
        .r = 10,
        .g = 20,
        .b = 30,
        .count = count,
    };
}

fn makeGrid(cells: []ascii.Cell, width: usize, height: usize) !ascii.Grid {
    var grid = try ascii.Grid.init(cells, width, height);
    grid.clear();
    return grid;
}

test "cloud: a grid refuses a buffer that is too small" {
    var cells: [4]ascii.Cell = undefined;
    try testing.expectError(error.GridTooSmall, ascii.Grid.init(&cells, 3, 3));
}

test "cloud: the nearer splat wins the cell" {
    var cells: [16]ascii.Cell = undefined;
    var grid = try makeGrid(&cells, 4, 4);
    var sink = ascii.GridSink{ .grid = &grid };

    sink.push(splatAt(1.2, 2.9, 100, 1));
    sink.push(splatAt(1.8, 2.1, 10, 300));
    sink.push(splatAt(1.4, 2.5, 500, 5));

    const cell = grid.get(1, 2);
    try testing.expectEqual(@as(f64, 10), cell.depth);
    try testing.expectEqual(@as(u32, 300), cell.count);
    try testing.expectEqual(ascii.glyphFor(300), cell.glyph);
}

test "cloud: splats outside the grid are dropped, not clamped" {
    var cells: [16]ascii.Cell = undefined;
    var grid = try makeGrid(&cells, 4, 4);
    var sink = ascii.GridSink{ .grid = &grid };

    sink.push(splatAt(-0.5, 2, 10, 1));
    sink.push(splatAt(4.0, 2, 10, 1));
    sink.push(splatAt(2, -1, 10, 1));
    sink.push(splatAt(2, 4.0, 10, 1));

    try testing.expectEqual(@as(usize, 4), sink.dropped);
    try testing.expectEqual(@as(usize, 0), sink.drawn);
}

// `if (x < 0 or x >= w)` would let NaN through into @intFromFloat, which is a
// panic in Debug and undefined behaviour in the ReleaseSmall wasm build.
test "cloud: nan and infinite splats are dropped" {
    var cells: [16]ascii.Cell = undefined;
    var grid = try makeGrid(&cells, 4, 4);
    var sink = ascii.GridSink{ .grid = &grid };

    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    sink.push(splatAt(nan, 2, 10, 1));
    sink.push(splatAt(2, nan, 10, 1));
    sink.push(splatAt(2, 2, nan, 1));
    sink.push(splatAt(inf, 2, 10, 1));
    sink.push(splatAt(2, 2, -inf, 1));

    try testing.expectEqual(@as(usize, 5), sink.dropped);
    try testing.expectEqual(@as(usize, 0), sink.drawn);
}

test "cloud: clearing resets every cell" {
    var cells: [16]ascii.Cell = undefined;
    var grid = try makeGrid(&cells, 4, 4);
    var sink = ascii.GridSink{ .grid = &grid };

    sink.push(splatAt(1, 1, 5, 9));
    try testing.expect(grid.get(1, 1).count != 0);

    grid.clear();
    try testing.expectEqual(@as(u32, 0), grid.get(1, 1).count);
    try testing.expectEqual(std.math.inf(f64), grid.get(1, 1).depth);
}

test "cloud: the glyph ramp grows with the aggregate size" {
    const ramp = [_]u32{ 1, 4, 32, 256, 2048, 40000 };
    var previous: u21 = ascii.glyphFor(0);

    for (ramp) |count| {
        const glyph = ascii.glyphFor(count);
        try testing.expect(glyph != previous);
        previous = glyph;
    }
    try testing.expectEqual(@as(u21, ' '), ascii.glyphFor(0));
}

test "cloud: a frame has one line per row and erases to end of line" {
    var cells: [12]ascii.Cell = undefined;
    var grid = try makeGrid(&cells, 4, 3);
    var sink = ascii.GridSink{ .grid = &grid };
    sink.push(splatAt(0, 0, 1, 1));

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ascii.writeFrame(&grid, &writer, .{});
    const output = writer.buffered();

    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, output, "\x1b[K"));
    // Rows are separated, not terminated, so the frame does not scroll.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "\r\n"));
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;10;20;30m") != null);
}

// Per-cell SGR alone caps the frame rate on Windows conhost, so a run of one
// colour must emit a single escape.
test "cloud: a run of one colour emits a single escape" {
    var cells: [12]ascii.Cell = undefined;
    var grid = try makeGrid(&cells, 4, 3);
    var sink = ascii.GridSink{ .grid = &grid };

    sink.push(splatAt(0, 0, 1, 1));
    sink.push(splatAt(1, 0, 1, 1));
    sink.push(splatAt(2, 0, 1, 1));

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ascii.writeFrame(&grid, &writer, .{});
    const output = writer.buffered();

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\x1b[38;2;"));
}

test "cloud: an empty frame writes only blanks" {
    var cells: [12]ascii.Cell = undefined;
    var grid = try makeGrid(&cells, 4, 3);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ascii.writeFrame(&grid, &writer, .{});
    const output = writer.buffered();

    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, output, "\x1b[38;2;"));
    try testing.expectEqual(@as(usize, 12), std.mem.count(u8, output, " "));
}
