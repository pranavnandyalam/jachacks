// Syntax-only check for a TypeScript/JavaScript file: prints nothing and exits 0
// when it parses, else prints the first errors and exits 1. No type-checking,
// so missing @types packages don't matter -- this only catches broken code.
const fs = require("fs");
const ts = require("typescript");

const file = process.argv[2];
const src = fs.readFileSync(file, "utf8");
const out = ts.transpileModule(src, {
  fileName: file,
  reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
});
const errs = (out.diagnostics || []).filter((d) => d.category === ts.DiagnosticCategory.Error);
if (errs.length) {
  for (const d of errs.slice(0, 3)) {
    const pos = d.file ? d.file.getLineAndCharacterOfPosition(d.start) : { line: 0 };
    console.log(`line ${pos.line + 1}: ${ts.flattenDiagnosticMessageText(d.messageText, " ")}`);
  }
  process.exit(1);
}
