const std = @import("std");
const algorithm = @import("../../../core/algorithm.zig");
const errors = @import("../../../core/errors.zig");

fn sizeCmp(lhs: usize, rhs: usize) algorithm.Order {
    if (lhs < rhs) {
        return .lt;
    } else if (lhs > rhs) {
        return .gt;
    } else {
        return .eq;
    }
}

const lowerBound = algorithm.lowerBound;

pub fn MemoryList(comptime PidT: type, comptime SizeT: type) type {
    const PageInfo = struct {
        pid: PidT,
        size: SizeT,
    };
    const Container = std.ArrayList(PageInfo);

    const Context = struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        pages: Container,
    };

    return struct {
        const Self = @This();
        pub const Pid = PidT;
        pub const Size = SizeT;

        pub const Error = std.mem.Allocator.Error ||
            errors.SetError ||
            errors.IndexError;

        ctx: Context = undefined,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return Self{
                .ctx = Context{
                    .allocator = allocator,
                    .pages = try Container.initCapacity(allocator, 4),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.ctx.pages.deinit(self.ctx.allocator);
            self.* = undefined;
        }

        pub fn insert(self: *Self, pid: PidT, size: SizeT) Error!usize {
            if (self.findPid(pid)) |_| {
                return Error.KeyAlreadyExists;
            }

            const idx = self.lowerBoundElement(size);
            const pinfo = PageInfo{
                .pid = pid,
                .size = size,
            };
            try self.ctx.pages.insert(self.ctx.allocator, idx, pinfo);
            return idx;
        }

        pub fn remove(self: *Self, idx: usize) Error!void {
            if (idx >= self.ctx.pages.items.len) {
                return Error.OutOfBounds;
            }
            try self.ctx.pages.remove(self.ctx.allocator, idx);
        }

        pub fn lowerBoundElement(self: *const Self, size: Size) usize {
            const idx = lowerBound(
                PageInfo,
                self.ctx.pages.items,
                size,
                pageInfoCmp,
                {},
            ) catch self.ctx.pages.items.len;
            return idx;
        }

        fn pageInfoCmp(_: void, lhs: PageInfo, rhs: usize) algorithm.Order {
            return sizeCmp(lhs.size, rhs);
        }

        fn findPid(self: *const Self, pid: PidT) ?usize {
            for (self.ctx.pages.items, 0..) |pinfo, idx| {
                if (pinfo.pid == pid) {
                    return idx;
                }
            }
            return null;
        }
    };
}
