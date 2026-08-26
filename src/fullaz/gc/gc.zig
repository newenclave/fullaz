const std = @import("std");
const interfaces = @import("interfaces.zig");

pub const models = @import("models/models.zig");
pub const scanners = @import("scanners.zig");

pub const Phase = enum(u8) {
    idle,
    preparing,
    marking,
    sweeping,
};

pub const StepStatus = enum {
    in_progress,
    complete,
};

/// A generic page-graph collector. Models own persistent state and page I/O;
/// this type owns only the runtime scanner registry and tracing policy.
pub fn Gc(comptime ModelT: type) type {
    comptime interfaces.assertModel(ModelT);

    return struct {
        const Self = @This();

        pub const Model = ModelT;
        pub const PageId = ModelT.PageId;
        pub const PageKind = u16;
        pub const ScannerVersion = u32;
        pub const Error = ModelT.Error ||
            std.mem.Allocator.Error ||
            error{
                DuplicateScanner,
                InvalidPageKind,
                InvalidScannerVersion,
                RegistryFrozen,
                CycleInactive,
                InvalidPageId,
                InvalidPage,
                InvalidScannerContext,
                FreePageReference,
                UnknownPageKind,
                RegistryMismatch,
            };

        pub const ReferenceSink = struct {
            context: *anyopaque,
            visit_fn: *const fn (*anyopaque, PageId) Error!void,
            value_context: ?*const anyopaque,
            value_scan: ?ValueScanner,

            pub fn visit(self: ReferenceSink, page_id: PageId) Error!void {
                return self.visit_fn(self.context, page_id);
            }

            pub fn hasValueScanner(self: ReferenceSink) bool {
                return self.value_scan != null;
            }

            /// Dispatches one decoded leaf value to its optional schema-aware
            /// value scanner. Plain values have no page references.
            pub fn visitValue(self: ReferenceSink, value: []const u8) Error!void {
                const scan = self.value_scan orelse return;
                return scan(self.value_context, value, self);
            }
        };

        pub const ValueScanner = *const fn (
            context: ?*const anyopaque,
            value: []const u8,
            sink: ReferenceSink,
        ) Error!void;

        pub const Scanner = *const fn (
            context: ?*const anyopaque,
            page_id: PageId,
            page: []const u8,
            sink: ReferenceSink,
        ) Error!void;

        pub const ScannerEntry = struct {
            page_kind: PageKind,
            version: ScannerVersion,
            scan_context: ?*const anyopaque,
            scan: Scanner,
            value_context: ?*const anyopaque,
            value_scan: ?ValueScanner,
        };

        model: *ModelT,
        scanners: std.ArrayList(ScannerEntry) = .empty,
        registry_digest: ?u64 = null,

        pub fn init(model: *ModelT) Self {
            return .{ .model = model };
        }

        pub fn deinit(self: *Self) void {
            self.scanners.deinit(self.model.allocator());
            self.* = undefined;
        }

        /// Registers the semantic scanner for one common-header page kind.
        /// Registration is immutable while a collection cycle is active.
        pub fn register(
            self: *Self,
            page_kind: PageKind,
            version: ScannerVersion,
            context: ?*const anyopaque,
            scan: Scanner,
            value_scan: ?ValueScanner,
        ) Error!void {
            return self.registerWithContexts(
                page_kind,
                version,
                context,
                scan,
                context,
                value_scan,
            );
        }

        /// Registers a page scanner and an optional value scanner with separate
        /// caller-owned contexts.
        pub fn registerWithContexts(
            self: *Self,
            page_kind: PageKind,
            version: ScannerVersion,
            scan_context: ?*const anyopaque,
            scan: Scanner,
            value_context: ?*const anyopaque,
            value_scan: ?ValueScanner,
        ) Error!void {
            if (self.model.isCycleActive()) {
                return error.RegistryFrozen;
            }
            return self.addScanner(
                page_kind,
                version,
                scan_context,
                scan,
                value_context,
                value_scan,
            );
        }

        /// Rebuilds the runtime scanner registry for a cycle restored from a
        /// durable model. The digest is checked before marking resumes.
        pub fn registerResumed(
            self: *Self,
            page_kind: PageKind,
            version: ScannerVersion,
            context: ?*const anyopaque,
            scan: Scanner,
            value_scan: ?ValueScanner,
        ) Error!void {
            return self.registerResumedWithContexts(
                page_kind,
                version,
                context,
                scan,
                context,
                value_scan,
            );
        }

        /// Rebuilds a durable cycle's registry with separate scanner contexts.
        pub fn registerResumedWithContexts(
            self: *Self,
            page_kind: PageKind,
            version: ScannerVersion,
            scan_context: ?*const anyopaque,
            scan: Scanner,
            value_context: ?*const anyopaque,
            value_scan: ?ValueScanner,
        ) Error!void {
            if (!self.model.isCycleActive()) {
                return error.CycleInactive;
            }
            return self.addScanner(
                page_kind,
                version,
                scan_context,
                scan,
                value_context,
                value_scan,
            );
        }

        fn addScanner(
            self: *Self,
            page_kind: PageKind,
            version: ScannerVersion,
            scan_context: ?*const anyopaque,
            scan: Scanner,
            value_context: ?*const anyopaque,
            value_scan: ?ValueScanner,
        ) Error!void {
            if (page_kind == 0 or page_kind == std.math.maxInt(PageKind)) {
                return error.InvalidPageKind;
            }
            if (version == 0) {
                return error.InvalidScannerVersion;
            }
            for (self.scanners.items) |entry| {
                if (entry.page_kind == page_kind) {
                    return error.DuplicateScanner;
                }
            }
            try self.scanners.append(self.model.allocator(), .{
                .page_kind = page_kind,
                .version = version,
                .scan_context = scan_context,
                .scan = scan,
                .value_context = value_context,
                .value_scan = value_scan,
            });
            self.registry_digest = null;
        }

        /// Returns a stable digest of the registered page-kind scanner semantics.
        pub fn registryDigest(self: *Self) u64 {
            if (self.registry_digest) |digest| {
                return digest;
            }
            std.sort.insertion(ScannerEntry, self.scanners.items, {}, lessThan);
            var hasher = std.hash.Wyhash.init(0);
            for (self.scanners.items) |entry| {
                var bytes: [@sizeOf(PageKind) + @sizeOf(ScannerVersion)]u8 = undefined;
                std.mem.writeInt(PageKind, bytes[0..@sizeOf(PageKind)], entry.page_kind, .little);
                std.mem.writeInt(
                    ScannerVersion,
                    bytes[@sizeOf(PageKind)..],
                    entry.version,
                    .little,
                );
                hasher.update(&bytes);
            }
            const digest = hasher.final();
            self.registry_digest = digest;
            return digest;
        }

        pub fn findScanner(self: *Self, page_kind: PageKind) ?ScannerEntry {
            _ = self.registryDigest();
            var low: usize = 0;
            var high = self.scanners.items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const entry = self.scanners.items[middle];
                if (entry.page_kind < page_kind) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            if (low < self.scanners.items.len and self.scanners.items[low].page_kind == page_kind) {
                return self.scanners.items[low];
            }
            return null;
        }

        pub fn start(self: *Self, roots: []const PageId) Error!void {
            if (self.model.isCycleActive()) {
                return error.RegistryFrozen;
            }
            const snapshot_page_count = try self.model.beginCycle(self.registryDigest());
            for (roots) |root| {
                try self.enqueueReference(root, snapshot_page_count);
            }
        }

        pub fn step(self: *Self, maximum_pages: usize) Error!StepStatus {
            if (!self.model.isCycleActive()) {
                return error.CycleInactive;
            }
            if (maximum_pages == 0) {
                return .in_progress;
            }
            switch (self.model.phase()) {
                .preparing => {
                    if (try self.model.prepare(maximum_pages)) {
                        try self.model.setPhase(.marking);
                    }
                },
                .marking => {
                    if (self.model.registryDigest() != self.registryDigest()) {
                        return error.RegistryMismatch;
                    }
                    var processed: usize = 0;
                    while (processed < maximum_pages) : (processed += 1) {
                        const page_id = (try self.model.dequeue()) orelse {
                            try self.model.setPhase(.sweeping);
                            break;
                        };
                        var page = try self.model.fetchPage(page_id);
                        defer self.model.releasePage(&page);
                        const page_kind = try self.model.pageKind(&page, page_id);
                        const scanner = self.findScanner(page_kind) orelse return error.UnknownPageKind;
                        try scanner.scan(
                            scanner.scan_context,
                            page_id,
                            try self.model.pageData(&page),
                            .{
                                .context = @ptrCast(self),
                                .visit_fn = visitReference,
                                .value_context = scanner.value_context,
                                .value_scan = scanner.value_scan,
                            },
                        );
                    }
                },
                .sweeping => {
                    var processed: usize = 0;
                    while (processed < maximum_pages) : (processed += 1) {
                        const page_id = self.model.sweepCursor();
                        const page_index = std.math.cast(usize, page_id) orelse return error.InvalidPageId;
                        if (page_index >= self.model.snapshotPageCount()) {
                            try self.model.finishCycle();
                            return .complete;
                        }
                        const next_page_id = std.math.add(PageId, page_id, 1) catch {
                            try self.model.finishCycle();
                            return .complete;
                        };
                        try self.model.setSweepCursor(next_page_id);
                        if (try self.model.isReserved(page_id) or
                            try self.model.isFree(page_id) or
                            self.model.isMarked(page_id))
                        {
                            continue;
                        }
                        try self.model.reclaim(page_id);
                    }
                },
                .idle => return .complete,
            }
            return .in_progress;
        }

        fn visitReference(context: *anyopaque, page_id: PageId) Error!void {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.enqueueReference(page_id, self.model.snapshotPageCount());
        }

        fn enqueueReference(self: *Self, page_id: PageId, snapshot_page_count: usize) Error!void {
            const page_index = std.math.cast(usize, page_id) orelse return error.InvalidPageId;
            if (page_index >= snapshot_page_count) {
                return error.InvalidPageId;
            }
            if (try self.model.isFree(page_id)) {
                return error.FreePageReference;
            }
            if (try self.model.mark(page_id)) {
                try self.model.enqueue(page_id);
            }
        }

        fn lessThan(_: void, left: ScannerEntry, right: ScannerEntry) bool {
            return left.page_kind < right.page_kind;
        }
    };
}
