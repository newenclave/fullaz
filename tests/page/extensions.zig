const std = @import("std");
const extensions = @import("fullaz").page.extensions;
const PackedInt = @import("fullaz").core.packed_int.PackedInt;

const FsmTrait = struct {
    pub const Storage = extern struct {
        page_id: PackedInt(u32, .little),
        slot_id: PackedInt(u16, .little),
    };
};

const LinksTrait = struct {
    pub const Storage = extern struct {
        prev: PackedInt(u32, .little),
        next: PackedInt(u32, .little),
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

test "page extension Compose generates one typed storage field" {
    const Additional = extensions.Compose(.{
        extensions.field("fsm", FsmTrait),
    });

    var storage: Additional.Storage = undefined;
    Additional.fieldMut(&storage, "fsm").page_id.set(77);
    Additional.fieldMut(&storage, "fsm").slot_id.set(3);

    try std.testing.expectEqual(@as(usize, 1), @alignOf(Additional.Storage));
    try std.testing.expectEqual(@sizeOf(FsmTrait.Storage), @sizeOf(Additional.Storage));
    try std.testing.expectEqual(@as(u32, 77), Additional.field(&storage, "fsm").page_id.get());
    try std.testing.expectEqual(@as(u16, 3), Additional.field(&storage, "fsm").slot_id.get());
}

test "page extension Compose preserves descriptor order across typed fields" {
    const Additional = extensions.Compose(.{
        extensions.field("fsm", FsmTrait),
        extensions.field("links", LinksTrait),
    });

    var storage: Additional.Storage = undefined;
    Additional.fieldMut(&storage, "fsm").page_id.set(77);
    Additional.fieldMut(&storage, "fsm").slot_id.set(3);
    Additional.fieldMut(&storage, "links").prev.set(11);
    Additional.fieldMut(&storage, "links").next.set(22);

    try std.testing.expectEqual(@as(usize, 1), @alignOf(Additional.Storage));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Additional.Storage, "fsm"));
    try std.testing.expectEqual(@sizeOf(FsmTrait.Storage), @offsetOf(Additional.Storage, "links"));
    try std.testing.expectEqual(@sizeOf(FsmTrait.Storage) + @sizeOf(LinksTrait.Storage), @sizeOf(Additional.Storage));
    try std.testing.expectEqual(@as(u32, 77), Additional.field(&storage, "fsm").page_id.get());
    try std.testing.expectEqual(@as(u16, 3), Additional.field(&storage, "fsm").slot_id.get());
    try std.testing.expectEqual(@as(u32, 11), Additional.field(&storage, "links").prev.get());
    try std.testing.expectEqual(@as(u32, 22), Additional.field(&storage, "links").next.get());
}
