const std = @import("std");
const device_interface = @import("../../../device/interfaces.zig");
const page_cache = @import("../../../storage/page_cache.zig");
const radix_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;

pub fn Model(comptime PageCacheType: type, comptime StorageManager: type, comptime Value: type) type {
    _ = PageCacheType;
    _ = StorageManager;
    _ = Value;
}
