const component = @import("../../component/component.zig");
const page_cache_contract = @import("fullaz").contracts.page_cache;
const component_metadata = @import("component.zig");
const component_metadata_page = @import("page.zig");

/// Accesses one component's already-allocated metadata page through a page cache.
pub fn ComponentMetadataIo(comptime BindingT: type, comptime CacheT: type) type {
    comptime component.assertDynamicMetadata(BindingT, BindingT.DynamicMetadata);
    comptime page_cache_contract.requiresPageCache(CacheT);

    return struct {
        pub const Error = CacheT.Error ||
            component_metadata.Error ||
            component_metadata_page.Error;

        pub fn load(
            cache: *CacheT,
            page_id: CacheT.Pid,
            state: component_metadata_page.State,
            runtime: *BindingT.Runtime,
        ) Error!void {
            var page = try cache.fetch(page_id);
            defer page.deinit();
            const view = try component_metadata_page.read(try page.data(), state);
            try component_metadata.restore(BindingT, runtime, view.payload, cache.pageCount());
        }

        /// Formats a newly allocated page. It intentionally has no previous
        /// payload, so callers cannot accidentally overwrite unknown fields.
        pub fn initialize(
            cache: *CacheT,
            page_id: CacheT.Pid,
            state: component_metadata_page.State,
            runtime: *const BindingT.Runtime,
            payload_buffer: []u8,
            rewrite_scratch: []u8,
        ) Error!void {
            var page = try cache.fetch(page_id);
            defer page.deinit();
            const payload = try component_metadata.rewrite(
                BindingT,
                runtime,
                payload_buffer,
                rewrite_scratch,
                &.{},
            );
            try component_metadata_page.format(try page.dataMut(), state, payload);
        }

        /// Rewrites known fields while retaining fields unknown to this build.
        pub fn store(
            cache: *CacheT,
            page_id: CacheT.Pid,
            state: component_metadata_page.State,
            runtime: *const BindingT.Runtime,
            payload_buffer: []u8,
            rewrite_scratch: []u8,
        ) Error!void {
            var page = try cache.fetch(page_id);
            defer page.deinit();
            const view = try component_metadata_page.read(try page.data(), state);
            const payload = try component_metadata.rewrite(
                BindingT,
                runtime,
                payload_buffer,
                rewrite_scratch,
                view.payload,
            );
            try component_metadata_page.format(try page.dataMut(), state, payload);
        }
    };
}
