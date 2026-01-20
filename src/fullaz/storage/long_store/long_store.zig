const std = @import("std");
const headers = @import("../page/long_store.zig");
const page_view = @import("../page/header.zig").View;

const conracts = @import("../contracts/contracts.zig");

pub fn LongStore(comptime PageCacheType: type, comptime StorageManager: type) type {
    comptime {
        conracts.storage_manager.requireStorageManager(StorageManager);
    }

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const HeaderView = struct {};
    const ChunkView = struct {};

    return struct {};
}
