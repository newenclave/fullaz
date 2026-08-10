const std = @import("std");
const lod = @import("lod.zig");

// Nothing here allocates and nothing here does I/O: the caller owns the cells
// and passes any writer, which is what keeps this file wasm-safe and testable.
pub const Cell = struct {
    depth: f64 = std.math.inf(f64),
    glyph: u21 = ' ',
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    count: u32 = 0,
};

pub const Grid = struct {
    const Self = @This();

    cells: []Cell,
    width: usize,
    height: usize,

    pub fn init(cells: []Cell, width: usize, height: usize) !Self {
        if (cells.len < width * height) return error.GridTooSmall;
        return .{ .cells = cells, .width = width, .height = height };
    }

    pub fn clear(self: *Self) void {
        @memset(self.cells[0 .. self.width * self.height], .{});
    }

    pub fn at(self: *Self, col: usize, row: usize) *Cell {
        return &self.cells[row * self.width + col];
    }

    pub fn get(self: *const Self, col: usize, row: usize) Cell {
        return self.cells[row * self.width + col];
    }
};

// Denser glyphs for splats that stand for more points. Same shape as the ramp
// in demos/gravity/src/main.zig.
pub fn glyphFor(count: u32) u21 {
    return switch (count) {
        0 => ' ',
        1 => '·',
        2...8 => '∙',
        9...64 => '•',
        65...512 => '●',
        513...4096 => '◆',
        else => '★',
    };
}

// A per-cell depth test rather than a painter's algorithm, so nothing has to be
// sorted and push stays O(1).
pub const GridSink = struct {
    const Self = @This();

    grid: *Grid,
    dropped: usize = 0,
    drawn: usize = 0,

    pub fn push(self: *Self, splat: lod.Splat) void {
        const width: f64 = @floatFromInt(self.grid.width);
        const height: f64 = @floatFromInt(self.grid.height);

        // Positive form: a NaN coordinate is dropped rather than slipping
        // through into @intFromFloat.
        if (!(splat.x >= 0) or !(splat.x < width) or
            !(splat.y >= 0) or !(splat.y < height) or
            !(splat.depth > 0))
        {
            self.dropped += 1;
            return;
        }

        const col: usize = @intFromFloat(splat.x);
        const row: usize = @intFromFloat(splat.y);
        const cell = self.grid.at(col, row);
        if (!(splat.depth < cell.depth)) return;

        cell.* = .{
            .depth = splat.depth,
            .glyph = glyphFor(splat.count),
            .r = splat.r,
            .g = splat.g,
            .b = splat.b,
            .count = splat.count,
        };
        self.drawn += 1;
    }
};

fn writeCodepoint(writer: anytype, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch {
        try writer.writeByte('?');
        return;
    };
    try writer.writeAll(buffer[0..length]);
}

pub const FrameOptions = struct {
    // Off when stdout is not a terminal, so a piped frame stays plain text.
    colour: bool = true,
    // The interactive viewer redraws from the home position, so each line
    // erases whatever the previous frame left behind.
    erase_line: bool = true,
    newline: []const u8 = "\r\n",
};

// Colour runs are coalesced: on Windows conhost a per-cell SGR sequence alone
// is enough to cap the frame rate.
pub fn writeFrame(grid: *const Grid, writer: anytype, options: FrameOptions) !void {
    var row: usize = 0;
    while (row < grid.height) : (row += 1) {
        var active: ?[3]u8 = null;

        var col: usize = 0;
        while (col < grid.width) : (col += 1) {
            const cell = grid.get(col, row);
            if (cell.count == 0) {
                if (active != null) {
                    try writer.writeAll("\x1b[0m");
                    active = null;
                }
                try writer.writeByte(' ');
                continue;
            }

            if (options.colour) {
                const colour = [3]u8{ cell.r, cell.g, cell.b };
                if (active == null or !std.mem.eql(u8, &active.?, &colour)) {
                    try writer.print("\x1b[38;2;{d};{d};{d}m", .{ colour[0], colour[1], colour[2] });
                    active = colour;
                }
            }
            try writeCodepoint(writer, cell.glyph);
        }

        if (active != null) {
            try writer.writeAll("\x1b[0m");
        }
        if (options.erase_line) {
            try writer.writeAll("\x1b[K");
        }
        if (row + 1 < grid.height) {
            try writer.writeAll(options.newline);
        }
    }
}
