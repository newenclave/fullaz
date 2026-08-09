pub const memory = @import("memory.zig");
pub const paged = @import("paged/paged.zig");

pub const Memory = memory.Memory;
pub const MemoryImpl = memory.MemoryImpl;
pub const Paged = paged.PagedModel;
pub const PagedImpl = paged.PagedModelImpl;
