# Transactions, Ownership, And Lifetimes

One database has one mutable transaction at a time.

```zig
var transaction = try database.begin();
defer transaction.deinit();

try transaction.get("audit").append("changed something\n");
try transaction.commit();
```

## Commit Or Roll Back

Use `commit` to publish component changes together:

```zig
var transaction = try database.begin();
defer transaction.deinit();
if (!try transaction.get("users").insert("ada", "Ada Lovelace")) {
    return error.UserAlreadyExists;
}
try transaction.get("audit").append("created ada\n");
try transaction.commit();
```

Use `rollback` for an intentionally cancelled operation:

```zig
var transaction = try database.begin();
defer transaction.deinit();
_ = try transaction.get("users").insert("preview", "not published");
try transaction.rollback();
```

If a mutation fails, roll back or let `defer` run. Do not retry `commit` after
`TransactionRollbackOnly`.

## Close Results Before A Write

Some reads hold a page pin.

```zig
var iterator = (try database.getConst("users").find("ada")).?;
defer iterator.deinit();
const entry = (try iterator.get()).?;
std.debug.print("{s}\n", .{entry.value});
```

Close an iterator or SlotHeap peek before mutation, commit, or rollback. Copy
borrowed bytes when they must outlive the iterator.

R-tree callbacks receive borrowed value slices. Copy a value inside the
callback if it is needed later. Do not start a transaction from that callback.

## WAL Failure

`RecoveryRequired` means the database must be closed and reopened. If a WAL
`commit` fails, do not assume the transaction rolled back: its commit record
may already be durable. Reopen the image and WAL to determine the recovered
state.

[Previous: choose a backend](04-choosing-a-backend.md) | [Next: persistence](06-persistence-and-recovery.md)
