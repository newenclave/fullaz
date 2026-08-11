const header = @import("../../page/header.zig");
const location_accessor = @import("location_accessor.zig");
const requiresFnSignature = @import("../../contracts/interfaces.zig").requiresFnSignature;

pub fn HeaderLocationAccessor(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: @import("std").builtin.Endian,
    comptime AdditionalT: type,
    comptime field_name: []const u8,
) type {
    const TraitT = AdditionalT.traitType(field_name);
    const ReadView = header.ViewImpl(PageIdT, IndexT, AdditionalT, Endian, true);
    const WriteView = header.ViewImpl(PageIdT, IndexT, AdditionalT, Endian, false);

    comptime {
        if (!@hasDecl(TraitT, "Location")) {
            @compileError("FSM location trait must declare Location");
        }
        requiresFnSignature(TraitT, "get", fn (*const TraitT.Storage) ?TraitT.Location);
        requiresFnSignature(TraitT, "set", fn (*TraitT.Storage, TraitT.Location) void);
        requiresFnSignature(TraitT, "clear", fn (*TraitT.Storage) void);
        requiresFnSignature(TraitT, "validate", fn (*const TraitT.Storage) bool);
    }

    const Accessor = struct {
        pub const Location = TraitT.Location;
        pub const Error = ReadView.Error;

        pub fn read(page: []const u8) Error!?Location {
            const view = ReadView.init(page);
            try view.validateTyped();

            const storage = AdditionalT.field(view.additional(), field_name);
            if (!TraitT.validate(storage)) {
                return Error.InconsistentLayout;
            }
            return TraitT.get(storage);
        }

        pub fn write(page: []u8, location: Location) Error!void {
            var view = WriteView.init(page);
            try view.validateTyped();

            TraitT.set(AdditionalT.fieldMut(view.additionalMut(), field_name), location);
        }

        pub fn clear(page: []u8) Error!void {
            var view = WriteView.init(page);
            try view.validateTyped();

            TraitT.clear(AdditionalT.fieldMut(view.additionalMut(), field_name));
        }
    };

    comptime location_accessor.assertAccessor(Accessor);
    return Accessor;
}
