# Reclaim Unreachable Pages

Garbage collection (GC) finds pages that no live component can reach. It
returns those pages to the database free list. A later write can reuse them.
GC does not make the image file smaller.

Run GC after an operation removes a structural ownership edge. The common case
is removing an embedded child from a `hierarchyStore` owner.

## Before You Start

Use staged GC with these persistent typed factories:

- `StaticDatabase`
- `StaticDatabaseWithWal`
- `VirtualStaticDatabaseWithWal`
- `DynamicSchemaDatabase`
- `DynamicSchemaDatabaseWithWal`

It is not available on `MemoryDatabase`, raw `DynamicDatabase`, or
`VirtualStaticDatabaseWithCow`.

Close iterators, peeks, child handles, and value editors before GC. Finish or
roll back the normal transaction that removes the ownership edge first.

## Remove A Hierarchy Parent

This continues the hierarchy example from the previous chapter. `root` owns an
embedded `folder`. Removing `root` removes that ownership edge, but the folder
pages still exist until a GC cycle reclaims them.

```zig
var transaction = try database.begin();
defer transaction.deinit();

const files = transaction.get("store").owner("files");
if (!try files.proxy().remove("root")) {
    return error.RootMissing;
}
try transaction.commit();
```

All compiled top-level component roots remain GC roots. GC does not remove a
declared component because its top-level root is still live.

## Complete A GC Cycle

Start one cycle after the removal transaction commits. Each call to
`stepGarbageCollection` does at most the requested amount of page work.

```zig
try database.startGarbageCollection();

var status = try database.stepGarbageCollection(64);
while (status != .complete) {
    status = try database.stepGarbageCollection(64);
}
```

Use a small value when GC must share time with other application work. Use a
larger value for a maintenance job. GC blocks normal `begin()` transactions for
the whole active cycle. A normal write during that time returns
`GarbageCollectionActive`.

## Inspect Or Cancel A Cycle

`garbageCollectionPhase()` reports `.idle`, `.preparing`, `.marking`, or
`.sweeping`. It does not change the cycle.

```zig
try database.startGarbageCollection();
const phase = try database.garbageCollectionPhase();

if (phase != .idle) {
    try database.cancelGarbageCollection();
}
```

`cancelGarbageCollection()` ends the active cycle and allows normal writes
again. It does not restore pages that an earlier sweep step already reclaimed.
Calling `stepGarbageCollection` or `cancelGarbageCollection` without an active
cycle returns `BadGcState`.

## What GC Follows

GC follows page references that component bindings define as structural. Normal
byte values are opaque. `hierarchyStore` is the supported exception: it reads
validated embedded envelopes and follows their child roots. Raw hierarchy
payloads remain ordinary bytes.

Every component in the schema must provide the required GC capability. A custom
component without that capability cannot use staged GC in the typed database.

## Clear One Top-Level Component

Static factory transactions also have `reclaim("name")`. It clears a supported
top-level component and keeps its fixed schema slot ready for reuse. This is
not staged graph GC.

```zig
var transaction = try database.begin();
defer transaction.deinit();

try transaction.reclaim("notes");
try transaction.commit();
```

Use this only for a component that implements persistent reclamation. It does
not reclaim a `hierarchyStore` graph yet, because reclaiming only its owner
pages could orphan embedded child pages. Remove hierarchy parents and run
staged GC instead.

## Durability

Each GC start, step, and cancel operation uses its own database transaction.
WAL factories use their normal WAL rules for those operations. Do not interrupt
a no-WAL GC cycle: these factories do not provide atomic recovery.

[Previous: components and hierarchies](08-components-and-hierarchy.md) | [fullaz-db documentation](../README.md)
