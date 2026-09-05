# Persistence And Recovery

Persistent databases store pages in an image file. WAL variants also store redo
records in a second log file.

## Keep These Values Stable

- Use one page size, such as `4096`.
- Use one nonzero `[16]u8` `image_id`.
- Keep the schema and descriptor settings compatible.
- Keep a Static or Virtual Static image with its exact WAL.

`Database.format` rejects a nonempty device or log that it receives. This does
not protect file paths: `FileBlock.create` and `FileLog.create` truncate an
existing file before the database sees it. Treat a `format` command as
destructive. Use `open` for normal startup.

## Open An Existing Database

`open` needs the same page size, image ID, schema, component settings, and WAL
pair. A changed schema can fail to open by design. Migrate or create a new
image instead of suppressing the error.

Static WAL and Virtual Static WAL store identity data in their WALs and reject
a mismatched pair. Dynamic WAL does not currently do this. Keep Dynamic WAL
files paired by your own operational controls and treat that backend as
advanced.

## WAL Recovery

After an interruption or terminal WAL error, call `open`. A successful WAL
commit is durable. A failed commit has an unknown final result until recovery:
the commit record may already be durable even if later work failed.

## Run Garbage Collection

Persistent typed Static, Virtual Static WAL, and Dynamic Schema databases have
a staged graph-GC API. It blocks normal writes while a cycle is active.

```zig
try database.startGarbageCollection();
while (try database.stepGarbageCollection(64) != .complete) {}
```

Use `garbageCollectionPhase()` to inspect a cycle. Call
`cancelGarbageCollection()` to cancel it. Custom components must implement the
required GC capability.

[Previous: transactions](05-transactions-ownership-and-lifetimes.md) | [Next: common errors](07-common-errors.md)
