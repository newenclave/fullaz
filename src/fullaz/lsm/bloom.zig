const std = @import("std");

const ln2: f64 = 0.6931471805599453;
const ln2sq: f64 = ln2 * ln2;

// from the theory:
//
// N -- number of items to be inserted;
// F -- false positive rate;
// M -- number of bits in the Bloom filter;
// K -- number of hash functions.
//
//
//    F ~ pow(( 1 - (pow(e, -(N*K)/M)) ), K)
//    K ~ (M/N) * ln(2)
//    F ~ pow(1/2, K)

// calculate M
pub fn bitsForKeys(n: usize, p: f64) usize {
    if (n == 0) {
        return 1;
    }
    const nf: f64 = @floatFromInt(n);
    const m = -nf * @log(p) / ln2sq;
    const bits: usize = @intFromFloat(@ceil(m));
    return @max(1, bits);
}

// Optimal probe count k for m bits over n keys.
pub fn probeCount(m_bits: usize, n: usize) usize {
    if (n == 0) {
        return 1;
    }
    const mf: f64 = @floatFromInt(m_bits);
    const nf: f64 = @floatFromInt(n);
    const k: usize = @intFromFloat(@round(mf / nf * ln2));
    return @max(1, k);
}

const seed_a: u64 = 0x9e3779b97f4a7c15;
const seed_b: u64 = 0xc2b2ae3d27d4eb4f;

fn hashes(key: []const u8) [2]u64 {
    return .{
        std.hash.Wyhash.hash(seed_a, key),
        std.hash.Wyhash.hash(seed_b, key),
    };
}

fn probe(h: [2]u64, i: usize, nbits: usize) usize {
    const ii: u64 = @intCast(i);
    const combined = h[0] +% ii *% h[1];
    return @intCast(combined % @as(u64, @intCast(nbits)));
}

pub fn add(bits: anytype, key: []const u8, k: usize) void {
    const nbits = bits.bitsCount();
    if (nbits == 0) {
        return;
    }
    const h = hashes(key);
    var i: usize = 0;
    while (i < k) : (i += 1) {
        bits.set(probe(h, i, nbits)) catch unreachable;
    }
}

pub fn mightContain(bits: anytype, key: []const u8, k: usize) bool {
    const nbits = bits.bitsCount();
    if (nbits == 0) {
        return true;
    }
    const h = hashes(key);
    var i: usize = 0;
    while (i < k) : (i += 1) {
        if (!bits.isSet(probe(h, i, nbits))) {
            return false;
        }
    }
    return true;
}

pub fn wyHash(_: void, key: []const u8, seed: u64) !u64 {
    return std.hash.Wyhash.hash(seed, key);
}

pub fn BloomImpl(
    comptime HashType: type,
    comptime hash_call: anytype,
    comptime HashCtx: type,
    comptime seed1: HashType,
    comptime seed2: HashType,
) type {
    return struct {
        const Self = @This();

        const HashSet = [2]HashType;

        ctx: HashCtx,

        pub fn initWithContext(ctx: HashCtx) Self {
            return Self{ .ctx = ctx };
        }

        pub fn init() Self {
            if (HashCtx != void) {
                @compileError("Bloom: a non-void context requires initWithContext");
            }
            return Self{ .ctx = {} };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        fn initHashes(self: *const Self, key: []const u8, s1: HashType, s2: HashType) HashSet {
            const h1 = hash_call(self.ctx, key, s1) catch unreachable;
            const h2 = hash_call(self.ctx, key, s2) catch unreachable;
            return .{ h1, h2 };
        }

        fn calculateM(n: usize, p: f64) usize {
            return bitsForKeys(n, p);
        }

        fn calculateK(m: usize, n: usize) usize {
            return probeCount(m, n);
        }

        fn combineHashes(hash_set: HashSet, i: usize, nbits: usize) HashType {
            const ii: HashType = @intCast(i);
            const combined = hash_set[0] +% ii *% hash_set[1];
            return combined % @as(HashType, @intCast(nbits));
        }

        pub fn add(self: *const Self, bits: anytype, key: []const u8, k: usize) void {
            const nbits = bits.bitsCount();
            if (nbits == 0) {
                return;
            }
            const h = self.initHashes(key, seed1, seed2);
            var i: usize = 0;
            while (i < k) : (i += 1) {
                bits.set(combineHashes(h, i, nbits)) catch unreachable;
            }
        }

        pub fn mightContain(self: *const Self, bits: anytype, key: []const u8, k: usize) bool {
            const nbits = bits.bitsCount();
            if (nbits == 0) {
                return true;
            }
            const h = self.initHashes(key, seed1, seed2);
            var i: usize = 0;
            while (i < k) : (i += 1) {
                if (!bits.isSet(combineHashes(h, i, nbits))) {
                    return false;
                }
            }
            return true;
        }
    };
}

pub const Bloom = BloomImpl(u64, wyHash, void, seed_a, seed_b);
