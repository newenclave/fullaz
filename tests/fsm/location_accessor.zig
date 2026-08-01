const fullaz = @import("fullaz");

const TestLocation = struct {
    page_id: u32,
    slot_id: u16,
};

const TestAccessor = struct {
    pub const Location = TestLocation;
    pub const Error = error{};

    pub fn read(_: []const u8) Error!?Location {
        return null;
    }

    pub fn write(_: []u8, _: Location) Error!void {}

    pub fn clear(_: []u8) Error!void {}
};

test "FSM location accessor contract accepts static page accessors" {
    comptime fullaz.storage.fsm.location_accessor.assertAccessor(TestAccessor);
}
