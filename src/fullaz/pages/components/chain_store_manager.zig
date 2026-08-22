const interfaces = @import("../../contracts/interfaces.zig");
const page_cache_contract = @import("../../contracts/page_cache.zig");

/// Owns the external roots and byte count for one chain-store component.
pub fn ChainStoreManager(comptime BackendT: type) type {
    interfaces.requiresTypeDeclaration(BackendT, "PageId");
    interfaces.requiresTypeDeclaration(BackendT, "CacheType");
    const PageIdT = BackendT.PageId;
    const CacheT = BackendT.CacheType;
    comptime page_cache_contract.requiresTransactionalPageCache(CacheT);
    if (PageIdT != CacheT.Pid) {
        @compileError("ChainStore manager backend PageId must match CacheType.Pid");
    }
    interfaces.requiresFnSignature(BackendT, "cache", fn (*BackendT) *CacheT);
    interfaces.requiresFnSignature(CacheT, "free", fn (*CacheT, PageIdT) CacheT.Error!void);

    return struct {
        const Self = @This();

        pub const PageId = PageIdT;
        pub const Size = u64;
        pub const Error = CacheT.Error;
        pub const State = struct {
            first: ?PageId = null,
            last: ?PageId = null,
            total_size: Size = 0,
        };

        cache_ptr: *CacheT,
        state: State = .{},

        pub fn init(backend: *BackendT) Self {
            return .{ .cache_ptr = backend.cache() };
        }

        pub fn getState(self: *const Self) State {
            return self.state;
        }

        pub fn restoreState(self: *Self, state: State) void {
            self.state = state;
        }

        pub fn getTotalSize(self: *const Self) Error!Size {
            return self.state.total_size;
        }

        pub fn setTotalSize(self: *Self, total_size: Size) Error!void {
            self.state.total_size = total_size;
        }

        pub fn getFirst(self: *const Self) Error!?PageId {
            return self.state.first;
        }

        pub fn setFirst(self: *Self, first: ?PageId) Error!void {
            self.state.first = first;
        }

        pub fn getLast(self: *const Self) Error!?PageId {
            return self.state.last;
        }

        pub fn setLast(self: *Self, last: ?PageId) Error!void {
            self.state.last = last;
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.cache_ptr.free(page_id);
        }
    };
}
