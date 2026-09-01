const std = @import("std");
const fullaz = @import("fullaz");

const Model = struct {
    pub const PageId = u32;
    pub const Error = error{};

    allocator_value: std.mem.Allocator,
    cycle_active: bool = false,

    pub fn allocator(self: *const @This()) std.mem.Allocator {
        return self.allocator_value;
    }

    pub fn isCycleActive(self: *const @This()) bool {
        return self.cycle_active;
    }
};

test "GC: scanner registry is stable and frozen during a cycle" {
    const Collector = fullaz.gc.Gc(Model);
    const ScannerFixture = struct {
        fn scan(
            _: ?*const anyopaque,
            _: u32,
            _: []const u8,
            _: Collector.ReferenceSink,
        ) Collector.Error!void {}
    };

    var model = Model{ .allocator_value = std.testing.allocator };
    var gc = Collector.init(&model);
    defer gc.deinit();

    try gc.registerForCycle(9, 1, null, ScannerFixture.scan, null);
    try gc.register(3, 2, null, ScannerFixture.scan, null);
    const digest = gc.registryDigest();
    try std.testing.expectEqual(digest, gc.registryDigest());
    try std.testing.expectEqual(@as(u32, 3), gc.findScanner(3).?.page_kind);
    try std.testing.expectError(error.DuplicateScanner, gc.register(3, 1, null, ScannerFixture.scan, null));

    model.cycle_active = true;
    try std.testing.expectError(error.RegistryFrozen, gc.register(11, 1, null, ScannerFixture.scan, null));
    try gc.registerForCycle(11, 1, null, ScannerFixture.scan, null);
    try std.testing.expectEqual(@as(u32, 11), gc.findScanner(11).?.page_kind);
}
