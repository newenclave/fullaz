pub fn InPlaceWritePolicy(comptime ContextT: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{};

        pub const WriteBatch = struct {
            pub fn commit(_: *@This()) void {}

            pub fn discard(_: *@This()) void {}
        };

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn begin(
            _: *Self,
            _: ContextT.CacheRefs,
            _: u64,
        ) Error!WriteBatch {
            return .{};
        }

        pub fn prepareCreate(
            _: *Self,
            _: ContextT.CacheRefs,
        ) Error!void {}

        pub fn created(
            _: *Self,
            _: ContextT.HandleTarget,
        ) void {}

        pub fn prepareHandleWrite(
            _: *Self,
            _: ContextT.HandleTarget,
        ) Error!void {}

        pub fn prepareLayoutWrite(
            _: *Self,
            _: ContextT.LayoutTarget,
        ) Error!void {}
    };
}

pub fn CopyOnWritePolicy(comptime ContextT: type) type {
    const InnerCacheT = ContextT.InnerCacheType;
    const VirtualPageMapT = ContextT.VirtualPageMapType;
    const PidPolicyT = InnerCacheT.PidPolicyType;

    comptime page_cache_contract.requiresForkablePageCache(InnerCacheT);

    return struct {
        const Self = @This();

        pub const Error = InnerCacheT.Error || VirtualPageMapT.Error;

        pub const WriteBatch = struct {
            pub fn commit(_: *@This()) void {}

            pub fn discard(_: *@This()) void {}
        };

        context: PidPolicyT.RemapContextType,

        pub fn init(context: PidPolicyT.RemapContextType) Self {
            return .{ .context = context };
        }

        pub fn deinit(_: *Self) void {}

        pub fn begin(
            _: *Self,
            _: ContextT.CacheRefs,
            _: u64,
        ) Error!WriteBatch {
            return .{};
        }

        pub fn prepareCreate(
            _: *Self,
            _: ContextT.CacheRefs,
        ) Error!void {}

        pub fn created(
            _: *Self,
            _: ContextT.HandleTarget,
        ) void {}

        pub fn prepareHandleWrite(
            self: *Self,
            target: ContextT.HandleTarget,
        ) Error!void {
            return self.prepareWrite(target.refs, target.virtual_page_id, target.backing_page_id);
        }

        pub fn prepareLayoutWrite(
            self: *Self,
            target: ContextT.LayoutTarget,
        ) Error!void {
            return self.prepareWrite(target.refs, target.virtual_page_id, target.backing_page_id);
        }

        fn prepareWrite(
            self: *Self,
            refs: ContextT.CacheRefs,
            virtual_page_id: ContextT.VirtualPageIdType,
            backing_page_id: ContextT.PhysicalPageIdType,
        ) Error!void {
            if (try refs.vpm.get(virtual_page_id) != backing_page_id) {
                return error.InconsistentMapping;
            }

            var fork = (try refs.inner.prepareBackingFork(
                backing_page_id,
                self.context,
            )) orelse return;
            errdefer refs.inner.discardBackingFork(&fork);

            refs.vpm.remap(virtual_page_id, fork.targetPid()) catch |err| {
                refs.inner.markTransactionFailed();
                return err;
            };
            refs.inner.commitBackingFork(&fork);
        }
    };
}
const page_cache_contract = @import("../../contracts/page_cache.zig");
