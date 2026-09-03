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
        const State = chain_store.WeightedState(PageId, Size, constants.endian);

        pub const StateLeaseType = struct {
            const LeaseSelf = @This();

            pub const Error = SmSelf.Error;

            // The owner keeps the file metadata alive while this state view is in use.
            owner: *SmSelf,
            state: State,

            pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                return std.mem.asBytes(&self.state);
            }

            pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                return std.mem.asBytes(&self.state);
            }

            pub fn finish(self: *LeaseSelf) void {
                const first = self.state.chain.first.get();
                const last = self.state.chain.last.get();
                self.owner.roots.first = if (first == constants.pid_none) null else first;
                self.owner.roots.last = if (last == constants.pid_none) null else last;
                self.owner.roots.total = self.state.chain.total_size.get();
                const index = self.state.index.root.get();
                self.owner.roots.index = if (index == constants.pid_none) null else index;
            }

            pub fn deinit(_: *LeaseSelf) void {}
        };

        cache: *PageCacheType,
        roots: FileRoots,

        pub fn state(self: *SmSelf) Error!StateLeaseType {
            var lease: StateLeaseType = .{
                .owner = self,
                .state = .{},
            };
            lease.state.chain.first.set(self.roots.first orelse constants.pid_none);
            lease.state.chain.last.set(self.roots.last orelse constants.pid_none);
            lease.state.chain.total_size.set(self.roots.total);
            lease.state.index.root.set(self.roots.index orelse constants.pid_none);
            return lease;
        }

        pub fn destroyPage(self: *SmSelf, id: PageId) Error!void {
            if (comptime @hasDecl(PageCacheType, "free")) {
                self.cache.free(id) catch {};
            }
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
