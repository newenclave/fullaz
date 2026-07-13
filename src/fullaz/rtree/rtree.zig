pub const geometry = @import("geometry.zig");
pub const BoundingBox = geometry.BoundingBox;
pub const models = @import("models/models.zig");
pub const strategy = @import("strategy.zig");
pub const GuttmanStrategy = strategy.GuttmanStrategy;
pub const RStarStrategy = strategy.RStarStrategy;
pub const tree = @import("tree.zig");
pub const Tree = tree.Tree;

// R-tree = the generic tree with the Guttman insertion strategy.
pub fn RTree(comptime ModelT: type) type {
    return tree.Tree(ModelT, GuttmanStrategy);
}

// R*-tree = the generic tree with the R* insertion strategy.
pub fn RStarTree(comptime ModelT: type) type {
    return tree.Tree(ModelT, RStarStrategy);
}

// R*-tree = hybrid strategy. without reinsertion of underfull leaves.
pub fn RStarHybridTree(comptime ModelT: type) type {
    return tree.Tree(ModelT, strategy.HybridStrategy);
}
