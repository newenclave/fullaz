const std = @import("std");
const errors = @import("../../../../../core/errors.zig");
const storage_manager = @import("../../../../../core/storage_manager.zig");
const storage_manager_contract = @import("../../../../../contracts/storage_manager.zig");
const assertLocationAccessor = @import("../../../location_accessor.zig").assertAccessor;
const fsm_interfaces = @import("../../interfaces.zig");
const view_mod = @import("view.zig");
const state_mod = @import("state.zig");
const page_chain = @import("../../../../page_chain/page_chain.zig");
const scanner = @import("scanner.zig");

pub const Settings = struct {
    page_kind: u16 = 1,
};

pub fn Paged(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizePolicyT: type,
    comptime LocationAccessorT: type,
) type {
    @setEvalBranchQuota(100_000);
    comptime assertLocationAccessor(LocationAccessorT);
    comptime fsm_interfaces.assertSizePolicy(SizePolicyT);

    const CachePageId = PageCacheT.Pid;
    comptime storage_manager_contract.assertPagedStorageManager(StorageManagerT, CachePageId);
    const PageHandle = PageCacheT.Handle;
    const SizeClassT = SizePolicyT.SizeClass;
    const FsmState = state_mod.State(CachePageId, SizePolicyT, .little);
    const FsmStateView = storage_manager.StateAccessor(StorageManagerT.StateLeaseType, FsmState);
    const ClassState = page_chain.State(CachePageId, void, .little);
    const maximum_class_count = SizePolicyT.maximum_class_count;

    const View = view_mod.View(CachePageId, u16, SizeClassT, .little, false).SlabPageView;
    const ConstView = view_mod.View(CachePageId, u16, SizeClassT, .little, true).SlabPageView;

    const ClassTypes = struct {
        fn Manager(comptime class_index: usize) type {
            return storage_manager.PagedByteRegionStorageManager(
                StorageManagerT,
                @sizeOf(FsmState),
                @offsetOf(FsmState, "classes") + class_index * @sizeOf(ClassState),
                @sizeOf(ClassState),
            );
        }

        fn Chain(comptime class_index: usize) type {
            return page_chain.BidirectionalHandleImpl(
                PageCacheT,
                Manager(class_index),
                void,
                void,
                View.SubheaderType,
                .little,
            );
        }
    };

    const RepresentativeChain = ClassTypes.Chain(0);

    return struct {
        const Self = @This();

        pub const State = FsmState;
        pub const Pid = CachePageId;
        pub const Size = u16;
        pub const Error = RepresentativeChain.Error ||
            LocationAccessorT.Error ||
            FsmStateView.Error ||
            View.Error ||
            errors.PageError ||
            error{BadData};

        cache: *PageCacheT,
        sm: *StorageManagerT,
        policy: SizePolicyT,
        settings: Settings,

        pub fn init(
            cache: *PageCacheT,
            sm: *StorageManagerT,
            policy: SizePolicyT,
            settings: Settings,
        ) Self {
            return .{
                .cache = cache,
                .sm = sm,
                .policy = policy,
                .settings = settings,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn scanSlabRefs(
            self: *const Self,
            page_id: Pid,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const slab = ConstView.init(page);
            try slab.validateTyped();
            return scanner.scanRefs(
                Pid,
                u16,
                SizeClassT,
                .little,
                page_id,
                page,
                self.settings.page_kind,
                slab.sizeClass(),
                visitor,
            );
        }

        pub fn find(self: *Self, size: Size) Error!?Pid {
            @setEvalBranchQuota(100_000);
            const first_class = self.policy.getSizeClass(size);
            const class_count = try self.classCount();
            if (@as(usize, first_class) >= class_count) {
                return Error.BadData;
            }

            var class_index: usize = first_class;
            while (class_index < class_count) : (class_index += 1) {
                inline for (0..maximum_class_count) |candidate| {
                    if (class_index == candidate) {
                        if (try self.findInClass(candidate, size)) |page_id| {
                            return page_id;
                        }
                    }
                }
            }
            return null;
        }

        pub fn add(self: *Self, pid: Pid, free: Size) Error!void {
            @setEvalBranchQuota(100_000);
            const class = self.policy.getSizeClass(free);
            try self.validateClass(class);
            inline for (0..maximum_class_count) |candidate| {
                if (@as(usize, class) == candidate) {
                    return self.addToClass(candidate, pid, free);
                }
            }
            unreachable;
        }

        pub fn update(self: *Self, pid: Pid, free: Size) Error!void {
            try self.remove(pid);
            try self.add(pid, free);
        }

        pub fn remove(self: *Self, pid: Pid) Error!void {
            @setEvalBranchQuota(100_000);
            const location = (try self.readLocation(pid)) orelse return Error.BadData;
            var ph = try self.fetchSlab(location.page_id);
            var owns_page_handle = true;
            defer {
                if (owns_page_handle) {
                    ph.deinit();
                }
            }
            var slab = View.init(try ph.dataMut());
            const slot = (try slab.get(@intCast(location.slot_id))) orelse return Error.BadData;
            if (slot.pid != pid) {
                return Error.BadData;
            }
            const size_class = slab.sizeClass();
            try self.validateClass(size_class);
            if (!try self.classContains(size_class, location.page_id)) {
                return Error.BadData;
            }
            try slab.remove(slot.slot_id);
            if (!try slab.isEmpty()) {
                return;
            }

            inline for (0..maximum_class_count) |candidate| {
                if (@as(usize, size_class) == candidate) {
                    const Manager = ClassTypes.Manager(candidate);
                    const Chain = ClassTypes.Chain(candidate);
                    var manager = Manager.init(self.sm);
                    var chain = try Chain.init(self.cache, &manager, .{
                        .chunk_page_kind = self.settings.page_kind,
                    });
                    defer chain.deinit();

                    var chunk = Chain.Chunk.init(ph);
                    owns_page_handle = false;
                    chain.evictChunk(&chunk) catch |err| {
                        chunk.deinit();
                        return err;
                    };
                    try chain.destroyChunk(chunk);
                    return;
                }
            }
            unreachable;
        }

        fn findInClass(self: *Self, comptime class_index: usize, size: Size) Error!?Pid {
            const Manager = ClassTypes.Manager(class_index);
            const Chain = ClassTypes.Chain(class_index);
            const class: SizeClassT = @intCast(class_index);
            var manager = Manager.init(self.sm);
            var chain = try Chain.init(self.cache, &manager, .{
                .chunk_page_kind = self.settings.page_kind,
            });
            defer chain.deinit();
            var itr = try chain.iterator();
            defer itr.deinit();

            var steps: usize = 0;
            var expected_prev: ?Pid = null;
            while ((try itr.get()) != null) {
                if (steps >= self.cache.pageCount()) {
                    return Error.BadData;
                }
                steps += 1;
                const chunk = itr.chunkPtr().?;
                const slab = ConstView.init(try chunk.page());
                try validatePreviousLink(&slab, expected_prev);
                if (slab.sizeClass() != class) {
                    return Error.BadData;
                }
                if (try slab.findBySize(size)) |slot| {
                    return slot.pid;
                }
                expected_prev = try chunk.id();
                try itr.next();
            }
            return null;
        }

        fn addToClass(
            self: *Self,
            comptime class_index: usize,
            pid: Pid,
            free: Size,
        ) Error!void {
            const Manager = ClassTypes.Manager(class_index);
            const Chain = ClassTypes.Chain(class_index);
            const class: SizeClassT = @intCast(class_index);
            var manager = Manager.init(self.sm);
            var chain = try Chain.init(self.cache, &manager, .{
                .chunk_page_kind = self.settings.page_kind,
            });
            defer chain.deinit();
            var itr = try chain.iterator();
            defer itr.deinit();

            var steps: usize = 0;
            var expected_prev: ?Pid = null;
            while ((try itr.get()) != null) {
                if (steps >= self.cache.pageCount()) {
                    return Error.BadData;
                }
                steps += 1;
                const chunk = itr.chunkPtr().?;
                const read_view = ConstView.init(try chunk.page());
                try validatePreviousLink(&read_view, expected_prev);
                if (read_view.sizeClass() != class) {
                    return Error.BadData;
                }
                if (!try read_view.isFull()) {
                    var writable = (try itr.cloneChunk()).?;
                    defer writable.deinit();
                    var slab = View.init(try writable.pageMut());
                    const slot = try slab.insert(pid, free);
                    try self.writeLocation(pid, .{
                        .page_id = try writable.id(),
                        .slot_id = @intCast(slot.slot_id),
                    });
                    return;
                }
                expected_prev = try chunk.id();
                try itr.next();
            }

            var created = try chain.createChunk();
            errdefer created.deinit();
            var slab = View.init(try created.pageMut());
            try slab.formatPayload(class);
            const slot = try slab.insert(pid, free);
            const slab_page_id = try created.id();
            try chain.insertFirst(&created);
            try self.writeLocation(pid, .{
                .page_id = slab_page_id,
                .slot_id = @intCast(slot.slot_id),
            });
            created.deinit();
        }

        fn fetchSlab(self: *Self, pid: CachePageId) Error!PageHandle {
            var ph = try self.cache.fetch(pid);
            errdefer ph.deinit();
            const slab = ConstView.init(try ph.data());
            try slab.validateTyped();
            if (slab.pageHeader().kind.get() != self.settings.page_kind) {
                return Error.InvalidId;
            }
            return ph;
        }

        fn classCount(self: *const Self) Error!usize {
            const count = self.policy.count();
            if (count == 0 or count > maximum_class_count) {
                return Error.BadData;
            }

            var lease = try self.sm.state();
            defer lease.deinit();
            const state = try FsmStateView.view(&lease);
            for (state.classes[count..]) |unused| {
                if (!unused.first.isMax()) {
                    return Error.BadData;
                }
            }
            return count;
        }

        fn validateClass(self: *const Self, class: SizeClassT) Error!void {
            if (@as(usize, class) >= try self.classCount()) {
                return Error.BadData;
            }
        }

        fn classContains(self: *Self, class: SizeClassT, page_id: Pid) Error!bool {
            @setEvalBranchQuota(100_000);
            inline for (0..maximum_class_count) |candidate| {
                if (@as(usize, class) == candidate) {
                    return self.classContainsAt(candidate, page_id);
                }
            }
            unreachable;
        }

        fn classContainsAt(
            self: *Self,
            comptime class_index: usize,
            page_id: Pid,
        ) Error!bool {
            const Manager = ClassTypes.Manager(class_index);
            const Chain = ClassTypes.Chain(class_index);
            const class: SizeClassT = @intCast(class_index);
            var manager = Manager.init(self.sm);
            var chain = try Chain.init(self.cache, &manager, .{
                .chunk_page_kind = self.settings.page_kind,
            });
            defer chain.deinit();
            var itr = try chain.iterator();
            defer itr.deinit();

            var steps: usize = 0;
            var expected_prev: ?Pid = null;
            while (try itr.get()) |entry| {
                if (steps >= self.cache.pageCount()) {
                    return Error.BadData;
                }
                steps += 1;
                const chunk = itr.chunkPtr().?;
                const slab = ConstView.init(try chunk.page());
                try validatePreviousLink(&slab, expected_prev);
                if (slab.sizeClass() != class) {
                    return Error.BadData;
                }
                if (entry.page_id == page_id) {
                    return true;
                }
                expected_prev = entry.page_id;
                try itr.next();
            }
            return false;
        }

        fn validatePreviousLink(slab: *const ConstView, expected_prev: ?Pid) Error!void {
            if (slab.getPrev() != expected_prev) {
                return Error.BadData;
            }
        }

        fn writeLocation(
            self: *Self,
            data_pid: CachePageId,
            location: LocationAccessorT.Location,
        ) Error!void {
            var ph = try self.cache.fetch(data_pid);
            defer ph.deinit();
            try LocationAccessorT.write(try ph.dataMut(), location);
        }

        fn readLocation(self: *Self, data_pid: CachePageId) Error!?LocationAccessorT.Location {
            var ph = try self.cache.fetch(data_pid);
            defer ph.deinit();
            return try LocationAccessorT.read(try ph.data());
        }
    };
}
