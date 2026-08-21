const std = @import("std");
const errors = @import("../../../../../core/errors.zig");
const assertLocationAccessor = @import("../../../location_accessor.zig").assertAccessor;
const fsm_interfaces = @import("../../interfaces.zig");
const view_mod = @import("view.zig");
const page_chain = @import("../../../../page_chain/page_chain.zig");

pub const Settings = struct {
    page_kind: u16 = 1,
};

pub fn Paged(
    comptime PageCacheT: type,
    comptime SlabStorageManagerT: type,
    comptime SizePolicyT: type,
    comptime LocationAccessorT: type,
) type {
    comptime assertLocationAccessor(LocationAccessorT);
    comptime fsm_interfaces.assertSizePolicy(SizePolicyT);

    const PidT = PageCacheT.UnderlyingDevice.BlockId;
    comptime fsm_interfaces.assertSlabStorageManager(SlabStorageManagerT, PidT);
    const PageHandle = PageCacheT.Handle;
    const SizeClassT = SizePolicyT.SizeClass;

    const View = view_mod.View(PidT, u16, SizeClassT, .little, false).SlabPageView;
    const ConstView = view_mod.View(PidT, u16, SizeClassT, .little, true).SlabPageView;

    const ClassChainManagerImpl = struct {
        const Self = @This();
        pub const Size = u0;
        pub const Error = SlabStorageManagerT.Error;

        sm: *SlabStorageManagerT,
        class: SizeClassT,

        pub fn getFirst(self: *Self) SlabStorageManagerT.Error!?PidT {
            return self.sm.getSizeClassRoot(self.class);
        }

        pub fn setFirst(self: *Self, pid: ?PidT) SlabStorageManagerT.Error!void {
            return self.sm.setSizeClassRoot(self.class, pid);
        }

        pub fn destroyPage(self: *Self, pid: PidT) SlabStorageManagerT.Error!void {
            return self.sm.destroyPage(pid);
        }
    };

    return struct {
        const Self = @This();

        const ClassChainManager = ClassChainManagerImpl;

        const PageChainHandle = page_chain.BidirectionalHandleImpl(
            PageCacheT,
            ClassChainManager,
            void,
            View.SubheaderType,
            .little,
        );

        pub const Pid = PidT;
        pub const Size = u16;
        pub const Error = PageChainHandle.Error ||
            LocationAccessorT.Error ||
            View.Error ||
            errors.PageError;

        cache: *PageCacheT,
        sm: *SlabStorageManagerT,
        policy: SizePolicyT,
        settings: Settings,

        pub fn init(cache: *PageCacheT, sm: *SlabStorageManagerT, policy: SizePolicyT, settings: Settings) Self {
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

        fn initClassChainManager(self: *Self, class: SizeClassT) ClassChainManager {
            return .{
                .sm = self.sm,
                .class = class,
            };
        }

        fn initClassChain(self: *Self, manager: *ClassChainManager) PageChainHandle.Error!PageChainHandle {
            return PageChainHandle.init(self.cache, manager, .{
                .chunk_page_kind = self.settings.page_kind,
            });
        }

        pub fn find(self: *Self, size: Size) Error!?Pid {
            const c0 = self.policy.getSizeClass(size);
            const class_count = try self.classCount();
            if (@as(usize, c0) >= class_count) {
                return Error.BadData;
            }

            var class_index: usize = c0;
            while (class_index < class_count) : (class_index += 1) {
                const c: SizeClassT = @intCast(class_index);
                var manager = self.initClassChainManager(c);
                var chain = try self.initClassChain(&manager);
                defer {
                    chain.deinit();
                }
                var itr = try chain.iterator();
                defer {
                    itr.deinit();
                }

                var steps: usize = 0;
                var expected_prev: ?Pid = null;
                while ((try itr.get()) != null) {
                    if (steps >= self.cache.pageCount()) {
                        return Error.BadData;
                    }
                    steps += 1;
                    var slab = itr.chunkPtr().?;
                    const cv = ConstView.init(try slab.page());
                    try validatePreviousLink(&cv, expected_prev);
                    if (cv.sizeClass() != c) {
                        return Error.BadData;
                    }
                    if (try cv.findBySize(size)) |si| {
                        return si.pid;
                    }
                    expected_prev = try slab.id();
                    try itr.next();
                }
            }
            return null;
        }

        pub fn add(self: *Self, pid: Pid, free: Size) Error!void {
            const c = self.policy.getSizeClass(free);
            try self.validateClass(c);
            var slab = try self.slabWithRoom(c);
            defer {
                slab.chunk.deinit();
            }
            var v = View.init(try slab.chunk.pageMut());
            const si = try v.insert(pid, free);
            try self.writeLocation(pid, .{
                .page_id = try slab.chunk.id(),
                .slot_id = @intCast(si.slot_id),
            });
        }

        pub fn update(self: *Self, pid: Pid, free: Size) Error!void {
            try self.remove(pid);
            try self.add(pid, free);
        }

        pub fn remove(self: *Self, pid: Pid) Error!void {
            const location = (try self.readLocation(pid)) orelse return Error.BadData;
            var ph = try self.fetchSlab(location.page_id);
            var owns_page_handle = true;
            defer {
                if (owns_page_handle) {
                    ph.deinit();
                }
            }
            var v = View.init(try ph.dataMut());
            const slot = (try v.get(@intCast(location.slot_id))) orelse return Error.BadData;
            if (slot.pid != pid) {
                return Error.BadData;
            }
            const size_class = v.sizeClass();
            try self.validateClass(size_class);
            if (!try self.classContains(size_class, location.page_id)) {
                return Error.BadData;
            }
            try v.remove(slot.slot_id);
            if (try v.isEmpty()) {
                var manager = self.initClassChainManager(size_class);
                var chain = try self.initClassChain(&manager);
                defer {
                    chain.deinit();
                }

                var chunk = PageChainHandle.Chunk.init(ph);
                owns_page_handle = false;
                chain.evictChunk(&chunk) catch |err| {
                    chunk.deinit();
                    return err;
                };
                try chain.destroyChunk(chunk);
            }
        }

        // --- helpers ---
        const SlabRef = struct {
            chunk: PageChainHandle.Chunk,
        };

        fn fetchSlab(self: *Self, pid: PidT) Error!PageHandle {
            var ph = try self.cache.fetch(pid);
            errdefer {
                ph.deinit();
            }
            const cv = ConstView.init(try ph.data());
            try cv.validateTyped();
            if (cv.pageHeader().kind.get() != self.settings.page_kind) {
                return Error.InvalidId;
            }
            return ph;
        }

        fn createSlab(chain: *PageChainHandle, c: SizeClassT) Error!SlabRef {
            var chunk = try chain.createChunk();
            errdefer {
                chunk.deinit();
            }
            var v = View.init(try chunk.pageMut());
            try v.formatPayload(c);
            return .{ .chunk = chunk };
        }

        fn slabWithRoom(self: *Self, c: SizeClassT) Error!SlabRef {
            try self.validateClass(c);
            var manager = self.initClassChainManager(c);
            var chain = try self.initClassChain(&manager);
            defer {
                chain.deinit();
            }
            var itr = try chain.iterator();
            defer {
                itr.deinit();
            }

            var steps: usize = 0;
            var expected_prev: ?Pid = null;
            while ((try itr.get()) != null) {
                if (steps >= self.cache.pageCount()) {
                    return Error.BadData;
                }
                steps += 1;
                const slab = itr.chunkPtr().?;
                const cv = ConstView.init(try slab.page());
                try validatePreviousLink(&cv, expected_prev);
                if (cv.sizeClass() != c) {
                    return Error.BadData;
                }
                if (!try cv.isFull()) {
                    return .{ .chunk = (try itr.cloneChunk()).? };
                }
                expected_prev = try slab.id();
                try itr.next();
            }

            var created = try createSlab(&chain, c);
            errdefer {
                created.chunk.deinit();
            }
            try chain.insertFirst(&created.chunk);
            return created;
        }

        fn classCount(self: *const Self) Error!usize {
            const count = self.policy.count();
            if (count == 0 or count > @as(usize, std.math.maxInt(SizeClassT)) + 1) {
                return Error.BadData;
            }
            return count;
        }

        fn validateClass(self: *const Self, class: SizeClassT) Error!void {
            if (@as(usize, class) >= try self.classCount()) {
                return Error.BadData;
            }
        }

        fn classContains(self: *Self, class: SizeClassT, page_id: Pid) Error!bool {
            var manager = self.initClassChainManager(class);
            var chain = try self.initClassChain(&manager);
            defer {
                chain.deinit();
            }
            var itr = try chain.iterator();
            defer {
                itr.deinit();
            }

            var steps: usize = 0;
            var expected_prev: ?Pid = null;
            while (try itr.get()) |entry| {
                if (steps >= self.cache.pageCount()) {
                    return Error.BadData;
                }
                steps += 1;
                const slab = itr.chunkPtr().?;
                const cv = ConstView.init(try slab.page());
                try validatePreviousLink(&cv, expected_prev);
                if (cv.sizeClass() != class) {
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

        fn writeLocation(self: *Self, data_pid: PidT, location: LocationAccessorT.Location) Error!void {
            var ph = try self.cache.fetch(data_pid);
            defer {
                ph.deinit();
            }
            try LocationAccessorT.write(try ph.dataMut(), location);
        }

        fn readLocation(self: *Self, data_pid: PidT) Error!?LocationAccessorT.Location {
            var ph = try self.cache.fetch(data_pid);
            defer {
                ph.deinit();
            }
            return try LocationAccessorT.read(try ph.data());
        }
    };
}
