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
    requiresFnSignature(T, "pageMut", fn (*T, T.PageId) Error![]u8);
    requiresFnSignature(T, "pageConst", fn (*T, T.PageId) Error![]const u8);
}

pub fn FreeList(comptime Store: type, comptime Endian: std.builtin.Endian) type {
    comptime requiresStore(Store);

    const PageId = Store.PageId;
    const NIL: PageId = std.math.maxInt(PageId);
    const FreedView = freed.View(PageId, Endian, false);
    const FreedViewConst = freed.View(PageId, Endian, true);

    return struct {
        const Self = @This();
        pub const Error = Store.Error;

        store: *Store,

        pub fn init(store: *Store) Self {
            return Self{
                .store = store,
            };
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.store.getRoot() == null;
        }

        pub fn push(self: *Self, pid: PageId) Error!void {
            const next: PageId = if (self.store.getRoot()) |r| r else NIL;
            var view = FreedView.init(try self.store.pageMut(pid));
            view.formatPage(next);
            try self.store.setRoot(pid);
        }

        pub fn pop(self: *Self) Error!?PageId {
            const head = self.store.getRoot() orelse return null;
            const view = FreedViewConst.init(try self.store.pageConst(head));
            const next = view.header().next.get();
            try self.store.setRoot(if (next == NIL) null else next);
            return head;
        }
    };
}
