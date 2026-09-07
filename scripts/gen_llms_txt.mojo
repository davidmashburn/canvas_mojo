"""Generates docs/site/static/llms.txt: docs/llms.md (the hand-written
introduction and recipes) followed by an API digest read out of the
package's own source -- every public module, struct, trait and
function with its signature and the first sentence of its docstring.
Run as part of `pixi run docs` and on its own as `pixi run llms`.

The digest comes from the source text rather than `mojo doc`'s JSON
because Mojo's standard library has no JSON parser and this repo's
tooling stays in Mojo. `mojo format` normalizes the layout the parser
relies on: a `def` line that ends in `(` continues until a line that
ends in `:`, a docstring opens on the line after, and members of a
struct sit at four spaces.

Public means no leading underscore, plus `__init__`; the other dunder
methods are the language's, not the API's.
"""

from std.os import listdir
from std.os.path import isdir

comptime _SRC = "canvas"
comptime _HEADER = "docs/llms.md"
comptime _OUT = "docs/site/static/llms.txt"


def _sources(directory: String, mut out: List[String]) raises:
    var entries = listdir(directory)
    sort(entries)
    for entry in entries:
        var path = String(directory, "/", entry)
        if isdir(path):
            _sources(path, out)
        elif entry.endswith(".mojo") and not entry.startswith("__"):
            out.append(path)


def _module_name(path: String) -> String:
    # canvas/shapes/rects.mojo -> canvas.shapes.rects
    var trimmed = String(path[byte = : path.byte_length() - 5])
    return trimmed.replace("/", ".")


def _first_sentence(lines: List[String], start: Int) -> String:
    """The first sentence of the docstring opening at `lines[start]`,
    or "" when no docstring opens there."""
    if start >= len(lines):
        return ""
    var first = String(lines[start].strip())
    if not first.startswith('"""'):
        return ""
    var text = String()
    var i = start
    var opened = False
    while i < len(lines):
        var line = String(lines[i].strip())
        if not opened:
            var after_quotes = String(line[byte=3:])
            line = after_quotes
            opened = True
        var close = line.find('"""')
        if close >= 0:
            text += String(line[byte=:close])
            break
        if line == "" and text != "":
            break
        text += line + " "
        i += 1
    var flat = String(text.strip())
    # Cut at the first sentence end that is followed by a space or is
    # the end of the paragraph; a period inside backticks or a number
    # is not one.
    var pos = 0
    while True:
        var dot = flat.find(". ", pos)
        if dot < 0:
            return flat
        var before = String(flat[byte = dot - 1 : dot]) if dot > 0 else String(
            ""
        )
        if before == "`" or (before >= "0" and before <= "9"):
            pos = dot + 2
            continue
        return String(flat[byte = : dot + 1])


def _collapse(parts: List[String]) -> String:
    var joined = String()
    for part in parts:
        var p = String(part.strip())
        if p == "":
            continue
        if joined != "" and not joined.endswith("(") and not p.startswith(")"):
            joined += " "
        joined += p
    # "def f( a: Int, b: Int )" reads better without the inner spaces.
    return joined.replace("( ", "(").replace(" )", ")").replace(",)", ")")


def _def_name(stripped: String) -> String:
    var rest = String(stripped[byte=4:])
    var end = rest.byte_length()
    var paren = rest.find("(")
    if paren >= 0 and paren < end:
        end = paren
    var bracket = rest.find("[")
    if bracket >= 0 and bracket < end:
        end = bracket
    return String(rest[byte=:end])


def _public(name: String) -> Bool:
    if name == "__init__":
        return True
    return not name.startswith("_")


def _digest(path: String) raises -> String:
    var f = open(path, "r")
    var source = f.read()
    f.close()
    var lines = List[String]()
    for span in source.split("\n"):
        lines.append(String(span))
    var out = String()
    out += "## " + _module_name(path) + "\n\n"
    var summary = _first_sentence(lines, 0)
    if summary != "":
        out += summary + "\n\n"
    var in_public_type = False
    var constants = List[String]()
    var i = 0
    var entries = 0
    while i < len(lines):
        var line = lines[i]
        var stripped = String(line.strip())
        var indent = line.byte_length() - String(line.lstrip()).byte_length()
        if indent == 0 and (
            stripped.startswith("struct ") or stripped.startswith("trait ")
        ):
            var head = stripped
            var cut = head.find("(")
            var colon = head.find(":")
            if cut < 0 or (colon >= 0 and colon < cut):
                cut = colon
            var decl = String(head[byte=:cut]) if cut >= 0 else head
            var kind_end = decl.find(" ")
            var name = String(decl[byte = kind_end + 1 :])
            in_public_type = _public(name)
            if in_public_type:
                out += "### " + decl + "\n"
                var doc = _first_sentence(lines, i + 1)
                if doc != "":
                    out += doc + "\n"
                entries += 1
            i += 1
            continue
        if indent == 0 and stripped.startswith("comptime ") and "=" in stripped:
            # A module-level constant. A long list of them (the named
            # colors) is collapsed to its names.
            var eq = stripped.find("=")
            var name = String(stripped[byte=9:eq].strip())
            if _public(name):
                constants.append(name)
                entries += 1
            i += 1
            continue
        if (
            indent == 4
            and in_public_type
            and stripped.startswith("comptime ")
            and "= Self(" in stripped
        ):
            var eq = stripped.find("=")
            out += "- value `" + String(stripped[byte=9:eq].strip()) + "`\n"
            i += 1
            continue
        if stripped.startswith("def ") and (
            indent == 0 or (indent == 4 and in_public_type)
        ):
            var name = _def_name(stripped)
            if not _public(name):
                i += 1
                continue
            var parts = List[String]()
            var j = i
            while j < len(lines):
                var piece = String(lines[j].strip())
                parts.append(piece)
                if piece.endswith(":"):
                    break
                j += 1
            var collapsed = _collapse(parts)
            var signature = String(
                collapsed[byte = : collapsed.byte_length() - 1]
            )
            var doc = _first_sentence(lines, j + 1)
            var prefix = "- `" if indent == 0 else "  - `"
            out += prefix + signature + "`"
            if doc != "":
                out += " -- " + doc
            out += "\n"
            entries += 1
            i = j + 1
            continue
        if (
            indent == 0
            and stripped != ""
            and not stripped.startswith("#")
            and not stripped.startswith('"""')
            and not stripped.startswith("from ")
            and not stripped.startswith("import ")
        ):
            # Any other top-level statement ends a type's member list.
            if not stripped.startswith("struct ") and not stripped.startswith(
                "trait "
            ):
                in_public_type = False
        i += 1
    if len(constants) > 12:
        out += "Constants: " + String(", ").join(constants) + "\n"
    else:
        for name in constants:
            out += "- constant `" + name + "`\n"
    if entries == 0:
        return ""
    return out + "\n"


def main() raises:
    var files = List[String]()
    _sources(_SRC, files)
    var header = open(_HEADER, "r")
    var text = header.read()
    header.close()
    text += "## API\n\n"
    text += "Every public name, by module. `_aa` is anti-aliased; the same\n"
    text += "name without it is hard-edged. Signatures are Mojo: `mut` marks\n"
    text += "an argument the call modifies.\n\n"
    for path in files:
        text += _digest(path)
    var out = open(_OUT, "w")
    out.write(text)
    out.close()
    print("wrote", _OUT, "from", len(files), "source files")
