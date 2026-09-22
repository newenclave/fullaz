import { readFile } from "node:fs/promises";

const wasmPath = process.argv[2];
if (!wasmPath) {
    throw new Error("usage: node wasm_gc_smoke.mjs <db-lab.wasm>");
}

const { instance } = await WebAssembly.instantiate(await readFile(wasmPath), {});
const api = instance.exports;

function errorText() {
    return new TextDecoder().decode(
        new Uint8Array(api.memory.buffer, api.lastErrorPtr(), api.lastErrorLen()),
    );
}

function ensure(result, operation) {
    if (!result) {
        throw new Error(`${operation}: ${errorText() || "operation failed"}`);
    }
}

function expectFailure(result, expected, operation) {
    if (result) {
        throw new Error(`${operation}: expected ${expected}, but the operation succeeded`);
    }
    const actual = errorText();
    if (actual !== expected) {
        throw new Error(`${operation}: expected ${expected}, got ${actual}`);
    }
}

function withBytes(text, callback) {
    const bytes = new TextEncoder().encode(text);
    const ptr = api.allocate(bytes.length);
    try {
        new Uint8Array(api.memory.buffer).set(bytes, ptr);
        return callback(ptr, bytes.length);
    } finally {
        api.freeAllocation(ptr, bytes.length);
    }
}

function importImage(engine, image) {
    const ptr = api.allocate(image.length);
    try {
        new Uint8Array(api.memory.buffer).set(image, ptr);
        ensure(api.importImage(engine, ptr, image.length), "import active GC image");
    } finally {
        api.freeAllocation(ptr, image.length);
    }
}

function pumpAll(operation) {
    let pumps = 0;
    while (api.gcHasPendingWork()) {
        ensure(api.pumpGarbageCollection(), operation);
        pumps += 1;
        if (pumps > 10_000) {
            throw new Error(`${operation}: pump limit exceeded`);
        }
    }
    return pumps;
}

for (const engine of [1, 2, 3]) {
    ensure(api.format(engine), `format engine ${engine}`);
    ensure(api.markGarbageCollection(8), `schedule mark for engine ${engine}`);
    pumpAll(`mark engine ${engine}`);
    if (api.gcRunnerState() !== 2) {
        throw new Error(`engine ${engine}: mark did not pause before sweep`);
    }

    ensure(api.sweepGarbageCollection(8), `schedule sweep for engine ${engine}`);
    pumpAll(`sweep engine ${engine}`);
    if (api.gcRunnerState() !== 5) {
        throw new Error(`engine ${engine}: sweep did not complete`);
    }
}

ensure(api.format(2), "format virtual WAL scenario");
ensure(api.generateExamplesWithCount(32), "generate example catalog");
ensure(
    withBytes("planets", (ptr, len) => api.deleteTable(ptr, len)),
    "disconnect planets",
);

ensure(api.markGarbageCollection(1), "schedule detailed mark");
pumpAll("detailed mark");
if (api.gcRunnerState() !== 2 || api.gcHasPendingWork()) {
    throw new Error("mark boundary did not wait for an explicit sweep request");
}

expectFailure(
    withBytes("blocked", (ptr, len) => api.createTable(ptr, len)),
    "GarbageCollectionActive",
    "mutation during GC",
);
expectFailure(api.format(2), "GarbageCollectionActive", "replacement during GC");

ensure(api.sweepGarbageCollection(1), "schedule partial sweep");
ensure(api.pumpGarbageCollection(), "commit one partial sweep step");
if (api.gcRunnerState() !== 3 || !api.gcHasPendingWork()) {
    throw new Error("partial sweep did not leave durable work pending");
}
const activeImage = new Uint8Array(
    api.memory.buffer,
    api.imagePtr(),
    api.imageLen(),
).slice();

ensure(api.cancelGarbageCollection(), "schedule cancellation");
pumpAll("cancel active GC");
if (api.gcRunnerState() !== 0) {
    throw new Error("cancellation did not return the runner to idle");
}

importImage(2, activeImage);
if (api.gcRunnerState() !== 2 || api.gcHasPendingWork()) {
    throw new Error("imported sweep phase did not wait for user input");
}
ensure(api.sweepGarbageCollection(8), "continue imported sweep");
pumpAll("imported sweep");
if (api.gcRunnerState() !== 5) {
    throw new Error("imported GC did not complete");
}
ensure(api.snapshotRows(), "snapshot rows after imported sweep");
if (api.rowsCount() !== 5) {
    throw new Error(`imported sweep lost live rows: expected 5, got ${api.rowsCount()}`);
}

ensure(api.format(2), "format queued cancellation scenario");
ensure(api.markGarbageCollection(8), "queue mark before cancellation");
ensure(api.cancelGarbageCollection(), "cancel queued mark");
if (api.gcHasPendingWork() || api.gcRunnerState() !== 0) {
    throw new Error("queued startup cancellation touched the database");
}

ensure(api.format(0), "format memory engine");
expectFailure(
    api.markGarbageCollection(8),
    "GarbageCollectionUnsupported",
    "memory engine GC",
);

if (api.gcEventSequence() === 0) {
    throw new Error("observer did not publish GC events");
}

console.log("db-lab WASM GC smoke passed");
