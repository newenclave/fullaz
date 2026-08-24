const std = @import("std");

pub const Error = error{
    BadCatalogRef,
    BufferTooSmall,
};

pub const encoded_size = 16;

/// Stable locator of the current immutable catalog record for one component ID.
pub const CatalogRef = struct {
    page_id: u64,
    slot_id: u16,
    record_revision: u32,

    pub fn init(page_id: u64, slot_id: u16, record_revision: u32) Error!CatalogRef {
        if (page_id == 0 or record_revision == 0) {
            return error.BadCatalogRef;
        }
        return .{
            .page_id = page_id,
            .slot_id = slot_id,
            .record_revision = record_revision,
        };
    }

    pub fn getPageId(self: *const CatalogRef) u64 {
        return self.page_id;
    }

    pub fn getSlotId(self: *const CatalogRef) u16 {
        return self.slot_id;
    }

    pub fn getRecordRevision(self: *const CatalogRef) u32 {
        return self.record_revision;
    }

    pub fn encode(self: CatalogRef, bytes: []u8) Error!void {
        if (bytes.len < encoded_size) {
            return error.BufferTooSmall;
        }
        _ = try init(self.page_id, self.slot_id, self.record_revision);

        std.mem.writeInt(u64, bytes[0..8], self.page_id, .little);
        std.mem.writeInt(u16, bytes[8..10], self.slot_id, .little);
        std.mem.writeInt(u16, bytes[10..12], 0, .little);
        std.mem.writeInt(u32, bytes[12..16], self.record_revision, .little);
    }

    pub fn decode(bytes: []const u8) Error!CatalogRef {
        if (bytes.len != encoded_size) {
            return error.BadCatalogRef;
        }
        if (std.mem.readInt(u16, bytes[10..12], .little) != 0) {
            return error.BadCatalogRef;
        }
        return init(
            std.mem.readInt(u64, bytes[0..8], .little),
            std.mem.readInt(u16, bytes[8..10], .little),
            std.mem.readInt(u32, bytes[12..16], .little),
        );
    }
};
