const std = @import("std");
const interfaces = @import("fullaz").contracts.interfaces;
const page_cache_contract = @import("fullaz").contracts.page_cache;

/// Provides a direct, pinned view of one component-owned durable state struct.
pub fn StateManager(comptime BackendT: type, comptime StateT: type) type {
    interfaces.requiresTypeDeclaration(BackendT, "PageId");
    interfaces.requiresTypeDeclaration(BackendT, "CacheType");
    const PageIdT = BackendT.PageId;
    const CacheT = BackendT.CacheType;
    comptime page_cache_contract.requiresTransactionalPageCache(CacheT);
    if (PageIdT != CacheT.Pid) {
        @compileError("Pages state manager backend PageId must match CacheType.Pid");
    }
    if (@typeInfo(StateT) != .@"struct" or @typeInfo(StateT).@"struct".layout != .@"extern") {
        @compileError("Pages state manager State must be an extern struct");
    }
    if (@alignOf(StateT) != 1 or @sizeOf(StateT) == 0) {
        @compileError("Pages state manager State must be non-empty and byte-aligned");
    }
    interfaces.requiresFnSignature(BackendT, "cache", fn (*BackendT) *CacheT);
    interfaces.requiresFnSignature(CacheT, "free", fn (*CacheT, PageIdT) CacheT.Error!void);

    return struct {
        const Self = @This();

        pub const PageId = PageIdT;
        pub const Error = CacheT.Error;
        pub const StateLeaseType = struct {
            const LeaseSelf = @This();

            pub const Error = CacheT.Error;

            state: *StateT,

            pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                return std.mem.asBytes(@as(*const StateT, self.state));
            }

            pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                return std.mem.asBytes(self.state);
            }

            pub fn finish(_: *LeaseSelf) void {}

            pub fn deinit(_: *LeaseSelf) void {}
        };

        cache_ptr: *CacheT,
        state_ptr: *StateT,

        pub fn init(backend: *BackendT, state_ptr: *StateT) Self {
            return .{
                .cache_ptr = backend.cache(),
                .state_ptr = state_ptr,
            };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .state = self.state_ptr };
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.cache_ptr.free(page_id);
        }
    };
}
