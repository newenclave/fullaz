const std = @import("std");
const fullaz = @import("fullaz");
const flush_policy = fullaz.lsm.flush_policy;

test "LSM ThresholdFlushPolicy satisfies the flush-policy contract" {
    comptime flush_policy.assertFlushPolicy(flush_policy.ThresholdFlushPolicy);
}

test "LSM ThresholdFlushPolicy: byte-size threshold only" {
    const policy = flush_policy.ThresholdFlushPolicy.init(100, null);
    try std.testing.expect(!policy.shouldFlush(99, 1000));
    try std.testing.expect(policy.shouldFlush(100, 0));
    try std.testing.expect(policy.shouldFlush(150, 0));
}

test "LSM ThresholdFlushPolicy: count threshold only" {
    const policy = flush_policy.ThresholdFlushPolicy.init(null, 10);
    try std.testing.expect(!policy.shouldFlush(1_000_000, 9));
    try std.testing.expect(policy.shouldFlush(0, 10));
    try std.testing.expect(policy.shouldFlush(0, 20));
}

test "LSM ThresholdFlushPolicy: both thresholds, either can trigger" {
    const policy = flush_policy.ThresholdFlushPolicy.init(100, 10);
    try std.testing.expect(!policy.shouldFlush(50, 5));
    try std.testing.expect(policy.shouldFlush(100, 5));
    try std.testing.expect(policy.shouldFlush(50, 10));
}

test "LSM ThresholdFlushPolicy: neither threshold set never triggers" {
    const policy = flush_policy.ThresholdFlushPolicy.init(null, null);
    try std.testing.expect(!policy.shouldFlush(std.math.maxInt(usize), std.math.maxInt(usize)));
}
