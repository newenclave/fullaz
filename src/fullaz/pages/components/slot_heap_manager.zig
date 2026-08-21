const interfaces = @import("../../contracts/interfaces.zig");
const page_cache_contract = @import("../../contracts/page_cache.zig");

/// Stores all SlotHeap and slab-FSM metadata for one pages component runtime.
pub fn SlotHeapManager(
    comptime BackendT: type,
    comptime LocationT: type,
    comptime maximum_level: usize,
    comptime size_class_count: usize,
) type {
    interfaces.requiresTypeDeclaration(BackendT, "PageId");
    interfaces.requiresTypeDeclaration(BackendT, "CacheType");
    const PageIdT = BackendT.PageId;
    const CacheT = BackendT.CacheType;
    comptime page_cache_contract.requiresTransactionalPageCache(CacheT);
    if (PageIdT != CacheT.Pid) {
        @compileError("SlotHeap manager backend PageId must match CacheType.Pid");
    }
    if (maximum_level == 0) {
        @compileError("SlotHeap manager maximum_level must be greater than zero");
    }
    if (size_class_count == 0) {
        @compileError("SlotHeap manager size_class_count must be greater than zero");
    }
    interfaces.requiresFnSignature(BackendT, "cache", fn (*BackendT) *CacheT);
    interfaces.requiresFnSignature(CacheT, "free", fn (*CacheT, PageIdT) CacheT.Error!void);

    return struct {
        const Self = @This();

        pub const PageId = BackendT.PageId;
        pub const CountType = u64;
        pub const Error = CacheT.Error || error{
            InvalidSizeClass,
            MaxDepth,
        };

        pub const State = struct {
            root: ?PageId = null,
            cached_top: ?LocationT = null,
            entries_count: CountType = 0,
            available_inode_heads: [maximum_level + 1]?PageId = .{null} ** (maximum_level + 1),
            fsm_class_roots: [size_class_count]?PageId = .{null} ** size_class_count,
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

        pub fn getRoot(self: *const Self) ?PageId {
            return self.state.root;
        }

        pub fn setRoot(self: *Self, root: ?PageId) Error!void {
            self.state.root = root;
        }

        pub fn getCachedTop(self: *const Self) ?LocationT {
            return self.state.cached_top;
        }

        pub fn setCachedTop(self: *Self, top: ?LocationT) Error!void {
            self.state.cached_top = top;
        }

        pub fn getEntriesCount(self: *const Self) Error!CountType {
            return self.state.entries_count;
        }

        pub fn setEntriesCount(self: *Self, count: CountType) Error!void {
            self.state.entries_count = count;
        }

        pub fn getAvailableInode(self: *const Self, level: usize) Error!?PageId {
            if (level == 0 or level > maximum_level) {
                return Error.MaxDepth;
            }
            return self.state.available_inode_heads[level];
        }

        pub fn setAvailableInode(self: *Self, level: usize, inode: ?PageId) Error!void {
            if (level == 0 or level > maximum_level) {
                return Error.MaxDepth;
            }
            self.state.available_inode_heads[level] = inode;
        }

        pub fn getSizeClassRoot(self: *const Self, class: u16) Error!?PageId {
            const index: usize = class;
            if (index >= size_class_count) {
                return Error.InvalidSizeClass;
            }
            return self.state.fsm_class_roots[index];
        }

        pub fn setSizeClassRoot(self: *Self, class: u16, root: ?PageId) Error!void {
            const index: usize = class;
            if (index >= size_class_count) {
                return Error.InvalidSizeClass;
            }
            self.state.fsm_class_roots[index] = root;
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.cache_ptr.free(page_id);
        }
    };
}
