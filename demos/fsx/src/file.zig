const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const inode = @import("inode.zig");

const chain_store = fullaz.storage.chain_store;

const FileRoots = inode.FileRoots;

pub fn File(comptime PageCacheType: type) type {
    const FileSM = struct {
        const SmSelf = @This();
        pub const PageId = constants.PageId;
        pub const Size = constants.Size;
        pub const Error = error{};

        cache: *PageCacheType,
        roots: FileRoots,

        pub fn getTotalSize(self: *const SmSelf) Error!Size {
            return self.roots.total;
        }
        pub fn setTotalSize(self: *SmSelf, n: Size) Error!void {
            self.roots.total = n;
        }
        pub fn getFirst(self: *const SmSelf) Error!?PageId {
            return self.roots.first;
        }
        pub fn getLast(self: *const SmSelf) Error!?PageId {
            return self.roots.last;
        }
        pub fn setFirst(self: *SmSelf, pid: ?PageId) Error!void {
            self.roots.first = pid;
        }
        pub fn setLast(self: *SmSelf, pid: ?PageId) Error!void {
            self.roots.last = pid;
        }
        pub fn destroyPage(self: *SmSelf, id: PageId) Error!void {
            if (comptime @hasDecl(PageCacheType, "free")) {
                self.cache.free(id) catch {};
            }
        }
        pub fn getIndexRoot(self: *const SmSelf) ?PageId {
            return self.roots.index;
        }
        pub fn setIndexRoot(self: *SmSelf, pid: ?PageId) Error!void {
            self.roots.index = pid;
        }
    };

    const Chain = chain_store.HandleWeighted(PageCacheType, FileSM, constants.endian);
    return struct {
        const Self = @This();

        cache: *PageCacheType,
        roots: FileRoots,
        settings: chain_store.Settings,

        pub fn init(cache: *PageCacheType, roots: FileRoots, settings: chain_store.Settings) Self {
            return .{ .cache = cache, .roots = roots, .settings = settings };
        }

        pub fn getRoots(self: *const Self) FileRoots {
            return self.roots;
        }

        pub fn size(self: *const Self) constants.Size {
            return self.roots.total;
        }

        pub fn append(self: *Self, bytes: []const u8) !usize {
            var sm = FileSM{ .cache = self.cache, .roots = self.roots };
            var handle = Chain.init(self.cache, &sm, self.settings);
            defer handle.deinit();

            if (sm.roots.first == null) {
                try handle.create();
            }
            const total = try handle.totalSize();
            try handle.setp(total);
            const written = try handle.write(bytes);
            self.roots = sm.roots;
            return written;
        }

        pub fn replace(self: *Self, bytes: []const u8) !usize {
            var sm = FileSM{ .cache = self.cache, .roots = self.roots };
            var handle = Chain.init(self.cache, &sm, self.settings);
            defer handle.deinit();

            if (sm.roots.first != null) {
                try handle.truncate(sm.roots.total);
            }
            if (bytes.len == 0) {
                self.roots = sm.roots;
                return 0;
            }
            if (sm.roots.first == null) {
                try handle.create();
            }
            try handle.setp(0);
            const written = try handle.write(bytes);
            self.roots = sm.roots;
            return written;
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            var sm = FileSM{ .cache = self.cache, .roots = self.roots };
            var handle = Chain.init(self.cache, &sm, self.settings);
            defer handle.deinit();

            if (sm.roots.first == null) {
                return 0;
            }
            try handle.setg(0);
            return try handle.read(buf);
        }

        pub fn destroy(self: *Self) !void {
            var sm = FileSM{ .cache = self.cache, .roots = self.roots };
            var handle = Chain.init(self.cache, &sm, self.settings);
            defer handle.deinit();

            if (sm.roots.first != null) {
                try handle.truncate(sm.roots.total);
                // truncate retains one empty tail chunk so a live handle can keep
                // writing; a deleted fsx file owns and releases that final page.
                if (sm.roots.first) |pid| {
                    try self.cache.free(pid);
                }
            }
            self.roots = .{};
        }
    };
}
