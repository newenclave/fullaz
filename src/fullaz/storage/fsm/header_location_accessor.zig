const header = @import("../../page/header.zig");
const location_accessor = @import("location_accessor.zig");

pub fn HeaderLocationAccessor(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: @import("std").builtin.Endian,
    comptime Additional: type,
    comptime field_name: []const u8,
) type {
    const Trait = Additional.traitType(field_name);
    const ReadView = header.ViewImpl(PageIdT, IndexT, Additional, Endian, true);
    const WriteView = header.ViewImpl(PageIdT, IndexT, Additional, Endian, false);

    comptime {
        if (!@hasDecl(Trait, "Location")) {
            @compileError("FSM location trait must declare Location");
        }
        if (!@hasDecl(Trait, "get") or @TypeOf(Trait.get) != fn (*const Trait.Storage) ?Trait.Location) {
            @compileError("FSM location trait must declare get(*const Storage) ?Location");
        }
        if (!@hasDecl(Trait, "set") or @TypeOf(Trait.set) != fn (*Trait.Storage, Trait.Location) void) {
            @compileError("FSM location trait must declare set(*Storage, Location) void");
        }
        if (!@hasDecl(Trait, "clear") or @TypeOf(Trait.clear) != fn (*Trait.Storage) void) {
            @compileError("FSM location trait must declare clear(*Storage) void");
        }
        if (!@hasDecl(Trait, "validate") or @TypeOf(Trait.validate) != fn (*const Trait.Storage) bool) {
            @compileError("FSM location trait must declare validate(*const Storage) bool");
        }
    }

    const Accessor = struct {
        pub const Location = Trait.Location;
        pub const Error = ReadView.Error;

        pub fn read(page: []const u8) Error!?Location {
            const view = ReadView.init(page);
            try view.validateTyped();

            const storage = Additional.field(view.additional(), field_name);
            if (!Trait.validate(storage)) {
                return Error.InconsistentLayout;
            }
            return Trait.get(storage);
        }

        pub fn write(page: []u8, location: Location) Error!void {
            var view = WriteView.init(page);
            try view.validateTyped();

            Trait.set(Additional.fieldMut(view.additionalMut(), field_name), location);
        }

        pub fn clear(page: []u8) Error!void {
            var view = WriteView.init(page);
            try view.validateTyped();

            Trait.clear(Additional.fieldMut(view.additionalMut(), field_name));
        }
    };

    comptime location_accessor.assertAccessor(Accessor);
    return Accessor;
}
