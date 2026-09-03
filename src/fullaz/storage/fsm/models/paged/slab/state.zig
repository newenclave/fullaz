const std = @import("std");
const page_chain = @import("../../../../page_chain/page_chain.zig");
const interfaces = @import("../../interfaces.zig");

/// Fixed durable roots for every size class the policy can produce.
pub fn State(
    comptime PageIdT: type,
    comptime SizePolicyT: type,
    comptime Endian: std.builtin.Endian,
) type {
    comptime interfaces.assertSizePolicy(SizePolicyT);
    const ClassState = page_chain.State(PageIdT, void, Endian);
    const Classes = [SizePolicyT.maximum_class_count]ClassState;
    const StateT = extern struct {
        classes: Classes = .{@as(ClassState, .{})} ** SizePolicyT.maximum_class_count,
    };
    comptime {
        if (@alignOf(StateT) != 1 or
            @sizeOf(StateT) == 0 or
            @offsetOf(StateT, "classes") != 0 or
            @sizeOf(StateT) != @sizeOf(Classes) or
            @sizeOf(StateT) != SizePolicyT.maximum_class_count * @sizeOf(ClassState))
        {
            @compileError("Paged slab FSM state layout changed");
        }
    }
    return StateT;
}

pub fn emptyState(
    comptime PageIdT: type,
    comptime SizePolicyT: type,
    comptime Endian: std.builtin.Endian,
) State(PageIdT, SizePolicyT, Endian) {
    const ClassState = page_chain.State(PageIdT, void, Endian);
    return .{
        .classes = .{@as(ClassState, .{})} ** SizePolicyT.maximum_class_count,
    };
}
