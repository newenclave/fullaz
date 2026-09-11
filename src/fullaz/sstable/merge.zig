const std = @import("std");
const sstable = @import("sstable.zig");
const errors = @import("errors.zig");

pub fn Merger(
    comptime Format: type,
    comptime LogT: type,
    comptime cmp: anytype,
    comptime CtxT: type,
) type {
    const ReaderT = sstable.Reader(Format, LogT, cmp, CtxT);
    const WriterT = sstable.Writer(Format, LogT, cmp, CtxT);

    return struct {
        const Self = @This();

        pub const EntryCountStrategy = union(enum) {
            exact_two_pass,
            upper_bound,
            estimate: usize,
        };

        pub const Options = struct {
            comparator_id: u32,
            settings: sstable.Settings = .{},
            entry_count_strategy: EntryCountStrategy = .upper_bound,
            /// Optional override for the Bloom sizing hint.
            keys_count: ?usize = null,
            drop_winning_tombstones: bool = false,
        };

        pub const Error = ReaderT.Error || WriterT.Error || errors.Merger;

        const Counts = struct {
            entry_count: usize = 0,
            keys_count: usize = 0,
        };

        const Cursor = struct {
            reader: *ReaderT,
            data_page: []u8,
            key: []u8,
            scratch: ReaderT.ReadScratchType,
            iterator: ReaderT.Iterator,
            current: ?ReaderT.ScanEntry,

            fn init(
                self: *Cursor,
                allocator: std.mem.Allocator,
                reader: *ReaderT,
            ) Error!void {
                self.reader = reader;
                self.data_page = try allocator.alloc(
                    u8,
                    reader.footer.settings.data_page_bytes,
                );
                errdefer allocator.free(self.data_page);
                self.key = try allocator.alloc(
                    u8,
                    reader.scratchRequirements().key_bytes,
                );
                errdefer allocator.free(self.key);
                self.scratch = .{
                    .data_page = self.data_page,
                    .key = self.key,
                };
                self.iterator = try reader.iterator(&self.scratch);
                self.current = try self.iterator.next();
            }

            fn deinit(self: *Cursor, allocator: std.mem.Allocator) void {
                allocator.free(self.key);
                allocator.free(self.data_page);
            }

            fn advance(self: *Cursor) Error!void {
                self.current = try self.iterator.next();
            }
        };

        pub fn run(
            allocator: std.mem.Allocator,
            inputs: []const *ReaderT,
            output_log: *LogT,
            options: Options,
            ctx: CtxT,
        ) Error!void {
            try validateInputs(inputs, options);
            var target_counts: Counts = switch (options.entry_count_strategy) {
                .exact_two_pass => try runPass(
                    allocator,
                    inputs,
                    null,
                    output_log,
                    options,
                    .{},
                    ctx,
                ),
                .upper_bound => try countsUpperBound(inputs),
                .estimate => |count| if (count == 0) {
                    return Error.InvalidEstimate;
                } else .{ .entry_count = count, .keys_count = count },
            };
            if (options.keys_count) |keys_count| {
                target_counts.keys_count = keys_count;
            }

            var writer: ?WriterT = null;
            defer if (writer) |*owned_writer| {
                owned_writer.deinit();
            };
            const output_counts = try runPass(
                allocator,
                inputs,
                &writer,
                output_log,
                options,
                target_counts,
                ctx,
            );
            if (output_counts.entry_count == 0) {
                return Error.EmptyOutput;
            }
            try writer.?.finish();
        }

        fn validateInputs(inputs: []const *ReaderT, options: Options) Error!void {
            if (options.keys_count == 0) {
                return Error.InvalidSettings;
            }
            if (Format.versioned_keys and options.drop_winning_tombstones) {
                return Error.InvalidSettings;
            }
            if (inputs.len == 0) {
                return Error.NoInputs;
            }
            for (inputs) |reader| {
                if (reader.footer.comparator_id != options.comparator_id) {
                    return Error.ComparatorMismatch;
                }
                if (reader.footer.settings.max_key_bytes > options.settings.max_key_bytes) {
                    return Error.OutputKeyTooSmall;
                }
                if (reader.footer.settings.max_value_bytes > options.settings.max_value_bytes) {
                    return Error.OutputValueTooSmall;
                }
            }
        }

        fn countsUpperBound(inputs: []const *ReaderT) Error!Counts {
            var counts: Counts = .{};
            for (inputs) |reader| {
                const entry_count = std.math.cast(usize, reader.footer.entry_count) orelse {
                    return Error.CountOverflow;
                };
                const keys_count = std.math.cast(usize, reader.footer.keys_count) orelse {
                    return Error.CountOverflow;
                };
                counts.entry_count = std.math.add(usize, counts.entry_count, entry_count) catch {
                    return Error.CountOverflow;
                };
                counts.keys_count = std.math.add(usize, counts.keys_count, keys_count) catch {
                    return Error.CountOverflow;
                };
            }
            return counts;
        }

        fn runPass(
            allocator: std.mem.Allocator,
            inputs: []const *ReaderT,
            writer: ?*?WriterT,
            output_log: *LogT,
            options: Options,
            target_counts: Counts,
            ctx: CtxT,
        ) Error!Counts {
            const cursors = try allocator.alloc(Cursor, inputs.len);
            defer allocator.free(cursors);
            var initialized: usize = 0;
            defer {
                for (cursors[0..initialized]) |*cursor| {
                    cursor.deinit(allocator);
                }
            }
            for (inputs, cursors) |reader, *cursor| {
                try cursor.init(allocator, reader);
                initialized += 1;
            }

            var output_counts: Counts = .{};
            // Cursor keys are borrowed and change on advance.
            var previous_key: std.ArrayList(u8) = .empty;
            defer previous_key.deinit(allocator);
            while (try smallestCursor(cursors, ctx)) |smallest_index| {
                const smallest_entry = cursors[smallest_index].current.?;
                var winner_index = smallest_index;
                for (cursors, 0..) |*cursor, index| {
                    const entry = cursor.current orelse continue;
                    const order = compareEntries(ctx, entry, smallest_entry);
                    if (order == .lt) {
                        return Error.UnorderedKey;
                    } else if (order == .eq) {
                        const winner = cursors[winner_index].current.?;
                        if (entry.metadata.lsn > winner.metadata.lsn) {
                            winner_index = index;
                        }
                    } else if (order != .gt) {
                        return Error.UnorderedKey;
                    }
                }
                const winner = cursors[winner_index].current.?;
                if (!options.drop_winning_tombstones or winner.metadata.flags != .tombstone) {
                    const new_key = output_counts.entry_count == 0 or
                        cmp(ctx, previous_key.items, winner.key) != .eq;
                    const entry_count = std.math.add(usize, output_counts.entry_count, 1) catch {
                        return Error.CountOverflow;
                    };
                    const keys_count = std.math.add(
                        usize,
                        output_counts.keys_count,
                        @intFromBool(new_key),
                    ) catch return Error.CountOverflow;
                    _ = std.math.cast(Format.Offset, entry_count) orelse return Error.CountOverflow;
                    _ = std.math.cast(Format.Offset, keys_count) orelse return Error.CountOverflow;
                    if (new_key) {
                        try previous_key.ensureTotalCapacity(allocator, winner.key.len);
                        previous_key.clearRetainingCapacity();
                        previous_key.appendSliceAssumeCapacity(winner.key);
                    }
                    if (writer) |writer_slot| {
                        if (writer_slot.* == null) {
                            writer_slot.* = try WriterT.init(
                                allocator,
                                output_log,
                                .{
                                    .entry_count = target_counts.entry_count,
                                    .keys_count = target_counts.keys_count,
                                    .enforce_entry_count = switch (options.entry_count_strategy) {
                                        .exact_two_pass => true,
                                        .upper_bound, .estimate => false,
                                    },
                                    .comparator_id = options.comparator_id,
                                    .settings = options.settings,
                                },
                                ctx,
                            );
                        }
                        try (writer_slot.*).?.addWithMetadata(
                            winner.key,
                            winner.value,
                            winner.metadata,
                        );
                    }
                    output_counts = .{ .entry_count = entry_count, .keys_count = keys_count };
                }
                for (cursors, 0..) |*cursor, index| {
                    if (index == smallest_index) {
                        continue;
                    }
                    const entry = cursor.current orelse continue;
                    const order = compareEntries(ctx, entry, smallest_entry);
                    if (order == .lt) {
                        return Error.UnorderedKey;
                    } else if (order == .eq) {
                        try cursor.advance();
                    } else if (order != .gt) {
                        return Error.UnorderedKey;
                    }
                }
                try cursors[smallest_index].advance();
            }
            return output_counts;
        }

        fn smallestCursor(cursors: []const Cursor, ctx: CtxT) Error!?usize {
            var smallest_index: ?usize = null;
            for (cursors, 0..) |cursor, index| {
                const entry = cursor.current orelse continue;
                const smallest = smallest_index orelse {
                    smallest_index = index;
                    continue;
                };
                const smallest_entry = cursors[smallest].current.?;
                const order = compareEntries(ctx, entry, smallest_entry);
                if (order == .lt) {
                    smallest_index = index;
                } else if (order != .eq and order != .gt) {
                    return Error.UnorderedKey;
                }
            }
            return smallest_index;
        }

        fn compareEntries(ctx: CtxT, a: ReaderT.ScanEntry, b: ReaderT.ScanEntry) std.math.Order {
            const order = cmp(ctx, a.key, b.key);
            if (!Format.versioned_keys or order != .eq) {
                return order;
            }
            return std.math.order(b.metadata.lsn, a.metadata.lsn);
        }
    };
}
