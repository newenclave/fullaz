const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");
const inode = @import("inode.zig");

pub const PageRole = enum(u8) {
    superblock,
    directory_leaf,
    directory_inode,
    file_chunk,
    file_index_leaf,
    file_index_inode,
    freed,
    unknown,
};

pub const PageInfo = struct {
    pid: constants.PageId,
    role: PageRole,
    used: u32,
    capacity: u32,
};

pub const OwnershipRole = enum(u8) {
    directory_tree,
    file_chunk,
    file_index,
};

pub const OwnedPage = struct {
    pid: constants.PageId,
    role: OwnershipRole,
};

pub fn Inspector(comptime PageCacheType: type) type {
    const HeaderView = fullaz.page.header.View(constants.PageId, u16, constants.endian, true);
    const FreedView = fullaz.page.freed.View(constants.PageId, constants.endian, true);
    const Slots = fullaz.slots.Variadic(u16, constants.endian, true);
    const DirectoryView = fullaz.bpt.models.paged.View(constants.PageId, u16, constants.endian, true);
    const IndexView = fullaz.weighted_bpt.models.paged.View(constants.PageId, u16, constants.Size, constants.endian, true);
    const ChunkView = fullaz.storage.chain_store.View(constants.PageId, u16, constants.Size, constants.endian, true).Chunk;

    return struct {
        const Self = @This();

        cache: *PageCacheType,

        pub fn init(cache: *PageCacheType) Self {
            return .{ .cache = cache };
        }

        pub fn scan(
            self: *Self,
            format_version: u16,
            ctx: anytype,
            comptime callback: fn (@TypeOf(ctx), PageInfo) anyerror!void,
        ) anyerror!void {
            const count = self.cache.device.blocksCount();
            for (0..count) |index| {
                const pid: constants.PageId = @intCast(index);
                var handle = try self.cache.fetch(pid);
                defer handle.deinit();
                try callback(ctx, inspectPage(pid, try handle.data(), format_version));
            }
        }

        pub fn traceDirectory(
            self: *Self,
            root: ?constants.PageId,
            ctx: anytype,
            comptime callback: fn (@TypeOf(ctx), OwnedPage) anyerror!void,
        ) anyerror!void {
            if (root) |pid| {
                try self.traceDirectoryNode(pid, ctx, callback);
            }
        }

        pub fn traceFile(
            self: *Self,
            roots: inode.FileRoots,
            format_version: u16,
            ctx: anytype,
            comptime callback: fn (@TypeOf(ctx), OwnedPage) anyerror!void,
        ) anyerror!void {
            var next = roots.first;
            while (next) |pid| {
                try callback(ctx, .{ .pid = pid, .role = .file_chunk });
                var handle = try self.cache.fetch(pid);
                defer handle.deinit();
                const chunk = ChunkView.init(try handle.data());
                next = chunk.link().getFwd();
            }
            if (roots.index) |pid| {
                try self.traceIndexNode(pid, format_version, ctx, callback);
            }
        }

        fn traceDirectoryNode(
            self: *Self,
            pid: constants.PageId,
            ctx: anytype,
            comptime callback: fn (@TypeOf(ctx), OwnedPage) anyerror!void,
        ) anyerror!void {
            try callback(ctx, .{ .pid = pid, .role = .directory_tree });
            var handle = try self.cache.fetch(pid);
            defer handle.deinit();
            const data = try handle.data();
            const header = HeaderView.init(data);
            try header.validateCommon();
            if (header.header().kind.get() != constants.PageKind.dir_inode) {
                return;
            }

            const node = DirectoryView.InodeSubheaderView.init(data);
            const slots = try node.slotsDir();
            const count = slots.size();
            for (0..count) |index| {
                try self.traceDirectoryNode((try node.get(index)).child, ctx, callback);
            }
            const rightmost = node.subheader().rightmost_child;
            if (!rightmost.isMax()) {
                try self.traceDirectoryNode(rightmost.get(), ctx, callback);
            }
        }

        fn traceIndexNode(
            self: *Self,
            pid: constants.PageId,
            format_version: u16,
            ctx: anytype,
            comptime callback: fn (@TypeOf(ctx), OwnedPage) anyerror!void,
        ) anyerror!void {
            try callback(ctx, .{ .pid = pid, .role = .file_index });
            var handle = try self.cache.fetch(pid);
            defer handle.deinit();
            const data = try handle.data();
            const header = HeaderView.init(data);
            try header.validateCommon();
            if (header.header().kind.get() != constants.fileIndexInodeKind(format_version)) {
                return;
            }

            const node = IndexView.InodeSubheaderView.init(data);
            const count = try node.entries();
            for (0..count) |index| {
                try self.traceIndexNode((try node.get(index)).child, format_version, ctx, callback);
            }
        }

        fn inspectPage(pid: constants.PageId, data: []const u8, format_version: u16) PageInfo {
            const capacity: u32 = @intCast(data.len);
            if (pid == constants.superblock_pid) {
                const sb = superblock.View(true).init(data);
                if (sb.validate(capacity)) |_| {
                    return .{
                        .pid = pid,
                        .role = .superblock,
                        .used = @sizeOf(superblock.Header),
                        .capacity = capacity,
                    };
                } else |_| {}
                return .{ .pid = pid, .role = .unknown, .used = 0, .capacity = capacity };
            }

            const freed = FreedView.init(data);
            if (freed.header().kind.get() == constants.PageKind.freed) {
                return .{
                    .pid = pid,
                    .role = .freed,
                    .used = @sizeOf(FreedView.FreedHeader),
                    .capacity = capacity,
                };
            }

            const header = HeaderView.init(data);
            header.validateCommon() catch {
                return .{ .pid = pid, .role = .unknown, .used = 0, .capacity = capacity };
            };

            const kind = header.header().kind.get();
            const role: PageRole = if (kind == constants.PageKind.dir_leaf)
                .directory_leaf
            else if (kind == constants.PageKind.dir_inode)
                .directory_inode
            else if (kind == constants.PageKind.file_chunk)
                .file_chunk
            else if (kind == constants.fileIndexLeafKind(format_version))
                .file_index_leaf
            else if (kind == constants.fileIndexInodeKind(format_version))
                .file_index_inode
            else
                .unknown;
            const used = switch (role) {
                .directory_leaf, .directory_inode, .file_index_leaf, .file_index_inode => slotsUsed(&header),
                .file_chunk => chunkUsed(&header, data),
                else => 0,
            };
            return .{ .pid = pid, .role = role, .used = used, .capacity = capacity };
        }

        fn slotsUsed(header: *const HeaderView) u32 {
            const slots = Slots.init(header.data()) catch return @intCast(header.allHeadersSize());
            const used = slots.usedSpace() catch return @intCast(header.allHeadersSize());
            return @intCast(header.allHeadersSize() + used);
        }

        fn chunkUsed(header: *const HeaderView, data: []const u8) u32 {
            const chunk = ChunkView.init(data);
            return @intCast(header.allHeadersSize() + chunk.getSize());
        }
    };
}
