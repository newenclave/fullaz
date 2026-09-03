pub const Memory = @import("virtual_page_map/memory.zig").Memory;
const paged = @import("virtual_page_map/paged.zig");

pub const Paged = paged.Paged;
pub const State = paged.State;
pub const CowPaged = @import("virtual_page_map/cow_paged.zig").CowPaged;
pub const CowPagedState = @import("virtual_page_map/cow_paged.zig").State;
