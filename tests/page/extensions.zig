const std = @import("std");
const extensions = @import("fullaz").page.extensions;
const PackedInt = @import("fullaz").core.packed_int.PackedInt;

const FsmTrait = struct {
    pub const Storage = extern struct {
        page_id: PackedInt(u32, .little),
        slot_id: PackedInt(u16, .little),
    };

    pub fn format(storage: *Storage) void {
        storage.page_id.setMax();
        storage.slot_id.setMax();
    }

    pub fn validate(storage: *const Storage) bool {
        return storage.page_id.isMax() == storage.slot_id.isMax();
    }
};

const LinksTrait = struct {
    pub const Storage = extern struct {
        prev: PackedInt(u32, .little),
        next: PackedInt(u32, .little),
    };

    pub fn format(storage: *Storage) void {
        storage.prev.setMax();
        storage.next.setMax();
    }

    pub fn validate(storage: *const Storage) bool {
        return storage.prev.isMax() == storage.next.isMax();
    }
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
        .version = 2,
        .fields = .{
            extensions.field("fsm", FsmTrait),
        },
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
        .version = 2,
        .fields = .{
            extensions.field("fsm", FsmTrait),
            extensions.field("links", LinksTrait),
        },
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

test "page extension Compose formats and validates every field" {
    const Additional = extensions.Compose(.{
        .version = 2,
        .fields = .{
            extensions.field("fsm", FsmTrait),
            extensions.field("links", LinksTrait),
        },
    });

    var storage: Additional.Storage = undefined;
    Additional.format(&storage);

    try std.testing.expect(Additional.validate(&storage));
    try std.testing.expect(Additional.field(&storage, "fsm").page_id.isMax());
    try std.testing.expect(Additional.field(&storage, "fsm").slot_id.isMax());
    try std.testing.expect(Additional.field(&storage, "links").prev.isMax());
    try std.testing.expect(Additional.field(&storage, "links").next.isMax());

    Additional.fieldMut(&storage, "fsm").page_id.set(77);
    try std.testing.expect(!Additional.validate(&storage));

    Additional.fieldMut(&storage, "fsm").slot_id.set(3);
    try std.testing.expect(Additional.validate(&storage));

    Additional.fieldMut(&storage, "links").prev.set(11);
    try std.testing.expect(!Additional.validate(&storage));
}

test "page extension Compose retains its page version" {
    const Additional = extensions.Compose(.{
        .version = 7,
        .fields = .{
            extensions.field("fsm", FsmTrait),
        },
    });

    try std.testing.expectEqual(@as(u8, 7), Additional.page_version);
}

test "page extension Compose returns traits by field name" {
    const Additional = extensions.Compose(.{
        .version = 7,
        .fields = .{
            extensions.field("fsm", FsmTrait),
            extensions.field("links", LinksTrait),
        },
    });

    comptime if (Additional.traitType("fsm") != FsmTrait) {
        @compileError("fsm field must return FsmTrait");
    };
    comptime if (Additional.traitType("links") != LinksTrait) {
        @compileError("links field must return LinksTrait");
    };
}

test "page extension Extend appends fields with a new version" {
    const Base = extensions.Compose(.{
        .version = 2,
        .fields = .{
            extensions.field("fsm", FsmTrait),
        },
    });
    const Additional = extensions.Extend(Base, .{
        .version = 3,
        .fields = .{
            extensions.field("links", LinksTrait),
        },
    });

    var storage: Additional.Storage = undefined;
    Additional.format(&storage);

    try std.testing.expectEqual(@as(u8, 3), Additional.page_version);
    try std.testing.expectEqual(@as(usize, 2), Additional.fields.len);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Additional.Storage, "fsm"));
    try std.testing.expectEqual(@sizeOf(FsmTrait.Storage), @offsetOf(Additional.Storage, "links"));
    try std.testing.expect(Additional.validate(&storage));
    try std.testing.expect(Additional.field(&storage, "fsm").page_id.isMax());
    try std.testing.expect(Additional.field(&storage, "links").prev.isMax());
}
