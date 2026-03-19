const std = @import("std");

fn getFnInfo(comptime T: type) std.builtin.Type.Fn {
    return switch (@typeInfo(T)) {
        .@"fn" => |info| info,
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"fn" => |info| info,
            else => @compileError("callback must be a function or function pointer"),
        },
        else => @compileError("callback must be a function or function pointer"),
    };
}

pub fn CallbackResult(comptime Callback: type) type {
    const fn_info = getFnInfo(Callback);
    const ret_ty = fn_info.return_type orelse
        @compileError("callback must have a return type");

    return ret_ty;
}

pub fn callCallback1(callback: anytype, par0: anytype) !CallbackResult(@TypeOf(callback)) {
    const fn_info = comptime getFnInfo(@TypeOf(callback));
    const ret_ty = fn_info.return_type orelse
        @compileError("callback must have a return type");

    return switch (@typeInfo(ret_ty)) {
        .error_union => try callback(par0),
        else => callback(par0),
    };
}

pub fn callCallback2(callback: anytype, par0: anytype, par1: anytype) !CallbackResult(@TypeOf(callback)) {
    const fn_info = comptime getFnInfo(@TypeOf(callback));
    const ret_ty = fn_info.return_type orelse
        @compileError("callback must have a return type");

    return switch (@typeInfo(ret_ty)) {
        .error_union => try callback(par0, par1),
        else => callback(par0, par1),
    };
}
