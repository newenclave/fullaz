const std = @import("std");
const errors = @import("../../../../../core/errors.zig");
const assertLocationAccessor = @import("../../../location_accessor.zig").assertAccessor;
const view_mod = @import("view.zig");
const page_chain = @import("../../../../page_chain/page_chain.zig");

pub const Settings = struct {
    page_kind: u16 = 1,
};

pub fn Paged(
    comptime PageCacheType: type,
    comptime SlabStorageManagerT: type,
    comptime SizePolicyT: type,
    comptime LocationAccessorT: type,
) type {
    comptime assertLocationAccessor(LocationAccessorT);

    const PidT = PageCacheType.UnderlyingDevice.BlockId;
    const PageHandle = PageCacheType.Handle;
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
            PageCacheType,
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

        cache: *PageCacheType,
        sm: *SlabStorageManagerT,
        policy: SizePolicyT,
        settings: Settings,

        pub fn init(cache: *PageCacheType, sm: *SlabStorageManagerT, policy: SizePolicyT, settings: Settings) Self {
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
            const c0 = try self.policy.getSizeClass(size);
            const n = self.policy.count();
            var c: SizeClassT = c0;
            while (c < n) : (c += 1) {
                var manager = self.initClassChainManager(c);
                var chain = try self.initClassChain(&manager);
                defer chain.deinit();
                var itr = try chain.iterator();
                defer itr.deinit();

                while ((try itr.get()) != null) {
                    var slab = itr.chunkPtr().?;
                    const cv = ConstView.init(try slab.getPage());
                    if (cv.sizeClass() != c) {
                        return Error.BadData;
                    }
                    if (try cv.findBySize(size)) |si| {
                        return si.pid;
                    }
                    try itr.next();
                }
            }
            return null;
        }

        pub fn add(self: *Self, pid: Pid, free: Size) Error!void {
            const c = try self.policy.getSizeClass(free);
            var slab = try self.slabWithRoom(c);
            defer slab.chunk.deinit();
            var v = View.init(try slab.chunk.getPageMut());
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
            defer ph.deinit();
            var v = View.init(try ph.getDataMut());
            const slot = (try v.get(@intCast(location.slot_id))) orelse return Error.BadData;
            if (slot.pid != pid) {
                return Error.BadData;
            }
            try v.remove(slot.slot_id);
            if (try v.isEmpty()) {
                try self.unlinkAndDestroy(&v, location.page_id);
            }
        }

        // --- helpers ---
        const SlabRef = struct {
            chunk: PageChainHandle.Chunk,
        };

        fn fetchSlab(self: *Self, pid: PidT) Error!PageHandle {
            var ph = try self.cache.fetch(pid);
            errdefer ph.deinit();
            const cv = ConstView.init(try ph.getData());
            if (cv.pageHeader().kind.get() != self.settings.page_kind) {
                return Error.InvalidId;
            }
            return ph;
        }

        fn createSlab(chain: *PageChainHandle, c: SizeClassT) Error!SlabRef {
            var chunk = try chain.createChunk();
            errdefer chunk.deinit();
            var v = View.init(try chunk.getPageMut());
            try v.formatPayload(c);
            return .{ .chunk = chunk };
        }

        fn slabWithRoom(self: *Self, c: SizeClassT) Error!SlabRef {
            var manager = self.initClassChainManager(c);
            var chain = try self.initClassChain(&manager);
            defer chain.deinit();
            var itr = try chain.iterator();
            defer itr.deinit();

            while ((try itr.get()) != null) {
                const slab = itr.chunkPtr().?;
                const cv = ConstView.init(try slab.getPage());
                if (cv.sizeClass() != c) {
                    return Error.BadData;
                }
                if (!try cv.isFull()) {
                    return .{ .chunk = (try itr.cloneChunk()).? };
                }
                try itr.next();
            }

            var created = try createSlab(&chain, c);
            errdefer created.chunk.deinit();
            try chain.insertFirst(&created.chunk);
            return created;
        }

        fn unlinkAndDestroy(self: *Self, v: *View, slab_pid: PidT) Error!void {
            const c = v.sizeClass();
            const prev = v.getPrev();
            const next = v.getNext();
            if (prev) |p| {
                var pph = try self.fetchSlab(p);
                defer pph.deinit();
                var pv = View.init(try pph.getDataMut());
                try pv.setNext(next);
            }
            if (next) |nx| {
                var nph = try self.fetchSlab(nx);
                defer nph.deinit();
                var nv = View.init(try nph.getDataMut());
                try nv.setPrev(prev);
            }
            if (try self.sm.getSizeClassRoot(c)) |root| {
                if (root == slab_pid) {
                    try self.sm.setSizeClassRoot(c, next);
                }
            }
            try self.sm.destroyPage(slab_pid);
        }

        fn writeLocation(self: *Self, data_pid: PidT, location: LocationAccessorT.Location) Error!void {
            var ph = try self.cache.fetch(data_pid);
            defer ph.deinit();
            try LocationAccessorT.write(try ph.getDataMut(), location);
        }

        fn readLocation(self: *Self, data_pid: PidT) Error!?LocationAccessorT.Location {
            var ph = try self.cache.fetch(data_pid);
            defer ph.deinit();
            return try LocationAccessorT.read(try ph.getData());
        }
    };
}
