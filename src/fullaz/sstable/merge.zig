const std = @import("std");
const sstable = @import("sstable.zig");

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
            drop_winning_tombstones: bool = false,
        };

        pub const Error = ReaderT.Error || WriterT.Error || error{
            NoInputs,
            InvalidEstimate,
            ComparatorMismatch,
            OutputKeyTooSmall,
            OutputValueTooSmall,
            CountOverflow,
            UnorderedKey,
            EmptyOutput,
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
                self.key = try allocator.alloc(u8, reader.footer.settings.max_key_bytes);
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
            const target_entry_count = switch (options.entry_count_strategy) {
                .exact_two_pass => try runPass(
                    allocator,
                    inputs,
                    null,
                    output_log,
                    options,
                    0,
                    ctx,
                ),
                .upper_bound => try entryCountUpperBound(inputs),
                .estimate => |count| if (count == 0) {
                    return Error.InvalidEstimate;
                } else count,
            };

            var writer: ?WriterT = null;
            defer if (writer) |*owned_writer| {
                owned_writer.deinit();
            };
            const output_count = try runPass(
                allocator,
                inputs,
                &writer,
                output_log,
                options,
                target_entry_count,
                ctx,
            );
            if (output_count == 0) {
                return Error.EmptyOutput;
            }
            try writer.?.finish();
        }

        fn validateInputs(inputs: []const *ReaderT, options: Options) Error!void {
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

        fn entryCountUpperBound(inputs: []const *ReaderT) Error!usize {
            var count: usize = 0;
            for (inputs) |reader| {
                const entry_count = std.math.cast(usize, reader.footer.entry_count) orelse {
                    return Error.CountOverflow;
                };
                count = std.math.add(usize, count, entry_count) catch {
                    return Error.CountOverflow;
                };
            }
            return count;
        }

        fn runPass(
            allocator: std.mem.Allocator,
            inputs: []const *ReaderT,
            writer: ?*?WriterT,
            output_log: *LogT,
            options: Options,
            target_entry_count: usize,
            ctx: CtxT,
        ) Error!usize {
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

            var output_count: usize = 0;
            while (try smallestCursor(cursors, ctx)) |smallest_index| {
                const key = cursors[smallest_index].current.?.key;
                var winner_index = smallest_index;
                for (cursors, 0..) |*cursor, index| {
                    const entry = cursor.current orelse continue;
                    switch (cmp(ctx, entry.key, key)) {
                        .lt => return Error.UnorderedKey,
                        .eq => {
                            const winner = cursors[winner_index].current.?;
                            if (entry.metadata.lsn > winner.metadata.lsn) {
                                winner_index = index;
                            }
                        },
                        .gt => {},
                        .unordered => return Error.UnorderedKey,
                    }
                }
                const winner = cursors[winner_index].current.?;
                if (!options.drop_winning_tombstones or winner.metadata.flags != .tombstone) {
                    if (writer) |writer_slot| {
                        if (writer_slot.* == null) {
                            writer_slot.* = try WriterT.init(
                                allocator,
                                output_log,
                                .{
                                    .entry_count = target_entry_count,
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
                    output_count = std.math.add(usize, output_count, 1) catch {
                        return Error.CountOverflow;
                    };
                }
                for (cursors, 0..) |*cursor, index| {
                    if (index == smallest_index) {
                        continue;
                    }
                    const entry = cursor.current orelse continue;
                    switch (cmp(ctx, entry.key, key)) {
                        .lt => return Error.UnorderedKey,
                        .eq => try cursor.advance(),
                        .gt => {},
                        .unordered => return Error.UnorderedKey,
                    }
                }
                try cursors[smallest_index].advance();
            }
            return output_count;
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
                switch (cmp(ctx, entry.key, smallest_entry.key)) {
                    .lt => smallest_index = index,
                    .eq, .gt => {},
                    .unordered => return Error.UnorderedKey,
                }
            }
            return smallest_index;
        }
    };
}
