const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const dispatch = @import("dispatch");

const Device = fullaz.device.FileBlock(u32);
const Log = fullaz.device.FileLog(u32);
const Database = fullaz_db.StaticDatabaseWithWal(dispatch.Schema, Device, Log);

pub fn main(init: std.process.Init) !void {
    const image_path = "dispatch.img";
    const log_path = "dispatch.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x44} ** 16,
        .components = .{
            .orders = .{},
            .by_status_due = .{},
            .service_areas = .{},
            .dispatch_queue = .{},
            .audit_log = .{},
            .runbook = .{},
        },
    };

    std.Io.Dir.cwd().deleteFile(init.io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(init.io, log_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(init.io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(init.io, log_path) catch {};

    var database = try Database.format(
        init.gpa,
        try Device.create(init.io, image_path, 512),
        try Log.create(init.io, log_path),
        options,
    );
    defer database.deinit();
    try dispatch.run(Database, &database);

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll("dispatch WAL scenario: verified\n");
    try stdout_writer.interface.flush();
}
