/// Maximum supported inode level. Tree traversal uses fixed-size stacks indexed
/// by level, so persisted and in-memory nodes must stay below this bound.
pub const max_depth: usize = 64;
