const std = @import("std");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");
const inode = @import("inode.zig");
const dir = @import("dir.zig");

const PageId = constants.PageId;
const Inode = inode.Inode;

const max_depth: usize = 32;

pub const Error = error{
    NotFreshDevice,
    NotFound,
    NotADirectory,
    AlreadyExists,
    PathTooDeep,
    InvalidPath,
};

pub fn Fs(comptime PageCacheType: type) type {
    const Dir = dir.Directory(PageCacheType);

    return struct {
        const Self = @This();

        cache: *PageCacheType,
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
            return .{ .cache = cache, .block_size = block_size };
        }

        pub fn open(cache: *PageCacheType, block_size: u32) !Self {
            var ph = try cache.fetch(constants.superblock_pid);
            defer ph.deinit();
            const sb = superblock.View(true).init(try ph.getData());
            try sb.validate(block_size);
            return .{ .cache = cache, .block_size = block_size };
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
            const root0 = try self.getRootDirRoot();
            var cur = Inode{ .dir = .{ .root = root0 } };
            var it = std.mem.tokenizeScalar(u8, path, '/');
            while (it.next()) |comp| {
                const droot = switch (cur) {
                    .dir => |d| d.root,
                    .file => {
                        return Error.NotADirectory;
                    },
                };
                var d = Dir.init(self.cache, droot);
                cur = (try d.lookup(comp)) orelse return null;
            }
            return cur;
        }

        fn splitPath(path: []const u8, comps: *[max_depth][]const u8) !usize {
            var n: usize = 0;
            var it = std.mem.tokenizeScalar(u8, path, '/');
            while (it.next()) |comp| {
                if (n >= max_depth) {
                    return Error.PathTooDeep;
                }
                comps[n] = comp;
                n += 1;
            }
            return n;
        }

        pub fn mkdir(self: *Self, path: []const u8) !void {
            var comps: [max_depth][]const u8 = undefined;
            const n = try splitPath(path, &comps);
            if (n == 0) {
                return Error.InvalidPath;
            }

            var roots: [max_depth]?PageId = undefined;
            roots[0] = try self.getRootDirRoot();

            var i: usize = 0;
            while (i + 1 < n) : (i += 1) {
                var d = Dir.init(self.cache, roots[i]);
                const child = (try d.lookup(comps[i])) orelse return Error.NotFound;
                roots[i + 1] = switch (child) {
                    .dir => |dd| dd.root,
                    .file => {
                        return Error.NotADirectory;
                    },
                };
            }

            const p = n - 1;
            const root0_before = roots[0];
            {
                var parent = Dir.init(self.cache, roots[p]);
                if ((try parent.lookup(comps[p])) != null) {
                    return Error.AlreadyExists;
                }
                _ = try parent.insert(comps[p], Inode.newDir());
                roots[p] = parent.getRoot();
            }

            var j = p;
            while (j > 0) {
                var up = Dir.init(self.cache, roots[j - 1]);
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
            var d = Dir.init(self.cache, droot);
            try d.iterate(ctx, cb);
        }
    };
}
