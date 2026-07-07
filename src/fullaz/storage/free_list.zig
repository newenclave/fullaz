const std = @import("std");
const freed = @import("../page/freed.zig");
const contracts = @import("../contracts/contracts.zig");

const requiresFnSignature = contracts.interfaces.requiresFnSignature;
const requiresErrorDeclaration = contracts.interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = contracts.interfaces.requiresTypeDeclaration;

pub fn requiresStore(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    const Error = T.Error;
    requiresTypeDeclaration(T, "PageId");
    requiresFnSignature(T, "getRoot", fn (*const T) ?T.PageId);
    requiresFnSignature(T, "setRoot", fn (*T, ?T.PageId) Error!void);
}

pub fn FreeList(comptime PageCacheType: type, comptime StoreManager: type, comptime Endian: std.builtin.Endian) type {
    comptime requiresStore(StoreManager);

    const PageId = StoreManager.PageId;
    const NIL: PageId = std.math.maxInt(PageId);
    const FreedView = freed.View(PageId, Endian, false);
    const FreedViewConst = freed.View(PageId, Endian, true);

    return struct {
        const Self = @This();
        pub const Error = StoreManager.Error || PageCacheType.Error;

        cache: *PageCacheType = undefined,
        store: *StoreManager = undefined,

        pub fn init(cache: *PageCacheType, store: *StoreManager) Self {
            return Self{
                .store = store,
                .cache = cache,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.store.getRoot() == null;
        }

        pub fn push(self: *Self, pid: PageId) Error!void {
            const next: PageId = if (self.store.getRoot()) |r| r else NIL;
            var ph = try self.cache.fetch(pid);
            defer ph.deinit();
            var view = FreedView.init(try ph.getDataMut());
            view.formatPage(next);
            try self.store.setRoot(pid);
        }

        pub fn pop(self: *Self) Error!?PageId {
            const head = self.store.getRoot() orelse return null;
            var ph = try self.cache.fetch(head);
            defer ph.deinit();

            const view = FreedViewConst.init(try ph.getData());
            const next = view.header().next.get();
            try self.store.setRoot(if (next == NIL) null else next);
            return head;
        }
    };
}
