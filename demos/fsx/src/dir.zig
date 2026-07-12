const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const inode = @import("inode.zig");

const bpt = fullaz.bpt;
const algorithm = fullaz.core.algorithm;

const PageId = constants.PageId;
const Inode = inode.Inode;

pub const Error = error{NameTooLong};

fn nameCmp(ctx: anytype, a: []const u8, b: []const u8) algorithm.Order {
    return algorithm.cmpSlices(u8, a, b, algorithm.CmpNum(u8).asc, ctx) catch .gt;
}

pub fn Directory(comptime PageCacheType: type) type {
    const settings: bpt.models.paged.Settings = .{
        .maximum_key_size = constants.max_name_len,
        .maximum_value_size = constants.dir_value_max,
        .leaf_page_kind = constants.PageKind.dir_leaf,
        .inode_page_kind = constants.PageKind.dir_inode,
    };

    const DirSM = struct {
        const SmSelf = @This();
        pub const PageId = constants.PageId;
        pub const Error = error{};

        cache: *PageCacheType,
        root: ?constants.PageId = null,

        pub fn getRoot(self: *const SmSelf) ?constants.PageId {
            return self.root;
        }
        pub fn setRoot(self: *SmSelf, r: ?constants.PageId) SmSelf.Error!void {
            self.root = r;
        }
        pub fn destroyPage(self: *SmSelf, id: constants.PageId) SmSelf.Error!void {
            if (comptime @hasDecl(PageCacheType, "free")) {
                self.cache.free(id) catch {};
            }
        }
    };

    const Model = bpt.models.PagedModel(PageCacheType, DirSM, nameCmp, void);
    const Tree = bpt.Bpt(Model);

    return struct {
        const Self = @This();

        cache: *PageCacheType,
        root: ?PageId,

        pub fn init(cache: *PageCacheType, root: ?PageId) Self {
            return .{ .cache = cache, .root = root };
        }

        pub fn getRoot(self: *const Self) ?PageId {
            return self.root;
        }

        pub fn insert(self: *Self, name: []const u8, node: Inode) !bool {
            if (name.len > constants.max_name_len) {
                return Error.NameTooLong;
            }
            var sm = DirSM{ .cache = self.cache, .root = self.root };
            var model = Model.init(self.cache, &sm, settings, {});
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            var buf: [inode.file_len]u8 = undefined;
            const bytes = try inode.encode(node, &buf);
            const ok = try tree.insert(name, bytes);
            self.root = sm.root;
            return ok;
        }

        pub fn lookup(self: *Self, name: []const u8) !?Inode {
            var sm = DirSM{ .cache = self.cache, .root = self.root };

            var model = Model.init(self.cache, &sm, settings, {});

            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            var it = (try tree.find(name)) orelse return null;
            defer it.deinit();
            const res = (try it.get()) orelse return null;
            return try inode.decode(res.value);
        }

        pub fn update(self: *Self, name: []const u8, node: Inode) !bool {
            var sm = DirSM{ .cache = self.cache, .root = self.root };
            var model = Model.init(self.cache, &sm, settings, {});
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            var buf: [inode.file_len]u8 = undefined;
            const bytes = try inode.encode(node, &buf);
            const ok = try tree.update(name, bytes);
            self.root = sm.root;
            return ok;
        }

        pub fn remove(self: *Self, name: []const u8) !bool {
            var sm = DirSM{ .cache = self.cache, .root = self.root };
            var model = Model.init(self.cache, &sm, settings, {});
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            const ok = try tree.remove(name);
            self.root = sm.root;
            return ok;
        }

        pub fn iterate(
            self: *Self,
            ctx: anytype,
            comptime cb: fn (@TypeOf(ctx), []const u8, Inode) anyerror!void,
        ) !void {
            var sm = DirSM{ .cache = self.cache, .root = self.root };
            var model = Model.init(self.cache, &sm, settings, {});
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            var it_opt = try tree.iterator();
            if (it_opt) |*it| {
                defer it.deinit();
                while (try it.next()) |res| {
                    const node = try inode.decode(res.value);
                    try cb(ctx, res.key, node);
                }
            }
        }

        pub fn isEmpty(self: *Self) !bool {
            const S = struct {
                fn cb(flag: *bool, name: []const u8, node: Inode) anyerror!void {
                    _ = name;
                    _ = node;
                    flag.* = true;
                }
            };
            var any = false;
            try self.iterate(&any, S.cb);
            return !any;
        }
    };
}
