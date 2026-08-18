pub const geometry = @import("../geometry.zig");
pub const BoundingBox = geometry.BoundingBox;
pub const models = @import("models/models.zig");
pub const strategy = @import("strategy.zig");
pub const GuttmanStrategy = strategy.GuttmanStrategy;
pub const LinearStrategy = strategy.LinearStrategy;
pub const RStarStrategy = strategy.RStarStrategy;
pub const tree = @import("tree.zig");
pub const Tree = tree.Tree;
pub const FatTree = tree.FatTree;
pub const assertFatKey = tree.assertFatKey;

// R-tree = the generic tree with the classic Guttman quadratic split strategy.
pub fn RTree(comptime ModelT: type) type {
    return tree.Tree(ModelT, GuttmanStrategy);
}

// R-tree with Guttman cheaper linear-cost split (lower splitting quality).
pub fn RLinearTree(comptime ModelT: type) type {
    return tree.Tree(ModelT, LinearStrategy);
}

/// R-tree with fat inode MBRs. The margin is applied when an inode entry is created or grows.
pub fn FatRTree(comptime ModelT: type, comptime margin: ModelT.KeyType.Coord) type {
    return tree.FatTree(ModelT, GuttmanStrategy, margin);
}

/// Linear-split R-tree with fat inode MBRs.
pub fn FatRLinearTree(comptime ModelT: type, comptime margin: ModelT.KeyType.Coord) type {
    return tree.FatTree(ModelT, LinearStrategy, margin);
}

// R*-tree = the generic tree with the R* insertion strategy.
pub fn RStarTree(comptime ModelT: type) type {
    return tree.Tree(ModelT, RStarStrategy);
}

/// R*-tree with fat inode MBRs.
pub fn FatRStarTree(comptime ModelT: type, comptime margin: ModelT.KeyType.Coord) type {
    return tree.FatTree(ModelT, RStarStrategy, margin);
}

// R*-tree = hybrid strategy. without reinsertion.
pub fn RStarHybridTree(comptime ModelT: type) type {
    return tree.Tree(ModelT, strategy.HybridStrategy);
}

/// Hybrid R*-tree with fat inode MBRs.
pub fn FatRStarHybridTree(comptime ModelT: type, comptime margin: ModelT.KeyType.Coord) type {
    return tree.FatTree(ModelT, strategy.HybridStrategy, margin);
}
