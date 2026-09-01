const PageKind = @import("../component/component.zig").PageKind;

pub const invalid: PageKind = 0x0000;
pub const catalog_slot_chain: PageKind = 0x0001;
pub const component_id_radix_leaf: PageKind = 0x0002;
pub const component_id_radix_inode: PageKind = 0x0003;
pub const component_name_bpt_leaf: PageKind = 0x0004;
pub const component_name_bpt_inode: PageKind = 0x0005;
pub const component_metadata: PageKind = 0x0006;
pub const retired_page_queue: PageKind = 0x0007;
pub const gc_state: PageKind = 0x0008;
pub const gc_mark_bitmap: PageKind = 0x0009;
pub const gc_free_bitmap: PageKind = 0x000a;
pub const gc_queue: PageKind = 0x000b;
pub const first_reserved: PageKind = 0x000c;
pub const first_component: PageKind = 0x0100;
pub const invalid_sentinel: PageKind = 0xffff;

pub fn isSystem(kind: PageKind) bool {
    return kind >= catalog_slot_chain and kind < first_component;
}

pub fn isComponent(kind: PageKind) bool {
    return kind >= first_component and kind != invalid_sentinel;
}

comptime {
    const assigned = [_]PageKind{
        catalog_slot_chain,
        component_id_radix_leaf,
        component_id_radix_inode,
        component_name_bpt_leaf,
        component_name_bpt_inode,
        component_metadata,
        retired_page_queue,
        gc_state,
        gc_mark_bitmap,
        gc_free_bitmap,
        gc_queue,
    };
    for (assigned, 0..) |kind, index| {
        if (kind < catalog_slot_chain or kind >= first_reserved) {
            @compileError("dynamic database system page kind is outside the assigned system range");
        }
        for (assigned[0..index]) |previous| {
            if (kind == previous) {
                @compileError("duplicate dynamic database system page kind");
            }
        }
    }
}
