// The BBC's sound, played: the emulation worker sends batches of samples
// (at the AudioContext's rate) straight here, through a MessagePort, and
// this plays them out. The worker runs by the clock, and so does the
// audio hardware, but not quite at the same rate: what's waiting is kept
// between about 40ms and 150ms (beyond that the oldest is dropped), and an
// empty buffer fades to silence rather than clicking. Every 250ms it tells
// the page the loudest sample, for its meter.

declare const sampleRate: number;
declare function registerProcessor(name: string, processor: unknown): void;
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
}

class BeebSound extends AudioWorkletProcessor {
  private queue: Float32Array[] = [];
  private offset = 0;
  private queued = 0;
  private last = 0;
  private started = false;
  private peak = 0;
  private sinceReport = 0;
  private readonly maxQueued = Math.round(sampleRate * 0.15);
  private readonly minStart = Math.round(sampleRate * 0.04);

  constructor() {
    super();
    this.port.onmessage = (event: MessageEvent) => {
      // The worker's port, to listen to.
      const port = event.data.port as MessagePort | undefined;
      if (port) port.onmessage = (e: MessageEvent<Float32Array>) => this.add(e.data);
    };
  }

  private add(samples: Float32Array) {
    this.queue.push(samples);
    this.queued += samples.length;
    // Too far behind: drop the oldest.
    while (this.queued > this.maxQueued && this.queue.length > 1) {
      const dropped = this.queue.shift()!;
      this.queued -= dropped.length - this.offset;
      this.offset = 0;
    }
  }

  process(_inputs: Float32Array[][], outputs: Float32Array[][]): boolean {
    const output = outputs[0];
    const out = output[0];
    if (!this.started && this.queued >= this.minStart) this.started = true;
    for (let i = 0; i < out.length; i++) {
      if (this.started && this.queue.length) {
        const head = this.queue[0];
        this.last = head[this.offset++];
        this.queued--;
        if (this.offset >= head.length) {
          this.queue.shift();
          this.offset = 0;
        }
      } else {
        // Run dry: fade out, and wait to fill again before playing.
        this.started = false;
        this.last *= 0.995;
      }
      out[i] = this.last;
      this.peak = Math.max(this.peak, Math.abs(this.last));
    }
    for (let c = 1; c < output.length; c++) output[c].set(out);
    this.sinceReport += out.length;
    if (this.sinceReport >= sampleRate / 4) {
      this.port.postMessage({ peak: this.peak, queuedMs: (this.queued / sampleRate) * 1000 });
      this.peak = 0;
      this.sinceReport = 0;
    }
    return true;
  }
}

registerProcessor("beeb-sound", BeebSound);
