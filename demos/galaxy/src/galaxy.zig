const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");
const storage = @import("storage.zig");
const starfield = @import("starfield.zig");

const rtree = fullaz.rtree;
const Star = starfield.Star;

pub const Direction = enum { north, south, east, west };

pub fn Galaxy(comptime PageCacheType: type, comptime RStar: bool) type {
    const Storage = storage.RootStorage(PageCacheType);

    const PageId = PageCacheType.Pid;
    const RtreePage = fullaz.page.rtree.Rtree(PageId, u16, f64, 2, constants.endian);
    const SlotEntry = fullaz.slots.Variadic(u16, constants.endian, false).Entry;
    const leaf_slot = @sizeOf(RtreePage.LeafSlotHeader) + Star.size + @sizeOf(SlotEntry);
    const inode_slot = @sizeOf(RtreePage.InodeSlotHeader) + @sizeOf(SlotEntry);
    const max_entries = constants.default_block_size / @min(leaf_slot, inode_slot);

    const Model = rtree.models.Paged(
        PageCacheType,
        Storage,
        f64,
        2,
        max_entries,
        constants.max_value_size,
        constants.endian,
    );
    const Tree = if (RStar) rtree.RStarTree(Model) else rtree.RTree(Model);
    const Key = Model.KeyType;

    return struct {
        const Self = @This();

        pub const KeyType = Key;

        gpa: std.mem.Allocator,
        cache: *PageCacheType,
        storage: *Storage,
        model: *Model,
        tree: Tree,

        seed: u64,
        px: f64,
        py: f64,
        cell: f64,
        view_w: f64,
        view_h: f64,
        star_counter: u32,

        fn point(x: f64, y: f64) Key {
            return Key.initWith(.{ x, y }, .{ x, y });
        }

        fn window(lx: f64, ly: f64, hx: f64, hy: f64) Key {
            return Key.initWith(.{ lx, ly }, .{ hx, hy });
        }

        fn wire(gpa: std.mem.Allocator, cache: *PageCacheType, root: ?PageCacheType.Pid) !struct { s: *Storage, m: *Model } {
            const s = try gpa.create(Storage);
            errdefer gpa.destroy(s);
            s.* = Storage.init(cache, root);
            const m = try gpa.create(Model);
            errdefer gpa.destroy(m);
            m.* = Model.init(cache, s, .{});
            return .{ .s = s, .m = m };
        }

        pub fn format(
            gpa: std.mem.Allocator,
            cache: *PageCacheType,
            block_size: u32,
            seed: u64,
            spawn_x: f64,
            spawn_y: f64,
        ) !Self {
            var ph = try cache.create();
            defer ph.deinit();
            if (try ph.pid() != constants.superblock_pid) {
                return error.NotFreshDevice;
            }
            var sb = superblock.View(false).init(try ph.getDataMut());
            sb.format(block_size);
            sb.setSeed(seed);
            sb.setPlayer(spawn_x, spawn_y);
            try cache.flush(constants.superblock_pid);

            const wired = try wire(gpa, cache, null);
            var self = Self{
                .gpa = gpa,
                .cache = cache,
                .storage = wired.s,
                .model = wired.m,
                .tree = Tree.init(wired.m),
                .seed = seed,
                .px = spawn_x,
                .py = spawn_y,
                .cell = constants.cell_size,
                .view_w = constants.view_w,
                .view_h = constants.view_h,
                .star_counter = 0,
            };
            _ = try self.reveal();
            return self;
        }

        pub fn open(gpa: std.mem.Allocator, cache: *PageCacheType, block_size: u32) !Self {
            const root = blk: {
                var ph = try cache.fetch(constants.superblock_pid);
                defer ph.deinit();
                const sb = superblock.View(true).init(try ph.getData());
                try sb.validate(block_size);
                const p = sb.getPlayer();
                const v = sb.getView();
                break :blk .{
                    .root = sb.getRoot(),
                    .seed = sb.getSeed(),
                    .px = p[0],
                    .py = p[1],
                    .cell = sb.getCellSize(),
                    .vw = v[0],
                    .vh = v[1],
                    .counter = sb.getStarCounter(),
                };
            };

            const wired = try wire(gpa, cache, root.root);
            return Self{
                .gpa = gpa,
                .cache = cache,
                .storage = wired.s,
                .model = wired.m,
                .tree = Tree.init(wired.m),
                .seed = root.seed,
                .px = root.px,
                .py = root.py,
                .cell = root.cell,
                .view_w = root.vw,
                .view_h = root.vh,
                .star_counter = root.counter,
            };
        }

        pub fn deinit(self: *Self) void {
            self.gpa.destroy(self.model);
            self.gpa.destroy(self.storage);
        }

        fn cellIndex(self: *const Self, v: f64) i64 {
            return @intFromFloat(@floor(v / self.cell));
        }

        fn cellGenerated(self: *Self, cx: i64, cy: i64) !bool {
            const lx = @as(f64, @floatFromInt(cx)) * self.cell;
            const ly = @as(f64, @floatFromInt(cy)) * self.cell;
            const q = window(lx, ly, lx + self.cell, ly + self.cell);
            var probe = Probe{};
            try self.tree.search(q, &probe, Probe.cb);
            return probe.found;
        }

        pub fn reveal(self: *Self) !usize {
            const hw = self.view_w / 2;
            const hh = self.view_h / 2;
            const min_cx = self.cellIndex(self.px - hw);
            const max_cx = self.cellIndex(self.px + hw);
            const min_cy = self.cellIndex(self.py - hh);
            const max_cy = self.cellIndex(self.py + hh);

            var created: usize = 0;
            var cy = min_cy;
            while (cy <= max_cy) : (cy += 1) {
                var cx = min_cx;
                while (cx <= max_cx) : (cx += 1) {
                    if (try self.cellGenerated(cx, cy)) continue;
                    var specs: [constants.star_jitter]starfield.StarSpec = undefined;
                    const k = starfield.genCell(cx, cy, self.cell, self.seed, self.star_counter, &specs);
                    var i: usize = 0;
                    while (i < k) : (i += 1) {
                        const b = specs[i].star.bytes();
                        try self.tree.insert(point(specs[i].x, specs[i].y), &b);
                    }
                    self.star_counter += @intCast(k);
                    created += k;
                }
            }
            return created;
        }

        pub fn move(self: *Self, dir: Direction) !usize {
            switch (dir) {
                .north => self.py += constants.step,
                .south => self.py -= constants.step,
                .east => self.px += constants.step,
                .west => self.px -= constants.step,
            }
            return self.reveal();
        }

        pub fn moveBy(self: *Self, dx: f64, dy: f64) !usize {
            self.px += dx;
            self.py += dy;
            return self.reveal();
        }

        pub fn setView(self: *Self, w: f64, h: f64) !usize {
            self.view_w = w;
            self.view_h = h;
            return self.reveal();
        }

        pub fn queryViewport(self: *Self, ctx: anytype, cb: anytype) !void {
            const hw = self.view_w / 2;
            const hh = self.view_h / 2;
            try self.tree.search(window(self.px - hw, self.py - hh, self.px + hw, self.py + hh), ctx, cb);
        }

        pub fn queryBox(self: *Self, lx: f64, ly: f64, hx: f64, hy: f64, ctx: anytype, cb: anytype) !void {
            try self.tree.search(window(lx, ly, hx, hy), ctx, cb);
        }

        pub fn walkNodes(self: *Self, ctx: anytype, cb: anytype) !void {
            const acc = self.model.getAccessor();
            const root = acc.getRoot() orelse return;
            try walkNode(acc, root, ctx, cb);
        }

        fn walkNode(acc: anytype, id: Model.NodeIdType, ctx: anytype, cb: anytype) !void {
            if (try acc.isLeafId(id)) {
                var leaf = (try acc.loadLeaf(id)).?;
                defer acc.deinitLeaf(leaf);
                try cb(ctx, try leaf.nodeMbr(), @as(usize, 0), true);
                return;
            }
            var inode = (try acc.loadInode(id)).?;
            defer acc.deinitInode(inode);
            try cb(ctx, try inode.nodeMbr(), try inode.getLevel(), false);
            const n = try inode.size();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try walkNode(acc, try inode.getChild(i), ctx, cb);
            }
        }

        pub fn renderGrid(self: *Self, grid: *[constants.map_rows * constants.map_cols]u21) !usize {
            for (grid) |*c| c.* = ' ';

            const Plot = struct {
                grid: *[constants.map_rows * constants.map_cols]u21,
                lx: f64,
                ly: f64,
                vw: f64,
                vh: f64,
                count: usize = 0,

                fn cb(p: *@This(), mbr: Key, value: []const u8) anyerror!void {
                    p.count += 1;
                    const sx = mbr.low[0];
                    const sy = mbr.low[1];
                    const fx = (sx - p.lx) / p.vw; // 0..1 left→right
                    const fy = (sy - p.ly) / p.vh; // 0..1 bottom→top
                    if (fx < 0 or fx >= 1 or fy < 0 or fy >= 1) {
                        return;
                    }
                    const col: usize = @intFromFloat(fx * @as(f64, constants.map_cols));
                    const row_from_bottom: usize = @intFromFloat(fy * @as(f64, constants.map_rows));
                    const row = constants.map_rows - 1 - row_from_bottom; // screen y is top-down
                    const star = Star.fromBytes(value);
                    p.grid[row * constants.map_cols + col] = starfield.glyph(star.brightness);
                }
            };

            const hw = self.view_w / 2;
            const hh = self.view_h / 2;
            var plot = Plot{
                .grid = grid,
                .lx = self.px - hw,
                .ly = self.py - hh,
                .vw = self.view_w,
                .vh = self.view_h,
            };
            try self.queryViewport(&plot, Plot.cb);

            grid[(constants.map_rows / 2) * constants.map_cols + (constants.map_cols / 2)] = '@';
            return plot.count;
        }

        pub fn render(self: *Self, writer: anytype) !void {
            var grid: [constants.map_rows * constants.map_cols]u21 = undefined;
            const count = try self.renderGrid(&grid);

            var utf8: [4]u8 = undefined;
            var row: usize = 0;
            while (row < constants.map_rows) : (row += 1) {
                var col: usize = 0;
                while (col < constants.map_cols) : (col += 1) {
                    const n = try std.unicode.utf8Encode(grid[row * constants.map_cols + col], &utf8);
                    try writer.writeAll(utf8[0..n]);
                }
                try writer.writeAll("\n");
            }
            try writer.print("at ({d:.1}, {d:.1})  view {d:.0}x{d:.0}  stars in view: {d}\n", .{
                self.px, self.py, self.view_w, self.view_h, count,
            });
        }

        pub fn save(self: *Self) !void {
            var ph = try self.cache.fetch(constants.superblock_pid);
            defer ph.deinit();
            var sb = superblock.View(false).init(try ph.getDataMut());
            sb.setPlayer(self.px, self.py);
            sb.setStarCounter(self.star_counter);
            try self.cache.flush(constants.superblock_pid);
        }

        const Probe = struct {
            found: bool = false,
            fn cb(self: *Probe, _: Key, _: []const u8) anyerror!void {
                self.found = true;
            }
        };
    };
}
