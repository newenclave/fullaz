const std = @import("std");
const interfaces = @import("fullaz").contracts.interfaces;
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");

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
        @compileError("fullaz-db component trait must declare kind_name: []const u8");
    }
    if (TraitT.kind_name.len == 0) {
        @compileError("fullaz-db component kind_name cannot be empty");
    }
    if (!std.unicode.utf8ValidateSlice(TraitT.kind_name) or
        std.mem.indexOfScalar(u8, TraitT.kind_name, 0) != null)
    {
        @compileError("fullaz-db component kind_name must be valid UTF-8 without NUL bytes");
    }
    if (!@hasDecl(TraitT, "format_version") or @TypeOf(TraitT.format_version) != u32) {
        @compileError("fullaz-db component trait must declare format_version: u32");
    }
    if (TraitT.format_version == 0) {
        @compileError("fullaz-db component format_version cannot be zero");
    }
    if (!@hasDecl(TraitT, "page_kind_count") or @TypeOf(TraitT.page_kind_count) != usize) {
        @compileError("fullaz-db component trait must declare page_kind_count: usize");
    }
    if (TraitT.page_kind_count == 0) {
        @compileError("fullaz-db component page_kind_count cannot be zero");
    }
    const maximum_component_page_kinds = std.math.maxInt(PageKind) - 0x0100;
    if (TraitT.page_kind_count > maximum_component_page_kinds) {
        @compileError("fullaz-db component page_kind_count exceeds available page-kind space");
    }
    if (!@hasDecl(TraitT, "page_roles") or
        @TypeOf(TraitT.page_roles) != [TraitT.page_kind_count][]const u8)
    {
        @compileError("fullaz-db component trait page_roles must match page_kind_count");
    }
    inline for (TraitT.page_roles, 0..) |role, index| {
        if (role.len == 0 or !std.unicode.utf8ValidateSlice(role) or
            std.mem.indexOfScalar(u8, role, 0) != null)
        {
            @compileError("fullaz-db component page role must be non-empty UTF-8 without NUL bytes");
        }
        inline for (TraitT.page_roles[0..index]) |previous| {
            if (std.mem.eql(u8, role, previous)) {
                @compileError("Duplicate pages component page role: " ++ role);
            }
        }
    }
    if (!@hasDecl(TraitT, "Binding")) {
        @compileError("fullaz-db component trait must declare Binding(comptime BackendT: type) type");
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
///     pub const ConstProxy = Runtime;
///     pub const InitOptions = struct {};
///     pub const TransactionState = void;
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
///     pub fn captureTransactionState(_: *const Runtime) TransactionState {}
///     pub fn restoreTransactionState(_: *Runtime, _: TransactionState) void {}
///     pub fn proxy(runtime: *Runtime) Proxy { return runtime.*; }
///     pub fn proxyConst(runtime: *const Runtime) *const ConstProxy { return runtime; }
/// };
/// comptime assertBinding(Binding, Backend);
/// ```
///
/// `initRuntime` must release all resources it acquired before returning an
/// error. `TransactionState` must be non-owning and trivially copied; it
/// captures only metadata outside page-cache state, and restoring it must be
/// infallible.
pub fn assertBinding(comptime BindingT: type, comptime BackendT: type) void {
    interfaces.requiresTypeDeclaration(BindingT, "Runtime");
    interfaces.requiresTypeDeclaration(BindingT, "Proxy");
    interfaces.requiresTypeDeclaration(BindingT, "ConstProxy");
    interfaces.requiresTypeDeclaration(BindingT, "InitOptions");
    interfaces.requiresTypeDeclaration(BindingT, "TransactionState");
    interfaces.requiresErrorDeclaration(BindingT, "Error");

    const Runtime = BindingT.Runtime;
    const Proxy = BindingT.Proxy;
    const ConstProxy = BindingT.ConstProxy;
    const InitOptions = BindingT.InitOptions;
    const TransactionState = BindingT.TransactionState;
    const Error = BindingT.Error;
    if (@typeInfo(Error).error_set == null) {
        @compileError("fullaz-db component binding Error cannot be anyerror");
    }
    const options_info = @typeInfo(InitOptions);
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("fullaz-db component binding InitOptions must be a named struct");
    }

    interfaces.requiresFnSignature(
        BindingT,
        "initRuntime",
        fn (*Runtime, *BackendT, PageKindRange, InitOptions) Error!void,
    );
    interfaces.requiresFnSignature(BindingT, "deinitRuntime", fn (*Runtime) void);
    interfaces.requiresFnSignature(
        BindingT,
        "captureTransactionState",
        fn (*const Runtime) TransactionState,
    );
    interfaces.requiresFnSignature(
        BindingT,
        "restoreTransactionState",
        fn (*Runtime, TransactionState) void,
    );
    interfaces.requiresFnSignature(BindingT, "proxy", fn (*Runtime) Proxy);
    interfaces.requiresFnSignature(BindingT, "proxyConst", fn (*const Runtime) *const ConstProxy);
}

/// Verifies persistent root metadata supplied by a concrete component binding.
///
/// ```zig
/// const StaticMetadata = struct {
///     pub const Storage = extern struct { root: PackedPageId };
///     pub const Error = error{BadMetadata};
///     pub fn capture(_: *const Runtime) Storage { return undefined; }
///     pub fn restore(_: *Runtime, _: *const Storage) void {}
///     pub fn validate(_: *const Storage, _: usize) Error!void {}
/// };
/// comptime assertStaticMetadata(Binding, StaticMetadata);
/// ```
pub fn assertStaticMetadata(comptime BindingT: type, comptime MetadataT: type) void {
    interfaces.requiresTypeDeclaration(MetadataT, "Storage");
    interfaces.requiresErrorDeclaration(MetadataT, "Error");
    const Storage = MetadataT.Storage;
    const Error = MetadataT.Error;
    if (@typeInfo(Storage) != .@"struct" or @typeInfo(Storage).@"struct".layout != .@"extern") {
        @compileError("Pages StaticMetadata.Storage must be an extern struct");
    }
    if (@typeInfo(Error).error_set == null) {
        @compileError("Pages StaticMetadata.Error cannot be anyerror");
    }
    interfaces.requiresFnSignature(MetadataT, "capture", fn (*const BindingT.Runtime) Storage);
    interfaces.requiresFnSignature(MetadataT, "restore", fn (*BindingT.Runtime, *const Storage) void);
    interfaces.requiresFnSignature(MetadataT, "validate", fn (*const Storage, usize) Error!void);
}

/// Verifies tagged metadata supplied by a dynamic catalog component binding.
///
/// ```zig
/// const DynamicMetadata = struct {
///     pub const format_version: u32 = 1;
///     pub const known_tags: []const u16 = &.{0x0100};
///     pub const repeated_tags: []const u16 = &.{};
///     pub const Error = fullaz_db.file.dynamic_metadata.Error;
///     pub fn restore(_: *Runtime, _: []const u8, _: usize) Error!void {}
///     pub fn encodeKnown(_: *const Runtime, _: *tagged_fields.Writer) Error!void {}
///     // Optional: emit target fields for an older payload. Call
///     // dynamic_metadata.copyForwardUnknownFields to retain forward fields.
///     pub fn migrate(_: u32, _: []const u8, _: *tagged_fields.Writer) Error!void {}
/// };
/// comptime assertDynamicMetadata(Binding, DynamicMetadata);
/// ```
pub fn assertDynamicMetadata(comptime BindingT: type, comptime MetadataT: type) void {
    if (!@hasDecl(MetadataT, "format_version") or @TypeOf(MetadataT.format_version) != u32) {
        @compileError("fullaz-db DynamicMetadata must declare format_version: u32");
    }
    if (MetadataT.format_version == 0) {
        @compileError("fullaz-db DynamicMetadata format_version cannot be zero");
    }
    if (!@hasDecl(MetadataT, "known_tags") or @TypeOf(MetadataT.known_tags) != []const u16) {
        @compileError("fullaz-db DynamicMetadata must declare known_tags: []const u16");
    }
    inline for (MetadataT.known_tags, 0..) |tag, index| {
        if (tag < 0x0100) {
            @compileError("fullaz-db DynamicMetadata tags must be component tags >= 0x0100");
        }
        inline for (MetadataT.known_tags[0..index]) |previous| {
            if (tag == previous) {
                @compileError("fullaz-db DynamicMetadata known_tags must be unique");
            }
        }
    }
    if (!@hasDecl(MetadataT, "repeated_tags") or @TypeOf(MetadataT.repeated_tags) != []const u16) {
        @compileError("fullaz-db DynamicMetadata must declare repeated_tags: []const u16");
    }
    inline for (MetadataT.repeated_tags, 0..) |tag, index| {
        var known = false;
        inline for (MetadataT.known_tags) |known_tag| {
            known = known or tag == known_tag;
        }
        if (!known) {
            @compileError("fullaz-db DynamicMetadata repeated_tags must be declared in known_tags");
        }
        inline for (MetadataT.repeated_tags[0..index]) |previous| {
            if (tag == previous) {
                @compileError("fullaz-db DynamicMetadata repeated_tags must be unique");
            }
        }
    }
    interfaces.requiresErrorDeclaration(MetadataT, "Error");
    if (MetadataT.Error != dynamic_metadata.Error) {
        @compileError("fullaz-db DynamicMetadata Error must be file.dynamic_metadata.Error");
    }
    interfaces.requiresFnSignature(
        MetadataT,
        "restore",
        fn (*BindingT.Runtime, []const u8, usize) dynamic_metadata.Error!void,
    );
    interfaces.requiresFnSignature(
        MetadataT,
        "encodeKnown",
        fn (*const BindingT.Runtime, *tagged.Writer) dynamic_metadata.Error!void,
    );
    if (@hasDecl(MetadataT, "migrate")) {
        interfaces.requiresFnSignature(
            MetadataT,
            "migrate",
            fn (u32, []const u8, *tagged.Writer) dynamic_metadata.Error!void,
        );
    }
}

pub fn bindingFor(comptime value: Descriptor, comptime BackendT: type) type {
    comptime assertTrait(value.Trait);
    const binding = value.Trait.Binding(BackendT);
    if (@TypeOf(binding) != type) {
        @compileError("fullaz-db component Binding must return a type");
    }
    const BindingT: type = binding;
    comptime assertBinding(BindingT, BackendT);
    return BindingT;
}
