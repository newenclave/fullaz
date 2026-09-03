const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");
const superblock = @import("superblock.zig");

const FreeList = fullaz.storage.free_list.FreeList;

pub fn ReclaimingCache(comptime InnerCacheT: type) type {
    return struct {
        const Self = @This();

        pub const Handle = InnerCacheT.Handle;
        pub const Pid = InnerCacheT.Pid;
        pub const PageId = Pid;
        pub const UnderlyingDevice = InnerCacheT.UnderlyingDevice;
        pub const Error = InnerCacheT.Error || error{CannotFreeSuperblock};
        pub const FreeListState = superblock.FreeListState;
        pub const StateLeaseType = struct {
            pub const Error = InnerCacheT.Error;

            handle: InnerCacheT.Handle,
            value: *FreeListState,
            persisted: ?*FreeListState = null,

            pub fn data(self: *const @This()) @This().Error![]const u8 {
                return std.mem.asBytes(@as(*const FreeListState, self.value));
            }

            pub fn dataMut(self: *@This()) @This().Error![]u8 {
                const bytes = try self.handle.dataMut();
                const offset = @offsetOf(superblock.Header, "free_page_root");
                self.persisted = @ptrCast(bytes[offset..].ptr);
                return std.mem.asBytes(self.value);
            }

            pub fn finish(self: *@This()) void {
                if (self.persisted) |persisted| {
                    persisted.* = self.value.*;
                }
            }

            pub fn deinit(self: *@This()) void {
                self.handle.deinit();
            }
        };

        pub const State = struct {
            free_list: FreeListState = .{},
            free_page_count: usize = 0,
            reused_page_count: usize = 0,
        };

        inner: *InnerCacheT,
        state_value: State,

        pub fn init(inner: *InnerCacheT, initial_state: State) Self {
            return .{ .inner = inner, .state_value = initial_state };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{
                .handle = try self.inner.fetch(constants.superblock_pid),
                .value = &self.state_value.free_list,
            };
        }

        pub fn getTemporaryPage(self: *Self) Error!Handle {
            return self.inner.getTemporaryPage();
        }

        pub fn fetch(self: *Self, pid: Pid) Error!Handle {
            return self.inner.fetch(pid);
        }

        pub fn create(self: *Self) Error!Handle {
            var free_list = FreeList(InnerCacheT, Self, constants.endian).init(self.inner, self);
            if (try free_list.pop()) |pid| {
                var handle = try self.inner.fetch(pid);
                errdefer handle.deinit();
                @memset(try handle.dataMut(), 0);
                self.state_value.free_page_count -= 1;
                self.state_value.reused_page_count += 1;
                try self.persistState();
                return handle;
            }
            return self.inner.create();
        }

        pub fn free(self: *Self, pid: Pid) Error!void {
            if (pid == constants.superblock_pid) {
                return Error.CannotFreeSuperblock;
            }
            var free_list = FreeList(InnerCacheT, Self, constants.endian).init(self.inner, self);
            try free_list.push(pid);
            self.state_value.free_page_count += 1;
            try self.persistState();
        }

        pub fn flush(self: *Self, pid: Pid) Error!void {
            return self.inner.flush(pid);
        }

        pub fn flushAll(self: *Self) Error!void {
            return self.inner.flushAll();
        }

        pub fn pageSize(self: *const Self) usize {
            return self.inner.pageSize();
        }

        pub fn pageCount(self: *const Self) usize {
            return self.inner.pageCount();
        }

        fn persistState(self: *Self) Error!void {
            var handle = try self.inner.fetch(constants.superblock_pid);
            defer handle.deinit();
            var view = superblock.View(false).init(try handle.dataMut());
            view.headerMut().free_page_root = self.state_value.free_list;
            view.setFreePageCount(self.state_value.free_page_count);
            view.setReusedPageCount(self.state_value.reused_page_count);
        }
    };
}
