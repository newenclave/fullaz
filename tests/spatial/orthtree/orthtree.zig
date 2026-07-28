const std = @import("std");
const fulla = @import("fullaz");
const orthtree = fulla.spatial.orthtree;

test "OrthTree: create" {
    _ = fulla.spatial.orthtree;
}

test "OrthTree: memory model" {
    const Model = orthtree.models.memory.Model(u32, 2);
    const tree = orthtree.TreeImpl(Model).init(&Model);
    _ = tree;
}
