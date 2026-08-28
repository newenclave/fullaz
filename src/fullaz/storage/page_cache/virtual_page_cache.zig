const std = @import("std");
const page_cache_contract = @import("../../contracts/page_cache.zig");
const virtual_page_map_contract = @import("../../contracts/virtual_page_map.zig");
const page_cache_interfaces = @import("interfaces.zig");
const write_policies = @import("write_policy.zig");

pub fn VirtualPageCache(
    comptime InnerCacheT: type,
    comptime VirtualPageMapT: type,
) type {
    return VirtualPageCacheImpl(
        InnerCacheT,
        VirtualPageMapT,
        write_policies.InPlaceWritePolicy,
    );
}

pub fn VirtualPageCacheImpl(
    comptime InnerCacheT: type,
    comptime VirtualPageMapT: type,
    comptime WritePolicyFactoryT: fn (type) type,
) type {
    comptime page_cache_contract.requiresAppendOnlyDensePageCache(InnerCacheT);
    comptime virtual_page_map_contract.assertVirtualPageMap(VirtualPageMapT);
    comptime {
        if (InnerCacheT.Pid != VirtualPageMapT.PhysicalPageIdType) {
            @compileError("VirtualPageCache VPM physical page ID must match inner cache Pid");
        }
    }

    const InnerHandle = InnerCacheT.Handle;
    const VirtualPageId = VirtualPageMapT.VirtualPageIdType;

    const PolicyContext = struct {
        pub const InnerCacheType = InnerCacheT;
        pub const VirtualPageMapType = VirtualPageMapT;
        pub const InnerHandleType = InnerHandle;
        pub const InnerLayoutLockType = InnerHandle.LayoutLock;
        pub const PhysicalPageIdType = InnerCacheT.Pid;
        pub const VirtualPageIdType = VirtualPageId;

        pub const CacheRefs = struct {
            inner: *InnerCacheT,
            vpm: *VirtualPageMapT,
        };

        pub const HandleTarget = struct {
            refs: CacheRefs,
            virtual_page_id: VirtualPageId,
            backing_page_id: PhysicalPageIdType,
            inner: *InnerHandle,
        };

        pub const LayoutTarget = struct {
            refs: CacheRefs,
            virtual_page_id: VirtualPageId,
            backing_page_id: PhysicalPageIdType,
            inner: *InnerHandle.LayoutLock,
        };
    };

    const WritePolicy = WritePolicyFactoryT(PolicyContext);
    comptime page_cache_interfaces.assertVirtualWritePolicy(WritePolicy, PolicyContext);

    return struct {
        const Self = @This();

        const TransactionPhase = enum {
            idle,
            active,
            discarding,
        };

        const VirtualHandle = struct {
            const HandleSelf = @This();

            const Identity = union(enum) {
                persistent: VirtualPageId,
                temporary,
            };

            const HandleError = InnerHandle.Error || WritePolicy.Error || error{InvalidId};

            pub const Error = HandleError;
            pub const Pid = VirtualPageId;

            pub const LayoutLock = struct {
                const LayoutLockSelf = @This();

                inner: InnerHandle.LayoutLock,
                identity: Identity,
                owner: *Self,

                pub fn deinit(self: *LayoutLockSelf) void {
                    self.inner.deinit();
                }

                pub fn pid(self: *const LayoutLockSelf) HandleError!VirtualPageId {
                    try self.owner.ensureUsable();
                    return switch (self.identity) {
                        .persistent => |virtual_page_id| virtual_page_id,
                        .temporary => error.InvalidId,
                    };
                }

                pub fn data(self: *const LayoutLockSelf) HandleError![]const u8 {
                    try self.owner.ensureUsable();
                    return self.inner.data();
                }

                pub fn dataMut(self: *LayoutLockSelf) HandleError![]u8 {
                    try self.owner.ensureUsable();
                    switch (self.identity) {
                        .persistent => |virtual_page_id| {
                            const backing_page_id = try self.inner.pid();
                            try self.owner.write_policy.prepareLayoutWrite(.{
                                .refs = self.owner.refs(),
                                .virtual_page_id = virtual_page_id,
                                .backing_page_id = backing_page_id,
                                .inner = &self.inner,
                            });
                        },
                        .temporary => {},
                    }
                    return self.inner.dataMut();
                }
            };

            inner: InnerHandle,
            identity: Identity,
            owner: *Self,

            pub fn deinit(self: *HandleSelf) void {
                self.inner.deinit();
            }

            pub fn markDirty(self: *HandleSelf) HandleError!void {
                try self.owner.ensureUsable();
                try self.prepareWrite();
                return self.inner.markDirty();
            }

            pub fn pid(self: *const HandleSelf) HandleError!VirtualPageId {
                try self.owner.ensureUsable();
                return switch (self.identity) {
                    .persistent => |virtual_page_id| blk: {
                        _ = try self.inner.pid();
                        break :blk virtual_page_id;
                    },
                    .temporary => error.InvalidId,
                };
            }

            pub fn data(self: *const HandleSelf) HandleError![]const u8 {
                try self.owner.ensureUsable();
                return self.inner.data();
            }

            pub fn dataMut(self: *HandleSelf) HandleError![]u8 {
                try self.owner.ensureUsable();
                try self.prepareWrite();
                return self.inner.dataMut();
            }

            pub fn isLayoutLocked(self: *const HandleSelf) HandleError!bool {
                try self.owner.ensureUsable();
                return self.inner.isLayoutLocked();
            }

            pub fn lockLayout(self: *const HandleSelf) HandleError!LayoutLock {
                try self.owner.ensureUsable();
                return .{
                    .inner = try self.inner.lockLayout(),
                    .identity = self.identity,
                    .owner = self.owner,
                };
            }

            pub fn clone(self: *const HandleSelf) HandleError!HandleSelf {
                try self.owner.ensureUsable();
                return .{
                    .inner = try self.inner.clone(),
                    .identity = self.identity,
                    .owner = self.owner,
                };
            }

            pub fn take(self: *HandleSelf) HandleError!HandleSelf {
                try self.owner.ensureUsable();
                return .{
                    .inner = try self.inner.take(),
                    .identity = self.identity,
                    .owner = self.owner,
                };
            }

            fn prepareWrite(self: *HandleSelf) HandleError!void {
                switch (self.identity) {
                    .persistent => |virtual_page_id| {
                        const backing_page_id = try self.inner.pid();
                        try self.owner.write_policy.prepareHandleWrite(.{
                            .refs = self.owner.refs(),
                            .virtual_page_id = virtual_page_id,
                            .backing_page_id = backing_page_id,
                            .inner = &self.inner,
                        });
                    },
                    .temporary => {},
                }
            }
        };

        pub const Handle = VirtualHandle;
        pub const Pid = VirtualPageId;
        pub const Error = InnerCacheT.Error || VirtualPageMapT.Error || WritePolicy.Error;
        pub const append_only_dense_page_ids = VirtualPageMapT.append_only_dense_virtual_page_ids;

        pub const WriteBatch = struct {
            const Phase = enum {
                active,
                policy_restored,
                state_restored,
                inactive,
            };

            cache: *Self,
            inner: InnerCacheT.WriteBatch,
            mapping: VirtualPageMapT.WriteBatch,
            policy: WritePolicy.WriteBatch,
            phase: Phase = .active,

            pub fn commit(self: *WriteBatch) Error!void {
                if (self.phase != .active) {
                    return error.TransactionInactive;
                }
                try self.inner.commit();
                self.mapping.commit();
                self.policy.commit();
                self.phase = .inactive;
                self.cache.transaction_phase = .idle;
            }

            pub fn discard(self: *WriteBatch) Error!void {
                switch (self.phase) {
                    .active => {
                        self.policy.discard();
                        self.phase = .policy_restored;
                    },
                    .policy_restored => {},
                    .state_restored => {},
                    .inactive => return error.TransactionInactive,
                }
                if (self.phase == .policy_restored) {
                    self.mapping.discard();
                    self.phase = .state_restored;
                }
                self.cache.transaction_phase = .discarding;
                try self.inner.discard();
                self.phase = .inactive;
                self.cache.transaction_phase = .idle;
            }
        };

        inner: *InnerCacheT,
        vpm: *VirtualPageMapT,
        write_policy: WritePolicy,
        transaction_phase: TransactionPhase = .idle,

        pub fn init(
            inner: *InnerCacheT,
            vpm: *VirtualPageMapT,
            write_policy: WritePolicy,
        ) Self {
            return .{
                .inner = inner,
                .vpm = vpm,
                .write_policy = write_policy,
            };
        }

        pub fn deinit(self: *Self) void {
            self.write_policy.deinit();
            self.* = undefined;
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            try self.ensureUsable();
            return .{
                .inner = try self.inner.getTemporaryPage(),
                .identity = .temporary,
                .owner = self,
            };
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            if (self.transaction_phase != .idle) {
                return error.BatchActive;
            }
            var inner = try self.inner.begin();
            errdefer inner.discard() catch {};
            const generation = self.inner.transactionGeneration() orelse return error.TransactionInactive;
            var mapping = try self.vpm.begin();
            errdefer mapping.discard();
            const policy = try self.write_policy.begin(self.refs(), generation);
            self.transaction_phase = .active;
            return .{
                .cache = self,
                .inner = inner,
                .mapping = mapping,
                .policy = policy,
            };
        }

        pub fn fetch(self: *Self, virtual_page_id: Pid) Error!Handle {
            try self.ensureUsable();
            const physical_page_id = try self.vpm.get(virtual_page_id);
            return .{
                .inner = try self.inner.fetch(physical_page_id),
                .identity = .{ .persistent = virtual_page_id },
                .owner = self,
            };
        }

        pub fn create(self: *Self) Error!Handle {
            try self.ensureUsable();
            try self.write_policy.prepareCreate(self.refs());
            try self.vpm.prepareSet();
            var inner_handle = try self.inner.create();
            errdefer inner_handle.deinit();
            const physical_page_id = try inner_handle.pid();
            const virtual_page_id = self.vpm.set(physical_page_id) catch |err| {
                self.inner.markTransactionFailed();
                return err;
            };
            self.write_policy.created(.{
                .refs = self.refs(),
                .virtual_page_id = virtual_page_id,
                .backing_page_id = physical_page_id,
                .inner = &inner_handle,
            });
            return .{
                .inner = inner_handle,
                .identity = .{ .persistent = virtual_page_id },
                .owner = self,
            };
        }

        pub fn flush(self: *Self, virtual_page_id: Pid) Error!void {
            try self.ensureUsable();
            return self.inner.flush(try self.vpm.get(virtual_page_id));
        }

        pub fn flushAll(self: *Self) Error!void {
            try self.ensureUsable();
            return self.inner.flushAll();
        }

        pub fn pageSize(self: *const Self) usize {
            return self.inner.pageSize();
        }

        pub fn pageCount(self: *const Self) usize {
            return self.vpm.pageCount();
        }

        pub fn isPinned(self: *const Self, virtual_page_id: Pid) Error!bool {
            try self.ensureUsable();
            return self.inner.isPinned(try self.vpm.get(virtual_page_id));
        }

        pub fn transactionActive(self: *const Self) bool {
            return self.transaction_phase != .idle;
        }

        pub fn transactionGeneration(self: *const Self) ?u64 {
            return self.inner.transactionGeneration();
        }

        pub fn markTransactionFailed(self: *Self) void {
            self.inner.markTransactionFailed();
        }

        fn refs(self: *Self) PolicyContext.CacheRefs {
            return .{
                .inner = self.inner,
                .vpm = self.vpm,
            };
        }

        fn ensureUsable(self: *const Self) error{PageBusy}!void {
            if (self.transaction_phase == .discarding) {
                return error.PageBusy;
            }
        }

        comptime {
            page_cache_contract.requiresTransactionalPageCache(Self);
        }
    };
}
