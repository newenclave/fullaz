const std = @import("std");
const fullaz = @import("fullaz");
const fsx = @import("fsx");

const Device = fullaz.device.MemoryBlock(fsx.constants.PageId);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const Fs = fsx.fs.Fs(PageCache, fsx.path.Default);
const cache_frames = 128;

pub const panic = std.debug.FullPanic(struct {
    fn f(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.f);

const allocator = std.heap.wasm_allocator;

var device: Device = undefined;
var cache: PageCache = undefined;
var filesystem: Fs = undefined;
var ready = false;
var last_error: []const u8 = "";

var entries: std.ArrayList(u8) = .empty;
var page_records: std.ArrayList(u32) = .empty;
var ownership_records: std.ArrayList(u32) = .empty;
var read_allocation: []u8 = &.{};
var read_result: []u8 = &.{};

fn fail(err: anyerror) u32 {
    last_error = @errorName(err);
    return 0;
}

fn input(ptr: usize, len: usize) []const u8 {
    if (len == 0) return &.{};
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

fn teardown() void {
    if (!ready) return;
    releaseRead();
    cache.deinit();
    device.deinit();
    ready = false;
}

fn beginMutation() ?PageCache.WriteBatch {
    if (!ready) {
        last_error = "NotReady";
        return null;
    }
    return cache.begin() catch |err| {
        _ = fail(err);
        return null;
    };
}

fn discard(batch: *PageCache.WriteBatch, original: anyerror) u32 {
    batch.discard() catch |err| return fail(err);
    return fail(original);
}

fn appendInt(output: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

fn appendPageRecord(output: *std.ArrayList(u32), pid: u32, role: u8, used: u32, capacity: u32) !void {
    try output.append(allocator, pid);
    try output.append(allocator, role);
    try output.append(allocator, used);
    try output.append(allocator, capacity);
}

export fn format() u32 {
    teardown();
    device = Device.init(allocator, fsx.constants.default_block_size) catch |err| return fail(err);
    cache = PageCache.init(&device, allocator, cache_frames) catch |err| {
        device.deinit();
        return fail(err);
    };
    filesystem = Fs.format(&cache, fsx.constants.default_block_size) catch |err| {
        cache.deinit();
        device.deinit();
        return fail(err);
    };
    ready = true;
    last_error = "";
    return 1;
}

export fn importImage(ptr: usize, len: usize) u32 {
    if (len == 0 or len % fsx.constants.default_block_size != 0) {
        last_error = "InvalidImageSize";
        return 0;
    }
    teardown();
    device = Device.init(allocator, fsx.constants.default_block_size) catch |err| return fail(err);
    device.storage.resize(allocator, len) catch |err| {
        device.deinit();
        return fail(err);
    };
    @memcpy(device.storage.items, input(ptr, len));
    cache = PageCache.init(&device, allocator, cache_frames) catch |err| {
        device.deinit();
        return fail(err);
    };
    filesystem = Fs.open(&cache, fsx.constants.default_block_size) catch |err| {
        cache.deinit();
        device.deinit();
        return fail(err);
    };
    ready = true;
    last_error = "";
    return 1;
}

export fn imagePtr() usize {
    if (!ready) return 0;
    cache.flushAll() catch |err| {
        _ = fail(err);
        return 0;
    };
    return @intFromPtr(device.storage.items.ptr);
}

export fn imageLen() usize {
    return if (ready) device.storage.items.len else 0;
}

export fn allocate(len: usize) usize {
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

export fn freeAllocation(ptr: usize, len: usize) void {
    if (len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator.free(bytes[0..len]);
}

export fn mkdir(path_ptr: usize, path_len: usize) u32 {
    var batch = beginMutation() orelse return 0;
    filesystem.mkdir(input(path_ptr, path_len)) catch |err| return discard(&batch, err);
    batch.commit() catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn touch(path_ptr: usize, path_len: usize) u32 {
    var batch = beginMutation() orelse return 0;
    filesystem.touch(input(path_ptr, path_len)) catch |err| return discard(&batch, err);
    batch.commit() catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn removeFile(path_ptr: usize, path_len: usize) u32 {
    var batch = beginMutation() orelse return 0;
    filesystem.rm(input(path_ptr, path_len)) catch |err| return discard(&batch, err);
    batch.commit() catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn removeDirectory(path_ptr: usize, path_len: usize) u32 {
    var batch = beginMutation() orelse return 0;
    filesystem.rmdir(input(path_ptr, path_len)) catch |err| return discard(&batch, err);
    batch.commit() catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn replace(path_ptr: usize, path_len: usize, data_ptr: usize, data_len: usize) u32 {
    var batch = beginMutation() orelse return 0;
    _ = filesystem.replace(input(path_ptr, path_len), input(data_ptr, data_len)) catch |err| return discard(&batch, err);
    batch.commit() catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn list(path_ptr: usize, path_len: usize) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    entries.clearRetainingCapacity();
    const Collector = struct {
        fn collect(_: *void, name: []const u8, node: fsx.inode.Inode) anyerror!void {
            const kind: u8 = switch (node) {
                .file => 1,
                .dir => 2,
            };
            const size: u32 = switch (node) {
                .file => |roots| roots.total,
                .dir => 0,
            };
            try entries.append(allocator, kind);
            try appendInt(&entries, u16, @intCast(name.len));
            try appendInt(&entries, u32, size);
            try entries.appendSlice(allocator, name);
        }
    };
    var context: void = {};
    filesystem.ls(input(path_ptr, path_len), &context, Collector.collect) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn entriesPtr() usize {
    return @intFromPtr(entries.items.ptr);
}

export fn entriesLen() usize {
    return entries.items.len;
}

export fn read(path_ptr: usize, path_len: usize) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    releaseRead();
    const size = filesystem.size(input(path_ptr, path_len)) catch |err| return fail(err);
    if (size == 0) {
        last_error = "";
        return 1;
    }
    read_allocation = allocator.alloc(u8, size) catch |err| return fail(err);
    const read_len = filesystem.read(input(path_ptr, path_len), read_allocation) catch |err| {
        releaseRead();
        return fail(err);
    };
    read_result = read_allocation[0..read_len];
    last_error = "";
    return 1;
}

export fn readPtr() usize {
    return @intFromPtr(read_result.ptr);
}

export fn readLen() usize {
    return read_result.len;
}

export fn releaseRead() void {
    if (read_allocation.len > 0) allocator.free(read_allocation);
    read_allocation = &.{};
    read_result = &.{};
}

export fn snapshotPages() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    page_records.clearRetainingCapacity();
    const Collector = struct {
        fn collect(_: *void, info: fsx.inspect.PageInfo) anyerror!void {
            try appendPageRecord(&page_records, info.pid, @intFromEnum(info.role), info.used, info.capacity);
        }
    };
    var context: void = {};
    filesystem.inspectPages(&context, Collector.collect) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn pagesPtr() usize {
    return @intFromPtr(page_records.items.ptr);
}

export fn pagesCount() usize {
    return page_records.items.len / 4;
}

export fn snapshotOwnership(path_ptr: usize, path_len: usize) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    ownership_records.clearRetainingCapacity();
    const Collector = struct {
        fn collect(_: *void, page: fsx.inspect.OwnedPage) anyerror!void {
            try ownership_records.append(allocator, page.pid);
            try ownership_records.append(allocator, @intFromEnum(page.role));
        }
    };
    var context: void = {};
    filesystem.inspectOwnership(input(path_ptr, path_len), &context, Collector.collect) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn ownershipPtr() usize {
    return @intFromPtr(ownership_records.items.ptr);
}

export fn ownershipCount() usize {
    return ownership_records.items.len / 2;
}

export fn lastErrorPtr() usize {
    return @intFromPtr(last_error.ptr);
}

export fn lastErrorLen() usize {
    return last_error.len;
}
