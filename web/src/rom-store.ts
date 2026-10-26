// Remembering the viewer's ROMs in this browser (IndexedDB), if they ask:
// a convenience, so storage that's unavailable (a private window, blocked
// site data) just means choosing them again.

type ROMs = Record<string, Map<number, Uint8Array>>;

const DB = "macbeeb-web";
const STORE = "roms";

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function transact<T>(mode: IDBTransactionMode, body: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  try {
    return await new Promise<T>((resolve, reject) => {
      const request = body(db.transaction(STORE, mode).objectStore(STORE));
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  } finally {
    db.close();
  }
}

export async function saveROMs(roms: ROMs) {
  try {
    const plain = Object.fromEntries(Object.entries(roms).map(([model, slots]) => [model, [...slots.entries()]]));
    await transact("readwrite", (store) => store.put(plain, "roms"));
  } catch {
    // Not remembered, then.
  }
}

export async function loadROMs(): Promise<ROMs | null> {
  try {
    const plain = await transact<Record<string, [number, Uint8Array][]> | undefined>("readonly", (store) => store.get("roms"));
    if (!plain) return null;
    return Object.fromEntries(Object.entries(plain).map(([model, slots]) => [model, new Map(slots)]));
  } catch {
    return null;
  }
}

export async function forgetROMs() {
  try {
    await transact("readwrite", (store) => store.delete("roms"));
  } catch {
    // Nothing to forget.
  }
}
