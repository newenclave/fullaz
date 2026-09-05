const std = @import("std");
const fullaz = @import("fullaz");
const component = @import("../../component/component.zig");
const value_envelope = @import("../../value_envelope.zig");

/// One fixed-capacity hierarchy value ready for a native component proxy.
pub fn EncodedValue(comptime capacity: usize) type {
    if (capacity < value_envelope.envelope_byte_size) {
        @compileError("hierarchy encoded value capacity cannot hold an envelope");
    }

    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,

        pub fn data(self: *const Self) []const u8 {
            return &self.bytes;
        }

        pub fn formatRaw(
            metadata: value_envelope.Metadata,
            payload: []const u8,
        ) value_envelope.Error!Self {
            var result: Self = .{};
            try value_envelope.formatRaw(&result.bytes, metadata, payload);
            return result;
        }

        pub fn formatEmbedded(
            metadata: value_envelope.Metadata,
            payload: []const u8,
        ) value_envelope.Error!Self {
            var result: Self = .{};
            try value_envelope.formatEmbedded(&result.bytes, metadata, payload);
            return result;
        }
    };
}

/// A mutable paged storage manager whose durable state is an envelope payload.
/// `payload` must remain valid until all state leases are released.
pub fn MutablePayloadStorageManager(comptime CacheT: type, comptime StateT: type) type {
    assertState(StateT);

    return struct {
        const Self = @This();

        pub const PageId = CacheT.Pid;
        pub const Size = u64;
        pub const Error = CacheT.Error || error{BadPayloadLength};
        pub const StateLeaseType = struct {
            const LeaseSelf = @This();

            pub const Error = error{};

            payload: []u8,

            pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                return self.payload;
            }

            pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                return self.payload;
            }

            pub fn finish(_: *LeaseSelf) void {}

            pub fn deinit(_: *LeaseSelf) void {}
        };

        cache: *CacheT,
        payload: []u8,

        pub fn init(cache: *CacheT, payload: []u8) Error!Self {
            if (payload.len != @sizeOf(StateT)) {
                return error.BadPayloadLength;
            }
            return .{
                .cache = cache,
                .payload = payload,
            };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .payload = self.payload };
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            return self.cache.free(page_id);
        }
    };
}

/// A read-only paged storage manager whose durable state is an envelope payload.
/// Mutating a child through this manager fails with `error.ReadOnly`.
pub fn ReadonlyPayloadStorageManager(comptime CacheT: type, comptime StateT: type) type {
    assertState(StateT);

    return struct {
        const Self = @This();

        pub const PageId = CacheT.Pid;
        pub const Size = u64;
        pub const Error = error{
            BadPayloadLength,
            ReadOnly,
        };
        pub const StateLeaseType = struct {
            const LeaseSelf = @This();

            pub const Error = error{ReadOnly};

            payload: []const u8,

            pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                return self.payload;
            }

            pub fn dataMut(_: *LeaseSelf) LeaseSelf.Error![]u8 {
                return error.ReadOnly;
            }

            pub fn finish(_: *LeaseSelf) void {}

            pub fn deinit(_: *LeaseSelf) void {}
        };

        cache: *CacheT,
        payload: []const u8,

        pub fn init(cache: *CacheT, payload: []const u8) Error!Self {
            if (payload.len != @sizeOf(StateT)) {
                return error.BadPayloadLength;
            }
            return .{
                .cache = cache,
                .payload = payload,
            };
        }

        pub fn state(self: *Self) Error!StateLeaseType {
            return .{ .payload = self.payload };
        }

        pub fn destroyPage(_: *Self, _: PageId) Error!void {
            return error.ReadOnly;
        }
    };
}

/// Owns one arbitrary parent value editor behind the operations required by an
/// embedded child. `rollback()` releases the editor without committing it.
pub fn ParentEditorLease(comptime LeaseError: type) type {
    return struct {
        const Self = @This();

        pub const Error = LeaseError;

        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        value_mut_fn: *const fn (*anyopaque) Error![]u8,
        finish_fn: *const fn (*anyopaque) Error!void,
        rollback_fn: *const fn (*anyopaque) void,
        deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,

        pub fn init(
            comptime EditorT: type,
            allocator: std.mem.Allocator,
            editor: EditorT,
        ) std.mem.Allocator.Error!Self {
            const ptr = try allocator.create(EditorT);
            ptr.* = editor;
            return .{
                .ptr = ptr,
                .allocator = allocator,
                .value_mut_fn = struct {
                    fn valueMut(ptr_: *anyopaque) Error![]u8 {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        return typed.valueMut();
                    }
                }.valueMut,
                .finish_fn = struct {
                    fn finish(ptr_: *anyopaque) Error!void {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        return typed.finish();
                    }
                }.finish,
                .rollback_fn = struct {
                    fn rollback(ptr_: *anyopaque) void {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        typed.deinit();
                    }
                }.rollback,
                .deinit_fn = struct {
                    fn deinit(ptr_: *anyopaque, allocator_: std.mem.Allocator) void {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        allocator_.destroy(typed);
                    }
                }.deinit,
            };
        }

        pub fn valueMut(self: *const Self) Error![]u8 {
            return self.value_mut_fn(self.ptr);
        }

        pub fn finish(self: *const Self) Error!void {
            return self.finish_fn(self.ptr);
        }

        pub fn rollback(self: *const Self) void {
            self.rollback_fn(self.ptr);
        }

        pub fn deinit(self: *Self) void {
            self.deinit_fn(self.ptr, self.allocator);
            self.* = undefined;
        }
    };
}

/// An owned mutable child runtime over one embedded envelope payload.
///
/// `BindingT` is the ordinary child binding. Its `StorageBinding` is selected
/// automatically with `MutablePayloadStorageManager`. The caller transfers a
/// live parent editor to `init`; `finish` commits both the envelope and parent.
pub fn OwnedMutableChild(
    comptime BackendT: type,
    comptime BindingT: type,
    comptime ParentError: type,
) type {
    if (!@hasDecl(BackendT, "CacheType")) {
        @compileError("embedded child backend must declare CacheType");
    }

    const CacheT = BackendT.CacheType;
    const StateT = BindingT.State;
    const ManagerT = MutablePayloadStorageManager(CacheT, StateT);
    const ChildBindingT = component.storageBindingFor(BindingT, BackendT, ManagerT);
    const ParentLeaseT = ParentEditorLease(ParentError);

    return struct {
        const Self = @This();

        pub const StorageManager = ManagerT;
        pub const StorageBinding = ChildBindingT;
        pub const Error = ChildBindingT.Error ||
            ManagerT.Error ||
            ParentLeaseT.Error ||
            value_envelope.Error ||
            std.mem.Allocator.Error;

        backend: *BackendT,
        parent_editor: ParentLeaseT,
        envelope_editor: value_envelope.EmbeddedEditor,
        manager: *ManagerT,
        runtime: *ChildBindingT.Runtime,
        closed: bool = false,

        /// Transfers ownership of `parent_editor` and `envelope_editor`.
        /// `payload` must be the mutable payload slice returned by that editor.
        pub fn init(
            backend: *BackendT,
            payload: []u8,
            envelope_editor: value_envelope.EmbeddedEditor,
            parent_editor: anytype,
            page_kinds: component.PageKindRange,
            init_options: ChildBindingT.InitOptions,
        ) Error!Self {
            const allocator = backend.allocator();
            var owned_envelope_editor = envelope_editor;
            errdefer owned_envelope_editor.invalidate();

            var owned_parent_editor = try ParentLeaseT.init(
                @TypeOf(parent_editor),
                allocator,
                parent_editor,
            );
            errdefer {
                owned_parent_editor.rollback();
                owned_parent_editor.deinit();
            }

            const manager = try allocator.create(ManagerT);
            errdefer allocator.destroy(manager);
            manager.* = try ManagerT.init(backend.cache(), payload);

            const runtime = try allocator.create(ChildBindingT.Runtime);
            errdefer allocator.destroy(runtime);
            try ChildBindingT.initRuntime(
                runtime,
                backend,
                manager,
                page_kinds,
                init_options,
            );
            errdefer ChildBindingT.deinitRuntime(runtime);

            return .{
                .backend = backend,
                .parent_editor = owned_parent_editor,
                .envelope_editor = owned_envelope_editor,
                .manager = manager,
                .runtime = runtime,
            };
        }

        /// Returns a proxy borrowed from this child handle. Deinitialize every
        /// iterator and value editor from it before `finish` or `deinit`; both
        /// operations destroy the child runtime.
        pub fn proxy(self: *Self) ChildBindingT.Proxy {
            if (self.closed) {
                @panic("embedded child proxy requested after close");
            }
            return ChildBindingT.proxy(self.runtime);
        }

        pub fn formatRaw(
            _: *const Self,
            metadata: value_envelope.Metadata,
            payload: []const u8,
        ) value_envelope.Error!EncodedValue(ChildBindingT.value_capacity orelse
            @compileError("embedded child component cannot store hierarchy values")) {
            return EncodedValue(ChildBindingT.value_capacity orelse
                @compileError("embedded child component cannot store hierarchy values")).formatRaw(
                metadata,
                payload,
            );
        }

        pub fn formatEmbedded(
            _: *const Self,
            metadata: value_envelope.Metadata,
            payload: []const u8,
        ) value_envelope.Error!EncodedValue(ChildBindingT.value_capacity orelse
            @compileError("embedded child component cannot store hierarchy values")) {
            return EncodedValue(ChildBindingT.value_capacity orelse
                @compileError("embedded child component cannot store hierarchy values")).formatEmbedded(
                metadata,
                payload,
            );
        }

        /// The child must have no active mutable editor before it can commit.
        pub fn finish(self: *Self) Error!void {
            if (self.closed) {
                return error.EditorInvalidated;
            }
            try ChildBindingT.requireTransactionIdle(self.runtime);
            try self.envelope_editor.advanceRevision();
            try self.envelope_editor.finish();
            try self.parent_editor.finish();
            self.release();
        }

        /// Rolls back the parent editor and discards the envelope edit.
        /// If a child editor remains active, the cache transaction is failed and
        /// this handle stays open so it can be closed after that editor ends.
        pub fn deinit(self: *Self) void {
            if (self.closed) {
                return;
            }
            ChildBindingT.requireTransactionIdle(self.runtime) catch {
                self.backend.cache().markTransactionFailed();
                return;
            };
            self.envelope_editor.invalidate();
            self.backend.cache().markTransactionFailed();
            self.release();
        }

        fn release(self: *Self) void {
            ChildBindingT.deinitRuntime(self.runtime);
            self.backend.allocator().destroy(self.runtime);
            self.backend.allocator().destroy(self.manager);
            self.parent_editor.rollback();
            self.parent_editor.deinit();
            self.closed = true;
        }
    };
}

/// An owned read-only child runtime that retains the parent value pin.
pub fn OwnedConstChild(
    comptime BackendT: type,
    comptime BindingT: type,
    comptime ParentPinT: type,
) type {
    const CacheT = BackendT.CacheType;
    const StateT = BindingT.State;
    const ManagerT = ReadonlyPayloadStorageManager(CacheT, StateT);
    const ChildBindingT = component.storageBindingFor(BindingT, BackendT, ManagerT);

    return struct {
        const Self = @This();

        pub const Error = ChildBindingT.Error ||
            ManagerT.Error ||
            std.mem.Allocator.Error;

        backend: *BackendT,
        parent_pin: ParentPinT,
        manager: *ManagerT,
        runtime: *ChildBindingT.Runtime,
        closed: bool = false,

        pub fn init(
            backend: *BackendT,
            payload: []const u8,
            parent_pin: ParentPinT,
            page_kinds: component.PageKindRange,
            init_options: ChildBindingT.InitOptions,
        ) Error!Self {
            const allocator = backend.allocator();
            const manager = try allocator.create(ManagerT);
            errdefer allocator.destroy(manager);
            manager.* = try ManagerT.init(backend.cache(), payload);
            const runtime = try allocator.create(ChildBindingT.Runtime);
            errdefer allocator.destroy(runtime);
            try ChildBindingT.initRuntime(runtime, backend, manager, page_kinds, init_options);
            errdefer ChildBindingT.deinitRuntime(runtime);
            return .{
                .backend = backend,
                .parent_pin = parent_pin,
                .manager = manager,
                .runtime = runtime,
            };
        }

        /// Returns a proxy borrowed from this child handle. Deinitialize every
        /// iterator from it before `deinit`, which destroys the child runtime.
        pub fn proxy(self: *const Self) *const ChildBindingT.ConstProxy {
            if (self.closed) {
                @panic("embedded child proxy requested after close");
            }
            return ChildBindingT.proxyConst(self.runtime);
        }

        pub fn deinit(self: *Self) void {
            if (self.closed) {
                return;
            }
            ChildBindingT.deinitRuntime(self.runtime);
            self.backend.allocator().destroy(self.runtime);
            self.backend.allocator().destroy(self.manager);
            self.parent_pin.deinit();
            self.closed = true;
        }
    };
}

fn assertState(comptime StateT: type) void {
    if (@typeInfo(StateT) != .@"struct" or @typeInfo(StateT).@"struct".layout != .@"extern") {
        @compileError("embedded child state must be an extern struct");
    }
    if (@alignOf(StateT) != 1 or @sizeOf(StateT) == 0) {
        @compileError("embedded child state must be non-empty and byte-aligned");
    }
}

test "payload storage managers satisfy the paged storage-manager contract" {
    const State = extern struct { root: [4]u8 };
    const Cache = struct {
        pub const Pid = u32;
        pub const Error = error{};

        pub fn free(_: *@This(), _: Pid) Error!void {}
    };

    comptime fullaz.contracts.storage_manager.assertPagedStorageManager(
        MutablePayloadStorageManager(Cache, State),
        Cache.Pid,
    );
    comptime fullaz.contracts.storage_manager.assertPagedStorageManager(
        ReadonlyPayloadStorageManager(Cache, State),
        Cache.Pid,
    );
}
