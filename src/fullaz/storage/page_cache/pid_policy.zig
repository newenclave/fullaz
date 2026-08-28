pub fn Retain(comptime PageIdT: type) type {
    return struct {
        const Self = @This();

        pub const PageId = PageIdT;
        pub const Error = error{};
        pub const RemapContextType = void;

        pub fn init() Self {
            return .{};
        }

        pub fn prepareRemap(
            _: *Self,
            _: RemapContextType,
            _: PageId,
            _: PageId,
        ) Error!void {}

        pub fn discard(_: *Self) void {}

        pub fn written(_: *Self) void {}
    };
}
