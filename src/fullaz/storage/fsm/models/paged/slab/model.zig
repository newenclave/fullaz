const std = @import("std");
const errors = @import("../../../../../core/errors.zig");
const assertLocationAccessor = @import("../../../location_accessor.zig").assertAccessor;
const view_mod = @import("view.zig");

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

    return struct {
        const Self = @This();

        pub const Pid = PidT;
        pub const Size = u16;
        pub const Error = PageCacheType.Error ||
            SlabStorageManagerT.Error ||
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

        pub fn find(self: *Self, size: Size) Error!?Pid {
            const c0 = try self.policy.getSizeClass(size);
            const n = self.policy.count();
            var c: SizeClassT = c0;
            while (c < n) : (c += 1) {
                var cur: ?Pid = try self.sm.getSizeClassRoot(c);
                while (cur) |cur_pid| {
                    var ph = try self.fetchSlab(cur_pid);
                    defer ph.deinit();
                    const cv = ConstView.init(try ph.getData());
                    if (try cv.findBySize(size)) |si| {
                        return si.pid;
                    }
                    cur = cv.getNext();
                }
            }
            return null;
        }

        pub fn add(self: *Self, pid: Pid, free: Size) Error!void {
            const c = try self.policy.getSizeClass(free);
            var slab = try self.slabWithRoom(c);
            defer slab.ph.deinit();
            var v = View.init(try slab.ph.getDataMut());
            const si = try v.insert(pid, free);
            try self.writeLocation(pid, .{
                .page_id = slab.pid,
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
            try v.remove(@intCast(location.slot_id));
            if (try v.isEmpty()) {
                try self.unlinkAndDestroy(&v, location.page_id);
            }
        }

        // --- helpers ---
        const SlabRef = struct {
            pid: PidT,
            ph: PageHandle,
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

        fn createSlab(self: *Self, c: SizeClassT) Error!SlabRef {
            var ph = try self.cache.create();
            errdefer ph.deinit();
            const pid = try ph.pid();
            var v = View.init(try ph.getDataMut());
            try v.formatPage(self.settings.page_kind, pid, 0, c);
            return .{ .pid = pid, .ph = ph };
        }

        fn slabWithRoom(self: *Self, c: SizeClassT) Error!SlabRef {
            const root_opt = try self.sm.getSizeClassRoot(c);
            if (root_opt) |root_pid| {
                var cur_pid = root_pid;
                while (true) {
                    var ph = try self.fetchSlab(cur_pid);
                    const cv = ConstView.init(try ph.getData());
                    if (!try cv.isFull()) {
                        return .{ .pid = cur_pid, .ph = ph };
                    }
                    const nxt = cv.getNext();
                    ph.deinit();
                    if (nxt) |n| {
                        cur_pid = n;
                        continue;
                    }
                    var created = try self.createSlab(c);
                    errdefer created.ph.deinit();
                    {
                        var nv = View.init(try created.ph.getDataMut());
                        try nv.setNext(root_pid);
                        try nv.setPrev(null);
                    }
                    {
                        var rph = try self.fetchSlab(root_pid);
                        defer rph.deinit();
                        var rv = View.init(try rph.getDataMut());
                        try rv.setPrev(created.pid);
                    }
                    try self.sm.setSizeClassRoot(c, created.pid);
                    return created;
                }
            }
            var created = try self.createSlab(c);
            errdefer created.ph.deinit();
            try self.sm.setSizeClassRoot(c, created.pid);
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
