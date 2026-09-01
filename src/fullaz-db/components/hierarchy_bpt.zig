const core = @import("hierarchy_store/bpt.zig");

/// A fixed-value BPT whose values are tagged raw bytes or embedded child roots.
///
/// The implementation lives in the shared hierarchy-store BPT core so aggregate
/// owners and this legacy descriptor use the same envelope and editor machinery.
pub const hierarchyBpt = core.hierarchyBpt;
