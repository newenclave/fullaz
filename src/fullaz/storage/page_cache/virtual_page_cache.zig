const std = @import("std");
const page_cache_contract = @import("../../contracts/page_cache.zig");
const virtual_page_map_contract = @import("../../contracts/virtual_page_map.zig");

pub fn VirtualPageCache(
    comptime InnerCacheT: type,
    comptime VirtualPageMapT: type,
) type {
    comptime page_cache_contract.requiresAppendOnlyDensePageCache(InnerCacheT);
    comptime virtual_page_map_contract.assertVirtualPageMap(VirtualPageMapT);
    comptime {
        if (InnerCacheT.Pid != VirtualPageMapT.PhysicalPageIdType) {
            @compileError("VirtualPageCache VPM physical page ID must match inner cache Pid");
        }
    }

    return struct {
        const Self = @This();
        const InnerHandle = InnerCacheT.Handle;
        const VirtualPageId = VirtualPageMapT.VirtualPageIdType;

        const VirtualHandle = struct {
            const HandleSelf = @This();

            const Identity = union(enum) {
                persistent: VirtualPageId,
                temporary,
            };

            const HandleError = InnerHandle.Error || error{InvalidId};

            pub const Error = HandleError;
            pub const Pid = VirtualPageId;

            pub const LayoutLock = struct {
                const LayoutLockSelf = @This();

                inner: InnerHandle.LayoutLock,
                identity: Identity,

                pub fn deinit(self: *LayoutLockSelf) void {
                    self.inner.deinit();
                }

                pub fn pid(self: *const LayoutLockSelf) HandleError!VirtualPageId {
                    return switch (self.identity) {
                        .persistent => |virtual_page_id| virtual_page_id,
                        .temporary => error.InvalidId,
                    };
                }

                pub fn data(self: *const LayoutLockSelf) HandleError![]const u8 {
                    return self.inner.data();
                }

                pub fn dataMut(self: *const LayoutLockSelf) HandleError![]u8 {
                    return self.inner.dataMut();
                }
            };

            inner: InnerHandle,
            identity: Identity,

            pub fn deinit(self: *HandleSelf) void {
                self.inner.deinit();
            }

            pub fn markDirty(self: *HandleSelf) HandleError!void {
                return self.inner.markDirty();
            }

            pub fn pid(self: *const HandleSelf) HandleError!VirtualPageId {
                return switch (self.identity) {
                    .persistent => |virtual_page_id| blk: {
                        _ = try self.inner.pid();
                        break :blk virtual_page_id;
                    },
                    .temporary => error.InvalidId,
                };
            }

            pub fn data(self: *const HandleSelf) HandleError![]const u8 {
                return self.inner.data();
            }

            pub fn dataMut(self: *HandleSelf) HandleError![]u8 {
                return self.inner.dataMut();
            }

            pub fn isLayoutLocked(self: *const HandleSelf) HandleError!bool {
                return self.inner.isLayoutLocked();
            }

            pub fn lockLayout(self: *const HandleSelf) HandleError!LayoutLock {
                return .{
                    .inner = try self.inner.lockLayout(),
                    .identity = self.identity,
                };
            }

            pub fn clone(self: *const HandleSelf) HandleError!HandleSelf {
                return .{
                    .inner = try self.inner.clone(),
                    .identity = self.identity,
                };
            }

            pub fn take(self: *HandleSelf) HandleError!HandleSelf {
                return .{
                    .inner = try self.inner.take(),
                    .identity = self.identity,
                };
            }
        };

        pub const Handle = VirtualHandle;
        pub const Pid = VirtualPageId;
        pub const Error = InnerCacheT.Error || VirtualPageMapT.Error;
        pub const append_only_dense_page_ids = VirtualPageMapT.append_only_dense_virtual_page_ids;

        pub const WriteBatch = struct {
            const Phase = enum {
                active,
                state_restored,
                inactive,
            };

            inner: InnerCacheT.WriteBatch,
            mapping: VirtualPageMapT.WriteBatch,
            phase: Phase = .active,

            pub fn commit(self: *WriteBatch) Error!void {
                if (self.phase != .active) {
                    return error.TransactionInactive;
                }
                try self.inner.commit();
                self.mapping.commit();
                self.phase = .inactive;
            }

            pub fn discard(self: *WriteBatch) Error!void {
                switch (self.phase) {
                    .active => {
                        self.mapping.discard();
                        self.phase = .state_restored;
                    },
                    .state_restored => {},
                    .inactive => return error.TransactionInactive,
                }
                try self.inner.discard();
                self.phase = .inactive;
            }
        };

        inner: *InnerCacheT,
        vpm: *VirtualPageMapT,

        pub fn init(inner: *InnerCacheT, vpm: *VirtualPageMapT) Self {
            return .{
                .inner = inner,
                .vpm = vpm,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            return .{
                .inner = try self.inner.getTemporaryPage(),
                .identity = .temporary,
            };
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            var inner = try self.inner.begin();
            errdefer inner.discard() catch {};
            return .{
                .inner = inner,
                .mapping = try self.vpm.begin(),
            };
        }

        pub fn fetch(self: *Self, virtual_page_id: Pid) Error!Handle {
            const physical_page_id = try self.vpm.get(virtual_page_id);
            return .{
                .inner = try self.inner.fetch(physical_page_id),
                .identity = .{ .persistent = virtual_page_id },
            };
        }

        pub fn create(self: *Self) Error!Handle {
            try self.vpm.prepareSet();
            var inner_handle = try self.inner.create();
            errdefer inner_handle.deinit();
            const physical_page_id = try inner_handle.pid();
            const virtual_page_id = self.vpm.set(physical_page_id) catch |err| {
                self.inner.markTransactionFailed();
                return err;
            };
            return .{
                .inner = inner_handle,
                .identity = .{ .persistent = virtual_page_id },
            };
        }

        pub fn flush(self: *Self, virtual_page_id: Pid) Error!void {
            return self.inner.flush(try self.vpm.get(virtual_page_id));
        }

        pub fn flushAll(self: *Self) Error!void {
            return self.inner.flushAll();
        }

        pub fn pageSize(self: *const Self) usize {
            return self.inner.pageSize();
        }

        pub fn pageCount(self: *const Self) usize {
            return self.vpm.pageCount();
        }

        pub fn isPinned(self: *const Self, virtual_page_id: Pid) Error!bool {
            return self.inner.isPinned(try self.vpm.get(virtual_page_id));
        }

        pub fn transactionActive(self: *const Self) bool {
            return self.inner.transactionActive();
        }

        pub fn transactionGeneration(self: *const Self) ?u64 {
            return self.inner.transactionGeneration();
        }

        pub fn markTransactionFailed(self: *Self) void {
            self.inner.markTransactionFailed();
        }

        comptime {
            page_cache_contract.requiresTransactionalPageCache(Self);
        }
    };
}
