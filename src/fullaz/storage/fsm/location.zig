const std = @import("std");
const PageSlotRef = @import("../../page/page_slot_ref.zig").PageSlotRef;

pub fn Trait(
    comptime PageIdT: type,
    comptime SlotIdT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const StorageT = PageSlotRef(
        PageIdT,
        SlotIdT,
        Endian,
    );

    return struct {
        pub const Storage = StorageT;
        pub const Location = struct {
            page_id: PageIdT,
            slot_id: SlotIdT,
        };

        pub fn format(storage: *Storage) void {
            clear(storage);
        }

        pub fn validate(storage: *const Storage) bool {
            return storage.page_id.isMax() == storage.slot_id.isMax();
        }

        pub fn get(storage: *const Storage) ?Location {
            if (!validate(storage) or storage.page_id.isMax()) {
                return null;
            }
            return .{
                .page_id = storage.page_id.get(),
                .slot_id = storage.slot_id.get(),
            };
        }

        pub fn set(storage: *Storage, location: Location) void {
            storage.page_id.set(location.page_id);
            storage.slot_id.set(location.slot_id);
        }

        pub fn clear(storage: *Storage) void {
            storage.format();
        }
    };
}
