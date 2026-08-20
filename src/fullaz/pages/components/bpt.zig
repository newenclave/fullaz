const std = @import("std");
const component = @import("../component.zig");
const algorithm = @import("../../core/algorithm.zig");
const interfaces = @import("../../contracts/interfaces.zig");
const page_cache_contract = @import("../../contracts/page_cache.zig");
const low_level_bpt = @import("../../bpt/bpt.zig");

fn Manager(comptime BackendT: type) type {
    @setEvalBranchQuota(10_000);
    interfaces.requiresTypeDeclaration(BackendT, "PageId");
    interfaces.requiresTypeDeclaration(BackendT, "CacheType");
    const PageIdT = BackendT.PageId;
    const CacheT = BackendT.CacheType;
    comptime page_cache_contract.requiresPageCache(CacheT);
    if (PageIdT != CacheT.Pid) {
        @compileError("Pages backend PageId must match CacheType.Pid");
    }
    interfaces.requiresFnSignature(BackendT, "cache", fn (*BackendT) *CacheT);
    interfaces.requiresFnSignature(CacheT, "free", fn (*CacheT, PageIdT) CacheT.Error!void);

    return struct {
        const Self = @This();

        pub const PageId = PageIdT;
        pub const Error = CacheT.Error;

        cache_ptr: *CacheT,
        root: ?PageId = null,

        pub fn init(backend: *BackendT) Self {
            return .{ .cache_ptr = backend.cache() };
        }

        pub fn getRoot(self: *const Self) ?PageId {
            return self.root;
        }

        pub fn setRoot(self: *Self, root: ?PageId) Error!void {
            self.root = root;
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.cache_ptr.free(page_id);
        }
    };
}

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing pages.bpt option: " ++ name);
    }
}

fn unsignedOption(
    comptime value: anytype,
    comptime T: type,
    comptime diagnostic: []const u8,
) T {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {},
        else => @compileError(diagnostic),
    }
    return std.math.cast(T, value) orelse @compileError(diagnostic);
}

fn isKnownOption(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "compare") or
        std.mem.eql(u8, name, "CompareContext") or
        std.mem.eql(u8, name, "comparator_id") or
        std.mem.eql(u8, name, "maximum_key_size") or
        std.mem.eql(u8, name, "maximum_value_size") or
        std.mem.eql(u8, name, "rebalance_policy") or
        std.mem.eql(u8, name, "format_version");
}

pub fn bpt(comptime options: anytype) component.Descriptor {
    @setEvalBranchQuota(20_000);
    const OptionsT = @TypeOf(options);
    const options_info = @typeInfo(OptionsT);
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("pages.bpt options must be a named struct");
    }
    inline for (options_info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown pages.bpt option: " ++ field.name);
        }
    }
    requireOption(OptionsT, "compare");
    requireOption(OptionsT, "CompareContext");
    requireOption(OptionsT, "comparator_id");
    requireOption(OptionsT, "maximum_key_size");
    requireOption(OptionsT, "maximum_value_size");

    if (@TypeOf(options.CompareContext) != type) {
        @compileError("pages.bpt CompareContext must be a type");
    }
    const CompareContextT = options.CompareContext;
    const CompareFn = fn (CompareContextT, []const u8, []const u8) algorithm.Order;
    if (@TypeOf(options.compare) != CompareFn) {
        @compileError("pages.bpt compare has an invalid signature");
    }

    const configured_comparator_id = unsignedOption(
        options.comparator_id,
        u32,
        "pages.bpt comparator_id must fit u32",
    );
    if (configured_comparator_id == 0) {
        @compileError("pages.bpt comparator_id cannot be zero");
    }
    const configured_maximum_key_size = unsignedOption(
        options.maximum_key_size,
        usize,
        "pages.bpt maximum_key_size must fit usize",
    );
    const configured_maximum_value_size = unsignedOption(
        options.maximum_value_size,
        usize,
        "pages.bpt maximum_value_size must fit usize",
    );
    const configured_format_version = if (@hasField(OptionsT, "format_version"))
        unsignedOption(
            options.format_version,
            u32,
            "pages.bpt format_version must fit u32",
        )
    else
        1;
    if (configured_format_version == 0) {
        @compileError("pages.bpt format_version cannot be zero");
    }
    if (@hasField(OptionsT, "rebalance_policy")) {
        const PolicyT = @TypeOf(options.rebalance_policy);
        if (PolicyT != @TypeOf(.neighbor_share) and PolicyT != low_level_bpt.RebalancePolicy) {
            @compileError("pages.bpt rebalance_policy has an invalid type");
        }
    }
    const configured_rebalance_policy: low_level_bpt.RebalancePolicy = if (@hasField(
        OptionsT,
        "rebalance_policy",
    )) options.rebalance_policy else .neighbor_share;
    const configured_compare = options.compare;

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.bpt.paged";
        pub const format_version: u32 = configured_format_version;
        pub const page_kind_count: usize = 2;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode" };
        pub const comparator_id: u32 = configured_comparator_id;
        pub const CompareContext = CompareContextT;
        pub const compare = configured_compare;
        pub const maximum_key_size: usize = configured_maximum_key_size;
        pub const maximum_value_size: usize = configured_maximum_value_size;
        pub const rebalance_policy = configured_rebalance_policy;

        pub fn Binding(comptime BackendT: type) type {
            const ManagerT = Manager(BackendT);
            comptime low_level_bpt.models.interfaces.requiresStorageManager(ManagerT);
            const CacheT = BackendT.CacheType;
            const ModelT = low_level_bpt.models.PagedModel(
                CacheT,
                ManagerT,
                configured_compare,
                CompareContextT,
            );
            const ProxyT = low_level_bpt.Bpt(ModelT);
            const BindingT = struct {
                pub const Manager = ManagerT;
                pub const Model = ModelT;
                pub const Proxy = ProxyT;
                pub const Runtime = struct {
                    manager: ManagerT,
                    model: ModelT,
                    tree: ProxyT,
                };
                pub const InitOptions = if (CompareContextT == void)
                    struct { compare_context: void = {} }
                else
                    struct { compare_context: CompareContextT };
                pub const Error = Proxy.Error || error{InvalidPageKinds};

                pub fn initRuntime(
                    runtime: *Runtime,
                    backend: *BackendT,
                    page_kinds: component.PageKindRange,
                    init_options: InitOptions,
                ) Error!void {
                    if (page_kinds.count != page_kind_count) {
                        return Error.InvalidPageKinds;
                    }
                    const leaf_page_kind = page_kinds.kindAt(0) orelse
                        return Error.InvalidPageKinds;
                    const inode_page_kind = page_kinds.kindAt(1) orelse
                        return Error.InvalidPageKinds;

                    runtime.manager = ManagerT.init(backend);
                    runtime.model = try ModelT.init(
                        backend.cache(),
                        &runtime.manager,
                        .{
                            .maximum_key_size = configured_maximum_key_size,
                            .maximum_value_size = configured_maximum_value_size,
                            .leaf_page_kind = leaf_page_kind,
                            .inode_page_kind = inode_page_kind,
                        },
                        init_options.compare_context,
                    );
                    runtime.tree = ProxyT.init(&runtime.model, configured_rebalance_policy);
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    runtime.tree.deinit();
                    runtime.model.deinit();
                    runtime.* = undefined;
                }

                pub fn proxy(runtime: *Runtime) *Proxy {
                    return &runtime.tree;
                }

                pub fn proxyConst(runtime: *const Runtime) *const Proxy {
                    return &runtime.tree;
                }
            };
            comptime component.assertBinding(BindingT, BackendT);
            return BindingT;
        }
    };
    return component.descriptor(Trait);
}
