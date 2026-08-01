pub const Field = struct {
    name: []const u8,
    Trait: type,
};

pub fn field(comptime name: []const u8, comptime Trait: type) Field {
    comptime {
        if (name.len == 0) {
            @compileError("Page extension field name cannot be empty");
        }
        if (!@hasDecl(Trait, "Storage")) {
            @compileError("Page extension trait must declare Storage: " ++ @typeName(Trait));
        }
        if (@TypeOf(Trait.Storage) != type) {
            @compileError("Page extension trait Storage must be a type: " ++ @typeName(Trait));
        }
    }

    return .{
        .name = name,
        .Trait = Trait,
    };
}
