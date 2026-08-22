const interfaces = @import("fullaz").contracts.interfaces;
const page_cache_contract = @import("fullaz").contracts.page_cache;

pub fn SingleRootManager(comptime BackendT: type) type {
    interfaces.requiresTypeDeclaration(BackendT, "PageId");
    interfaces.requiresTypeDeclaration(BackendT, "CacheType");
    const PageIdT = BackendT.PageId;
    const CacheT = BackendT.CacheType;
    comptime page_cache_contract.requiresTransactionalPageCache(CacheT);
    if (PageIdT != CacheT.Pid) {
        @compileError("Pages backend PageId must match CacheType.Pid");
    }
    interfaces.requiresFnSignature(BackendT, "cache", fn (*BackendT) *CacheT);
    interfaces.requiresFnSignature(CacheT, "free", fn (*CacheT, PageIdT) CacheT.Error!void);

    return struct {
        const Self = @This();

        pub const PageId = PageIdT;
        pub const Error = CacheT.Error;

        cache_ptr: *CacheT,
        root: ?PageId = null,

        pub fn init(backend: *BackendT) Self {
            return .{ .cache_ptr = backend.cache() };
        }

        pub fn getRoot(self: *const Self) ?PageId {
            return self.root;
        }

        pub fn setRoot(self: *Self, root: ?PageId) Error!void {
            self.root = root;
        }

        pub fn restoreRoot(self: *Self, root: ?PageId) void {
            self.root = root;
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.cache_ptr.free(page_id);
        }
    };
}
