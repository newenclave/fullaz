const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

pub fn Trait(comptime PageIdT: type, comptime Endian: std.builtin.Endian) type {
    return TraitImpl(PageIdT, false, Endian);
}

pub fn TraitImpl(comptime PageIdT: type, comptime forward_only: bool, comptime Endian: std.builtin.Endian) type {
    if (forward_only) {
        return TraitForwardImpl(PageIdT, Endian);
    } else {
        return TraitBidirectionalImpl(PageIdT, Endian);
    }
}

pub fn TraitBidirectionalImpl(comptime PageIdT: type, comptime Endian: std.builtin.Endian) type {
    const PageId = PackedInt(PageIdT, Endian);

    return struct {
        pub const Storage = extern struct {
            prev: PageId,
            next: PageId,
        };

        pub fn format(storage: *Storage) void {
            clear(storage);
        }

        pub fn validate(_: *const Storage) bool {
            return true;
        }

        pub fn getPrev(storage: *const Storage) ?PageIdT {
            return if (storage.prev.isMax()) null else storage.prev.get();
        }

        pub fn getNext(storage: *const Storage) ?PageIdT {
            return if (storage.next.isMax()) null else storage.next.get();
        }

        pub fn setPrev(storage: *Storage, page_id: ?PageIdT) void {
            if (page_id) |id| {
                storage.prev.set(id);
            } else {
                storage.prev.setMax();
            }
        }

        pub fn setNext(storage: *Storage, page_id: ?PageIdT) void {
            if (page_id) |id| {
                storage.next.set(id);
            } else {
                storage.next.setMax();
            }
        }

        pub fn clear(storage: *Storage) void {
            storage.prev.setMax();
            storage.next.setMax();
        }
    };
}

pub fn TraitForwardImpl(comptime PageIdT: type, comptime Endian: std.builtin.Endian) type {
    const PageId = PackedInt(PageIdT, Endian);

    return struct {
        pub const Storage = extern struct {
            next: PageId,
        };

        pub fn format(storage: *Storage) void {
            clear(storage);
        }

        pub fn validate(_: *const Storage) bool {
            return true;
        }

        pub fn getNext(storage: *const Storage) ?PageIdT {
            return if (storage.next.isMax()) null else storage.next.get();
        }

        pub fn setNext(storage: *Storage, page_id: ?PageIdT) void {
            if (page_id) |id| {
                storage.next.set(id);
            } else {
                storage.next.setMax();
            }
        }

        pub fn clear(storage: *Storage) void {
            storage.next.setMax();
        }
    };
}
