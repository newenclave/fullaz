const bpt = @import("fullaz").bpt;
const algos = @import("fullaz").algorithm;

const MemoryModel = bpt.models.MemoryModel;

const std = @import("std");
const expect = std.testing.expect;

test "Bpt Create with Memory model" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const allocator = gpa.allocator();
    const KeyType = f32;

    const ModelType = MemoryModel(KeyType, 5, algos.CmpNum(KeyType).asc);

    var model = try ModelType.init(allocator);
    defer model.deinit();

    _ = bpt.Bpt(ModelType).init(&model, .neighbor_share);
}
