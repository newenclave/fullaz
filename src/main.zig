const std = @import("std");
const fullaz = @import("root.zig");

const algos = fullaz.algorithm;
const bpt = fullaz.bpt;
const models = fullaz.bpt.models;

pub fn main() !void {
    const Model = models.MemoryModel(u32, 10, algos.CmpNum(u32).asc);
    var model = try Model.init(std.heap.page_allocator);
    defer model.deinit();
    var bptree = bpt.Bpt(Model).init(&model, .neighbor_share);
    try bptree.insert(0, "zero");
    try bptree.insert(1, "one");
    try bptree.insert(2, "two");
    const val = try bptree.find(1);
    std.debug.print("Found value: {s}\n", .{(try val.?.get()).?.value});
}
