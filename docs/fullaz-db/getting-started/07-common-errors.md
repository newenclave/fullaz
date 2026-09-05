# Common Errors

Most errors show a mismatch in schema, settings, active lifetime, or persistent
files.

| Result | Usual cause | First action |
| --- | --- | --- |
| `InvalidSettings` | A component layout does not fit the page or has invalid settings. | Increase page size or reduce component limits. |
| `InvalidCacheFrames` | `cache_frames` is zero. | Use at least one cache frame. |
| `InvalidImageId` | `image_id` is all zero bytes. | Use a stable nonzero identity. |
| `DeviceNotEmpty` / `LogNotEmpty` | `format` received a nonempty device or log. | Use `open` or intentionally create new storage. |
| `BatchActive` | A mutable transaction is already active. | Commit or roll back that transaction. |
| `TransactionInactive` | A mutable proxy outlived its transaction. | Begin a new transaction and get a new proxy. |
| `TransactionRollbackOnly` | A previous mutation failed. | Roll back; do not retry commit. |
| `PageBusy` / `PageStillPinned` | A result still pins a page. | Deinitialize iterators, peeks, and handles. |
| `RecoveryRequired` | WAL commit or recovery reached a terminal I/O failure. | Stop using the value and reopen storage. |
| `WalIdentityMismatch` | Static or Virtual Static WAL belongs to another image/schema. | Restore the correct image and WAL pair. |
| `MissingComponent` | Typed Dynamic Schema does not match its catalog. | Open with a compatible schema or migrate. |
| `GarbageCollectionActive` | A staged GC cycle is active. | Finish or cancel GC before beginning a normal write. |
| `BadGcState` | GC has not started or is already complete. | Start a cycle or inspect its phase. |
| `BadKeyLength` | A SlotHeap key has the wrong fixed width. | Use exactly `maximum_key_size` bytes. |

## Normal `false` Results

Some B+ tree operations return `false` instead of an error:

```zig
if (!try transaction.get("users").insert("ada", "Ada")) {
    // The key already exists.
}
if (!try transaction.get("users").update("missing", "value")) {
    // The key is absent.
}
```

## Changed Schema

Changing a component name, descriptor setting, page-ID width, comparator ID, or
component order can make an image incompatible. A changed comparator with the
same `comparator_id` is also unsafe, even if opening succeeds. Treat every
such change as a migration decision.

[Previous: persistence](06-persistence-and-recovery.md) | [fullaz-db documentation](../README.md)
