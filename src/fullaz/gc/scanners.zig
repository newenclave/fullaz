/// Adapts a component's generic `scan*Refs` method to a concrete collector.
/// Component scanners stay independent of the GC error union and invoke only
/// the visitor's `visit`, `hasValueScanner`, and `visitValue` operations.
pub fn method(
    comptime CollectorT: type,
    comptime OwnerT: type,
    comptime scan_refs: anytype,
) CollectorT.Scanner {
    return struct {
        const Abort = error{Abort};

        const Visitor = struct {
            const Self = @This();
            sink: CollectorT.ReferenceSink,
            sink_error: ?CollectorT.Error = null,

            pub fn visit(self: *Self, page_id: CollectorT.PageId) Abort!void {
                self.sink.visit(page_id) catch |err| {
                    self.sink_error = err;
                    return error.Abort;
                };
            }

            pub fn hasValueScanner(self: *const Self) bool {
                return self.sink.hasValueScanner();
            }

            pub fn visitValue(self: *Self, value: []const u8) Abort!void {
                self.sink.visitValue(value) catch |err| {
                    self.sink_error = err;
                    return error.Abort;
                };
            }
        };

        fn scan(
            context: ?*const anyopaque,
            page_id: CollectorT.PageId,
            page: []const u8,
            sink: CollectorT.ReferenceSink,
        ) CollectorT.Error!void {
            const opaque_owner = context orelse return error.InvalidScannerContext;
            const owner: *const OwnerT = @ptrCast(@alignCast(opaque_owner));

            var visitor = Visitor{ .sink = sink };
            scan_refs(owner, page_id, page, &visitor) catch |err| {
                if (err == error.Abort) {
                    return visitor.sink_error.?;
                }
                return error.InvalidPage;
            };
        }
    }.scan;
}
