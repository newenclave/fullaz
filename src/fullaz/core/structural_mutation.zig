const std = @import("std");

/// Coordinates single-threaded structural mutations, read handles, and value editors.
pub const Error = error{
    ReadHandleActive,
    ValueEditorActive,
    StructuralMutationActive,
    StaleIterator,
    EditorInvalidated,
};

pub const StructuralMutationCoordinator = struct {
    const Self = @This();

    pub const MutationGuard = struct {
        const GuardSelf = @This();

        coordinator: *Self,
        active: bool = true,

        pub fn deinit(self: *GuardSelf) void {
            if (!self.active) {
                return;
            }
            self.coordinator.structural_mutation_active = false;
            self.active = false;
        }
    };

    structural_generation: u64 = 0,
    read_handle_count: usize = 0,
    value_editor_active: bool = false,
    structural_mutation_active: bool = false,

    pub fn generation(self: *const Self) u64 {
        return self.structural_generation;
    }

    pub fn beginStructuralMutation(self: *Self) Error!MutationGuard {
        if (self.read_handle_count != 0) {
            return error.ReadHandleActive;
        }
        if (self.value_editor_active) {
            return error.ValueEditorActive;
        }
        if (self.structural_mutation_active) {
            return error.StructuralMutationActive;
        }

        self.structural_mutation_active = true;
        self.structural_generation +%= 1;
        return .{ .coordinator = self };
    }

    pub fn beginReadHandle(self: *Self) Error!void {
        if (self.structural_mutation_active) {
            return error.StructuralMutationActive;
        }
        self.read_handle_count += 1;
    }

    pub fn finishReadHandle(self: *Self) void {
        std.debug.assert(self.read_handle_count != 0);
        self.read_handle_count -= 1;
    }

    pub fn beginValueEditor(self: *Self) Error!void {
        if (self.value_editor_active) {
            return error.ValueEditorActive;
        }
        if (self.structural_mutation_active) {
            return error.StructuralMutationActive;
        }

        self.value_editor_active = true;
    }

    pub fn finishValueEditor(self: *Self) void {
        self.value_editor_active = false;
    }

    pub fn checkGeneration(self: *const Self, expected: u64) Error!void {
        if (self.structural_generation != expected) {
            return error.StaleIterator;
        }
    }
};
