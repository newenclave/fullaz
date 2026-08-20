const std = @import("std");
const interfaces = @import("../contracts/interfaces.zig");

pub const PageKind = u16;

pub const PageKindRange = struct {
    base: PageKind,
    count: PageKind,

    pub fn kindAt(self: PageKindRange, index: usize) ?PageKind {
        const relative = std.math.cast(PageKind, index) orelse return null;
        if (relative >= self.count) {
            return null;
        }
        return std.math.add(PageKind, self.base, relative) catch null;
    }

    pub fn endExclusive(self: PageKindRange) u32 {
        return @as(u32, self.base) + @as(u32, self.count);
    }
};

pub const Descriptor = struct {
    Trait: type,
};

/// Verifies the static metadata required from a pages component trait.
///
/// ```zig
/// const Trait = struct {
///     pub const kind_name: []const u8 = "example.component";
///     pub const format_version: u32 = 1;
///     pub const page_kind_count: usize = 1;
///     pub const page_roles: [page_kind_count][]const u8 = .{"data"};
///     pub fn Binding(comptime BackendT: type) type {
///         _ = BackendT;
///         return struct {};
///     }
/// };
/// comptime assertTrait(Trait);
/// ```
pub fn assertTrait(comptime TraitT: type) void {
    if (!@hasDecl(TraitT, "kind_name") or @TypeOf(TraitT.kind_name) != []const u8) {
        @compileError("Pages component trait must declare kind_name: []const u8");
    }
    if (TraitT.kind_name.len == 0) {
        @compileError("Pages component kind_name cannot be empty");
    }
    if (!std.unicode.utf8ValidateSlice(TraitT.kind_name) or
        std.mem.indexOfScalar(u8, TraitT.kind_name, 0) != null)
    {
        @compileError("Pages component kind_name must be valid UTF-8 without NUL bytes");
    }
    if (!@hasDecl(TraitT, "format_version") or @TypeOf(TraitT.format_version) != u32) {
        @compileError("Pages component trait must declare format_version: u32");
    }
    if (TraitT.format_version == 0) {
        @compileError("Pages component format_version cannot be zero");
    }
    if (!@hasDecl(TraitT, "page_kind_count") or @TypeOf(TraitT.page_kind_count) != usize) {
        @compileError("Pages component trait must declare page_kind_count: usize");
    }
    if (TraitT.page_kind_count == 0) {
        @compileError("Pages component page_kind_count cannot be zero");
    }
    if (!@hasDecl(TraitT, "page_roles") or
        @TypeOf(TraitT.page_roles) != [TraitT.page_kind_count][]const u8)
    {
        @compileError("Pages component trait page_roles must match page_kind_count");
    }
    inline for (TraitT.page_roles, 0..) |role, index| {
        if (role.len == 0 or !std.unicode.utf8ValidateSlice(role) or
            std.mem.indexOfScalar(u8, role, 0) != null)
        {
            @compileError("Pages component page role must be non-empty UTF-8 without NUL bytes");
        }
        inline for (TraitT.page_roles[0..index]) |previous| {
            if (std.mem.eql(u8, role, previous)) {
                @compileError("Duplicate pages component page role: " ++ role);
            }
        }
    }
    if (!@hasDecl(TraitT, "Binding")) {
        @compileError("Pages component trait must declare Binding(comptime BackendT: type) type");
    }
}

pub fn descriptor(comptime TraitT: type) Descriptor {
    comptime assertTrait(TraitT);
    return .{ .Trait = TraitT };
}

/// Verifies the runtime contract generated for one concrete backend.
///
/// ```zig
/// const Backend = struct {};
/// const Binding = struct {
///     pub const Runtime = struct {};
///     pub const Proxy = Runtime;
///     pub const InitOptions = struct {};
///     pub const Error = error{};
///
///     pub fn initRuntime(
///         runtime: *Runtime,
///         backend: *Backend,
///         page_kinds: PageKindRange,
///         options: InitOptions,
///     ) Error!void {
///         runtime.* = .{};
///         _ = backend;
///         _ = page_kinds;
///         _ = options;
///     }
///     pub fn deinitRuntime(_: *Runtime) void {}
///     pub fn proxy(runtime: *Runtime) *Proxy { return runtime; }
///     pub fn proxyConst(runtime: *const Runtime) *const Proxy { return runtime; }
/// };
/// comptime assertBinding(Binding, Backend);
/// ```
pub fn assertBinding(comptime BindingT: type, comptime BackendT: type) void {
    interfaces.requiresTypeDeclaration(BindingT, "Runtime");
    interfaces.requiresTypeDeclaration(BindingT, "Proxy");
    interfaces.requiresTypeDeclaration(BindingT, "InitOptions");
    interfaces.requiresErrorDeclaration(BindingT, "Error");

    const Runtime = BindingT.Runtime;
    const Proxy = BindingT.Proxy;
    const InitOptions = BindingT.InitOptions;
    const Error = BindingT.Error;
    const options_info = @typeInfo(InitOptions);
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("Pages component binding InitOptions must be a named struct");
    }

    interfaces.requiresFnSignature(
        BindingT,
        "initRuntime",
        fn (*Runtime, *BackendT, PageKindRange, InitOptions) Error!void,
    );
    interfaces.requiresFnSignature(BindingT, "deinitRuntime", fn (*Runtime) void);
    interfaces.requiresFnSignature(BindingT, "proxy", fn (*Runtime) *Proxy);
    interfaces.requiresFnSignature(BindingT, "proxyConst", fn (*const Runtime) *const Proxy);
}

pub fn bindingFor(comptime value: Descriptor, comptime BackendT: type) type {
    comptime assertTrait(value.Trait);
    const binding = value.Trait.Binding(BackendT);
    if (@TypeOf(binding) != type) {
        @compileError("Pages component Binding must return a type");
    }
    const BindingT: type = binding;
    comptime assertBinding(BindingT, BackendT);
    return BindingT;
}
