# The Zig Concepts You Need

You need four Zig ideas to use the public database API.

## Types At Compile Time

`Schema`, component factories, and database factories make types. Keep them in
`const` declarations:

```zig
const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("blob", fullaz_db.chainStore(.{}));
const Database = fullaz_db.MemoryDatabase(Schema);
```

Create a value later with `init`, `format`, or `open`.

## Propagate Errors

Public storage operations return error unions. `try` returns an error to your
caller when an operation fails.

```zig
try transaction.get("blob").append("hello");
try transaction.commit();
```

B+ tree `insert`, `update`, and `remove` also return `bool`. `false` is a
normal result, such as a duplicate or missing key.

## Clean Up Owned Values

Put `defer` beside a successfully acquired database, transaction, iterator, or
peek. An active transaction normally rolls back at `deinit`.

```zig
var database = try Database.init(allocator, options);
defer database.deinit();

var transaction = try database.begin();
defer transaction.deinit();
```

After a terminal WAL error such as `RecoveryRequired`, stop using that database
value and reopen the image and its WAL. A failed commit can be indeterminate:
the WAL commit record may already be durable even when `commit` returns an
error.

## Borrowed Values

- A database owns its device, cache, and component runtimes.
- Proxies from `transaction.get("name")` borrow the active transaction.
- Proxies from `database.getConst("name")` borrow the database.
- B+ tree iterators and SlotHeap peeks own page pins and need `deinit`.
- Slices from iterators and peeks borrow page memory.

Do not copy a database, transaction, iterator, peek, or page handle. Do not
use a transaction proxy after commit or rollback.

`getConst` is not an isolation or snapshot API. Serialize application access
and avoid it while a mutable transaction is active unless you intentionally
need to inspect that transaction's current cache state.

[Previous: schema](01-pages-schemas-and-components.md) | [Next: memory database](03-first-memory-database.md)
