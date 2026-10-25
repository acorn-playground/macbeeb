// Connects VS Code's debugger to MacBeeb, which serves the Debug Adapter
// Protocol on a localhost port (Settings > Debugging). Starts MacBeeb if
// it isn't running.

const vscode = require("vscode");
const net = require("net");
const path = require("path");
const { execFile } = require("child_process");

const bundleID = "com.accidentalfish.macbeeb";
const defaultPort = 6502;

function canConnect(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: "127.0.0.1", port }, () => {
      socket.end();
      resolve(true);
    });
    socket.on("error", () => resolve(false));
  });
}

async function waitForMacBeeb(port) {
  if (await canConnect(port)) return;
  await new Promise((resolve) => execFile("open", ["-g", "-b", bundleID], () => resolve()));
  for (let i = 0; i < 50; i++) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    if (await canConnect(port)) return;
  }
  throw new Error(`MacBeeb isn't listening on port ${port}. Is it installed, with debugging on in Settings > Debugging?`);
}

// Baron and BeebAsm sources can both be .6502: Baron's save sections with
// a filename, BeebAsm's SAVE.
function looksLikeBaron(document) {
  const text = document.getText();
  return /^\s*SECTION\b/im.test(text) && !/^\s*SAVE\s*"/im.test(text);
}

// A Baron launch for the active file, using the Baron extension's settings
// (root source files, switches and defines) when it has them.
function baronConfiguration(config, document) {
  const folder = vscode.workspace.getWorkspaceFolder(document.uri);
  const settings = vscode.workspace.getConfiguration("baron", document.uri);
  const roots = settings.get("sourceFiles") || [];
  config.type = "macbeeb";
  config.request = "launch";
  config.name = "Assemble and run (Baron)";
  config.baron = roots.length && folder ? roots.map((f) => path.resolve(folder.uri.fsPath, f)) : [document.fileName];
  const defines = (settings.get("defines") || []).flatMap((d) => ["-D", d.includes("=") ? d : `${d}=TRUE`]);
  config.baronArgs = [...defines, ...(settings.get("buildArgs") || [])];
  return config;
}

function activate(context) {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("macbeeb", {
      async createDebugAdapterDescriptor(session) {
        const port = session.configuration.port || defaultPort;
        await waitForMacBeeb(port);
        return new vscode.DebugAdapterServer(port, "127.0.0.1");
      },
    }),
    vscode.debug.registerDebugConfigurationProvider("macbeeb", {
      resolveDebugConfiguration(folder, config) {
        // F5 with no launch.json: assemble and run a BeebAsm or Baron file,
        // run a BASIC program, or run the binary built from a ca65 one.
        if (!config.type && !config.request) {
          const editor = vscode.window.activeTextEditor;
          const language = editor && editor.document.languageId;
          if (language === "baron" || (language === "beebasm" && looksLikeBaron(editor.document))) {
            baronConfiguration(config, editor.document);
          } else if (language === "beebasm") {
            config.type = "macbeeb";
            config.request = "launch";
            config.name = "Assemble and run";
            config.source = editor.document.fileName;
          } else if (editor && editor.document.languageId === "bbcbasic") {
            config.type = "macbeeb";
            config.request = "launch";
            config.name = "Run BASIC on the BBC Micro";
            config.basic = editor.document.fileName;
          } else if (editor && editor.document.languageId === "ca65") {
            config.type = "macbeeb";
            config.request = "launch";
            config.name = "Run on the BBC Micro";
            config.program = editor.document.fileName.replace(/\.[^.]+$/, ".bin");
          }
        }
        // Save before assembling (or loading BASIC).
        if (config.source || config.baron || config.basic) {
          return vscode.workspace.saveAll(false).then(() => config);
        }
        return config;
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
