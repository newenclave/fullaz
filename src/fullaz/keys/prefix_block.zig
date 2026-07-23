const std = @import("std");
const algo = @import("../core/algorithm.zig");
const errors = @import("../core/errors.zig");

pub fn PrefixInfo(comptime T: type) type {
    return struct {
        const Self = @This();
        const Error = std.mem.Allocator.Error;
        common: usize,
        suffix: []const T,
        pub fn initAlloc(allocator: std.mem.Allocator, common: usize, suffix: []const T) Error!Self {
            const value = try allocator.alloc(T, suffix.len);
            @memcpy(value, suffix);
            return Self{
                .common = common,
                .suffix = value,
            };
        }

        pub fn deinitAlloc(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.suffix);
            self.* = undefined;
        }
    };
}

const ErrorSet = error{InvalidPrefix} ||
    errors.SpaceError || std.mem.Allocator.Error;

pub fn calculateDataLength(
    comptime T: type,
    base: []const T,
    prefix_infos: []const PrefixInfo(T),
) usize {
    var len = base.len;

    for (prefix_infos) |info| {
        len += info.suffix.len;
    }
    return len;
}

pub fn calculateDataSize(
    comptime T: type,
    base: []const T,
    prefix_infos: []const PrefixInfo(T),
) usize {
    return calculateDataLength(T, base, prefix_infos) * @sizeOf(T);
}

fn maxKeyLength(
    comptime T: type,
    base: []const T,
    prefix_infos: []const PrefixInfo(T),
) usize {
    var max = base.len;
    for (prefix_infos) |*info| {
        // if (info.common > std.math.maxInt(usize) - info.suffix.len) {
        //     return Error.InvalidPrefix;
        // }
        max = @max(max, info.common + info.suffix.len);
    }
    return max;
}

pub fn buildValue(
    comptime T: type,
    prefix_info: PrefixInfo(T),
    base: []const T,
    output: []T,
) ErrorSet![]const T {
    if (prefix_info.common > base.len) {
        return ErrorSet.InvalidPrefix;
    }

    if (prefix_info.common > output.len) {
        return ErrorSet.BufferTooSmall;
    }

    @memcpy(
        output[0..prefix_info.common],
        base[0..prefix_info.common],
    );

    return updateValue(T, prefix_info, output);
}

pub fn updateValue(
    comptime T: type,
    prefix_info: PrefixInfo(T),
    output: []T,
) ErrorSet![]const T {
    if (prefix_info.common > output.len) {
        return ErrorSet.BufferTooSmall;
    }

    if (prefix_info.suffix.len > output.len - prefix_info.common) {
        return ErrorSet.BufferTooSmall;
    }

    const full_size = prefix_info.common + prefix_info.suffix.len;

    @memcpy(
        output[prefix_info.common..full_size],
        prefix_info.suffix,
    );

    return output[0..full_size];
}

pub fn SimpleBuildStrategy(comptime T: type) type {
    const PrefixInfoImpl = PrefixInfo(T);
    return struct {
        pub const Error = error{};
        pub fn build(tmp: []const T, _: []const PrefixInfoImpl, _: []T) error{}![]const T {
            return tmp;
        }
    };
}

pub fn ChainedBuildStrategy(comptime T: type) type {
    const PrefixInfoImpl = PrefixInfo(T);

    return struct {
        pub const Error = ErrorSet;

        pub fn build(
            tmp: []const T,
            block: []const PrefixInfoImpl,
            tmp_buf: []T,
        ) Error![]const T {
            if (tmp.len > tmp_buf.len) {
                return Error.BufferTooSmall;
            }

            @memcpy(tmp_buf[0..tmp.len], tmp);
            var size = tmp.len;

            for (block) |*info| {
                const next = try updateValue(
                    T,
                    info.*,
                    tmp_buf[0..],
                );
                size = next.len;
            }

            return tmp_buf[0..size];
        }
    };
}

pub fn PrefixBlockImpl(
    comptime T: type,
    comptime BuildStrategy: type,
    comptime cmp: anytype,
    comptime Ctx: type,
) type {
    const PrefixInfoImpl = PrefixInfo(T);

    const ReaderImpl = struct {
        const Self = @This();

        pub const Error = BuildStrategy.Error ||
            errors.SpaceError ||
            errors.IndexError;

        const Context = struct {
            allocator: std.mem.Allocator,
            block: []const PrefixInfoImpl,
            base: []const T,
            max_key: usize,
        };

        context: Context = undefined,

        pub const Iterator = struct {
            const Itr = @This();
            const ItrError = Self.Error || errors.IteratorError;

            index: usize,
            reader: *const Self,
            buffer: []T = undefined,
            len: usize = 0,

            pub fn init(parent: *const Self, buffer: []T, init_len: usize) Itr {
                return Itr{
                    .index = 0,
                    .reader = parent,
                    .buffer = buffer,
                    .len = init_len,
                };
            }

            pub fn deinit(self: *Itr) void {
                self.reader.context.allocator.free(self.buffer);
                self.* = undefined;
            }

            pub fn current(self: *const Itr) []const T {
                return self.buffer[0..self.len];
            }

            pub fn isDone(self: *const Itr) bool {
                return (self.index == 0 and self.reader.context.block.len == 0) or
                    (self.index >= self.reader.context.block.len);
            }

            pub fn advance(self: *Itr) ItrError!bool {
                if (self.index >= self.reader.context.block.len) {
                    return ItrError.EndOfIterator;
                }

                const info = self.reader.context.block[self.index];

                if (info.common > self.len) {
                    return ItrError.InvalidPrefix;
                }

                const slice = try updateValue(T, info, self.buffer);

                self.index += 1;
                self.len = slice.len;

                return self.index < self.reader.context.block.len;
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            init_base: []const T,
            block: []const PrefixInfoImpl,
        ) Self {
            return Self{
                .context = .{
                    .allocator = allocator,
                    .base = init_base,
                    .block = block,
                    .max_key = maxKeyLength(T, init_base, block),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn iterator(self: *const Self) Error!Iterator {
            const len = self.context.max_key;
            const buffer = try self.context.allocator.alloc(T, len);
            const tmp_len = self.context.base.len;
            @memcpy(buffer[0..tmp_len], self.context.base);
            return Iterator.init(self, buffer, tmp_len);
        }

        pub fn iteratorFrom(self: *const Self, pos: usize) Error!Iterator {
            if (pos == 0) {
                return self.iterator();
            }

            if (pos > self.context.block.len) {
                return Error.OutOfBounds;
            }

            const len = self.context.max_key;
            const buffer = try self.context.allocator.alloc(T, len);
            errdefer self.context.allocator.free(buffer);

            const tmp_len = self.context.base.len;
            @memcpy(buffer[0..tmp_len], self.context.base);

            const ready = try BuildStrategy.build(self.context.base, self.context.block[0..pos], buffer);
            var res = Iterator.init(self, buffer, ready.len);
            res.index = pos;
            return res;
        }

        pub fn iteratorDeinit(self: *const Self, itr: *Iterator) void {
            self.context.allocator.free(itr.buffer);
            itr.* = undefined;
        }

        pub fn size(self: *const Self) usize {
            return self.context.block.len + 1;
        }

        pub fn base(self: *const Self) []const T {
            return self.context.base;
        }

        pub fn get(self: *const Self, index: usize, output: []T) Error![]const T {
            if (index == 0) {
                return self.context.base;
            }

            if (index > self.context.block.len) {
                return Error.OutOfBounds;
            }

            _ = try BuildStrategy.build(
                self.context.base,
                self.context.block[0 .. index - 1],
                output,
            );
            return try updateValue(T, self.context.block[index - 1], output);
        }
    };

    const BuilderImpl = struct {
        const Self = @This();

        const Context = struct {
            allocator: std.mem.Allocator,
            base: []const T,
            output: []PrefixInfoImpl,
            cur: usize,
            ctx: Ctx,
            max_key: usize = 0,
        };

        context: Context = undefined,

        pub const Error = errors.SpaceError ||
            BuildStrategy.Error ||
            ErrorSet;

        pub fn initWithContext(
            allocator: std.mem.Allocator,
            tmp: []const T,
            output: []PrefixInfoImpl,
            ctx: Ctx,
        ) Self {
            return Self{
                .context = .{
                    .allocator = allocator,
                    .base = tmp,
                    .output = output,
                    .cur = 0,
                    .ctx = ctx,
                    .max_key = tmp.len,
                },
            };
        }

        pub fn impl(allocator: std.mem.Allocator, tmp: []const T, output: []PrefixInfoImpl) Self {
            if (Ctx != void) {
                @compileError("PrefixBuilder: a non-void context requires initWithContext");
            }
            return initWithContext(allocator, tmp, output, {});
        }

        fn freeCurrent(self: *Self) void {
            for (self.context.output[0..self.context.cur]) |*info| {
                info.deinitAlloc(self.context.allocator);
            }
        }

        pub fn deinit(self: *Self) void {
            self.freeCurrent();
            self.* = undefined;
        }

        pub fn reader(self: *const Self) ReaderImpl {
            return ReaderImpl.init(
                self.context.allocator,
                self.context.base,
                self.context.output[0..self.context.cur],
            );
        }

        pub fn size(self: *const Self) usize {
            return self.context.cur + 1;
        }

        pub fn add(self: *Self, next: []const T) Error!void {
            if (self.context.cur >= self.context.output.len) {
                return Error.BufferTooSmall;
            }

            self.context.max_key = @max(self.context.max_key, next.len);

            const tmp_buf = try self.context.allocator.alloc(T, self.context.max_key);
            defer self.context.allocator.free(tmp_buf);

            const tmp = try BuildStrategy.build(self.context.base, self.current(), tmp_buf);

            const common = try algo.commonPrefixLength(
                T,
                tmp,
                next,
                cmp,
                self.context.ctx,
            );
            const suffix = next[common..];
            self.context.output[self.context.cur] = try PrefixInfoImpl.initAlloc(
                self.context.allocator,
                common,
                suffix,
            );
            self.context.cur += 1;
        }

        pub fn canAdd(self: *Self, _: []const T) bool {
            if (self.context.cur >= self.context.output.len) {
                return false;
            }
            return true;
        }

        pub fn reset(self: *Self) void {
            self.freeCurrent();
            self.context.cur = 0;
        }

        pub fn current(self: *Self) []PrefixInfoImpl {
            return self.context.output[0..self.context.cur];
        }
    };

    return struct {
        pub const Value = []const T;
        pub const Builder = BuilderImpl;
        pub const Reader = ReaderImpl;
        pub const PrefixInfo = PrefixInfoImpl;
    };
}

const StrCmp = struct {
    pub fn cmp(_: void, a: u8, b: u8) algo.Order {
        if (a < b) {
            return .lt;
        } else if (b < a) {
            return .gt;
        } else {
            return .eq;
        }
    }
};

pub const StringPrefixBlock = PrefixBlockImpl(u8, ChainedBuildStrategy(u8), StrCmp.cmp, void);
