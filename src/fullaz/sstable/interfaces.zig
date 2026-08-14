const interfaces = @import("../contracts/interfaces.zig");

const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

/// A writer accepts strictly ascending byte keys and becomes immutable after `finish`.
///
/// ```zig
/// const Writer = struct {
///     pub const Error = error{};
///     pub fn add(self: *Writer, key: []const u8, value: []const u8) Error!void { _ = self; _ = key; _ = value; }
///     pub fn finish(self: *Writer) Error!void { _ = self; }
///     pub fn deinit(self: *Writer) void { _ = self; }
/// };
/// comptime assertWriter(Writer);
/// ```
pub fn assertWriter(comptime WriterT: type) void {
    requiresErrorDeclaration(WriterT, "Error");
    const Error = WriterT.Error;

    requiresFnSignature(
        WriterT,
        "add",
        fn (*WriterT, []const u8, []const u8) Error!void,
    );
    requiresFnSignature(WriterT, "finish", fn (*WriterT) Error!void);
    requiresFnSignature(WriterT, "deinit", fn (*WriterT) void);
}

/// A reader looks up byte keys using caller-owned scratch storage.
/// Its returned entry exposes both the value and storage metadata; the value
/// borrows that scratch and is invalidated by its next use.
///
/// ```zig
/// const Reader = struct {
///     pub const Error = error{};
///     pub const ReadScratchType = struct {};
///     pub const Entry = struct { value: []const u8 };
///     pub fn find(self: *Reader, key: []const u8, scratch: *ReadScratchType) Error!?Entry { _ = self; _ = key; _ = scratch; return null; }
///     pub fn deinit(self: *Reader) void { _ = self; }
/// };
/// comptime assertReader(Reader);
/// ```
pub fn assertReader(comptime ReaderT: type) void {
    requiresErrorDeclaration(ReaderT, "Error");
    requiresTypeDeclaration(ReaderT, "ReadScratchType");
    requiresTypeDeclaration(ReaderT, "Entry");
    const Error = ReaderT.Error;

    requiresFnSignature(
        ReaderT,
        "find",
        fn (*ReaderT, []const u8, *ReaderT.ReadScratchType) Error!?ReaderT.Entry,
    );
    requiresFnSignature(ReaderT, "deinit", fn (*ReaderT) void);
}

pub fn assertUnsignedInt(comptime T: type, comptime name: []const u8) void {
    const info = switch (@typeInfo(T)) {
        .int => |int_info| int_info,
        else => @compileError(name ++ " must be an unsigned integer"),
    };
    if (info.signedness != .unsigned) {
        @compileError(name ++ " must be an unsigned integer");
    }
}
