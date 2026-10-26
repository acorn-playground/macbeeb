// MacBeeb's own ROMs and the Econet file server's disc, as the Mac app
// bundles them (Sources/BeebROMs: Acorn's copyright, not GPL), built into
// the page as assets so it starts with a working BBC.

// The page's: the Model B's and the Master 128's, with their network ROMs.
const roms = import.meta.glob([
  "../../Sources/BeebROMs/ROMs/os12.rom",
  "../../Sources/BeebROMs/ROMs/basic2.rom",
  "../../Sources/BeebROMs/ROMs/dfs12.rom",
  "../../Sources/BeebROMs/ROMs/dnfs.rom",
  "../../Sources/BeebROMs/ROMs/anfs425.rom",
  "../../Sources/BeebROMs/ROMs/mos320-*.rom",
], { query: "?url", import: "default", eager: true }) as Record<string, string>;
const discs = import.meta.glob("../../Sources/BeebROMs/Discs/econet-level1.ssd", { query: "?url", import: "default", eager: true }) as Record<string, string>;

function find(urls: Record<string, string>, name: string): string | undefined {
  return Object.entries(urls).find(([file]) => file.endsWith(`/${name}`))?.[1];
}

async function load(url: string | undefined): Promise<Uint8Array | null> {
  if (!url) return null;
  try {
    const response = await fetch(url);
    return response.ok ? new Uint8Array(await response.arrayBuffer()) : null;
  } catch {
    return null;
  }
}

/** A bundled ROM by MacBeeb's name for it (os12.rom, basic2.rom...). */
export const bundledROM = (name: string) => load(find(roms, name));

/** Acorn's Level 1 file server, on the disc the Mac app's Network Studio uses. */
export const fileServerDisc = () => load(find(discs, "econet-level1.ssd"));
