pub fn InPlaceWritePolicy(comptime ContextT: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{};

        pub const WriteBatch = struct {
            pub fn commit(_: *@This()) void {}

            pub fn discard(_: *@This()) void {}
        };

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn begin(
            _: *Self,
            _: ContextT.CacheRefs,
            _: u64,
        ) Error!WriteBatch {
            return .{};
        }

        pub fn prepareCreate(
            _: *Self,
            _: ContextT.CacheRefs,
        ) Error!void {}

        pub fn created(
            _: *Self,
            _: ContextT.HandleTarget,
        ) void {}

        pub fn prepareHandleWrite(
            _: *Self,
            _: ContextT.HandleTarget,
        ) Error!void {}

        pub fn prepareLayoutWrite(
            _: *Self,
            _: ContextT.LayoutTarget,
        ) Error!void {}
    };
}
