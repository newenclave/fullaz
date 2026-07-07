const constants = @import("constants.zig");
const superblock = @import("superblock.zig");
const inode = @import("inode.zig");
const dir = @import("dir.zig");
const file = @import("file.zig");
const reclaiming_cache = @import("reclaiming_cache.zig");

const PageId = constants.PageId;
const Size = constants.Size;
const Inode = inode.Inode;

pub const Error = error{
    NotFreshDevice,
    NotFound,
    NotADirectory,
    IsADirectory,
    AlreadyExists,
    DirNotEmpty,
    InvalidPath,
};

pub const Stat = struct {
    kind: inode.Kind,
    size: Size,
};

pub fn Fs(comptime PageCacheType: type, comptime PathPolicy: type) type {
    const Cache = reclaiming_cache.ReclaimingCache(PageCacheType);
    const Dir = dir.Directory(Cache);
    const FileT = file.File(Cache);

    return struct {
        const Self = @This();

        cache: Cache,
        block_size: u32,

        pub fn format(cache: *PageCacheType, block_size: u32) !Self {
            var ph = try cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            if (pid != constants.superblock_pid) {
                return Error.NotFreshDevice;
            }
            var sb = superblock.View(false).init(try ph.getDataMut());
            sb.format(block_size);
            try cache.flush(constants.superblock_pid);
            return .{ .cache = try Cache.init(cache), .block_size = block_size };
        }

        pub fn open(cache: *PageCacheType, block_size: u32) !Self {
            var ph = try cache.fetch(constants.superblock_pid);
            defer ph.deinit();
            const sb = superblock.View(true).init(try ph.getData());
            try sb.validate(block_size);
            return .{ .cache = try Cache.init(cache), .block_size = block_size };
        }

        pub fn getRootDirRoot(self: *Self) !?PageId {
            var ph = try self.cache.fetch(constants.superblock_pid);
            defer ph.deinit();
            const sb = superblock.View(true).init(try ph.getData());
            return sb.getRootDirRoot();
        }

        pub fn setRootDirRoot(self: *Self, pid: ?PageId) !void {
            var ph = try self.cache.fetch(constants.superblock_pid);
            defer ph.deinit();
            var sb = superblock.View(false).init(try ph.getDataMut());
            sb.setRootDirRoot(pid);
            try self.cache.flush(constants.superblock_pid);
        }

        pub fn resolve(self: *Self, path: []const u8) !?Inode {
            var comps_buf: [PathPolicy.MaxDepth][]const u8 = undefined;
            const n = try PathPolicy.split(path, &comps_buf);
            const comps = comps_buf[0..n];

            const root0 = try self.getRootDirRoot();
            var cur = Inode{ .dir = .{ .root = root0 } };
            for (comps) |comp| {
                const droot = switch (cur) {
                    .dir => |d| d.root,
                    .file => {
                        return Error.NotADirectory;
                    },
                };
                var d = Dir.init(&self.cache, droot);
                cur = (try d.lookup(comp)) orelse return null;
            }
            return cur;
        }

        fn descendParents(self: *Self, comps: []const []const u8, roots: []?PageId) !void {
            var i: usize = 0;
            while (i + 1 < comps.len) : (i += 1) {
                var d = Dir.init(&self.cache, roots[i]);
                const child = (try d.lookup(comps[i])) orelse return Error.NotFound;
                roots[i + 1] = switch (child) {
                    .dir => |dd| dd.root,
                    .file => {
                        return Error.NotADirectory;
                    },
                };
            }
        }

        fn flushUp(self: *Self, comps: []const []const u8, roots: []?PageId, root0_before: ?PageId) !void {
            var j: usize = comps.len - 1;
            while (j > 0) {
                var up = Dir.init(&self.cache, roots[j - 1]);
                const before = roots[j - 1];
                _ = try up.update(comps[j - 1], Inode{ .dir = .{ .root = roots[j] } });
                roots[j - 1] = up.getRoot();
                if (roots[j - 1] == before) {
                    break;
                }
                j -= 1;
            }
            if (roots[0] != root0_before) {
                try self.setRootDirRoot(roots[0]);
            }
        }

        fn createEntry(self: *Self, path: []const u8, node: Inode) !void {
            var comps_buf: [PathPolicy.MaxDepth][]const u8 = undefined;
            const n = try PathPolicy.split(path, &comps_buf);
            if (n == 0) {
                return Error.InvalidPath;
            }
            const comps = comps_buf[0..n];

            var roots_buf: [PathPolicy.MaxDepth]?PageId = undefined;
            const roots = roots_buf[0..n];
            roots[0] = try self.getRootDirRoot();
            try self.descendParents(comps, roots);

            const p = n - 1;
            const root0_before = roots[0];
            {
                var parent = Dir.init(&self.cache, roots[p]);
                if ((try parent.lookup(comps[p])) != null) {
                    return Error.AlreadyExists;
                }
                _ = try parent.insert(comps[p], node);
                roots[p] = parent.getRoot();
            }
            try self.flushUp(comps, roots, root0_before);
        }

        pub fn mkdir(self: *Self, path: []const u8) !void {
            try self.createEntry(path, Inode.newDir());
        }

        pub fn touch(self: *Self, path: []const u8) !void {
            try self.createEntry(path, Inode.newFile());
        }

        pub fn write(self: *Self, path: []const u8, bytes: []const u8) !usize {
            var comps_buf: [PathPolicy.MaxDepth][]const u8 = undefined;
            const n = try PathPolicy.split(path, &comps_buf);
            if (n == 0) {
                return Error.InvalidPath;
            }
            const comps = comps_buf[0..n];

            var roots_buf: [PathPolicy.MaxDepth]?PageId = undefined;
            const roots = roots_buf[0..n];
            roots[0] = try self.getRootDirRoot();
            try self.descendParents(comps, roots);

            const p = n - 1;
            const root0_before = roots[0];
            var written: usize = 0;
            {
                var parent = Dir.init(&self.cache, roots[p]);
                const entry = (try parent.lookup(comps[p])) orelse return Error.NotFound;
                const froots = switch (entry) {
                    .file => |fr| fr,
                    .dir => {
                        return Error.IsADirectory;
                    },
                };
                var f = FileT.init(&self.cache, froots);
                written = try f.append(bytes);
                _ = try parent.update(comps[p], Inode{ .file = f.getRoots() });
                roots[p] = parent.getRoot();
            }
            try self.flushUp(comps, roots, root0_before);
            return written;
        }

        pub fn read(self: *Self, path: []const u8, buf: []u8) !usize {
            const node = (try self.resolve(path)) orelse return Error.NotFound;
            const froots = switch (node) {
                .file => |fr| fr,
                .dir => {
                    return Error.IsADirectory;
                },
            };
            var f = FileT.init(&self.cache, froots);
            return try f.read(buf);
        }

        pub fn size(self: *Self, path: []const u8) !Size {
            const node = (try self.resolve(path)) orelse return Error.NotFound;
            return switch (node) {
                .file => |fr| fr.total,
                .dir => {
                    return Error.IsADirectory;
                },
            };
        }

        pub fn stat(self: *Self, path: []const u8) !Stat {
            const node = (try self.resolve(path)) orelse return Error.NotFound;
            return switch (node) {
                .file => |fr| .{ .kind = .file, .size = fr.total },
                .dir => .{ .kind = .dir, .size = 0 },
            };
        }

        pub fn rm(self: *Self, path: []const u8) !void {
            var comps_buf: [PathPolicy.MaxDepth][]const u8 = undefined;
            const n = try PathPolicy.split(path, &comps_buf);
            if (n == 0) {
                return Error.InvalidPath;
            }
            const comps = comps_buf[0..n];

            var roots_buf: [PathPolicy.MaxDepth]?PageId = undefined;
            const roots = roots_buf[0..n];
            roots[0] = try self.getRootDirRoot();
            try self.descendParents(comps, roots);

            const p = n - 1;
            const root0_before = roots[0];
            {
                var parent = Dir.init(&self.cache, roots[p]);
                const entry = (try parent.lookup(comps[p])) orelse return Error.NotFound;
                const froots = switch (entry) {
                    .file => |fr| fr,
                    .dir => {
                        return Error.IsADirectory;
                    },
                };
                var f = FileT.init(&self.cache, froots);
                try f.destroy();
                _ = try parent.remove(comps[p]);
                roots[p] = parent.getRoot();
            }
            try self.flushUp(comps, roots, root0_before);
        }

        pub fn rmdir(self: *Self, path: []const u8) !void {
            var comps_buf: [PathPolicy.MaxDepth][]const u8 = undefined;
            const n = try PathPolicy.split(path, &comps_buf);
            if (n == 0) {
                return Error.InvalidPath;
            }
            const comps = comps_buf[0..n];

            var roots_buf: [PathPolicy.MaxDepth]?PageId = undefined;
            const roots = roots_buf[0..n];
            roots[0] = try self.getRootDirRoot();
            try self.descendParents(comps, roots);

            const p = n - 1;
            const root0_before = roots[0];
            {
                var parent = Dir.init(&self.cache, roots[p]);
                const entry = (try parent.lookup(comps[p])) orelse return Error.NotFound;
                const droot = switch (entry) {
                    .dir => |d| d.root,
                    .file => {
                        return Error.NotADirectory;
                    },
                };
                var d = Dir.init(&self.cache, droot);
                if (!try d.isEmpty()) {
                    return Error.DirNotEmpty;
                }
                _ = try parent.remove(comps[p]);
                roots[p] = parent.getRoot();
            }
            try self.flushUp(comps, roots, root0_before);
        }

        pub fn ls(
            self: *Self,
            path: []const u8,
            ctx: anytype,
            comptime cb: fn (@TypeOf(ctx), []const u8, Inode) anyerror!void,
        ) !void {
            const node = (try self.resolve(path)) orelse return Error.NotFound;
            const droot = switch (node) {
                .dir => |d| d.root,
                .file => {
                    return Error.NotADirectory;
                },
            };
            var d = Dir.init(&self.cache, droot);
            try d.iterate(ctx, cb);
        }
    };
}
