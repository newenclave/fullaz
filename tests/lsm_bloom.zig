const std = @import("std");
const fullaz = @import("fullaz");
const bloom = fullaz.lsm.bloom;
const BitSet = fullaz.core.bitset.BitSet(u64, .little);

const Filter = struct {
    buf: []u8,
    bits: BitSet,
    k: usize,

    fn init(alloc: std.mem.Allocator, n: usize, p: f64) !Filter {
        const m = bloom.bitsForKeys(n, p);
        const words = (m + 63) / 64;
        const nbits = words * 64;
        const buf = try alloc.alloc(u8, words * @sizeOf(u64));
        @memset(buf, 0);
        return .{
            .buf = buf,
            .bits = try BitSet.initMutable(buf, nbits),
            .k = bloom.probeCount(nbits, n),
        };
    }

    fn deinit(self: *Filter, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }
};

test "LSM bloom: sizing is sane" {
    try std.testing.expect(bloom.bitsForKeys(1000, 0.01) >= 1000);
    try std.testing.expect(bloom.probeCount(bloom.bitsForKeys(1000, 0.01), 1000) >= 1);
    try std.testing.expectEqual(@as(usize, 1), bloom.bitsForKeys(0, 0.01));
    try std.testing.expectEqual(@as(usize, 1), bloom.probeCount(100, 0));
}

test "LSM bloom: no false negatives for added keys" {
    const alloc = std.testing.allocator;
    const n = 1000;
    var f = try Filter.init(alloc, n, 0.01);
    defer f.deinit(alloc);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        bloom.add(&f.bits, key, f.k);
    }

    i = 0;
    while (i < n) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        try std.testing.expect(bloom.mightContain(&f.bits, key, f.k));
    }
}

test "LSM bloom: false-positive rate stays near target" {
    const alloc = std.testing.allocator;
    const n = 1000;
    var f = try Filter.init(alloc, n, 0.01);
    defer f.deinit(alloc);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        bloom.add(&f.bits, key, f.k);
    }

    var false_pos: usize = 0;
    const probes = 2000;
    i = 0;
    while (i < probes) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "absent-{d}", .{i});
        if (bloom.mightContain(&f.bits, key, f.k)) {
            false_pos += 1;
        }
    }
    // deterministic keys + hashes: this is a fixed rate, generous bound
    try std.testing.expect(false_pos * 100 < probes * 5);
}

test "LSM bloom: no false negatives for added keys: BloomImpl" {
    const alloc = std.testing.allocator;
    const n = 1000;
    var f = try Filter.init(alloc, n, 0.01);
    defer f.deinit(alloc);

    var bloom_impl = bloom.Bloom.init();
    defer bloom_impl.deinit();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        bloom_impl.add(&f.bits, key, f.k);
    }

    i = 0;
    while (i < n) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        try std.testing.expect(bloom_impl.mightContain(&f.bits, key, f.k));
    }
}
test "LSM bloom: false-positive rate stays near target; BloomImpl" {
    const alloc = std.testing.allocator;
    const n = 1000;
    var f = try Filter.init(alloc, n, 0.01);
    defer f.deinit(alloc);

    var bloom_impl = bloom.Bloom.init();
    defer bloom_impl.deinit();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        bloom_impl.add(&f.bits, key, f.k);
    }

    var false_pos: usize = 0;
    const probes = 2000;
    i = 0;
    while (i < probes) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "absent-{d}", .{i});
        if (bloom_impl.mightContain(&f.bits, key, f.k)) {
            false_pos += 1;
        }
    }

    try std.testing.expect(false_pos * 100 < probes * 5);
}

test "LSM bloom: false-positive rate stays near target; BloomImpl with context" {
    const alloc = std.testing.allocator;
    const n = 1000;
    var f = try Filter.init(alloc, n, 0.01);
    defer f.deinit(alloc);

    // u32 just to check different types.
    const Context = struct {
        const Self = @This();
        enter: usize = 0,
        fn hash(self: *Self, key: []const u8, seed: u32) !u32 {
            self.enter += 1;
            return @truncate(std.hash.Wyhash.hash(seed, key));
        }
    };

    const seed_a: u32 = 0x7f4a7c15;
    const seed_b: u32 = 0x27d4eb4f;

    const BloomImplWithContext = bloom.BloomImpl(u32, Context.hash, *Context, seed_a, seed_b);

    var ctx = Context{};

    var bloom_impl = BloomImplWithContext.initWithContext(&ctx);
    defer bloom_impl.deinit();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        bloom_impl.add(&f.bits, key, f.k);
    }

    var false_pos: usize = 0;
    const probes = 2000;
    i = 0;
    while (i < probes) : (i += 1) {
        var kb: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "absent-{d}", .{i});
        if (bloom_impl.mightContain(&f.bits, key, f.k)) {
            false_pos += 1;
        }
    }

    try std.testing.expect(false_pos * 100 < probes * 5);
    try std.testing.expect(ctx.enter > 0);
}
