const std = @import("std");
const fullaz_db = @import("fullaz-db");

test "fullaz-db: DynamicMetadata contract accepts tagged metadata bindings" {
    const Binding = TestBinding(TestBackend);
    const Metadata = struct {
        pub const format_version: u32 = 1;
        pub const known_tags: []const u16 = &.{0x0100};
        pub const repeated_tags: []const u16 = &.{};
        pub const Error = fullaz_db.file.dynamic_metadata.Error;

        pub fn restore(_: *Binding.Runtime, _: []const u8, _: usize) Error!void {}

        pub fn encodeKnown(
            _: *const Binding.Runtime,
            _: *fullaz_db.file.tagged_fields.Writer,
        ) Error!void {}
    };

    comptime fullaz_db.assertDynamicMetadata(Binding, Metadata);
}

const TestBackend = struct {
    initialized: usize = 0,
};

fn TestBinding(comptime BackendT: type) type {
    return struct {
        pub const Proxy = struct {
            value: u32,
        };
        pub const ConstProxy = Proxy;
        pub const Runtime = struct {
            proxy_value: Proxy,
        };
        pub const InitOptions = struct {
            value: u32 = 0,
        };
        pub const TransactionState = Proxy;
        pub const Error = error{InvalidPageKinds};

        pub fn initRuntime(
            runtime: *Runtime,
            backend: *BackendT,
            page_kinds: fullaz_db.PageKindRange,
            options: InitOptions,
        ) Error!void {
            _ = page_kinds.kindAt(0) orelse return Error.InvalidPageKinds;
            runtime.* = .{ .proxy_value = .{ .value = options.value } };
            backend.initialized += 1;
        }

        pub fn deinitRuntime(runtime: *Runtime) void {
            runtime.proxy_value.value = 0;
        }

        pub fn requireTransactionIdle(_: *const Runtime) Error!void {}

        pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
            return runtime.proxy_value;
        }

        pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
            runtime.proxy_value = state;
        }

        pub fn proxy(runtime: *Runtime) Proxy {
            return runtime.proxy_value;
        }

        pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
            return &runtime.proxy_value;
        }
    };
}

const ValidTrait = struct {
    pub const kind_name: []const u8 = "test.component";
    pub const format_version: u32 = 1;
    pub const page_kind_count: usize = 2;
    pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode" };

    pub fn Binding(comptime BackendT: type) type {
        return TestBinding(BackendT);
    }
};

comptime {
    fullaz_db.assertTrait(ValidTrait);
    fullaz_db.assertBinding(ValidTrait.Binding(TestBackend), TestBackend);
}

test "fullaz-db: component descriptor preserves its exact trait" {
    const descriptor = fullaz_db.Descriptor{ .Trait = ValidTrait };
    try std.testing.expect(descriptor.Trait == ValidTrait);
}

test "fullaz-db: page-kind range performs checked lookup" {
    const range = fullaz_db.PageKindRange{ .base = 0x0100, .count = 2 };

    try std.testing.expectEqual(@as(?fullaz_db.PageKind, 0x0100), range.kindAt(0));
    try std.testing.expectEqual(@as(?fullaz_db.PageKind, 0x0101), range.kindAt(1));
    try std.testing.expectEqual(@as(?fullaz_db.PageKind, null), range.kindAt(2));
    try std.testing.expectEqual(@as(u32, 0x0102), range.endExclusive());
}

test "fullaz-db: page-kind range rejects integer overflow" {
    const range = fullaz_db.PageKindRange{
        .base = std.math.maxInt(fullaz_db.PageKind),
        .count = 2,
    };

    try std.testing.expectEqual(@as(?fullaz_db.PageKind, std.math.maxInt(fullaz_db.PageKind)), range.kindAt(0));
    try std.testing.expectEqual(@as(?fullaz_db.PageKind, null), range.kindAt(1));
    try std.testing.expectEqual(@as(?fullaz_db.PageKind, null), range.kindAt(std.math.maxInt(usize)));
}

test "fullaz-db: binding exposes a borrowed typed proxy" {
    const Binding = ValidTrait.Binding(TestBackend);
    var backend = TestBackend{};
    var runtime: Binding.Runtime = undefined;

    try Binding.initRuntime(
        &runtime,
        &backend,
        .{ .base = 0x0100, .count = 2 },
        .{ .value = 42 },
    );
    defer Binding.deinitRuntime(&runtime);

    const proxy = Binding.proxy(&runtime);
    try std.testing.expectEqual(@as(u32, 42), proxy.value);
    try std.testing.expectEqual(@as(usize, 1), backend.initialized);

    const runtime_const: *const Binding.Runtime = &runtime;
    const proxy_const = Binding.proxyConst(runtime_const);
    try std.testing.expect(proxy_const == &runtime.proxy_value);
}
