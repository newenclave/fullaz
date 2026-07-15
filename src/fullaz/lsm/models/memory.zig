const std = @import("std");
const interfaces = @import("interfaces.zig");

pub fn MemoryModel(comptime MemtableT: type) type {
    comptime interfaces.assertMemtable(MemtableT);

    return struct {
        const Self = @This();

        pub const RunIdType = usize;
        pub const Error = MemtableT.Error || std.mem.Allocator.Error;
        pub const MemtableType = MemtableT;

        pub const RunType = struct {
            table: *const MemtableT,
            run_id: RunIdType,

            pub const Error = MemtableT.Error;
            pub const Iterator = MemtableT.Iterator;

            pub fn id(self: *const RunType) RunIdType {
                return self.run_id;
            }

            pub fn byteSize(self: *const RunType) usize {
                return self.table.byteSize();
            }

            pub fn count(self: *const RunType) usize {
                return self.table.count();
            }

            pub fn get(self: *const RunType, key: []const u8) RunType.Error!?[]const u8 {
                return self.table.get(key);
            }

            pub fn iterator(self: *const RunType) RunType.Error!RunType.Iterator {
                return self.table.iterator();
            }

            pub fn seek(self: *const RunType, key: []const u8) RunType.Error!RunType.Iterator {
                return self.table.seek(key);
            }
        };

        pub const AccessorType = struct {
            allocator: std.mem.Allocator,
            active: MemtableT,
            run_table: std.ArrayList(?*MemtableT),
            run_order: std.ArrayList(RunIdType),

            pub const Error = MemtableT.Error || std.mem.Allocator.Error;

            pub fn init(allocator: std.mem.Allocator) AccessorType.Error!AccessorType {
                return .{
                    .allocator = allocator,
                    .active = try MemtableT.init(allocator),
                    .run_table = try std.ArrayList(?*MemtableT).initCapacity(allocator, 2),
                    .run_order = try std.ArrayList(RunIdType).initCapacity(allocator, 2),
                };
            }

            pub fn deinit(self: *AccessorType) void {
                self.active.deinit();
                for (self.run_table.items) |slot| {
                    if (slot) |table| {
                        table.deinit();
                        self.allocator.destroy(table);
                    }
                }
                self.run_table.deinit(self.allocator);
                self.run_order.deinit(self.allocator);
            }

            pub fn activeMemtable(self: *AccessorType) *MemtableT {
                return &self.active;
            }

            pub fn runCount(self: *const AccessorType) usize {
                return self.run_order.items.len;
            }

            pub fn runIdAt(self: *const AccessorType, index: usize) RunIdType {
                return self.run_order.items[index];
            }

            pub fn loadRun(self: *AccessorType, run_id: RunIdType) AccessorType.Error!?RunType {
                const slot = self.run_table.items[run_id] orelse return null;
                return RunType{ .table = slot, .run_id = run_id };
            }

            pub fn closeRun(self: *AccessorType, run: ?RunType) void {
                _ = self;
                _ = run;
            }
        };

        accessor: AccessorType,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return Self{ .accessor = try AccessorType.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *AccessorType {
            return &self.accessor;
        }
    };
}
