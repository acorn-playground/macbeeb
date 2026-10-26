// The WASI (preview 1) imports the Swift module needs, for hosts with no
// WASI of their own (browsers, Cloudflare Workers) and for Node alike.
//
// BeebCore doesn't touch files, sockets or the clock to emulate, so most of
// WASI is refused (ENOSYS, EBADF): there are no preopened directories, no
// stdin, and stdout/stderr go to callbacks. Swift's runtime asks for its
// environment and random bytes at start up; the environment turns on
// deterministic hashing, so the same inputs make the same machine on every
// host.

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_INVAL = 28;
const ERRNO_NOSYS = 52;
const ERRNO_SPIPE = 70;
const ERRNO_NOTCAPABLE = 76;

const FILETYPE_CHARACTER_DEVICE = 2;

/** Thrown when the module calls proc_exit (a Swift fatal error exits). */
export class WasiExit extends Error {
  code: number;
  constructor(code: number) {
    super(`the WebAssembly module exited (${code})`);
    this.code = code;
  }
}

export interface WasiOptions {
  /** Lines written to stdout and stderr (default: the console). */
  stdout?: (text: string) => void;
  stderr?: (text: string) => void;
  /** Wall-clock time in nanoseconds (default Date.now). */
  now?: () => bigint;
  /** Fills with random bytes (default crypto.getRandomValues). */
  random?: (bytes: Uint8Array) => void;
}

export class Wasi {
  memory: WebAssembly.Memory | null = null;
  readonly imports: Record<string, (...args: any[]) => number>;
  private readonly environment = ["SWIFT_DETERMINISTIC_HASHING=1"];
  private readonly pending: string[] = ["", ""];
  private readonly outputs: ((text: string) => void)[];

  constructor(options: WasiOptions = {}) {
    const stdout = options.stdout ?? ((t: string) => console.log(t));
    const stderr = options.stderr ?? ((t: string) => console.error(t));
    const now = options.now ?? (() => BigInt(Date.now()) * 1_000_000n);
    const random = options.random ?? ((bytes: Uint8Array) => crypto.getRandomValues(bytes));
    this.outputs = [stdout, stderr];
    const decoder = new TextDecoder();
    const encoder = new TextEncoder();
    const view = () => new DataView(this.memory!.buffer);
    const bytes = () => new Uint8Array(this.memory!.buffer);

    const strings = (list: string[], pointers: number, buffer: number) => {
      const v = view();
      let p = buffer;
      for (const [i, s] of list.entries()) {
        v.setUint32(pointers + i * 4, p, true);
        const encoded = encoder.encode(s);
        bytes().set(encoded, p);
        bytes()[p + encoded.length] = 0;
        p += encoded.length + 1;
      }
      return ERRNO_SUCCESS;
    };
    const sizes = (list: string[], count: number, size: number) => {
      const v = view();
      v.setUint32(count, list.length, true);
      v.setUint32(size, list.reduce((n, s) => n + encoder.encode(s).length + 1, 0), true);
      return ERRNO_SUCCESS;
    };
    const write = (fd: number, text: string) => {
      const out = this.outputs[fd - 1];
      const lines = (this.pending[fd - 1] + text).split("\n");
      this.pending[fd - 1] = lines.pop()!;
      for (const line of lines) out(line);
    };

    const known: Record<string, (...args: any[]) => number> = {
      args_sizes_get: (count: number, size: number) => sizes([], count, size),
      args_get: (pointers: number, buffer: number) => strings([], pointers, buffer),
      environ_sizes_get: (count: number, size: number) => sizes(this.environment, count, size),
      environ_get: (pointers: number, buffer: number) => strings(this.environment, pointers, buffer),
      clock_res_get: (_id: number, out: number) => {
        view().setBigUint64(out, 1000n, true);
        return ERRNO_SUCCESS;
      },
      clock_time_get: (id: number, _precision: bigint, out: number) => {
        // Realtime (0) and the rest alike: emulation doesn't read clocks.
        if (id < 0 || id > 3) return ERRNO_INVAL;
        view().setBigUint64(out, now(), true);
        return ERRNO_SUCCESS;
      },
      random_get: (pointer: number, length: number) => {
        // getRandomValues takes at most 64K at a time.
        for (let p = 0; p < length; p += 65536) {
          random(new Uint8Array(this.memory!.buffer, pointer + p, Math.min(65536, length - p)));
        }
        return ERRNO_SUCCESS;
      },
      fd_write: (fd: number, iovs: number, count: number, written: number) => {
        if (fd !== 1 && fd !== 2) return ERRNO_BADF;
        const v = view();
        let total = 0;
        for (let i = 0; i < count; i++) {
          const base = v.getUint32(iovs + i * 8, true);
          const length = v.getUint32(iovs + i * 8 + 4, true);
          write(fd, decoder.decode(bytes().subarray(base, base + length)));
          total += length;
        }
        v.setUint32(written, total, true);
        return ERRNO_SUCCESS;
      },
      fd_read: (fd: number, _iovs: number, _count: number, read: number) => {
        if (fd !== 0) return ERRNO_BADF;
        view().setUint32(read, 0, true);
        return ERRNO_SUCCESS;
      },
      fd_fdstat_get: (fd: number, out: number) => {
        if (fd > 2) return ERRNO_BADF;
        const v = view();
        for (let i = 0; i < 24; i += 4) v.setUint32(out + i, 0, true);
        v.setUint8(out, FILETYPE_CHARACTER_DEVICE);
        return ERRNO_SUCCESS;
      },
      fd_close: (fd: number) => (fd <= 2 ? ERRNO_SUCCESS : ERRNO_BADF),
      fd_seek: (fd: number) => (fd <= 2 ? ERRNO_SPIPE : ERRNO_BADF),
      fd_tell: (fd: number) => (fd <= 2 ? ERRNO_SPIPE : ERRNO_BADF),
      fd_sync: (fd: number) => (fd <= 2 ? ERRNO_SUCCESS : ERRNO_BADF),
      // No preopened directories, so no files at all.
      fd_prestat_get: () => ERRNO_BADF,
      fd_prestat_dir_name: () => ERRNO_BADF,
      path_open: () => ERRNO_NOTCAPABLE,
      proc_exit: (code: number) => {
        throw new WasiExit(code);
      },
    };
    this.imports = new Proxy(known, {
      get: (target, name: string) => target[name] ?? (() => ERRNO_NOSYS),
    });
  }

  /** Lines not yet ended with a newline. */
  flush() {
    for (const fd of [1, 2]) {
      if (this.pending[fd - 1]) {
        const text = this.pending[fd - 1];
        this.pending[fd - 1] = "";
        this.outputs[fd - 1](text);
      }
    }
  }
}
