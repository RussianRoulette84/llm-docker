#!/bin/bash
# check-py.sh — guard the builder-api Python split: py_compile every module +
# an AST undefined-name audit (catches a function referencing a name that isn't
# imported/defined in its module — the failure mode py_compile + import miss,
# since such a NameError only fires when the method runs). Closure vars and
# `except ... as e` bindings are handled to avoid false positives.
set -u
PKG="$(cd "$(dirname "$0")/../../src/builder-api" && pwd)"
python3 - "$PKG" <<'PY'
import ast, builtins, sys, py_compile, glob, os
pkg = sys.argv[1]
rc = 0
B = set(dir(builtins)) | {"__file__", "__name__", "__doc__"}
for path in sorted(glob.glob(os.path.join(pkg, "*.py"))):
    try:
        py_compile.compile(path, doraise=True)
    except py_compile.PyCompileError as e:
        print(f"  ✗ compile: {e}"); rc = 1; continue
    tree = ast.parse(open(path).read())
    gbl = set()
    for n in ast.walk(tree):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names: gbl.add((a.asname or a.name).split(".")[0])
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            gbl.add(n.name)
        elif isinstance(n, ast.Assign):
            for t in ast.walk(n):
                if isinstance(t, ast.Name) and isinstance(t.ctx, ast.Store): gbl.add(t.id)
        elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
            gbl.add(n.target.id)  # `NAME: type = value` module constants

    def bound(node):
        s = set()
        for nn in ast.walk(node):
            if isinstance(nn, ast.arg): s.add(nn.arg)
            elif isinstance(nn, ast.Name) and isinstance(nn.ctx, ast.Store): s.add(nn.id)
            elif isinstance(nn, ast.AnnAssign) and isinstance(nn.target, ast.Name): s.add(nn.target.id)
            elif isinstance(nn, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)): s.add(nn.name)
            elif isinstance(nn, ast.ExceptHandler) and nn.name: s.add(nn.name)
        return s

    funcs = [x for x in ast.walk(tree) if isinstance(x, (ast.FunctionDef, ast.AsyncFunctionDef))]
    for fn in funcs:
        b = bound(fn)
        for other in funcs:
            if fn is not other and any(fn is d for d in ast.walk(other)): b |= bound(other)
        for nn in ast.walk(fn):
            if isinstance(nn, ast.Name) and isinstance(nn.ctx, ast.Load):
                if nn.id not in b and nn.id not in gbl and nn.id not in B:
                    print(f"  ✗ {os.path.basename(path)}: undefined '{nn.id}' in {fn.name}() line {nn.lineno}")
                    rc = 1
sys.exit(rc)
PY
if [ $? -ne 0 ]; then echo "check-py: FAIL (undefined names)" >&2; exit 1; fi

# Import smoke — pulls the whole daemon chain (server → handler → routes +
# app_context → build_queue → config → jobs). Catches class-body / module-level
# NameErrors the function-scoped AST audit above can't see.
if ! ( cd "$PKG" && python3 -c 'import server' >/dev/null 2>&1 ); then
    echo "  ✗ 'import server' failed:" >&2
    ( cd "$PKG" && python3 -c 'import server' 2>&1 | tail -3 | sed 's/^/    /' ) >&2
    echo "check-py: FAIL (import)" >&2; exit 1
fi
echo "check-py: clean ✓ — compile + no undefined names + import chain OK"
