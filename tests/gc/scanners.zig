const std = @import("std");
const fullaz = @import("fullaz");

const Store = struct {
    pub const PageId = usize;
    pub const Error = error{InvalidPageId};

    pub const Page = struct {
        kind: u16,
    };

    const Entry = struct {
        kind: u16,
        free: bool = false,
        reserved: bool = false,
    };

    entries: []Entry,

    pub fn pageCount(self: *const Store) usize {
        return self.entries.len;
    }

    pub fn isFree(self: *const Store, page_id: usize) Error!bool {
        if (page_id >= self.entries.len) {
            return error.InvalidPageId;
        }
        return self.entries[page_id].free;
    }

    pub fn fetchPage(self: *const Store, page_id: usize) Error!Page {
        if (page_id >= self.entries.len or self.entries[page_id].free) {
            return error.InvalidPageId;
        }
        return .{ .kind = self.entries[page_id].kind };
    }

    pub fn releasePage(_: *const Store, _: *Page) void {}

    pub fn pageKind(_: *const Store, page: *const Page, _: usize) Error!u16 {
        return page.kind;
    }

    pub fn pageData(_: *const Store, _: *const Page) Error![]const u8 {
        return &.{};
    }

    pub fn isReserved(self: *const Store, page_id: usize) Error!bool {
        if (page_id >= self.entries.len) {
            return error.InvalidPageId;
        }
        return self.entries[page_id].reserved;
    }

    pub fn reclaim(self: *Store, page_id: usize) Error!void {
        if (page_id >= self.entries.len or self.entries[page_id].reserved) {
            return error.InvalidPageId;
        }
        self.entries[page_id].free = true;
    }
};

test "GC: method adapter separates page and value contexts" {
    const Model = fullaz.gc.models.Memory(Store);
    const Collector = fullaz.gc.Gc(Model);

    const Owner = struct {
        pub fn scanLeafRefs(_: *const @This(), _: usize, _: []const u8, visitor: anytype) !void {
            try visitor.visitValue("embedded-root");
        }
    };

    const ValueContext = struct {
        target: usize,
    };

    const ValueScanner = struct {
        fn scan(
            context: ?*const anyopaque,
            _: []const u8,
            sink: Collector.ReferenceSink,
        ) Collector.Error!void {
            const value_context: *const ValueContext = @ptrCast(@alignCast(context.?));
            try sink.visit(value_context.target);
        }
    };

    var entries = [_]Store.Entry{
        .{ .kind = 0, .reserved = true },
        .{ .kind = 1 },
        .{ .kind = 2 },
        .{ .kind = 2 },
    };

    var store = Store{ .entries = &entries };

    var model = Model.init(std.testing.allocator, &store);
    defer model.deinit();

    var collector = Collector.init(&model);
    defer collector.deinit();

    const owner = Owner{};
    const value_context = ValueContext{ .target = 2 };

    try collector.registerWithContexts(
        1,
        1,
        &owner,
        fullaz.gc.scanners.method(Collector, Owner, Owner.scanLeafRefs),
        &value_context,
        ValueScanner.scan,
    );

    try collector.register(2, 1, null, struct {
        fn scan(_: ?*const anyopaque, _: usize, _: []const u8, _: Collector.ReferenceSink) Collector.Error!void {}
    }.scan, null);

    try collector.start(&.{1});
    while (try collector.step(1) != .complete) {}

    try std.testing.expect(!entries[1].free);
    try std.testing.expect(!entries[2].free);
    try std.testing.expect(entries[3].free);
}

test "GC: method adapter classifies owner and page errors" {
    const Model = fullaz.gc.models.Memory(Store);
    const Collector = fullaz.gc.Gc(Model);
    const Owner = struct {
        pub fn invalid(_: *const @This(), _: usize, _: []const u8, _: anytype) !void {
            return error.BadData;
        }
    };

    var entries = [_]Store.Entry{
        .{ .kind = 0, .reserved = true },
        .{ .kind = 1 },
    };
    var store = Store{ .entries = &entries };
    var model = Model.init(std.testing.allocator, &store);
    defer model.deinit();
    var collector = Collector.init(&model);
    defer collector.deinit();
    const owner = Owner{};
    try collector.register(
        1,
        1,
        &owner,
        fullaz.gc.scanners.method(Collector, Owner, Owner.invalid),
        null,
    );
    try collector.start(&.{1});
    while (model.phase() != .marking) {
        _ = try collector.step(1);
    }
    try std.testing.expectError(error.InvalidPage, collector.step(1));
}

test "GC: method adapter rejects a missing owner context" {
    const Model = fullaz.gc.models.Memory(Store);
    const Collector = fullaz.gc.Gc(Model);
    const Owner = struct {
        pub fn scan(_: *const @This(), _: usize, _: []const u8, _: anytype) !void {}
    };

    var entries = [_]Store.Entry{
        .{ .kind = 0, .reserved = true },
        .{ .kind = 1 },
    };
    var store = Store{ .entries = &entries };
    var model = Model.init(std.testing.allocator, &store);
    defer model.deinit();
    var collector = Collector.init(&model);
    defer collector.deinit();
    try collector.register(
        1,
        1,
        null,
        fullaz.gc.scanners.method(Collector, Owner, Owner.scan),
        null,
    );
    try collector.start(&.{1});
    while (model.phase() != .marking) {
        _ = try collector.step(1);
    }
    try std.testing.expectError(error.InvalidScannerContext, collector.step(1));
}
