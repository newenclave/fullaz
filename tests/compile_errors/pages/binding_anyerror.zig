const pages = @import("fullaz").pages;

const Backend = struct {};

const Binding = struct {
    pub const Runtime = struct {};
    pub const Proxy = Runtime;
    pub const ConstProxy = Runtime;
    pub const InitOptions = struct {};
    pub const TransactionState = void;
    pub const Error = anyerror;

    pub fn initRuntime(
        runtime: *Runtime,
        _: *Backend,
        _: pages.PageKindRange,
        _: InitOptions,
    ) Error!void {
        runtime.* = .{};
    }

    pub fn deinitRuntime(_: *Runtime) void {}

    pub fn captureTransactionState(_: *const Runtime) TransactionState {}

    pub fn restoreTransactionState(_: *Runtime, _: TransactionState) void {}

    pub fn proxy(runtime: *Runtime) *Proxy {
        return runtime;
    }

    pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
        return runtime;
    }
};

comptime {
    pages.assertBinding(Binding, Backend);
}
