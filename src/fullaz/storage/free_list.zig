const std = @import("std");
const freed = @import("../page/freed.zig");
const contracts = @import("../contracts/contracts.zig");
const storage_manager = @import("../core/storage_manager.zig");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

/// Exact durable free-list state. `maxInt(PageIdT)` is the null root.
pub fn State(comptime PageIdT: type, comptime Endian: std.builtin.Endian) type {
    const PackedPageId = PackedInt(PageIdT, Endian);
    const StateT = extern struct {
        root: PackedPageId = .init(std.math.maxInt(PageIdT)),
    };
    comptime {
        if (@alignOf(StateT) != 1 or
            @offsetOf(StateT, "root") != 0 or
            @sizeOf(StateT) != @sizeOf(PackedPageId))
        {
            @compileError("FreeList state layout changed");
        }
    }
    return StateT;
}

pub fn FreeList(comptime PageCacheT: type, comptime StoreManagerT: type, comptime Endian: std.builtin.Endian) type {
    comptime contracts.storage_manager.assertStorageManager(StoreManagerT);

    const PageId = PageCacheT.Pid;
    const StateT = State(PageId, Endian);
    const StateAccessor = storage_manager.StateAccessor(StoreManagerT.StateLeaseType, StateT);
    const FreedView = freed.View(PageId, Endian, false);
    const FreedViewConst = freed.View(PageId, Endian, true);

    return struct {
        const Self = @This();
        pub const State = StateT;
        pub const Error = StoreManagerT.Error || StateAccessor.Error || PageCacheT.Error;

        cache: *PageCacheT = undefined,
        store: *StoreManagerT = undefined,

        pub fn init(cache: *PageCacheT, store: *StoreManagerT) Self {
            return Self{
                .store = store,
                .cache = cache,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn isEmpty(self: *Self) Error!bool {
            var lease = try self.store.state();
            defer lease.deinit();
            return (try StateAccessor.view(&lease)).root.isMax();
        }

        pub fn push(self: *Self, pid: PageId) Error!void {
            var lease = try self.store.state();
            defer lease.deinit();
            const state = try StateAccessor.viewMut(&lease);
            const next = state.root.get();
            var ph = try self.cache.fetch(pid);
            defer ph.deinit();
            var view = FreedView.init(try ph.dataMut());
            view.formatPage(next);
            state.root.set(pid);
            lease.finish();
        }

        pub fn pop(self: *Self) Error!?PageId {
            var lease = try self.store.state();
            defer lease.deinit();
            const state = try StateAccessor.view(&lease);
            if (state.root.isMax()) {
                return null;
            }
            const head = state.root.get();
            var ph = try self.cache.fetch(head);
            defer ph.deinit();

            const view = FreedViewConst.init(try ph.data());
            const next = view.header().next.get();
            (try StateAccessor.viewMut(&lease)).root.set(next);
            lease.finish();
            return head;
        }
    };
}
