const std = @import("std");
const extensions = @import("fullaz").page.extensions;
const PackedInt = @import("fullaz").core.packed_int.PackedInt;

const FsmTrait = struct {
    pub const Storage = extern struct {
        page_id: PackedInt(u32, .little),
        slot_id: PackedInt(u16, .little),
    };
};

test "page extension field records its name and trait" {
    const descriptor = comptime extensions.field("fsm", FsmTrait);

    try std.testing.expectEqualStrings("fsm", descriptor.name);
    comptime if (descriptor.Trait != FsmTrait) {
        @compileError("field must retain its trait type");
    };
    comptime if (descriptor.Trait.Storage != FsmTrait.Storage) {
        @compileError("field trait must expose its storage type");
    };
}
