const std = @import("std");

/// An editable byte sequence backed by a weighted B+ tree.
///
/// `TreeT` values are byte chunks and their weights are byte lengths. The
/// facade keeps individual inserted chunks bounded, while the tree supplies
/// O(log chunks) positional lookup and suffix shifting.
pub fn WeightedSeq(
    comptime TreeT: type,
    comptime maximum_chunk_size: usize,
) type {
    const TotalWeightReturn = @typeInfo(@TypeOf(TreeT.totalWeight)).@"fn".return_type.?;
    const TreeError = @typeInfo(TotalWeightReturn).error_union.error_set;
    const WeightT = @typeInfo(TotalWeightReturn).error_union.payload;
    switch (@typeInfo(WeightT)) {
        .int => |info| {
            if (info.signedness != .unsigned) {
                @compileError("WeightedSeq tree weight must be an unsigned integer");
            }
        },
        else => @compileError("WeightedSeq tree weight must be an unsigned integer"),
    }
    if (maximum_chunk_size == 0) {
        @compileError("WeightedSeq maximum_chunk_size must be greater than zero");
    }

    return struct {
        const Self = @This();

        pub const Offset = WeightT;
        pub const PageId = TreeT.PageId;
        pub const Error = TreeError || error{
            OutOfBounds,
            BadChunk,
        };

        tree: *TreeT,

        pub fn init(tree: *TreeT) Self {
            return .{ .tree = tree };
        }

        pub fn size(self: *Self) Error!WeightT {
            return std.math.cast(Offset, try self.tree.totalWeight()) orelse return Error.OutOfBounds;
        }

        pub fn readAt(self: *Self, offset: WeightT, out: []u8) Error!usize {
            const total = try self.size();
            if (offset > total) {
                return Error.OutOfBounds;
            }
            if (offset == total or out.len == 0) {
                return 0;
            }

            var at = (try self.tree.iteratorAtWeight(offset)).?;
            defer at.iterator.deinit();
            var copied: usize = 0;
            var skip = std.math.cast(usize, at.intra_weight) orelse return Error.OutOfBounds;
            while (copied < out.len and !at.iterator.isEnd()) {
                var value = try at.iterator.get();
                defer value.deinit();
                const bytes = try value.get();
                const available = bytes[skip..];
                const count = @min(available.len, out.len - copied);
                @memcpy(out[copied..][0..count], available[0..count]);
                copied += count;
                skip = 0;
                if (copied < out.len) {
                    _ = try at.iterator.next();
                }
            }
            return copied;
        }

        pub fn insert(self: *Self, offset: WeightT, bytes: []const u8) Error!void {
            const total = try self.size();
            if (offset > total) {
                return Error.OutOfBounds;
            }
            try self.insertSegments(offset, &.{bytes});
        }

        pub fn append(self: *Self, bytes: []const u8) Error!void {
            try self.insert(try self.size(), bytes);
        }

        pub fn erase(self: *Self, offset: WeightT, len: WeightT) Error!void {
            try self.replace(offset, len, "");
        }

        pub fn replace(self: *Self, offset: WeightT, removed_len: WeightT, bytes: []const u8) Error!void {
            const total = try self.size();
            const end = std.math.add(WeightT, offset, removed_len) catch return Error.OutOfBounds;
            if (offset > total or end > total) {
                return Error.OutOfBounds;
            }
            if (removed_len == 0) {
                return self.insert(offset, bytes);
            }

            var at = (try self.tree.iteratorAtWeight(offset)).?;
            errdefer at.iterator.deinit();
            var left: [maximum_chunk_size]u8 = undefined;
            var right: [maximum_chunk_size]u8 = undefined;
            var left_len: usize = 0;
            var right_len: usize = 0;
            var removed_entries: usize = 0;
            var entry_start = offset - @as(WeightT, @intCast(at.intra_weight));

            while (true) {
                var value = try at.iterator.get();
                defer value.deinit();
                const chunk = try value.get();
                if (chunk.len > maximum_chunk_size) {
                    return Error.BadChunk;
                }
                if (removed_entries == 0) {
                    left_len = std.math.cast(usize, offset - entry_start) orelse return Error.OutOfBounds;
                    @memcpy(left[0..left_len], chunk[0..left_len]);
                }
                const entry_end = std.math.add(
                    WeightT,
                    entry_start,
                    @intCast(chunk.len),
                ) catch return Error.OutOfBounds;
                removed_entries += 1;
                if (entry_end >= end) {
                    if (entry_end > end) {
                        const suffix_start = std.math.cast(usize, end - entry_start) orelse return Error.OutOfBounds;
                        right_len = chunk.len - suffix_start;
                        @memcpy(right[0..right_len], chunk[suffix_start..]);
                    }
                    break;
                }
                entry_start = entry_end;
                _ = try at.iterator.next();
            }
            at.iterator.deinit();

            const insertion_start = offset - @as(WeightT, @intCast(left_len));
            for (0..removed_entries) |_| {
                try self.tree.removeEntry(insertion_start);
            }
            const segments = [_][]const u8{
                left[0..left_len],
                bytes,
                right[0..right_len],
            };
            try self.insertSegments(insertion_start, &segments);
        }

        pub fn clear(self: *Self) Error!void {
            while (try self.tree.totalWeight() > 0) {
                try self.tree.removeEntry(0);
            }
        }

        pub fn scanInodeRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.tree.scanInodeRefs(page_id, page, visitor);
        }

        pub fn scanLeafRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const NoValueScan = struct {
                sink: @TypeOf(visitor),

                pub fn hasValueScanner(_: @This()) bool {
                    return false;
                }

                pub fn visit(wrapper: @This(), child_page_id: PageId) !void {
                    return wrapper.sink.visit(child_page_id);
                }

                pub fn visitValue(_: @This(), _: []const u8) !void {}
            };
            return self.tree.scanLeafRefs(page_id, page, NoValueScan{ .sink = visitor });
        }

        /// Emits adjacent replacement fragments as maximally sized chunks.
        fn insertSegments(self: *Self, offset: WeightT, segments: []const []const u8) Error!void {
            var chunk: [maximum_chunk_size]u8 = undefined;
            var position = offset;

            var segment_index: usize = 0;
            var segment_offset: usize = 0;

            while (segment_index < segments.len) {
                var chunk_len: usize = 0;
                while ((chunk_len < chunk.len) and (segment_index < segments.len)) {
                    const segment = segments[segment_index];
                    const available = segment.len - segment_offset;
                    const copied = @min(chunk.len - chunk_len, available);

                    @memcpy(chunk[chunk_len..][0..copied], segment[segment_offset..][0..copied]);

                    chunk_len += copied;
                    segment_offset += copied;

                    if (segment_offset == segment.len) {
                        segment_index += 1;
                        segment_offset = 0;
                    }
                }

                if (chunk_len > 0) {
                    _ = try self.tree.insert(position, chunk[0..chunk_len]);
                    position = std.math.add(
                        WeightT,
                        position,
                        std.math.cast(WeightT, chunk_len) orelse return Error.OutOfBounds,
                    ) catch return Error.OutOfBounds;
                }
            }
        }
    };
}
