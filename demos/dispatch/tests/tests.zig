const dispatch = @import("dispatch");

test "dispatch scenario commits every component and rolls back atomically" {
    try dispatch.runMemory(@import("std").testing.allocator);
}
