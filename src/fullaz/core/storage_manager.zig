const storage_manager_contract = @import("../contracts/storage_manager.zig");

/// Interprets one state lease as a checked byte-aligned durable state struct.
pub fn StateAccessor(comptime StateLeaseT: type, comptime StateT: type) type {
    assertExactStateType(StateT);

    return struct {
        pub const Error = StateLeaseT.Error || error{BadData};

        pub fn view(lease: *const StateLeaseT) Error!*const StateT {
            const bytes = try lease.data();
            if (bytes.len != @sizeOf(StateT)) {
                return error.BadData;
            }
            return @ptrCast(bytes.ptr);
        }

        pub fn viewMut(lease: *StateLeaseT) Error!*StateT {
            const bytes = try lease.dataMut();
            if (bytes.len != @sizeOf(StateT)) {
                return error.BadData;
            }
            return @ptrCast(bytes.ptr);
        }
    };
}

/// A lease that owns a parent lease and exposes one exact byte region from it.
pub fn ByteRegionLease(
    comptime ParentLeaseT: type,
    comptime parent_byte_len: usize,
    comptime byte_offset: usize,
    comptime byte_len: usize,
) type {
    comptime assertByteRegion(parent_byte_len, byte_offset, byte_len);
    comptime storage_manager_contract.assertStateLease(ParentLeaseT);

    return struct {
        const Self = @This();

        pub const Error = ParentLeaseT.Error || error{BadData};

        parent_lease: ParentLeaseT,
        finished: bool = false,
        deinitialized: bool = false,

        pub fn data(self: *const Self) Error![]const u8 {
            const bytes = try self.parent_lease.data();
            if (bytes.len != parent_byte_len) {
                return error.BadData;
            }
            return bytes[byte_offset .. byte_offset + byte_len];
        }

        pub fn dataMut(self: *Self) Error![]u8 {
            const bytes = try self.parent_lease.dataMut();
            if (bytes.len != parent_byte_len) {
                return error.BadData;
            }
            return bytes[byte_offset .. byte_offset + byte_len];
        }

        pub fn finish(self: *Self) void {
            if (self.finished or self.deinitialized) {
                return;
            }
            self.finished = true;
            self.parent_lease.finish();
        }

        pub fn deinit(self: *Self) void {
            if (self.deinitialized) {
                return;
            }
            self.deinitialized = true;
            self.parent_lease.deinit();
        }
    };
}

/// Projects one exact byte region from a state-only parent manager.
pub fn ByteRegionStorageManager(
    comptime ParentManagerT: type,
    comptime parent_byte_len: usize,
    comptime byte_offset: usize,
    comptime byte_len: usize,
) type {
    comptime storage_manager_contract.assertStorageManager(ParentManagerT);
    const ProjectedLease = ByteRegionLease(
        ParentManagerT.StateLeaseType,
        parent_byte_len,
        byte_offset,
        byte_len,
    );

    return struct {
        const Self = @This();

        pub const Error = ParentManagerT.Error;
        pub const StateLeaseType = ProjectedLease;

        parent: *ParentManagerT,

        pub fn init(parent: *ParentManagerT) Self {
            return .{ .parent = parent };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .parent_lease = try self.parent.state() };
        }
    };
}

/// Projects one exact byte region and delegates page destruction to its parent.
pub fn PagedByteRegionStorageManager(
    comptime ParentManagerT: type,
    comptime parent_byte_len: usize,
    comptime byte_offset: usize,
    comptime byte_len: usize,
) type {
    comptime storage_manager_contract.assertPagedStorageManager(
        ParentManagerT,
        ParentManagerT.PageId,
    );
    const ProjectedLease = ByteRegionLease(
        ParentManagerT.StateLeaseType,
        parent_byte_len,
        byte_offset,
        byte_len,
    );

    return struct {
        const Self = @This();

        pub const PageId = ParentManagerT.PageId;
        pub const Error = ParentManagerT.Error;
        pub const StateLeaseType = ProjectedLease;

        parent: *ParentManagerT,

        pub fn init(parent: *ParentManagerT) Self {
            return .{ .parent = parent };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .parent_lease = try self.parent.state() };
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.parent.destroyPage(page_id);
        }
    };
}

/// Projects a named field from an exact extern-struct parent state.
pub fn FieldStorageManager(
    comptime ParentManagerT: type,
    comptime ParentStateT: type,
    comptime field_name: []const u8,
) type {
    const FieldT = projectedFieldType(ParentStateT, field_name);
    return ByteRegionStorageManager(
        ParentManagerT,
        @sizeOf(ParentStateT),
        @offsetOf(ParentStateT, field_name),
        @sizeOf(FieldT),
    );
}

/// Projects a named field and delegates page destruction to its parent.
pub fn PagedFieldStorageManager(
    comptime ParentManagerT: type,
    comptime ParentStateT: type,
    comptime field_name: []const u8,
) type {
    const FieldT = projectedFieldType(ParentStateT, field_name);
    return PagedByteRegionStorageManager(
        ParentManagerT,
        @sizeOf(ParentStateT),
        @offsetOf(ParentStateT, field_name),
        @sizeOf(FieldT),
    );
}

/// Projects one indexed element from an exact array parent state.
pub fn ArrayElementStorageManager(
    comptime ParentManagerT: type,
    comptime ParentArrayT: type,
    comptime index: usize,
) type {
    const ElementT = projectedArrayElementType(ParentArrayT, index);
    return ByteRegionStorageManager(
        ParentManagerT,
        @sizeOf(ParentArrayT),
        index * @sizeOf(ElementT),
        @sizeOf(ElementT),
    );
}

/// Projects one indexed array element and delegates page destruction.
pub fn PagedArrayElementStorageManager(
    comptime ParentManagerT: type,
    comptime ParentArrayT: type,
    comptime index: usize,
) type {
    const ElementT = projectedArrayElementType(ParentArrayT, index);
    return PagedByteRegionStorageManager(
        ParentManagerT,
        @sizeOf(ParentArrayT),
        index * @sizeOf(ElementT),
        @sizeOf(ElementT),
    );
}

/// A non-owning exact-state lease over an already-held outer lease.
/// `finish()` and `deinit()` are no-ops; the outer lease owner remains
/// responsible for both calls after all borrowed leases stop being used.
pub fn BorrowedExactStateLease(
    comptime OuterLeaseT: type,
    comptime StateT: type,
) type {
    comptime storage_manager_contract.assertStateLease(OuterLeaseT);
    comptime assertExactStateType(StateT);

    return struct {
        const Self = @This();

        pub const Error = OuterLeaseT.Error || error{BadData};

        outer_lease: *OuterLeaseT,

        pub fn data(self: *const Self) Error![]const u8 {
            const bytes = try self.outer_lease.data();
            if (bytes.len != @sizeOf(StateT)) {
                return error.BadData;
            }
            return bytes;
        }

        pub fn dataMut(self: *Self) Error![]u8 {
            const bytes = try self.outer_lease.dataMut();
            if (bytes.len != @sizeOf(StateT)) {
                return error.BadData;
            }
            return bytes;
        }

        pub fn finish(_: *Self) void {}

        pub fn deinit(_: *Self) void {}
    };
}

/// Adapts an already-held outer lease as a borrowed exact-state manager.
/// The manager and its leases must not outlive the outer lease.
pub fn BorrowedExactStateManager(
    comptime ParentManagerT: type,
    comptime StateT: type,
) type {
    comptime storage_manager_contract.assertStorageManager(ParentManagerT);
    const BorrowedLease = BorrowedExactStateLease(ParentManagerT.StateLeaseType, StateT);

    return struct {
        const Self = @This();

        pub const Error = ParentManagerT.Error || BorrowedLease.Error;
        pub const StateLeaseType = BorrowedLease;

        outer_lease: *ParentManagerT.StateLeaseType,

        pub fn init(outer_lease: *ParentManagerT.StateLeaseType) Self {
            return .{ .outer_lease = outer_lease };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .outer_lease = self.outer_lease };
        }
    };
}

/// Adapts an already-held outer lease as a borrowed exact-state manager and
/// delegates page destruction. The parent manager and outer lease must outlive
/// this manager and all leases obtained from it.
pub fn BorrowedExactPagedStorageManager(
    comptime ParentManagerT: type,
    comptime StateT: type,
) type {
    comptime storage_manager_contract.assertPagedStorageManager(
        ParentManagerT,
        ParentManagerT.PageId,
    );
    const BorrowedLease = BorrowedExactStateLease(ParentManagerT.StateLeaseType, StateT);

    return struct {
        const Self = @This();

        pub const PageId = ParentManagerT.PageId;
        pub const Error = ParentManagerT.Error || BorrowedLease.Error;
        pub const StateLeaseType = BorrowedLease;

        parent: *ParentManagerT,
        outer_lease: *ParentManagerT.StateLeaseType,

        pub fn init(
            parent: *ParentManagerT,
            outer_lease: *ParentManagerT.StateLeaseType,
        ) Self {
            return .{
                .parent = parent,
                .outer_lease = outer_lease,
            };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .outer_lease = self.outer_lease };
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.parent.destroyPage(page_id);
        }
    };
}

fn assertExactStateType(comptime StateT: type) void {
    if (@typeInfo(StateT) != .@"struct" or @typeInfo(StateT).@"struct".layout != .@"extern") {
        @compileError("Storage state must be an extern struct");
    }
    if (@alignOf(StateT) != 1 or @sizeOf(StateT) == 0) {
        @compileError("Storage state must be non-empty and byte-aligned");
    }
}

fn assertByteRegion(
    comptime parent_byte_len: usize,
    comptime byte_offset: usize,
    comptime byte_len: usize,
) void {
    if (parent_byte_len == 0 or byte_len == 0) {
        @compileError("Storage byte regions must be non-empty");
    }
    if (byte_offset > parent_byte_len or byte_len > parent_byte_len - byte_offset) {
        @compileError("Storage byte region exceeds its parent state");
    }
}

fn projectedFieldType(
    comptime ParentStateT: type,
    comptime field_name: []const u8,
) type {
    const info = @typeInfo(ParentStateT);
    if (info != .@"struct" or info.@"struct".layout != .@"extern") {
        @compileError("Projected parent state must be an extern struct");
    }
    if (@alignOf(ParentStateT) != 1 or @sizeOf(ParentStateT) == 0) {
        @compileError("Projected parent state must be non-empty and byte-aligned");
    }
    if (!@hasField(ParentStateT, field_name)) {
        @compileError("Projected parent state has no field named " ++ field_name);
    }

    const FieldT = @FieldType(ParentStateT, field_name);
    if (@sizeOf(FieldT) == 0) {
        @compileError("Projected state field must be non-empty");
    }
    return FieldT;
}

fn projectedArrayElementType(
    comptime ParentArrayT: type,
    comptime index: usize,
) type {
    const info = @typeInfo(ParentArrayT);
    if (info != .array) {
        @compileError("Projected parent state must be an array");
    }
    if (@alignOf(ParentArrayT) != 1 or @sizeOf(ParentArrayT) == 0) {
        @compileError("Projected parent array must be non-empty and byte-aligned");
    }
    if (index >= info.array.len) {
        @compileError("Projected state array index is out of bounds");
    }
    if (@sizeOf(info.array.child) == 0) {
        @compileError("Projected state array element must be non-empty");
    }
    return info.array.child;
}
