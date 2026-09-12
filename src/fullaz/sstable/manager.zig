const std = @import("std");
const core = @import("../core/core.zig");
const device = @import("../device/device.zig");

const PackedInt = core.packed_int.PackedInt;

pub fn SstableManager(
    comptime Format: type,
    comptime LogT: type,
    comptime cmp: anytype,
    comptime CtxT: type,
) type {
    comptime {
        device.interfaces.assertLogDevice(LogT);
        if (LogT.Offset != Format.Offset) {
            @compileError("SstableManager LogT.Offset must equal Format.Offset");
        }
        if (!@hasDecl(LogT, "truncate")) {
            @compileError("SstableManager LogT must provide truncate(*LogT, LogT.Offset)");
        }
    }

    const PackedOffset = PackedInt(Format.Offset, Format.Endian);
    const PackedLsn = PackedInt(Format.Lsn, Format.Endian);
    const PackedU16 = PackedInt(u16, Format.Endian);
    const PackedU32 = PackedInt(u32, Format.Endian);
    const PackedU64 = PackedInt(u64, Format.Endian);

    const Header = extern struct {
        magic: [8]u8,
        version: PackedU16,
        header_size: PackedU16,
        frame_size: PackedOffset,
        frame_checksum: PackedU32,
        header_checksum: PackedU32,
        generation: PackedU64,
        comparator_id: PackedU32,
        last_assigned_lsn: PackedLsn,
        last_table_id: PackedU64,
        last_published_table_id: PackedU64,
        table_count: PackedOffset,
        offset_bytes: u8,
        page_id_bytes: u8,
        data_index_bytes: u8,
        lsn_bytes: u8,
        endian: u8,
        versioned_keys: u8,
        reserved: [2]u8,
    };

    const TableHeader = extern struct {
        table_id: PackedU64,
        file_size: PackedOffset,
        entry_count: PackedOffset,
        keys_count: PackedOffset,
        min_lsn: PackedLsn,
        max_lsn: PackedLsn,
        first_key_size: PackedU32,
        last_key_size: PackedU32,
    };

    return struct {
        const Self = @This();

        pub const TableId = u64;

        pub const TableInfo = struct {
            table_id: TableId,
            file_size: Format.Offset,
            entry_count: Format.Offset,
            keys_count: Format.Offset,
            min_lsn: Format.Lsn,
            max_lsn: Format.Lsn,
            smallest_key: []const u8,
            largest_key: []const u8,
        };

        pub const Edit = struct {
            added_tables: []const TableInfo = &.{},
            removed_table_ids: []const TableId = &.{},
        };

        pub const Options = struct {
            comparator_id: u32,
        };

        pub const LsnRange = struct {
            first: Format.Lsn,
            last: Format.Lsn,
        };

        pub const TableIdRange = struct {
            first: TableId,
            last: TableId,
        };

        pub const Error = std.mem.Allocator.Error ||
            LogT.Error ||
            error{
                EmptyMetadata,
                BadMagic,
                BadVersion,
                BadFrame,
                BadHeaderChecksum,
                BadChecksum,
                FormatMismatch,
                ComparatorMismatch,
                BadGeneration,
                BadTable,
                DuplicateTable,
                TableNotFound,
                LsnRegression,
                InvalidLsnCount,
                InvalidTableIdCount,
                CountOverflow,
                NoChanges,
                RecoveryRequired,
            };

        const magic = "FULLAZSM";
        const version: u16 = 1;

        const Snapshot = struct {
            generation: u64,
            last_assigned_lsn: Format.Lsn,
            last_table_id: TableId,
            last_published_table_id: TableId,
            tables: std.ArrayList(TableInfo) = .empty,

            fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
                deinitTables(allocator, &self.tables);
            }
        };

        allocator: std.mem.Allocator,
        log: *LogT,
        comparator_id: u32,
        ctx: CtxT,
        generation_: u64 = 0,
        last_assigned_lsn_: Format.Lsn = 0,
        last_table_id_: TableId = 0,
        last_published_table_id_: TableId = 0,
        tables_: std.ArrayList(TableInfo) = .empty,
        recovery_required: bool = false,

        pub fn create(
            allocator: std.mem.Allocator,
            log: *LogT,
            options: Options,
            ctx: CtxT,
        ) Error!Self {
            try log.reset();
            var self: Self = .{
                .allocator = allocator,
                .log = log,
                .comparator_id = options.comparator_id,
                .ctx = ctx,
            };
            errdefer self.deinit();
            try self.appendSnapshot(0, 0, 0, 0, &.{});
            return self;
        }

        pub fn open(
            allocator: std.mem.Allocator,
            log: *LogT,
            options: Options,
            ctx: CtxT,
        ) Error!Self {
            const log_size = std.math.cast(usize, log.size()) orelse {
                return Error.BadFrame;
            };
            if (log_size == 0) {
                return Error.EmptyMetadata;
            }

            var last_snapshot: ?Snapshot = null;
            errdefer if (last_snapshot) |*snapshot| {
                snapshot.deinit(allocator);
            };

            var offset: usize = 0;
            while (offset < log_size) {
                const remaining = log_size - offset;
                if (remaining < @sizeOf(Header)) {
                    if (last_snapshot == null) {
                        return Error.BadFrame;
                    }
                    try repairTail(log, offset);
                    break;
                }

                var header_bytes: [@sizeOf(Header)]u8 = undefined;
                try log.readAt(@intCast(offset), &header_bytes);
                const header: *const Header = @ptrCast(&header_bytes);
                try validateHeader(header, options.comparator_id);

                const frame_size = std.math.cast(usize, header.frame_size.get()) orelse {
                    return Error.BadFrame;
                };
                if (frame_size < @sizeOf(Header)) {
                    return Error.BadFrame;
                }
                if (frame_size > remaining) {
                    if (last_snapshot == null) {
                        return Error.BadFrame;
                    }
                    try repairTail(log, offset);
                    break;
                }

                const frame = try allocator.alloc(u8, frame_size);
                defer allocator.free(frame);
                try log.readAt(@intCast(offset), frame);
                const frame_header: *const Header = @ptrCast(frame.ptr);
                if (frameChecksum(frame) != frame_header.frame_checksum.get()) {
                    return Error.BadChecksum;
                }

                var snapshot = try decodeSnapshot(
                    allocator,
                    frame,
                    options.comparator_id,
                    ctx,
                );
                errdefer snapshot.deinit(allocator);
                if (last_snapshot) |*previous| {
                    const expected_generation = std.math.add(
                        u64,
                        previous.generation,
                        1,
                    ) catch return Error.BadGeneration;
                    if (snapshot.generation != expected_generation) {
                        return Error.BadGeneration;
                    }
                    if (snapshot.last_assigned_lsn < previous.last_assigned_lsn) {
                        return Error.LsnRegression;
                    }
                    if (snapshot.last_table_id < previous.last_table_id or
                        snapshot.last_published_table_id < previous.last_published_table_id)
                    {
                        return Error.BadTable;
                    }
                    previous.deinit(allocator);
                } else if (snapshot.generation != 0) {
                    return Error.BadGeneration;
                }
                last_snapshot = snapshot;
                offset += frame_size;
            }

            const snapshot = last_snapshot orelse return Error.EmptyMetadata;
            try log.sync();
            return .{
                .allocator = allocator,
                .log = log,
                .comparator_id = options.comparator_id,
                .ctx = ctx,
                .generation_ = snapshot.generation,
                .last_assigned_lsn_ = snapshot.last_assigned_lsn,
                .last_table_id_ = snapshot.last_table_id,
                .last_published_table_id_ = snapshot.last_published_table_id,
                .tables_ = snapshot.tables,
            };
        }

        pub fn deinit(self: *Self) void {
            deinitTables(self.allocator, &self.tables_);
        }

        pub fn lastAssignedLsn(self: *const Self) Format.Lsn {
            return self.last_assigned_lsn_;
        }

        pub fn lastAssignedTableId(self: *const Self) TableId {
            return self.last_table_id_;
        }

        /// The returned slice and its key bounds borrow `self` until membership changes.
        pub fn tables(self: *const Self) []const TableInfo {
            return self.tables_.items;
        }

        /// The returned pointer borrows `self` until membership changes.
        pub fn findTable(self: *const Self, table_id: TableId) ?*const TableInfo {
            for (self.tables_.items) |*table| {
                if (table.table_id == table_id) {
                    return table;
                }
            }
            return null;
        }

        pub fn isRecoveryRequired(self: *const Self) bool {
            return self.recovery_required;
        }

        pub fn nextLsn(self: *Self) Error!Format.Lsn {
            return (try self.reserveLsns(1)).first;
        }

        pub fn reserveLsns(self: *Self, count: Format.Lsn) Error!LsnRange {
            if (count == 0) {
                return Error.InvalidLsnCount;
            }
            const first = std.math.add(Format.Lsn, self.last_assigned_lsn_, 1) catch {
                return Error.CountOverflow;
            };
            const last = std.math.add(Format.Lsn, self.last_assigned_lsn_, count) catch {
                return Error.CountOverflow;
            };
            try self.advanceWatermarks(last, self.last_table_id_);
            return .{ .first = first, .last = last };
        }

        pub fn nextTableId(self: *Self) Error!TableId {
            return (try self.reserveTableIds(1)).first;
        }

        pub fn reserveTableIds(self: *Self, count: u64) Error!TableIdRange {
            if (count == 0) {
                return Error.InvalidTableIdCount;
            }
            const first = std.math.add(u64, self.last_table_id_, 1) catch {
                return Error.CountOverflow;
            };
            const last = std.math.add(u64, self.last_table_id_, count) catch {
                return Error.CountOverflow;
            };
            try self.advanceWatermarks(self.last_assigned_lsn_, last);
            return .{ .first = first, .last = last };
        }

        /// Added tables must have completed `Writer.finish()` and have durable names.
        /// Key bounds are inclusive user keys in comparator order and are copied.
        pub fn publish(self: *Self, edit: Edit) Error!void {
            if (self.recovery_required) {
                return Error.RecoveryRequired;
            }
            if (edit.added_tables.len == 0 and edit.removed_table_ids.len == 0) {
                return Error.NoChanges;
            }

            try validateEdit(self, edit);
            var next_tables: std.ArrayList(TableInfo) = .empty;
            errdefer deinitTables(self.allocator, &next_tables);
            const next_table_count = std.math.add(
                usize,
                self.tables_.items.len,
                edit.added_tables.len,
            ) catch return Error.CountOverflow;
            try next_tables.ensureTotalCapacity(
                self.allocator,
                next_table_count,
            );

            for (self.tables_.items) |table| {
                if (!containsId(edit.removed_table_ids, table.table_id)) {
                    next_tables.appendAssumeCapacity(try cloneTable(self.allocator, table));
                }
            }
            for (edit.added_tables) |table| {
                next_tables.appendAssumeCapacity(try cloneTable(self.allocator, table));
            }

            const next_generation = std.math.add(u64, self.generation_, 1) catch {
                return Error.CountOverflow;
            };
            const next_published_table_id = if (edit.added_tables.len == 0)
                self.last_published_table_id_
            else
                edit.added_tables[edit.added_tables.len - 1].table_id;
            try self.appendSnapshot(
                next_generation,
                self.last_assigned_lsn_,
                self.last_table_id_,
                next_published_table_id,
                next_tables.items,
            );

            deinitTables(self.allocator, &self.tables_);
            self.tables_ = next_tables;
            self.generation_ = next_generation;
            self.last_published_table_id_ = next_published_table_id;
        }

        fn advanceWatermarks(
            self: *Self,
            last_assigned_lsn: Format.Lsn,
            last_table_id: TableId,
        ) Error!void {
            if (self.recovery_required) {
                return Error.RecoveryRequired;
            }
            if (last_assigned_lsn < self.last_assigned_lsn_ or
                last_table_id < self.last_table_id_)
            {
                return Error.LsnRegression;
            }
            if (last_assigned_lsn == self.last_assigned_lsn_ and
                last_table_id == self.last_table_id_)
            {
                return Error.NoChanges;
            }
            const next_generation = std.math.add(u64, self.generation_, 1) catch {
                return Error.CountOverflow;
            };
            try self.appendSnapshot(
                next_generation,
                last_assigned_lsn,
                last_table_id,
                self.last_published_table_id_,
                self.tables_.items,
            );
            self.generation_ = next_generation;
            self.last_assigned_lsn_ = last_assigned_lsn;
            self.last_table_id_ = last_table_id;
        }

        fn appendSnapshot(
            self: *Self,
            snapshot_generation: u64,
            last_assigned_lsn: Format.Lsn,
            last_table_id: TableId,
            last_published_table_id: TableId,
            tables_list: []const TableInfo,
        ) Error!void {
            const frame = try encodeSnapshot(
                self.allocator,
                self.comparator_id,
                snapshot_generation,
                last_assigned_lsn,
                last_table_id,
                last_published_table_id,
                tables_list,
            );
            defer self.allocator.free(frame);

            const frame_size: Format.Offset = @intCast(frame.len);
            _ = std.math.add(Format.Offset, self.log.size(), frame_size) catch {
                return Error.CountOverflow;
            };

            self.log.append(frame) catch |err| {
                self.recovery_required = true;
                return err;
            };
            self.log.sync() catch |err| {
                self.recovery_required = true;
                return err;
            };
        }

        fn validateEdit(self: *const Self, edit: Edit) Error!void {
            for (edit.removed_table_ids, 0..) |table_id, index| {
                if (containsId(edit.removed_table_ids[0..index], table_id)) {
                    return Error.DuplicateTable;
                }
                if (self.findTable(table_id) == null) {
                    return Error.TableNotFound;
                }
            }

            var last_added_table_id = self.last_published_table_id_;
            for (edit.added_tables, 0..) |table, index| {
                try validateTable(table, self.last_assigned_lsn_, self.ctx);
                if (containsId(edit.removed_table_ids, table.table_id)) {
                    return Error.DuplicateTable;
                }
                if (self.findTable(table.table_id) != null or
                    containsTable(edit.added_tables[0..index], table.table_id))
                {
                    return Error.DuplicateTable;
                }
                if (table.table_id <= last_added_table_id or
                    table.table_id > self.last_table_id_)
                {
                    return Error.BadTable;
                }
                last_added_table_id = table.table_id;
            }
        }

        fn validateTable(table: TableInfo, last_assigned_lsn: Format.Lsn, ctx: CtxT) Error!void {
            if (table.table_id == 0 or
                table.file_size == 0 or
                table.entry_count == 0 or
                table.keys_count == 0 or
                table.keys_count > table.entry_count or
                table.min_lsn > table.max_lsn or
                table.max_lsn > last_assigned_lsn)
            {
                return Error.BadTable;
            }
            if (!Format.versioned_keys and table.keys_count != table.entry_count) {
                return Error.BadTable;
            }
            switch (cmp(ctx, table.smallest_key, table.largest_key)) {
                .lt, .eq => {},
                else => return Error.BadTable,
            }
            _ = std.math.cast(u32, table.smallest_key.len) orelse return Error.BadTable;
            _ = std.math.cast(u32, table.largest_key.len) orelse return Error.BadTable;
        }

        fn encodeSnapshot(
            allocator: std.mem.Allocator,
            comparator_id: u32,
            snapshot_generation: u64,
            last_assigned_lsn: Format.Lsn,
            last_table_id: TableId,
            last_published_table_id: TableId,
            tables_list: []const TableInfo,
        ) Error![]u8 {
            var frame_size: usize = @sizeOf(Header);
            for (tables_list) |table| {
                frame_size = std.math.add(usize, frame_size, @sizeOf(TableHeader)) catch {
                    return Error.CountOverflow;
                };
                frame_size = std.math.add(usize, frame_size, table.smallest_key.len) catch {
                    return Error.CountOverflow;
                };
                frame_size = std.math.add(usize, frame_size, table.largest_key.len) catch {
                    return Error.CountOverflow;
                };
            }
            const packed_frame_size = std.math.cast(Format.Offset, frame_size) orelse {
                return Error.CountOverflow;
            };
            const table_count = std.math.cast(Format.Offset, tables_list.len) orelse {
                return Error.CountOverflow;
            };

            const frame = try allocator.alloc(u8, frame_size);
            errdefer allocator.free(frame);
            @memset(frame, 0);
            const header: *Header = @ptrCast(frame.ptr);
            header.* = .{
                .magic = magic.*,
                .version = PackedU16.init(version),
                .header_size = PackedU16.init(@sizeOf(Header)),
                .frame_size = PackedOffset.init(packed_frame_size),
                .frame_checksum = PackedU32.init(0),
                .header_checksum = PackedU32.init(0),
                .generation = PackedU64.init(snapshot_generation),
                .comparator_id = PackedU32.init(comparator_id),
                .last_assigned_lsn = PackedLsn.init(last_assigned_lsn),
                .last_table_id = PackedU64.init(last_table_id),
                .last_published_table_id = PackedU64.init(last_published_table_id),
                .table_count = PackedOffset.init(table_count),
                .offset_bytes = @sizeOf(Format.Offset),
                .page_id_bytes = @sizeOf(Format.PageId),
                .data_index_bytes = @sizeOf(Format.DataIndex),
                .lsn_bytes = @sizeOf(Format.Lsn),
                .endian = endianByte(),
                .versioned_keys = @intFromBool(Format.versioned_keys),
                .reserved = .{ 0, 0 },
            };

            var cursor: usize = @sizeOf(Header);
            for (tables_list) |table| {
                const table_header: *TableHeader = @ptrCast(frame[cursor..].ptr);
                table_header.* = .{
                    .table_id = PackedU64.init(table.table_id),
                    .file_size = PackedOffset.init(table.file_size),
                    .entry_count = PackedOffset.init(table.entry_count),
                    .keys_count = PackedOffset.init(table.keys_count),
                    .min_lsn = PackedLsn.init(table.min_lsn),
                    .max_lsn = PackedLsn.init(table.max_lsn),
                    .first_key_size = PackedU32.init(@intCast(table.smallest_key.len)),
                    .last_key_size = PackedU32.init(@intCast(table.largest_key.len)),
                };
                cursor += @sizeOf(TableHeader);
                @memcpy(
                    frame[cursor .. cursor + table.smallest_key.len],
                    table.smallest_key,
                );
                cursor += table.smallest_key.len;
                @memcpy(
                    frame[cursor .. cursor + table.largest_key.len],
                    table.largest_key,
                );
                cursor += table.largest_key.len;
            }
            header.header_checksum.set(headerChecksum(frame[0..@sizeOf(Header)]));
            header.frame_checksum.set(frameChecksum(frame));
            return frame;
        }

        fn decodeSnapshot(
            allocator: std.mem.Allocator,
            frame: []const u8,
            comparator_id: u32,
            ctx: CtxT,
        ) Error!Snapshot {
            const header: *const Header = @ptrCast(frame.ptr);
            try validateHeader(header, comparator_id);
            const frame_size = std.math.cast(usize, header.frame_size.get()) orelse {
                return Error.BadFrame;
            };
            if (frame_size != frame.len) {
                return Error.BadFrame;
            }
            const table_count = std.math.cast(usize, header.table_count.get()) orelse {
                return Error.BadFrame;
            };
            const maximum_table_count = (frame.len - @sizeOf(Header)) / @sizeOf(TableHeader);
            if (table_count > maximum_table_count) {
                return Error.BadFrame;
            }

            var snapshot: Snapshot = .{
                .generation = header.generation.get(),
                .last_assigned_lsn = header.last_assigned_lsn.get(),
                .last_table_id = header.last_table_id.get(),
                .last_published_table_id = header.last_published_table_id.get(),
            };
            errdefer snapshot.deinit(allocator);
            if (snapshot.last_published_table_id > snapshot.last_table_id) {
                return Error.BadTable;
            }
            try snapshot.tables.ensureTotalCapacity(allocator, table_count);

            var cursor: usize = @sizeOf(Header);
            for (0..table_count) |_| {
                if (frame.len - cursor < @sizeOf(TableHeader)) {
                    return Error.BadFrame;
                }
                const table_header: *const TableHeader = @ptrCast(frame[cursor..].ptr);
                cursor += @sizeOf(TableHeader);
                const first_key_size = std.math.cast(
                    usize,
                    table_header.first_key_size.get(),
                ) orelse return Error.BadFrame;
                const last_key_size = std.math.cast(
                    usize,
                    table_header.last_key_size.get(),
                ) orelse return Error.BadFrame;
                const keys_size = std.math.add(usize, first_key_size, last_key_size) catch {
                    return Error.BadFrame;
                };
                if (keys_size > frame.len - cursor) {
                    return Error.BadFrame;
                }
                const smallest_key = frame[cursor .. cursor + first_key_size];
                cursor += first_key_size;
                const largest_key = frame[cursor .. cursor + last_key_size];
                cursor += last_key_size;
                const table: TableInfo = .{
                    .table_id = table_header.table_id.get(),
                    .file_size = table_header.file_size.get(),
                    .entry_count = table_header.entry_count.get(),
                    .keys_count = table_header.keys_count.get(),
                    .min_lsn = table_header.min_lsn.get(),
                    .max_lsn = table_header.max_lsn.get(),
                    .smallest_key = smallest_key,
                    .largest_key = largest_key,
                };
                try validateTable(table, snapshot.last_assigned_lsn, ctx);
                if (table.table_id > snapshot.last_published_table_id) {
                    return Error.BadTable;
                }
                if (containsTable(snapshot.tables.items, table.table_id)) {
                    return Error.DuplicateTable;
                }
                snapshot.tables.appendAssumeCapacity(try cloneTable(allocator, table));
            }
            if (cursor != frame.len) {
                return Error.BadFrame;
            }
            return snapshot;
        }

        fn validateHeader(header: *const Header, comparator_id: u32) Error!void {
            if (header.header_checksum.get() != headerChecksum(std.mem.asBytes(header))) {
                return Error.BadHeaderChecksum;
            }
            if (!std.mem.eql(u8, &header.magic, magic)) {
                return Error.BadMagic;
            }
            if (header.version.get() != version) {
                return Error.BadVersion;
            }
            if (header.header_size.get() != @sizeOf(Header)) {
                return Error.BadFrame;
            }
            if (header.comparator_id.get() != comparator_id) {
                return Error.ComparatorMismatch;
            }
            if (header.offset_bytes != @sizeOf(Format.Offset) or
                header.page_id_bytes != @sizeOf(Format.PageId) or
                header.data_index_bytes != @sizeOf(Format.DataIndex) or
                header.lsn_bytes != @sizeOf(Format.Lsn) or
                header.endian != endianByte() or
                header.versioned_keys != @intFromBool(Format.versioned_keys) or
                header.reserved[0] != 0 or
                header.reserved[1] != 0)
            {
                return Error.FormatMismatch;
            }
        }

        fn cloneTable(allocator: std.mem.Allocator, table: TableInfo) Error!TableInfo {
            const smallest_key = try allocator.dupe(u8, table.smallest_key);
            errdefer allocator.free(smallest_key);
            const largest_key = try allocator.dupe(u8, table.largest_key);
            return .{
                .table_id = table.table_id,
                .file_size = table.file_size,
                .entry_count = table.entry_count,
                .keys_count = table.keys_count,
                .min_lsn = table.min_lsn,
                .max_lsn = table.max_lsn,
                .smallest_key = smallest_key,
                .largest_key = largest_key,
            };
        }

        fn deinitTables(
            allocator: std.mem.Allocator,
            tables_list: *std.ArrayList(TableInfo),
        ) void {
            for (tables_list.items) |table| {
                allocator.free(table.smallest_key);
                allocator.free(table.largest_key);
            }
            tables_list.deinit(allocator);
        }

        fn containsId(table_ids: []const TableId, table_id: TableId) bool {
            return std.mem.indexOfScalar(TableId, table_ids, table_id) != null;
        }

        fn containsTable(tables_list: []const TableInfo, table_id: TableId) bool {
            for (tables_list) |table| {
                if (table.table_id == table_id) {
                    return true;
                }
            }
            return false;
        }

        fn frameChecksum(frame: []const u8) u32 {
            const checksum_offset = @offsetOf(Header, "frame_checksum");
            var crc = std.hash.Crc32.init();
            crc.update(frame[0..checksum_offset]);
            crc.update(frame[checksum_offset + @sizeOf(PackedU32) ..]);
            return crc.final();
        }

        fn headerChecksum(header_bytes: []const u8) u32 {
            const checksums_offset = @offsetOf(Header, "frame_checksum");
            const checksums_size = @sizeOf(PackedU32) * 2;
            var crc = std.hash.Crc32.init();
            crc.update(header_bytes[0..checksums_offset]);
            crc.update(header_bytes[checksums_offset + checksums_size ..]);
            return crc.final();
        }

        fn endianByte() u8 {
            return switch (Format.Endian) {
                .little => 0,
                .big => 1,
            };
        }

        fn repairTail(log: *LogT, offset: usize) Error!void {
            try log.truncate(@intCast(offset));
            try log.sync();
        }
    };
}
