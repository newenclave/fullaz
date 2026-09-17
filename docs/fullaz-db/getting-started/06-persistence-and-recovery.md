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

## Open Dynamic Storage Read-Only

Dynamic factories have `openReadOnly()`. For file storage, pass
`FileBlock.openReadOnly()` and, for WAL, `FileLog.openReadOnly()`.

The read-only type has no transaction or GC mutation methods. Committed Dynamic
WAL pages are applied in memory. The source files stay unchanged. Do not use a
concurrent writer with the same files.

Read [Reclaim unreachable pages](09-garbage-collection.md) when a persistent
database removes hierarchy parents or needs a maintenance GC cycle.

[Previous: transactions](05-transactions-ownership-and-lifetimes.md) | [Next: common errors](07-common-errors.md)
