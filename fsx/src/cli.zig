const std = @import("std");
const inode = @import("inode.zig");

pub fn Cli(comptime FsType: type) type {
    return struct {
        const Self = @This();
        const max_path = 1024;

        fs: *FsType,
        allocator: std.mem.Allocator,
        cwd_buf: [max_path]u8 = undefined,
        cwd_len: usize = 0,

        pub fn init(fs: *FsType, allocator: std.mem.Allocator) Self {
            var self = Self{ .fs = fs, .allocator = allocator };
            self.cwd_buf[0] = '/';
            self.cwd_len = 1;
            return self;
        }

        pub fn cwd(self: *const Self) []const u8 {
            return self.cwd_buf[0..self.cwd_len];
        }

        fn resolve(self: *const Self, arg: []const u8, out: []u8) []const u8 {
            if (arg.len > 0 and arg[0] == '/') {
                @memcpy(out[0..arg.len], arg);
                return out[0..arg.len];
            }
            const c = self.cwd();
            @memcpy(out[0..c.len], c);
            var n = c.len;
            if (c.len != 1) {
                out[n] = '/';
                n += 1;
            }
            @memcpy(out[n .. n + arg.len], arg);
            return out[0 .. n + arg.len];
        }

        fn setCwd(self: *Self, abs: []const u8) void {
            @memcpy(self.cwd_buf[0..abs.len], abs);
            self.cwd_len = abs.len;
        }

        fn cwdUp(self: *Self) void {
            if (self.cwd_len <= 1) {
                return;
            }
            var i = self.cwd_len - 1;
            while (i > 0 and self.cwd_buf[i] != '/') : (i -= 1) {}
            self.cwd_len = if (i == 0) 1 else i;
        }

        pub fn exec(self: *Self, line: []const u8, writer: anytype) !void {
            self.run(line, writer) catch |e| {
                try writer.print("error: {s}\n", .{@errorName(e)});
            };
        }

        fn run(self: *Self, line: []const u8, writer: anytype) !void {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) {
                return;
            }
            const sp = std.mem.indexOfScalar(u8, trimmed, ' ');
            const cmd = if (sp) |i| trimmed[0..i] else trimmed;
            const rest = if (sp) |i| std.mem.trimStart(u8, trimmed[i + 1 ..], " ") else "";
            const sp2 = std.mem.indexOfScalar(u8, rest, ' ');
            const arg1 = if (sp2) |i| rest[0..i] else rest;
            const rest2 = if (sp2) |i| rest[i + 1 ..] else "";

            var scratch: [max_path]u8 = undefined;

            if (std.mem.eql(u8, cmd, "pwd")) {
                try writer.print("{s}\n", .{self.cwd()});
            } else if (std.mem.eql(u8, cmd, "help")) {
                try writer.writeAll(help_text);
            } else if (std.mem.eql(u8, cmd, "cd")) {
                try self.cmdCd(arg1, &scratch);
            } else if (std.mem.eql(u8, cmd, "ls")) {
                try self.cmdLs(arg1, &scratch, writer);
            } else if (std.mem.eql(u8, cmd, "mkdir")) {
                try self.fs.mkdir(self.resolve(arg1, &scratch));
            } else if (std.mem.eql(u8, cmd, "rmdir")) {
                try self.fs.rmdir(self.resolve(arg1, &scratch));
            } else if (std.mem.eql(u8, cmd, "touch")) {
                try self.fs.touch(self.resolve(arg1, &scratch));
            } else if (std.mem.eql(u8, cmd, "rm")) {
                try self.fs.rm(self.resolve(arg1, &scratch));
            } else if (std.mem.eql(u8, cmd, "write")) {
                _ = try self.fs.write(self.resolve(arg1, &scratch), rest2);
            } else if (std.mem.eql(u8, cmd, "cat")) {
                try self.cmdCat(arg1, &scratch, writer);
            } else if (std.mem.eql(u8, cmd, "stat")) {
                try self.cmdStat(arg1, &scratch, writer);
            } else {
                try writer.print("unknown command: {s}\n", .{cmd});
            }
        }

        fn cmdCd(self: *Self, arg: []const u8, scratch: []u8) !void {
            if (arg.len == 0 or std.mem.eql(u8, arg, "/")) {
                self.cwd_buf[0] = '/';
                self.cwd_len = 1;
                return;
            }
            if (std.mem.eql(u8, arg, ".")) {
                return;
            }
            if (std.mem.eql(u8, arg, "..")) {
                self.cwdUp();
                return;
            }
            const abs = self.resolve(arg, scratch);
            const node = (try self.fs.resolve(abs)) orelse return error.NotFound;
            switch (node) {
                .dir => {},
                .file => return error.NotADirectory,
            }
            self.setCwd(abs);
        }

        fn cmdLs(self: *Self, arg: []const u8, scratch: []u8, writer: anytype) !void {
            const path = if (arg.len == 0) self.cwd() else self.resolve(arg, scratch);
            const P = struct {
                fn cb(w: @TypeOf(writer), name: []const u8, node: inode.Inode) anyerror!void {
                    try w.writeAll(name);
                    switch (node) {
                        .dir => try w.writeAll("/"),
                        .file => {},
                    }
                    try w.writeAll("\n");
                }
            };
            try self.fs.ls(path, writer, P.cb);
        }

        fn cmdCat(self: *Self, arg: []const u8, scratch: []u8, writer: anytype) !void {
            const path = self.resolve(arg, scratch);
            const sz = try self.fs.size(path);
            const buf = try self.allocator.alloc(u8, sz);
            defer self.allocator.free(buf);
            const r = try self.fs.read(path, buf);
            try writer.writeAll(buf[0..r]);
            try writer.writeAll("\n");
        }

        fn cmdStat(self: *Self, arg: []const u8, scratch: []u8, writer: anytype) !void {
            const path = self.resolve(arg, scratch);
            const s = try self.fs.stat(path);
            const kind_str = switch (s.kind) {
                .file => "file",
                .dir => "dir",
            };
            try writer.print("{s} size={d}\n", .{ kind_str, s.size });
        }

        const help_text =
            \\commands: pwd cd ls mkdir rmdir touch rm write cat stat help quit
            \\
        ;
    };
}
