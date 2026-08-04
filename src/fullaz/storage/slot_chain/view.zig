const std = @import("std");
const header = @import("../../page/header.zig");
const extensions = @import("../../page/extensions.zig");
const slots = @import("../../slots/variadic.zig");
const links = @import("../../page/links.zig");

const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const LinkTrait = links.Trait(PageIdT, Endian);
    const SlotsDirType = slots.VariadicImpl(IndexT, Endian, read_only, 2);

    _ = SlotsDirType;

    const Additional = extensions.Compose(.{
        .version = 9,
        .fields = .{
            extensions.field("links", LinkTrait),
        },
    });
    const PageHeader = header.HeaderEx(
        PageIdT,
        IndexT,
        Additional.Storage,
        Endian,
    );

    return struct {
        pub const Header = PageHeader;
        pub const Error = error{};
    };
}
