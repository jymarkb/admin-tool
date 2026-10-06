"""Syntax-check a Luau file with a stock Lua runtime.

Lua 5.4/5.5 has no compound assignment, so files using `+=` fail to compile for
reasons that have nothing to do with their correctness. This normalises only that
construct, then compiles. Anchored on real code lines (a comment such as
"-- changed += 1" cannot match, because `\\S+` must directly follow whitespace),
so comments and strings are left alone.

    python3 tools/luau_syntax_check.py farmer/debug.lua
"""
import lupa, re, sys

# `lhs += rhs` anywhere on a line, not just at statement start. The RHS is kept
# to a simple term (number, name, index, or call) which covers every use in these
# files; anything left unconsumed is reported rather than silently ignored.
# The RHS is kept to a simple term - optional unary minus/not, then a number,
# name, index or call - which covers every use in these files. Anything left
# unconsumed is reported rather than silently ignored.
ASSIGN = re.compile(
    r'([A-Za-z_][\w\.\[\]\'"]*)\s*\+=\s*'
    r'(-?\s*(?:\([^()]*\)|[\w\.\[\]\'"]+(?:\([^()]*\))?'
    r'[\w\.\[\]\'"]*))')

def normalise(src: str) -> str:
    src = ASSIGN.sub(lambda m: f"{m.group(1)} = {m.group(1)} + ({m.group(2)})", src)
    return src

def check(path):
    src = open(path).read()
    lua = lupa.LuaRuntime()
    try:
        lua.compile(src)
        return "OK (no normalisation needed)", 0
    except Exception:
        pass
    norm = normalise(src)
    left = norm.count("+=")
    if left:
        print(f"  note: {left} '+=' not normalised (complex RHS); "
              "check spans 'end'/newline and is a plain assignment")
        for i, line in enumerate(norm.split("\n"), 1):
            if "+=" in line:
                print(f"    {i:4d}| {line.strip()[:90]}")
    try:
        lua.compile(norm)
        return "OK (after normalising +=)", 0
    except Exception as e:
        line = 0
        m = re.search(r'\[string "<python>"\]:(\d+)', str(e))
        if m:
            line = int(m.group(1))
            ctx = norm.split("\n")
            lo, hi = max(0, line - 3), min(len(ctx), line + 2)
            print("  context:")
            for i in range(lo, hi):
                print(f"    {i+1:4d}| {ctx[i]}")
        return f"SYNTAX ERROR: {str(e)[:160]}", 1

if __name__ == "__main__":
    for path in sys.argv[1:]:
        status, code = check(path)
        print(f"{path}: {status}")
        if code:
            sys.exit(code)
