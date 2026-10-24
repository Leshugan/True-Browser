#!/bin/bash
# True Browser: the whole build. Lives in the repo root.
# Started by .github/workflows/build.yml every time a file is uploaded to the repo root.
# Results (Actions -> run -> Artifacts): TrueBrowser-<ver>-arm64.apk and report.txt
set -eo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND"' ERR
REPO=$(cd "$(dirname "$0")" && pwd)
cd "$GITHUB_WORKSPACE"

echo "::group::Repo cleanup + signing key"
cd "$REPO"
git config user.name "github-actions"; git config user.email "github-actions@users.noreply.github.com"
[ -f signing/truebrowser.jks ] && [ ! -f truebrowser.jks ] && git mv signing/truebrowser.jks truebrowser.jks
if [ ! -f truebrowser.jks ]; then   # created once, every build signs with it -> installs over the previous one
  keytool -genkeypair -keystore truebrowser.jks -storepass truebrowser -keypass truebrowser -alias tb \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=True Browser"
  git add truebrowser.jks
fi
if [ ! -f truebrowser_ext.pem ]; then   # key of the built-in helper extension: created once, keeps its ID forever
  openssl genrsa -out truebrowser_ext.pem 2048 2>/dev/null
  git add truebrowser_ext.pem
fi
# keep only: the build script, the key, the workflow, README/LICENSE
git ls-files | grep -vE '^(truebrowser\.sh|truebrowser\.jks|truebrowser_ext\.pem|\.github/.*|README.*|LICENSE.*)$' | while read -r f; do git rm -q -- "$f"; echo "removed $f"; done || true
if ! git diff --cached --quiet; then git commit -qm "Tidy repo: build script and signing key in the root"; git push -q; fi
cp truebrowser.jks "$GITHUB_WORKSPACE/ks.jks"
cp truebrowser_ext.pem "$GITHUB_WORKSPACE/ext.pem"
cd "$GITHUB_WORKSPACE"
echo "::endgroup::"

echo "::group::Download latest Titanium (arm64)"
gh release view -R jqssun/android-titanium-browser --json tagName,assets > rel.json
TAG=$(jq -r .tagName rel.json); VER=${TAG#v}
NAME=$(jq -r '.assets[].name' rel.json | grep -i arm64 | grep -i '\.apk$' | head -1)
gh release download "$TAG" -R jqssun/android-titanium-browser -p "$NAME" -O app.apk
BT=$ANDROID_HOME/build-tools/$(ls $ANDROID_HOME/build-tools | sort -V | tail -1)
curl -fsSL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar \
  || curl -fsSL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v2.10.0/apktool_2.10.0.jar
echo "::endgroup::"

mkdir -p tb out
cat > tb/axml.py <<'PYEOF'
"""Minimal reader/writer for Android binary XML (AXML) files.

Supports what layouts and manifests in a compiled APK use: string pool
(UTF-8 or UTF-16, no styles), resource map, namespaces, elements, CDATA.
"""
import struct

RES_STRING_POOL = 0x0001
RES_XML = 0x0003
XML_START_NS = 0x0100
XML_END_NS = 0x0101
XML_START_EL = 0x0102
XML_END_EL = 0x0103
XML_CDATA = 0x0104
XML_RES_MAP = 0x0180
NONE = 0xFFFFFFFF

T_REFERENCE = 0x01
T_STRING = 0x03
T_FLOAT = 0x04
T_INT_DEC = 0x10
T_INT_HEX = 0x11

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ATTR = {  # android attribute resource ids
    "id": 0x010100D0,
    "layout_gravity": 0x010100B3,
    "layout_width": 0x010100F4,
    "layout_height": 0x010100F5,
    "layout_marginTop": 0x010100F8,
    "layout_marginBottom": 0x010100FA,
    "rotation": 0x01010326,
    "scaleX": 0x01010324,
    "src": 0x01010119,
    "visibility": 0x010100DC,
    "onClick": 0x0101026F,
    "contentDescription": 0x01010273,
    "tooltipText": 0x01010534,
    "fillViewport": 0x0101017A,
    "background": 0x010100D4,
    "layout_marginStart": 0x010103B5,
    "layoutDirection": 0x010103B2,
    "gravity": 0x010100AF,
}


class Attr:
    def __init__(self, ns, name, raw, dtype, data):
        self.ns, self.name, self.raw, self.dtype, self.data = ns, name, raw, dtype, data


class Node:
    def __init__(self, kind, line, comment):
        self.kind, self.line, self.comment = kind, line, comment
        self.ns = self.name = NONE
        self.attrs = []
        self.prefix = self.uri = NONE
        self.cdata = NONE
        self.ctype = (0, 0)


def _read_pool(buf, off):
    (t, hsz, size, count, scount, flags, sstart, _) = struct.unpack_from("<HHIIIIII", buf, off)
    if scount:
        raise ValueError("string pool styles are not supported")
    utf8 = bool(flags & 0x100)
    offs = struct.unpack_from("<%dI" % count, buf, off + hsz)
    base = off + sstart
    out = []
    for o in offs:
        p = base + o
        if utf8:
            n = buf[p]; p += 1
            if n & 0x80:
                p += 1
            n = buf[p]; p += 1
            if n & 0x80:
                n = ((n & 0x7F) << 8) | buf[p]; p += 1
            out.append(buf[p:p + n].decode("utf-8", "surrogatepass"))
        else:
            n, = struct.unpack_from("<H", buf, p); p += 2
            if n & 0x8000:
                n2, = struct.unpack_from("<H", buf, p); p += 2
                n = ((n & 0x7FFF) << 16) | n2
            out.append(buf[p:p + 2 * n].decode("utf-16-le", "surrogatepass"))
    return out, utf8, size


def _write_pool(strings, utf8):
    data = bytearray()
    offs = []
    for s in strings:
        offs.append(len(data))
        if utf8:
            b = s.encode("utf-8", "surrogatepass")
            u16 = len(s.encode("utf-16-le", "surrogatepass")) // 2
            for n in (u16, len(b)):
                if n > 0x7F:
                    data += bytes([0x80 | (n >> 8), n & 0xFF])
                else:
                    data += bytes([n])
            data += b + b"\x00"
        else:
            b = s.encode("utf-16-le", "surrogatepass")
            n = len(b) // 2
            if n > 0x7FFF:
                data += struct.pack("<HH", 0x8000 | (n >> 16), n & 0xFFFF)
            else:
                data += struct.pack("<H", n)
            data += b + b"\x00\x00"
    while len(data) % 4:
        data += b"\x00"
    hsz = 28
    sstart = hsz + 4 * len(strings)
    size = sstart + len(data)
    head = struct.pack("<HHIIIIII", RES_STRING_POOL, hsz, size, len(strings), 0,
                       0x100 if utf8 else 0, sstart, 0)
    return head + struct.pack("<%dI" % len(offs), *offs) + bytes(data)


class AXML:
    def __init__(self, data):
        buf = bytes(data)
        t, hsz, total = struct.unpack_from("<HHI", buf, 0)
        if t != RES_XML:
            raise ValueError("not a binary XML file")
        off = hsz
        self.strings, self.utf8, self.resmap, self.nodes = [], True, [], []
        while off < total:
            ct, chs, csz = struct.unpack_from("<HHI", buf, off)
            if ct == RES_STRING_POOL:
                self.strings, self.utf8, _ = _read_pool(buf, off)
            elif ct == XML_RES_MAP:
                n = (csz - chs) // 4
                self.resmap = list(struct.unpack_from("<%dI" % n, buf, off + chs))
            elif XML_START_NS <= ct <= XML_CDATA:
                line, comment = struct.unpack_from("<II", buf, off + 8)
                nd = Node(ct, line, comment)
                e = off + chs
                if ct in (XML_START_NS, XML_END_NS):
                    nd.prefix, nd.uri = struct.unpack_from("<II", buf, e)
                elif ct == XML_START_EL:
                    nd.ns, nd.name, astart, asize, acount = struct.unpack_from("<IIHHH", buf, e)
                    a = e + astart
                    for _ in range(acount):
                        ns, name, raw, _s, _r, dt, d = struct.unpack_from("<IIIHBBI", buf, a)
                        nd.attrs.append(Attr(ns, name, raw, dt, d))
                        a += asize
                elif ct == XML_END_EL:
                    nd.ns, nd.name = struct.unpack_from("<II", buf, e)
                else:
                    nd.cdata, _s, _r, dt, d = struct.unpack_from("<IHBBI", buf, e)
                    nd.ctype = (dt, d)
                self.nodes.append(nd)
            off += csz

    # ---------- strings ----------
    def s(self, i):
        return None if i == NONE else self.strings[i]

    def _shift(self, pos):
        def f(i):
            return i + 1 if i != NONE and i >= pos else i
        for nd in self.nodes:
            nd.comment = f(nd.comment)
            nd.ns, nd.name, nd.prefix, nd.uri, nd.cdata = map(f, (nd.ns, nd.name, nd.prefix, nd.uri, nd.cdata))
            if nd.ctype[0] == T_STRING:
                nd.ctype = (T_STRING, f(nd.ctype[1]))
            for a in nd.attrs:
                a.ns, a.name, a.raw = f(a.ns), f(a.name), f(a.raw)
                if a.dtype == T_STRING:
                    a.data = f(a.data)

    def attr_name(self, name):
        """String index for android:<name>, inserted into the resource-mapped area if missing."""
        rid = ATTR[name]
        if rid in self.resmap:
            return self.resmap.index(rid)
        pos = len(self.resmap)
        self._shift(pos)
        self.strings.insert(pos, name)
        self.resmap.append(rid)
        return pos

    def string_index(self, value):
        if value in self.strings[len(self.resmap):]:
            return self.strings.index(value, len(self.resmap))
        self.strings.append(value)
        return len(self.strings) - 1

    def android_ns(self):
        if ANDROID_NS in self.strings:
            return self.strings.index(ANDROID_NS)
        self.strings.append(ANDROID_NS)
        return len(self.strings) - 1

    # ---------- elements ----------
    def elements(self):
        """Yield (node, parent_node) for every start element."""
        stack = []
        for nd in self.nodes:
            if nd.kind == XML_START_EL:
                yield nd, (stack[-1] if stack else None)
                stack.append(nd)
            elif nd.kind == XML_END_EL:
                stack.pop()

    def tag(self, nd):
        return self.s(nd.name)

    def attr_res(self, a):
        return self.resmap[a.name] if a.name < len(self.resmap) else None

    def get(self, nd, name):
        rid = ATTR.get(name)
        for a in nd.attrs:
            if rid is not None and self.attr_res(a) == rid:
                return a
            if rid is None and self.s(a.name) == name and a.ns == NONE:
                return a
        return None

    def set(self, nd, name, dtype, data):
        a = self.get(nd, name)
        if a is None:
            nm = self.attr_name(name)  # may insert a string: resolve namespace after it
            a = Attr(self.android_ns(), nm, NONE, dtype, data)
            nd.attrs.append(a)
        a.raw, a.dtype, a.data = NONE, dtype, data

    def rename_attr(self, nd, old, new):
        a = self.get(nd, old)
        if a is None:
            return False
        a.name = self.attr_name(new)
        return True

    # ---------- tree editing ----------
    def span(self, nd):
        """(first, last) node indices of an element including its children."""
        i = next(k for k, n in enumerate(self.nodes) if n is nd)
        depth = 0
        for j in range(i, len(self.nodes)):
            k = self.nodes[j].kind
            if k == XML_START_EL:
                depth += 1
            elif k == XML_END_EL:
                depth -= 1
                if depth == 0:
                    return i, j
        raise ValueError("unbalanced element")

    def move_after_start(self, nd, parent):
        """Move element nd (with children) to be the first child of parent."""
        i, j = self.span(nd)
        block = self.nodes[i:j + 1]
        del self.nodes[i:j + 1]
        p = next(k for k, n in enumerate(self.nodes) if n is parent)
        self.nodes[p + 1:p + 1] = block

    def wrap(self, nd, tag, attrs):
        """Put element nd inside a new element <tag attrs...>; returns the new element."""
        i, j = self.span(nd)
        w = Node(XML_START_EL, self.nodes[i].line, NONE)
        w.ns, w.name = NONE, self.string_index(tag)
        e = Node(XML_END_EL, self.nodes[i].line, NONE)
        e.ns, e.name = NONE, w.name
        self.nodes.insert(j + 1, e)
        self.nodes.insert(i, w)
        for name, dtype, data in attrs:
            self.set(w, name, dtype, data)
        return w

    def clone_first_child(self, src, parent):
        """Copy element src (no children) and insert the copy as the first child of parent."""
        i, _ = self.span(src)
        s = self.nodes[i]
        n = Node(XML_START_EL, s.line, NONE)
        n.ns, n.name = s.ns, s.name
        n.attrs = [Attr(a.ns, a.name, a.raw, a.dtype, a.data) for a in s.attrs]
        e = Node(XML_END_EL, s.line, NONE)
        e.ns, e.name = s.ns, s.name
        k = next(k for k, x in enumerate(self.nodes) if x is parent)
        self.nodes[k + 1:k + 1] = [n, e]
        return n

    def retag(self, nd, tag):
        _, j = self.span(nd)
        nd.ns = self.nodes[j].ns = NONE
        nd.name = self.nodes[j].name = self.string_index(tag)

    def drop(self, nd, name):
        rid = ATTR[name]
        nd.attrs = [a for a in nd.attrs if self.attr_res(a) != rid]

    def set_str(self, nd, name, value):
        self.set(nd, name, T_STRING, 0)
        a = self.get(nd, name)
        a.data = a.raw = self.string_index(value)

    def move_after(self, nd, sibling):
        """Move element nd (with children) right after element sibling."""
        i, j = self.span(nd)
        block = self.nodes[i:j + 1]
        del self.nodes[i:j + 1]
        _, e = self.span(sibling)
        self.nodes[e + 1:e + 1] = block

    # ---------- write ----------
    def tobytes(self):
        for nd in self.nodes:
            if nd.kind == XML_START_EL:
                def key(a):
                    r = self.attr_res(a)
                    return (0, r) if r is not None else (1, 0)
                nd.attrs.sort(key=key)
        out = bytearray()
        out += _write_pool(self.strings, self.utf8)
        out += struct.pack("<HHI", XML_RES_MAP, 8, 8 + 4 * len(self.resmap))
        out += struct.pack("<%dI" % len(self.resmap), *self.resmap)
        for nd in self.nodes:
            if nd.kind in (XML_START_NS, XML_END_NS):
                body = struct.pack("<II", nd.prefix, nd.uri)
            elif nd.kind == XML_START_EL:
                idx = {"id": 0, "class": 0, "style": 0}
                for i, a in enumerate(nd.attrs, 1):
                    if self.attr_res(a) == ATTR["id"]:
                        idx["id"] = i
                    elif a.ns == NONE and self.s(a.name) in ("class", "style"):
                        idx[self.s(a.name)] = i
                body = struct.pack("<IIHHHHHH", nd.ns, nd.name, 20, 20, len(nd.attrs),
                                   idx["id"], idx["class"], idx["style"])
                for a in nd.attrs:
                    body += struct.pack("<IIIHBBI", a.ns, a.name, a.raw, 8, 0, a.dtype, a.data)
            elif nd.kind == XML_END_EL:
                body = struct.pack("<II", nd.ns, nd.name)
            else:
                body = struct.pack("<IHBBI", nd.cdata, 8, 0, nd.ctype[0], nd.ctype[1])
            out += struct.pack("<HHIII", nd.kind, 16, 16 + len(body), nd.line, nd.comment) + body
        return struct.pack("<HHI", RES_XML, 8, 8 + len(out)) + bytes(out)
PYEOF
cat > tb/patch_apk.py <<'PYEOF'
#!/usr/bin/env python3
"""True Browser: edits the original Titanium APK in place (no apktool rebuild).

Usage: patch_apk.py <in.apk> <public.xml> <out.apk> [--no-layout] [--no-rename]

Only the few compiled XML files that need changes are rewritten; every other
entry (code, native libs, resources.arsc) is copied byte-for-byte.
  1. Tab grid anchored to the bottom, rows grow upwards
     (recycler rotated 180 + RTL, each card rotated back).
  2. Tab switcher toolbar moved to the bottom.
  3. Package renamed to leshugan.truebrowser.
"""
import os, re, struct, sys, zipfile
from axml import AXML, T_FLOAT, T_INT_DEC, T_INT_HEX, T_REFERENCE, T_STRING, NONE

SRC, PUBLIC, DST = sys.argv[1:4]
OPTS = set(sys.argv[4:])
REPLACE = dict(o[10:].split("=", 1) for o in OPTS if o.startswith("--replace="))
OLD_PKG = "io.github.jqssun.helium"
NEW_PKG = "leshugan.truebrowser"
APP_NAME = "True Browser"
ROT180 = struct.unpack("<I", struct.pack("<f", 180.0))[0]
MATCH_PARENT, WRAP_CONTENT, GRAVITY_BOTTOM = 0xFFFFFFFF, 0xFFFFFFFE, 0x50
RTL, LTR = 1, 0
T_BOOLEAN, TRUE = 0x12, 0xFFFFFFFF


def die(msg):
    print("ERROR:", msg)
    sys.exit(1)


pub = open(PUBLIC, encoding="utf-8").read()


def res_id(typ, name):
    m = re.search(r'type="%s" name="%s" id="(0x[0-9a-f]+)"' % (typ, name), pub)
    if not m:
        die("no id for %s/%s" % (typ, name))
    return int(m.group(1), 16)


ID_TLRV = res_id("id", "tab_list_recycler_view")
ID_HPHC = res_id("id", "hub_pane_host_container")
ID_HMC = res_id("id", "hub_main_container")
ID_TAC = res_id("id", "toolbar_action_container")
ID_TAB = res_id("id", "toolbar_action_button")
ID_PSC = res_id("id", "pane_switcher_card")
ID_PS = res_id("id", "pane_switcher")
GRAVITY_CENTER = 0x11
GRAVITY_BOTTOM_CENTER = 0x51
GRAVITY_START_CV = 0x00800013
T_DIMENSION, DP16, DP48 = 0x05, (16 << 8) | 1, (48 << 8) | 1
ID_MBC = res_id("id", "menu_button_container")
_m = re.search(r'type="id" name="location_bar_status_icon" id="(0x[0-9a-f]+)"', pub)
ID_STATUS = int(_m.group(1), 16) if _m else None
STATUS_FROM = os.environ.get("TB_STATUS_TAG", "")
# extensions button on the browser toolbar: hidden (gone and zero size, so the code cannot bring it back)
EXT_IDS = {int(m.group(2), 16): m.group(1) for m in re.finditer(
    r'type="id" name="(extensions_menu_button)" id="(0x[0-9a-f]+)"', pub)}
print("extensions button ids:", sorted(EXT_IDS.values()))



def el_id(x, nd):
    a = x.get(nd, "id")
    return a.data if a is not None else None


def patch_layouts(zin):
    changed = {}
    found = {"recycler": 0, "card": 0, "hub": 0}
    ntp = {"bottom": 0, "tiles": 0}
    found_ext = []
    if "--no-toolbar" not in OPTS:
        found["toolbar"] = 0
    for info in zin.infolist():
        n = info.filename
        if not (n.startswith("res/") and n.endswith(".xml")):
            continue
        data = zin.read(n)
        if data[:2] != b"\x03\x00":
            continue
        try:
            x = AXML(data)
        except Exception:
            continue
        els = list(x.elements())
        if not els:
            continue
        root = els[0][0]
        tag = x.tag(root) or ""
        mod = False
        if tag == "org.chromium.chrome.browser.tasks.tab_management.TabListRecyclerView" and el_id(x, root) == ID_TLRV:
            x.set(root, "rotation", T_FLOAT, ROT180)
            x.set(root, "layoutDirection", T_INT_DEC, RTL)
            found["recycler"] += 1; mod = True
        elif tag.endswith("TabGridView"):
            x.set(root, "rotation", T_FLOAT, ROT180)
            x.set(root, "layoutDirection", T_INT_DEC, LTR)
            found["card"] += 1; mod = True
        elif any(el_id(x, nd) == ID_HPHC for nd, _ in els):
            c = i = 0
            for nd, parent in els:
                if el_id(x, nd) == ID_HPHC and x.rename_attr(nd, "layout_marginTop", "layout_marginBottom"):
                    c += 1
                if x.tag(nd) == "include" and parent is not None and el_id(x, parent) == ID_HMC:
                    x.set(nd, "layout_width", T_INT_DEC, MATCH_PARENT)
                    x.set(nd, "layout_height", T_INT_DEC, WRAP_CONTENT)
                    x.set(nd, "layout_gravity", T_INT_HEX, GRAVITY_BOTTOM)
                    i += 1
            if c != 1 or i != 1:
                die("hub layout %s: container=%d toolbar include=%d" % (n, c, i))
            found["hub"] += 1; mod = True
        if "--no-toolbar" not in OPTS and any(el_id(x, nd) == ID_TAC for nd, _ in els):
            # tab switcher toolbar: put "+" right after the tabs/groups switcher
            byid = {el_id(x, nd): (nd, par) for nd, par in els if el_id(x, nd) is not None}
            if ID_TAB not in byid:
                die("toolbar %s: no action button" % n)
            btn, btn_parent = byid[ID_TAB]
            if ID_PSC in byid:  # switcher in a card: card goes first into the "+" row, row centered
                card = byid[ID_PSC][0]
                # the code casts the card's layout params to FrameLayout ones: keep a FrameLayout parent
                holder = x.wrap(card, "FrameLayout", [("layout_width", T_INT_DEC, WRAP_CONTENT),
                                                      ("layout_height", T_INT_DEC, MATCH_PARENT)])
                x.move_after_start(holder, btn_parent)
                x.set(btn_parent, "layout_gravity", T_INT_HEX, GRAVITY_CENTER)
                print("toolbar %s: card (in its own frame) moved before +" % n)
            elif ID_PS in byid:  # plain switcher in one row: "+" goes after it
                x.move_after(btn, byid[ID_PS][0])
                print("toolbar %s: + moved after switcher" % n)
            else:
                die("toolbar %s: no switcher" % n)
            # "close all tabs" button on the left: a copy of the menu button, sized like "+",
            # on the switcher's rounded background; the double cross is drawn by tb.CloseAllButton
            menu = next((nd for nd, par in els if par is not None and el_id(x, par) == ID_MBC
                         and (x.tag(nd) or "").endswith("ImageButton")), None)
            if menu is None:
                die("toolbar %s: no menu button to copy" % n)
            tac = byid[ID_TAC][0]
            b = x.clone_first_child(menu, tac)
            for a in ("id", "tooltipText", "visibility", "src", "layout_marginStart"):
                x.drop(b, a)
            # fixed 48dp touch target; the rounded backing is drawn by the button itself
            x.drop(b, "background")
            x.set(b, "layout_width", T_DIMENSION, DP48)
            x.set(b, "layout_height", T_DIMENSION, DP48)
            x.set(b, "layout_marginStart", T_DIMENSION, DP16)
            x.set(b, "layout_gravity", T_INT_HEX, GRAVITY_START_CV)
            x.retag(b, "tb.CloseAllButton")
            x.set_str(b, "contentDescription", "Закрыть все вкладки")
            print("toolbar %s: close-all button added" % n)
            found["toolbar"] += 1; mod = True
        if tag.endswith("ntp.NewTabPageLayout"):
            # home page content sits at the bottom (the code makes the page as tall as the screen)
            x.set(root, "gravity", T_INT_HEX, GRAVITY_BOTTOM_CENTER)
            ntp["bottom"] += 1; mod = True
        for nd, _ in els:
            if el_id(x, nd) in EXT_IDS:
                x.set(nd, "visibility", T_INT_DEC, 2)
                x.set(nd, "layout_width", T_DIMENSION, 0)
                x.set(nd, "layout_height", T_DIMENSION, 0)
                found_ext.append("%s in %s" % (EXT_IDS[el_id(x, nd)], n)); mod = True
        for nd, _ in els:
            if ID_STATUS is not None and STATUS_FROM and el_id(x, nd) == ID_STATUS and x.tag(nd) == STATUS_FROM:
                # address bar icon: drawn round when it shows a site / search engine picture
                x.retag(nd, "tb.RoundIcon")
                print("status icon made round in %s" % n); mod = True
        tiles_row = next((nd for nd, _ in els if (x.tag(nd) or "").endswith("MostVisitedTilesLayout")), None)
        if tiles_row is not None:
            # home page speed dial right to left: the row fills the width and lays tiles out from the right
            # (no mirroring: a mirrored row showed reversed text while a tile is held)
            x.set(root, "fillViewport", T_BOOLEAN, TRUE)
            x.set(tiles_row, "layoutDirection", T_INT_DEC, RTL)
            ntp["tiles"] += 1; mod = True
            print("tiles row right to left: %s" % n)
        if mod:
            out = x.tobytes()
            AXML(out)  # sanity re-parse
            changed[n] = out
            print("patched %s (%s)" % (n, tag))
    print("found:", found, "home page:", ntp)
    print("extensions button hidden:", found_ext)
    if not all(found.values()):
        die("not all layouts found")
    return changed


# ---------- chrome://extensions page (inside resources.pak) ----------
PAK_EDITS = [
    # developer buttons wrap onto several rows instead of being cut off
    ('#buttonStrip cr-button{margin-inline-end:16px}',
     '#buttonStrip cr-button{margin-inline-end:16px}'
     '#devDrawer[expanded]{height:auto}'
     '#buttonStrip{position:static;display:flex;flex-wrap:wrap;gap:8px;box-sizing:border-box;'
     'width:auto;margin-inline-start:16px;margin-inline-end:16px}'
     '#buttonStrip cr-button{margin-inline-end:0}'
     '#devDrawer:not([expanded]) #buttonStrip{display:none}'),
    # "install from CRX" button
    ('<cr-button ?hidden="${!this.canLoadUnpacked_()}" id="loadUnpacked"',
     '<cr-button id="tbInstallCrx" @click="${this.onTbInstallCrxClick_}">'
     'Установить из CRX</cr-button>\n'
     '    <cr-button ?hidden="${!this.canLoadUnpacked_()}" id="loadUnpacked"'),
    # opens the built-in helper's page (file picker); the helper hands the CRX to the browser's own installer
    ('onUpdateNowClick_(){',
     'onTbInstallCrxClick_(){window.open("chrome-extension://%s/install.html","_blank")}' % os.environ["TB_EXT_ID"] +
     'onUpdateNowClick_(){'),
]


def pak_entries(data):
    ver = struct.unpack_from("<I", data, 0)[0]
    if ver != 5:
        raise ValueError("pak version %d" % ver)
    _, enc, cnt, na = struct.unpack_from("<IIHH", data, 0)
    ents = [struct.unpack_from("<HI", data, 12 + 6 * k) for k in range(cnt + 1)]
    aoff = 12 + 6 * (cnt + 1)
    aliases = data[aoff:aoff + 4 * na]
    return enc, ents, aliases


def patch_paks(zin):
    import gzip
    changed = {}
    for n in zin.namelist():
        if not n.startswith("assets/resources.pak"):
            continue
        data = zin.read(n)
        enc, ents, aliases = pak_entries(data)
        cnt = len(ents) - 1
        blobs = [data[ents[k][1]:ents[k + 1][1]] for k in range(cnt)]
        hit = False
        for k, b in enumerate(blobs):
            if b[:2] != b"\x1f\x8b":
                continue
            t = gzip.decompress(b)
            if b'id="loadUnpacked"' not in t or b"onUpdateNowClick_(){" not in t:
                continue
            s = t.decode("utf-8")
            for old, new in PAK_EDITS:
                if s.count(old) != 1:
                    die("extensions page: anchor not found: %s" % old[:40])
                s = s.replace(old, new)
            blobs[k] = gzip.compress(s.encode("utf-8"), 9, mtime=0)
            hit = True
            print("extensions page patched: %s id=%d" % (n, ents[k][0]))
        if not hit:
            continue
        head = 12 + 6 * (cnt + 1) + len(aliases)
        out = bytearray(struct.pack("<IIHH", 5, enc, cnt, len(aliases) // 4))
        off = head
        table = bytearray()
        for k in range(cnt):
            table += struct.pack("<HI", ents[k][0], off)
            off += len(blobs[k])
        table += struct.pack("<HI", ents[cnt][0], off)
        out += table + aliases
        for b in blobs:
            out += b
        changed[n] = bytes(out)
    if not changed:
        die("extensions page not found in resources.pak")
    return changed


def patch_manifest(zin):
    x = AXML(zin.read("AndroidManifest.xml"))
    cnt = 0
    for i, s in enumerate(x.strings):
        if s == OLD_PKG or s.startswith(OLD_PKG + "."):
            x.strings[i] = NEW_PKG + s[len(OLD_PKG):]
            cnt += 1
    print("manifest strings renamed:", cnt)
    # app name: application/activity labels pointing to the app-name string -> literal "True Browser"
    els = list(x.elements())
    app = next(nd for nd, _ in els if x.tag(nd) == "application")
    lab = next((a for a in app.attrs if x.attr_res(a) == 0x01010001), None)
    if lab is not None and lab.dtype == T_REFERENCE:
        ref = lab.data
        idx = x.string_index(APP_NAME)
        n = 0
        for nd, _ in els:
            for a in nd.attrs:
                if x.attr_res(a) == 0x01010001 and a.dtype == T_REFERENCE and a.data == ref:
                    a.raw, a.dtype, a.data = idx, T_STRING, idx
                    n += 1
        print("app name labels replaced:", n)
    else:
        print("WARNING: application label is not a reference:", lab and (lab.dtype, lab.data))
    out = x.tobytes()
    AXML(out)
    return {"AndroidManifest.xml": out}


with zipfile.ZipFile(SRC) as zin:
    changed = {}
    if "--no-layout" not in OPTS:
        changed.update(patch_layouts(zin))
    if "--no-rename" not in OPTS:
        changed.update(patch_manifest(zin))
    changed.update(patch_paks(zin))
    names = set(zin.namelist())
    with zipfile.ZipFile(DST, "w", allowZip64=True) as zout:
        for info in zin.infolist():
            n = info.filename
            if n.startswith("META-INF/") and n.upper().endswith((".SF", ".RSA", ".EC", ".DSA", "MANIFEST.MF")):
                continue  # old signature
            data = changed.get(n)
            if data is None and n in REPLACE:
                data = open(REPLACE[n], "rb").read(); print("replaced", n)
            if data is None:
                data = zin.read(n)
            zi = zipfile.ZipInfo(n, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zout.writestr(zi, data)
        for n, path in REPLACE.items():  # new entries (extra code file)
            if n not in names:
                zi = zipfile.ZipInfo(n, date_time=(2020, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_STORED if n.endswith(".crx") else zipfile.ZIP_DEFLATED
                zout.writestr(zi, open(path, "rb").read())
                print("added", n)
print("written", DST)
PYEOF

java -Xmx6g -jar apktool.jar d -s -f -o dec app.apk > decode.log 2>&1 || (tail -50 decode.log; exit 1)
cp dec/res/values/public.xml public.xml && rm -rf dec

echo "::group::Home page code (no search box, page as tall as the screen)"
java -Xmx8g -jar apktool.jar d -r -f -o code app.apk > code.log 2>&1 || (tail -50 code.log; exit 1)
F=$(ls code/smali*/org/chromium/chrome/browser/ntp/NewTabPageLayout.smali)
C=$(ls code/smali*/org/chromium/chrome/browser/ChromeTabbedActivity.smali)
KEEP="${F%%/org/*}"
CLOSE_ID=$(grep -oE 'type="id" name="close_all_tabs_menu_id" id="0x7f[0-9a-f]+"' public.xml | grep -oE '0x7f[0-9a-f]+')
python3 - "$F" <<'SMEOF'
import sys
f = sys.argv[1]; s = open(f).read()
anchor = "    invoke-super {p0, p1, p2}, Landroid/widget/LinearLayout;->onMeasure(II)V"
m = s.index(".method public final onMeasure(II)V"); e = s.index(".end method", m)
assert s[m:e].count(anchor) == 1, "onMeasure anchor not found"
inj = """    # True Browser: hide the search box
    iget-object v0, p0, Lorg/chromium/chrome/browser/ntp/NewTabPageLayout;->r:Lw2a;
    if-eqz v0, :tb_search_done
    iget-object v0, v0, Lw2a;->a:Ld3a;
    iget-object v0, v0, Ld3a;->A:Lmea;
    if-eqz v0, :tb_search_done
    invoke-interface {v0}, Lmea;->a()Landroid/view/View;
    move-result-object v0
    if-eqz v0, :tb_search_done
    const/16 v1, 0x8
    invoke-virtual {v0, v1}, Landroid/view/View;->setVisibility(I)V
    :tb_search_done
    # True Browser: page as tall as the scrolling list that holds it, so content (gravity bottom) sits at the bottom
    invoke-virtual {p0}, Landroid/view/View;->getParent()Landroid/view/ViewParent;
    move-result-object v0
    :tb_walk
    instance-of v1, v0, Landroidx/recyclerview/widget/RecyclerView;
    if-nez v1, :tb_found
    instance-of v1, v0, Landroid/widget/ScrollView;
    if-nez v1, :tb_found
    instance-of v1, v0, Landroid/view/View;
    if-eqz v1, :tb_height_done
    check-cast v0, Landroid/view/View;
    invoke-virtual {v0}, Landroid/view/View;->getParent()Landroid/view/ViewParent;
    move-result-object v0
    goto :tb_walk
    :tb_found
    check-cast v0, Landroid/view/View;
    invoke-virtual {v0}, Landroid/view/View;->getHeight()I
    move-result v1
    if-gtz v1, :tb_have_height
    invoke-virtual {v0}, Landroid/view/View;->getMeasuredHeight()I
    move-result v1
    if-lez v1, :tb_height_done
    :tb_have_height
    invoke-virtual {v0}, Landroid/view/View;->getPaddingTop()I
    move-result v2
    sub-int/2addr v1, v2
    invoke-virtual {v0}, Landroid/view/View;->getPaddingBottom()I
    move-result v2
    sub-int/2addr v1, v2
    invoke-virtual {p0}, Landroid/view/View;->getMinimumHeight()I
    move-result v2
    if-eq v1, v2, :tb_height_done
    invoke-virtual {p0, v1}, Landroid/view/View;->setMinimumHeight(I)V
    :tb_height_done
"""
i = s.index(anchor, m)
s = s[:i] + inj + s[i:]
open(f, "w").write(s)
print("NewTabPageLayout.onMeasure patched")
SMEOF
{ # data for the address bar on the home page (read by Claude)
  N=$(grep -rl 'Ld3a;' code/smali* | xargs grep -l '^\.field .* G:Ld3a;' 2>/dev/null | head -1)
  echo "=== HOME PAGE object: $N"
  [ -n "$N" ] && { sed -n '1,12p' "$N"; grep -n '^\.method' "$N"; }
  echo "=== its boolean methods"
  [ -n "$N" ] && awk '/^\.method .*\)Z$/{f=1} f{print} f&&/^\.end method/{f=0}' "$N" | grep -v '^\s*\.line\|^\s*$' | head -260
  for T in $(ls code/smali*/org/chromium/chrome/browser/toolbar/top/ToolbarPhone.smali 2>/dev/null); do
    echo "=== ToolbarPhone: boolean calls on interfaces (with context)"
    grep -n -B6 -A3 -E 'invoke-interface \{[^}]*\}, L[a-z0-9]+;->[a-zA-Z0-9]+\(\)Z' "$T" | grep -v '\.line\|^\S*-\s*$' | head -200
  done
} > closeall.txt 2>&1 || true
# the main code file is full (65536 limit): all new code goes into a new, extra code file
CD=code/smali_classes$(( $(unzip -Z1 app.apk | grep -cE '^classes[0-9]*\.dex$') + 1 ))
KEEP="$KEEP $CD"
mkdir -p $CD/tb
cat > $CD/tb/CloseAllItem.smali <<SMEOF
.class public Ltb/CloseAllItem;
.super Ljava/lang/Object;
.implements Landroid/view/MenuItem;

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public getItemId()I
    .locals 1
    const v0, $CLOSE_ID
    return v0
.end method

.method public getGroupId()I
    .locals 1
    const/4 v0, 0x0
    return v0
.end method

.method public getOrder()I
    .locals 1
    const/4 v0, 0x0
    return v0
.end method

.method public isCheckable()Z
    .locals 1
    const/4 v0, 0x0
    return v0
.end method

.method public isChecked()Z
    .locals 1
    const/4 v0, 0x0
    return v0
.end method

.method public isEnabled()Z
    .locals 1
    const/4 v0, 0x1
    return v0
.end method

.method public isVisible()Z
    .locals 1
    const/4 v0, 0x1
    return v0
.end method

.method public hasSubMenu()Z
    .locals 1
    const/4 v0, 0x0
    return v0
.end method

.method public getTitle()Ljava/lang/CharSequence;
    .locals 1
    const/4 v0, 0x0
    return-object v0
.end method

.method public getIntent()Landroid/content/Intent;
    .locals 1
    const/4 v0, 0x0
    return-object v0
.end method
SMEOF
# the menu action handler of the activity, e.g. R2(IZLandroid/os/Bundle;Lpo9;)Z
ACTION=$(awk -v id="$CLOSE_ID" '/^\.method/{h=$0} index($0, "const v3, " id){print h; exit}' "$C" | awk '{print $NF}')
case "$ACTION" in *"(IZLandroid/os/Bundle;"*")Z") ;; *) echo "close-all: unexpected handler '$ACTION'"; exit 1;; esac
echo "close-all: handler $ACTION"
# crash catcher: on a crash the error text goes to the clipboard (paste it to Claude)
cat > $CD/tb/Crash.smali <<'SMEOF'
.class public Ltb/Crash;
.super Ljava/lang/Object;
.implements Ljava/lang/Thread$UncaughtExceptionHandler;

.field private final prev:Ljava/lang/Thread$UncaughtExceptionHandler;

.method public constructor <init>(Ljava/lang/Thread$UncaughtExceptionHandler;)V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Ltb/Crash;->prev:Ljava/lang/Thread$UncaughtExceptionHandler;
    return-void
.end method

.method public static install()V
    .locals 2
    invoke-static {}, Ljava/lang/Thread;->getDefaultUncaughtExceptionHandler()Ljava/lang/Thread$UncaughtExceptionHandler;
    move-result-object v0
    instance-of v1, v0, Ltb/Crash;
    if-nez v1, :done
    new-instance v1, Ltb/Crash;
    invoke-direct {v1, v0}, Ltb/Crash;-><init>(Ljava/lang/Thread$UncaughtExceptionHandler;)V
    invoke-static {v1}, Ljava/lang/Thread;->setDefaultUncaughtExceptionHandler(Ljava/lang/Thread$UncaughtExceptionHandler;)V
    :done
    return-void
.end method

.method public uncaughtException(Ljava/lang/Thread;Ljava/lang/Throwable;)V
    .locals 4
    :try_start
    const-string v0, "android.app.ActivityThread"
    invoke-static {v0}, Ljava/lang/Class;->forName(Ljava/lang/String;)Ljava/lang/Class;
    move-result-object v0
    const-string v1, "currentApplication"
    const/4 v2, 0x0
    new-array v3, v2, [Ljava/lang/Class;
    invoke-virtual {v0, v1, v3}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;
    move-result-object v0
    const/4 v1, 0x0
    new-array v3, v2, [Ljava/lang/Object;
    invoke-virtual {v0, v1, v3}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/content/Context;
    const-string v1, "clipboard"
    invoke-virtual {v0, v1}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/content/ClipboardManager;
    invoke-static {p2}, Landroid/util/Log;->getStackTraceString(Ljava/lang/Throwable;)Ljava/lang/String;
    move-result-object v1
    const-string v3, "True Browser crash"
    invoke-static {v3, v1}, Landroid/content/ClipData;->newPlainText(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;
    move-result-object v1
    invoke-virtual {v0, v1}, Landroid/content/ClipboardManager;->setPrimaryClip(Landroid/content/ClipData;)V
    :try_end
    .catch Ljava/lang/Throwable; {:try_start .. :try_end} :after
    :after
    iget-object v0, p0, Ltb/Crash;->prev:Ljava/lang/Thread$UncaughtExceptionHandler;
    if-eqz v0, :end
    invoke-interface {v0, p1, p2}, Ljava/lang/Thread$UncaughtExceptionHandler;->uncaughtException(Ljava/lang/Thread;Ljava/lang/Throwable;)V
    :end
    return-void
.end method
SMEOF
# the button is its own small class (in the extra code file): it finds the activity and runs the menu action
SUPER=Landroid/widget/ImageButton
CIB=$(ls code/smali*/org/chromium/ui/widget/ChromeImageButton.smali 2>/dev/null | head -1 || true)
if [ -n "$CIB" ] && ! grep -q '^\.class.* final ' "$CIB" \
   && grep -q 'constructor <init>(Landroid/content/Context;Landroid/util/AttributeSet;)V' "$CIB"; then
  SUPER=Lorg/chromium/ui/widget/ChromeImageButton
fi
cat > $CD/tb/CloseAllButton.smali <<SMEOF
.class public Ltb/CloseAllButton;
.super $SUPER;
.implements Landroid/view/View\$OnClickListener;

.method public constructor <init>(Landroid/content/Context;Landroid/util/AttributeSet;)V
    .locals 0
    invoke-direct {p0, p1, p2}, $SUPER;-><init>(Landroid/content/Context;Landroid/util/AttributeSet;)V
    invoke-virtual {p0, p0}, Landroid/view/View;->setOnClickListener(Landroid/view/View\$OnClickListener;)V
    return-void
.end method

.method public onClick(Landroid/view/View;)V
    .locals 4
    :click_try
    invoke-virtual {p0}, Landroid/view/View;->getContext()Landroid/content/Context;
    move-result-object v0
    :walk
    instance-of v1, v0, Landroid/app/Activity;
    if-nez v1, :found
    instance-of v1, v0, Landroid/content/ContextWrapper;
    if-eqz v1, :done
    check-cast v0, Landroid/content/ContextWrapper;
    invoke-virtual {v0}, Landroid/content/ContextWrapper;->getBaseContext()Landroid/content/Context;
    move-result-object v0
    goto :walk
    :found
    instance-of v1, v0, Lorg/chromium/chrome/browser/ChromeTabbedActivity;
    if-eqz v1, :done
    check-cast v0, Lorg/chromium/chrome/browser/ChromeTabbedActivity;
    const v1, $CLOSE_ID
    const/4 v2, 0x1
    const/4 v3, 0x0
    invoke-virtual {v0, v1, v2, v3, v3}, Lorg/chromium/chrome/browser/ChromeTabbedActivity;->$ACTION
    :done
    :click_end
    .catch Ljava/lang/Throwable; {:click_try .. :click_end} :click_fail
    return-void
    :click_fail
    return-void
.end method

.method static constructor <clinit>()V
    .locals 0
    invoke-static {}, Ltb/Crash;->install()V
    return-void
.end method

# draws the 'close all tabs' icon (two stacked tabs, the front one crossed) on a rounded tonal square
.method protected onDraw(Landroid/graphics/Canvas;)V
    .locals 11
    invoke-super {p0, p1}, $SUPER;->onDraw(Landroid/graphics/Canvas;)V
    :draw_try
    invoke-virtual {p1}, Landroid/graphics/Canvas;->save()I
    move-result v10
    new-instance v0, Landroid/graphics/Paint;
    const/4 v1, 0x1
    invoke-direct {v0, v1}, Landroid/graphics/Paint;-><init>(I)V
    invoke-virtual {p0}, Landroid/widget/ImageView;->getImageTintList()Landroid/content/res/ColorStateList;
    move-result-object v1
    const v2, -0x1f2f38
    if-eqz v1, :tint_done
    invoke-virtual {p0}, Landroid/view/View;->getDrawableState()[I
    move-result-object v3
    invoke-virtual {v1, v3, v2}, Landroid/content/res/ColorStateList;->getColorForState([II)I
    move-result v2
    :tint_done
    invoke-virtual {v0, v2}, Landroid/graphics/Paint;->setColor(I)V
    move-object v4, p1
    move-object v9, v0
    invoke-virtual {p0}, Landroid/view/View;->getWidth()I
    move-result v1
    int-to-float v5, v1
    invoke-virtual {p0}, Landroid/view/View;->getHeight()I
    move-result v1
    int-to-float v6, v1
    invoke-static {v5, v6}, Ljava/lang/Math;->min(FF)F
    move-result v7
    const v1, 0x3f000000
    mul-float/2addr v5, v1
    mul-float/2addr v6, v1
    invoke-virtual {v4, v5, v6}, Landroid/graphics/Canvas;->translate(FF)V
    const v1, 0x3f570a3d
    mul-float/2addr v7, v1
    const/16 v1, 0x1c
    invoke-virtual {v0, v1}, Landroid/graphics/Paint;->setAlpha(I)V
    const v1, 0x3f000000
    mul-float v8, v7, v1
    neg-float v5, v8
    new-instance v3, Landroid/graphics/RectF;
    invoke-direct {v3, v5, v5, v8, v8}, Landroid/graphics/RectF;-><init>(FFFF)V
    const v1, 0x3e8f5c29
    mul-float v6, v7, v1
    invoke-virtual {v4, v3, v6, v6, v9}, Landroid/graphics/Canvas;->drawRoundRect(Landroid/graphics/RectF;FFLandroid/graphics/Paint;)V
    invoke-virtual {p0}, Landroid/view/View;->getResources()Landroid/content/res/Resources;
    move-result-object v1
    invoke-virtual {v1}, Landroid/content/res/Resources;->getDisplayMetrics()Landroid/util/DisplayMetrics;
    move-result-object v1
    iget v1, v1, Landroid/util/DisplayMetrics;->density:F
    const v2, 0x3f4ccccd
    mul-float/2addr v1, v2
    invoke-virtual {v4, v1, v1}, Landroid/graphics/Canvas;->scale(FF)V
    const/16 v1, 0xff
    invoke-virtual {v0, v1}, Landroid/graphics/Paint;->setAlpha(I)V
    sget-object v1, Landroid/graphics/Paint\$Style;->STROKE:Landroid/graphics/Paint\$Style;
    invoke-virtual {v0, v1}, Landroid/graphics/Paint;->setStyle(Landroid/graphics/Paint\$Style;)V
    sget-object v1, Landroid/graphics/Paint\$Cap;->ROUND:Landroid/graphics/Paint\$Cap;
    invoke-virtual {v0, v1}, Landroid/graphics/Paint;->setStrokeCap(Landroid/graphics/Paint\$Cap;)V
    sget-object v1, Landroid/graphics/Paint\$Join;->ROUND:Landroid/graphics/Paint\$Join;
    invoke-virtual {v0, v1}, Landroid/graphics/Paint;->setStrokeJoin(Landroid/graphics/Paint\$Join;)V
    const v1, 0x40000000
    invoke-virtual {v0, v1}, Landroid/graphics/Paint;->setStrokeWidth(F)V
    const v5, 0xc1480000
    const v6, 0xc0e00000
    const v7, 0x40e00000
    const v8, 0x41480000
    invoke-virtual {v3, v5, v6, v7, v8}, Landroid/graphics/RectF;->set(FFFF)V
    const v1, 0x40800000
    invoke-virtual {v4, v3, v1, v1, v9}, Landroid/graphics/Canvas;->drawRoundRect(Landroid/graphics/RectF;FFLandroid/graphics/Paint;)V
    new-instance v2, Landroid/graphics/Path;
    invoke-direct {v2}, Landroid/graphics/Path;-><init>()V
    const v5, 0xc0e00000
    const v6, 0xc1180000
    invoke-virtual {v2, v5, v6}, Landroid/graphics/Path;->moveTo(FF)V
    const v6, 0xc1480000
    invoke-virtual {v2, v5, v6}, Landroid/graphics/Path;->lineTo(FF)V
    const v5, 0x41480000
    invoke-virtual {v2, v5, v6}, Landroid/graphics/Path;->lineTo(FF)V
    const v6, 0x40e00000
    invoke-virtual {v2, v5, v6}, Landroid/graphics/Path;->lineTo(FF)V
    const v5, 0x41180000
    invoke-virtual {v2, v5, v6}, Landroid/graphics/Path;->lineTo(FF)V
    invoke-virtual {v4, v2, v9}, Landroid/graphics/Canvas;->drawPath(Landroid/graphics/Path;Landroid/graphics/Paint;)V
    const v5, 0xc0c80000
    const v6, 0xbf400000
    const v7, 0x3f400000
    const v8, 0x40c80000
    invoke-virtual/range {v4 .. v9}, Landroid/graphics/Canvas;->drawLine(FFFFLandroid/graphics/Paint;)V
    const v5, 0x3f400000
    const v6, 0xbf400000
    const v7, 0xc0c80000
    const v8, 0x40c80000
    invoke-virtual/range {v4 .. v9}, Landroid/graphics/Canvas;->drawLine(FFFFLandroid/graphics/Paint;)V
    invoke-virtual {p1, v10}, Landroid/graphics/Canvas;->restoreToCount(I)V
    :draw_end
    .catch Ljava/lang/Throwable; {:draw_try .. :draw_end} :draw_fail
    return-void
    :draw_fail
    return-void
.end method
SMEOF
echo "close-all: id $CLOSE_ID, button based on $SUPER, code in $CD"
# address bar icon: the search engine / site picture is drawn inside a circle
TB_STATUS_TAG=$(python3 - <<'STEOF'
import re, sys, zipfile
sys.path.insert(0, "tb")
from axml import AXML
pub = open("public.xml", encoding="utf-8").read()
m = re.search(r'type="id" name="location_bar_status_icon" id="(0x[0-9a-f]+)"', pub)
tags = set()
if m:
    rid = int(m.group(1), 16)
    z = zipfile.ZipFile("app.apk")
    for n in z.namelist():
        if not (n.startswith("res/") and n.endswith(".xml")): continue
        d = z.read(n)
        if d[:2] != b"\x03\x00": continue
        try: x = AXML(d)
        except Exception: continue
        for nd, _ in x.elements():
            a = x.get(nd, "id")
            if a is not None and a.data == rid: tags.add(x.tag(nd))
print(tags.pop() if len(tags) == 1 else "")
STEOF
)
export TB_STATUS_TAG
echo "status icon class: '$TB_STATUS_TAG'"
if [ -n "$TB_STATUS_TAG" ]; then
  case "$TB_STATUS_TAG" in *.*) RSUP=L$(echo "$TB_STATUS_TAG" | tr . /);; *) RSUP=Landroid/widget/$TB_STATUS_TAG;; esac
  RF=$(ls code/smali*/${RSUP#L}.smali 2>/dev/null | head -1 || true)
  if [ -n "$RF" ] && grep -q '^\.class.* final ' "$RF"; then echo "status icon class is final, not changed"; TB_STATUS_TAG=""; export TB_STATUS_TAG; fi
fi
if [ -n "$TB_STATUS_TAG" ]; then
  cat > $CD/tb/RoundIcon.smali <<SMEOF
.class public Ltb/RoundIcon;
.super $RSUP;

.method public constructor <init>(Landroid/content/Context;Landroid/util/AttributeSet;)V
    .locals 0
    invoke-direct {p0, p1, p2}, $RSUP;-><init>(Landroid/content/Context;Landroid/util/AttributeSet;)V
    return-void
.end method

# pictures (search engine logo, site icon) are clipped to a circle; vector icons are drawn as they are
.method protected onDraw(Landroid/graphics/Canvas;)V
    .locals 8
    invoke-virtual {p0}, Landroid/widget/ImageView;->getDrawable()Landroid/graphics/drawable/Drawable;
    move-result-object v0
    instance-of v0, v0, Landroid/graphics/drawable/BitmapDrawable;
    if-eqz v0, :plain
    :clip_try
    invoke-virtual {p1}, Landroid/graphics/Canvas;->save()I
    move-result v7
    invoke-virtual {p0}, Landroid/view/View;->getWidth()I
    move-result v1
    invoke-virtual {p0}, Landroid/view/View;->getPaddingLeft()I
    move-result v2
    sub-int/2addr v1, v2
    invoke-virtual {p0}, Landroid/view/View;->getPaddingRight()I
    move-result v3
    sub-int/2addr v1, v3
    invoke-virtual {p0}, Landroid/view/View;->getHeight()I
    move-result v4
    invoke-virtual {p0}, Landroid/view/View;->getPaddingTop()I
    move-result v5
    sub-int/2addr v4, v5
    invoke-virtual {p0}, Landroid/view/View;->getPaddingBottom()I
    move-result v6
    sub-int/2addr v4, v6
    invoke-static {v1, v4}, Ljava/lang/Math;->min(II)I
    move-result v6
    int-to-float v6, v6
    const/high16 v0, 0x3f000000
    mul-float/2addr v6, v0
    int-to-float v1, v1
    mul-float/2addr v1, v0
    int-to-float v2, v2
    add-float/2addr v1, v2
    int-to-float v4, v4
    mul-float/2addr v4, v0
    int-to-float v5, v5
    add-float/2addr v4, v5
    new-instance v0, Landroid/graphics/Path;
    invoke-direct {v0}, Landroid/graphics/Path;-><init>()V
    sget-object v2, Landroid/graphics/Path\$Direction;->CW:Landroid/graphics/Path\$Direction;
    invoke-virtual {v0, v1, v4, v6, v2}, Landroid/graphics/Path;->addCircle(FFFLandroid/graphics/Path\$Direction;)V
    invoke-virtual {p1, v0}, Landroid/graphics/Canvas;->clipPath(Landroid/graphics/Path;)Z
    invoke-super {p0, p1}, $RSUP;->onDraw(Landroid/graphics/Canvas;)V
    invoke-virtual {p1, v7}, Landroid/graphics/Canvas;->restoreToCount(I)V
    :clip_end
    .catch Ljava/lang/Throwable; {:clip_try .. :clip_end} :plain
    return-void
    :plain
    invoke-super {p0, p1}, $RSUP;->onDraw(Landroid/graphics/Canvas;)V
    return-void
.end method
SMEOF
fi
# address bar visible on the home page: the page says "search provider has a logo" -> false,
# so the browser stops treating the (removed) search box on the page as the address bar
NTPF=$(grep -rl '^\.field .* G:Ld3a;' code/smali* | head -1)
NTPC=$(basename "$NTPF" .smali)
python3 - "$NTPC" code <<'NTEOF'
import os, re, sys
cls, root = sys.argv[1], sys.argv[2]
pat = re.compile(r"^(\s*)iput-boolean (v\d+|p\d+), (\S+), L%s;->(K|L):Z$" % re.escape(cls), re.M)
n = 0; dirs = set()
for d, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith(".smali"): continue
        path = os.path.join(d, f); s = open(path).read()
        if ("L%s;->" % cls) not in s: continue
        s2, k = pat.subn(lambda m: "%s# True Browser: no logo -> address bar shown on the home page\n%sconst/4 %s, 0x0\n%s" % (m.group(1), m.group(1), m.group(2), m.group(0)), s)
        if k:
            open(path, "w").write(s2); n += k
            dirs.add(path.split(os.sep)[1])
print("home page logo flags forced off:", n, "in", sorted(dirs))
open("ntp_dirs.txt", "w").write(" ".join("code/" + x for x in sorted(dirs)))
assert n > 0, "home page logo flags not found"
NTEOF
KEEP="$KEEP $(cat ntp_dirs.txt)"
# extension files (.crx): no "where to save" dialog - the download goes straight on, so the browser's
# own "add extension" prompt comes up at once (same as pressing Cancel in that dialog)
DDB=$(ls code/smali*/org/chromium/chrome/browser/download/DownloadDialogBridge.smali | head -1)
python3 - "$DDB" <<'DDEOF'
import re, sys
f = sys.argv[1]; s = open(f).read()
m = s.index(".method public final showDialog(Lorg/chromium/ui/base/WindowAndroid;JIILjava/lang/String;Lorg/chromium/chrome/browser/profiles/Profile;)V")
e = s.index(".end method", m); body = re.sub(r"(?m)^\s*\.line .*$", "", s[m:e])
c = re.search(r"const/16 (\w+), (0x[0-9a-f]+)\s+invoke-static \{\1, (\w+), (\w+)\}, (LJ/N;->\w+\(IJ\)V)", body)
w = re.search(r"invoke-static \{p1\}, (L\w+;->\w+\(Lorg/chromium/ui/base/WindowAndroid;\)V)", body)
assert c and w, "download dialog cancel path not found"
cls = "Lorg/chromium/chrome/browser/download/DownloadDialogBridge;"
inj = f"""    # True Browser: .crx -> no dialog
    if-eqz p6, :tb_dialog
    invoke-virtual {{p6}}, Ljava/lang/String;->toLowerCase()Ljava/lang/String;
    move-result-object v0
    const-string/jumbo v1, ".crx"
    invoke-virtual {{v0, v1}}, Ljava/lang/String;->endsWith(Ljava/lang/String;)Z
    move-result v0
    if-eqz v0, :tb_dialog
    iput-object p1, p0, {cls}->c:Lorg/chromium/ui/base/WindowAndroid;
    iget-wide v0, p0, {cls}->a:J
    const-wide/16 v2, 0x0
    cmp-long v2, v0, v2
    if-eqz v2, :tb_no_native
    const/16 v2, {c.group(2)}
    invoke-static {{v2, v0, v1}}, {c.group(5)}
    :tb_no_native
    invoke-static {{p1}}, {w.group(1)}
    invoke-virtual {{p0}}, {cls}->b()V
    return-void
    :tb_dialog
"""
li = s.index(".locals", m); le = s.index("\n", li) + 1
n = int(s[li:le].split()[1])
s = s[:li] + ".locals %d\n" % max(n, 4) + inj + s[le:]
open(f, "w").write(s)
print("download dialog: skipped for .crx via", c.group(5), c.group(2))
DDEOF
KEEP="$KEEP $(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$DDB")")")")")")"
# the toolbar asks the home page "is the address bar shown inside the page?" (method k() of the
# home-page interface used by ToolbarPhone) -> always "no", so the toolbar shows its own address bar
TPH=$(ls code/smali*/org/chromium/chrome/browser/toolbar/top/ToolbarPhone.smali | head -1)
IFACE=$(grep -oE 'invoke-interface \{[^}]*\}, L[a-z0-9]+;->k\(\)Z' "$TPH" | head -1 | grep -oE 'L[a-z0-9]+;' )
{ echo "=== home page interface used by the toolbar: $IFACE"
  for f in $(grep -rl "^\.implements $IFACE" code/smali*); do
    echo ">> $f"
    awk '/^\.method .* [a-z]\(\)Z$/{f=1} f{print} f&&/^\.end method/{f=0}' "$f" | grep -v '^\s*\.line\|^\s*$' | head -120
  done
} > ntp_iface.txt 2>&1 || true
{ # data for the "Sign in" entry in settings (read by Claude)
  echo "=== SETTINGS: main settings screen and the sign-in entry"
  for f in $(ls code/smali*/org/chromium/chrome/browser/sync/settings/SignInPreference.smali \
                code/smali*/org/chromium/chrome/browser/settings/MainSettings.smali 2>/dev/null); do
    echo "################ $f ($(wc -l < "$f") lines)"
    grep -v '^\s*\.line\|^\s*$' "$f" | head -500
  done
  grep -rln 'SignInPreference' code/smali* | head -10
} >> ntp_iface.txt 2>&1 || true
{ # data for the "dangerous file" download dialog (read by Claude)
  for f in $(ls code/smali*/org/chromium/chrome/browser/download/*Danger*.smali 2>/dev/null | head -6); do
    echo "################ $f ($(wc -l < "$f") lines)"
    grep -v '^\s*\.line\|^\s*$' "$f" | head -300
  done
} >> ntp_iface.txt 2>&1 || true
{ # data for skipping the download dialog for extension files (read by Claude)
  for f in $(ls code/smali*/org/chromium/chrome/browser/download/DownloadDialogBridge.smali \
                code/smali*/org/chromium/chrome/browser/download/dialogs/*.smali 2>/dev/null | head -12); do
    echo "################ $f ($(wc -l < "$f") lines)"
    grep -v '^\s*\.line\|^\s*$' "$f" | head -400
  done
  echo "=== callers of DownloadDialogBridge"
  grep -rln 'Lorg/chromium/chrome/browser/download/DownloadDialogBridge;' code/smali* | head -10
} >> ntp_iface.txt 2>&1 || true
python3 - "$IFACE" code <<'IFEOF'
import os, sys
iface, root = sys.argv[1], sys.argv[2]
n = 0; dirs = set()
for d, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith(".smali"): continue
        path = os.path.join(d, f); s = open(path).read()
        if (".implements %s\n" % iface) not in s: continue
        i = s.find(".method public final k()Z\n")
        if i < 0: i = s.find(".method public k()Z\n")
        if i < 0: continue
        li = s.index(".locals", i); j = s.index("\n", li) + 1
        if s[li:j].strip() == ".locals 0":
            s = s[:li] + ".locals 1\n" + s[j:]; j = s.index("\n", li) + 1
        s = s[:j] + "    # True Browser: the address bar is never inside the home page\n    const/4 v0, 0x0\n    return v0\n" + s[j:]
        open(path, "w").write(s); n += 1; dirs.add(path.split(os.sep)[1])
print("home page 'address bar inside page' answers forced to no:", n, sorted(dirs))
open("ntp_dirs2.txt", "w").write(" ".join("code/" + x for x in sorted(dirs)))
IFEOF
KEEP="$KEEP $(cat ntp_dirs2.txt)"
# bottom address bar also on the home page: the position decision ignores "home page is showing"
TP=$(grep -rl 'cr_ToolbarPosition' code/smali* | head -1)
python3 - "$TP" <<'TPEOF'
import sys
f = sys.argv[1]; s = open(f).read()
h = ".method public static a(ZZZZZZZZI)I\n    .locals 2\n"
assert s.count(h) == 1, "toolbar position method not found"
s = s.replace(h, h + "    # True Browser: home page does not force the toolbar to the top\n    const/4 p1, 0x0\n")
open(f, "w").write(s)
print("toolbar position patched in", f)
TPEOF
KEEP="$KEEP $(dirname "$TP")"
for d in code/smali*; do case " $KEEP " in *" $d "*) ;; *) rm -rf "$d";; esac; done
java -Xmx8g -jar apktool.jar b -o code.apk code > codebuild.log 2>&1 || (tail -50 codebuild.log; exit 1)
REPL=()
for d in $(echo $KEEP | tr ' ' '\n' | sort -u); do
  X=${d#code/}; X=${X/smali_/}; [ "$X" = smali ] && X=classes; X=$X.dex
  unzip -o -q code.apk "$X" -d newdex
  REPL+=("--replace=$X=newdex/$X")
  echo "rebuilt $X ($(du -h newdex/$X | cut -f1))"
done
echo "::endgroup::"

echo "::group::Built-in helper extension (install from CRX)"
mkdir -p ext
cat > ext/manifest.json <<'EXEOF'
{
  "manifest_version": 3,
  "name": "True Browser",
  "version": "1.0.2",
  "description": "Встроенный помощник True Browser: установка расширений из файлов CRX и сразу при их скачивании.",
  "permissions": ["downloads"],
  "host_permissions": ["<all_urls>"],
  "background": { "service_worker": "bg.js" }
}
EXEOF
cat > ext/bg.js <<'EXEOF'
"use strict";
// A .crx that a site hands out as an ordinary file: stop that download and install it instead.
const CRX = "application/x-chrome-extension";
const handled = new Set();
function isCrx(item) {
  const name = (item.filename || "").toLowerCase();
  let path = "";
  try { path = new URL(item.finalUrl || item.url).pathname.toLowerCase(); } catch {}
  return name.endsWith(".crx") || path.endsWith(".crx");
}
async function take(item) {
  if (handled.has(item.id) || item.byExtensionId === chrome.runtime.id) return;
  if (item.mime === CRX || !isCrx(item)) return;
  const url = item.finalUrl || item.url;
  if (!/^https?:/i.test(url)) return;
  handled.add(item.id);
  try { await chrome.downloads.cancel(item.id); } catch {}
  try { await chrome.downloads.erase({ id: item.id }); } catch {}
  chrome.tabs.create({ url: chrome.runtime.getURL("install.html") + "#u=" + encodeURIComponent(url), active: true });
}
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => { suggest(); take(item); });
chrome.downloads.onCreated.addListener((item) => { take(item); });
// our own hand-over downloads: the browser deletes the file after installing; drop the list entry too
chrome.downloads.onChanged.addListener(async (d) => {
  if (!d.state || d.state.current === "in_progress") return;
  const [item] = await chrome.downloads.search({ id: d.id });
  if (item && item.byExtensionId === chrome.runtime.id) {
    setTimeout(() => chrome.downloads.erase({ id: d.id }).catch(() => {}), 60000);
  }
});
EXEOF
cat > ext/install.html <<'EXEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Установка расширения</title>
<style>
:root { color-scheme: light dark; --bg:#EEF1F4; --card:#FFFFFF; --fg:#1b1d21; --muted:#5f6670; --accent:#2F80ED; }
@media (prefers-color-scheme: dark) { :root { --bg:#1d1715; --card:#2a2220; --fg:#f0e4de; --muted:#b9aaa3; --accent:#ffb59d; } }
html, body { margin:0; height:100%; background:var(--bg); color:var(--fg); font:16px/1.45 system-ui, sans-serif; }
main { min-height:100%; box-sizing:border-box; display:flex; flex-direction:column; justify-content:flex-end; gap:16px; padding:24px 16px 40px; }
.card { background:var(--card); border-radius:24px; padding:20px; }
h1 { font-size:20px; margin:0 0 6px; }
#status { color:var(--muted); margin:0; word-break:break-word; }
button { width:100%; border:0; border-radius:20px; padding:16px; font:600 16px system-ui, sans-serif; background:var(--accent); color:#fff; }
@media (prefers-color-scheme: dark) { button { color:#3a1a10; } }
button[hidden] { display:none; }
</style>
</head>
<body>
<main>
  <div class="card">
    <h1>Установка расширения</h1>
    <p id="status">Выберите файл CRX — браузер покажет своё окно установки.</p>
  </div>
  <button id="pick">Выбрать файл CRX</button>
  <input id="file" type="file" hidden>
</main>
<script src="install.js"></script>
</body>
</html>
EXEOF
cat > ext/install.js <<'EXEOF'
"use strict";
const CRX = "application/x-chrome-extension";
const status = document.getElementById("status");
const pick = document.getElementById("pick");
const file = document.getElementById("file");

function crxName(name) {
  const base = (name || "").split(/[\/?#]/).filter(Boolean).pop() || "extension";
  // a fresh name every time, so the browser never asks to download an existing file again
  return base.replace(/\.crx$/i, "").replace(/[^\w.-]+/g, "_").slice(0, 60) + "-" + Date.now().toString(36) + ".crx";
}

// The browser installs an extension when a CRX is downloaded by an extension:
// the file is handed over as such a download and the browser shows its own install prompt.
async function install(buf, name) {
  const bytes = new Uint8Array(buf);
  if (!(bytes.length > 4 && bytes[0] === 0x43 && bytes[1] === 0x72 && bytes[2] === 0x32 && bytes[3] === 0x34)) {
    throw new Error("это не файл расширения CRX");
  }
  const url = URL.createObjectURL(new Blob([bytes], { type: CRX }));
  const id = await chrome.downloads.download({ url, filename: crxName(name), conflictAction: "uniquify" });
  status.textContent = "Подтвердите установку в окне браузера.";
  const accept = (danger) => {
    if (danger && danger !== "safe" && danger !== "accepted") chrome.downloads.acceptDanger(id).catch(() => {});
  };
  chrome.downloads.onChanged.addListener(function onChanged(d) {
    if (d.id !== id) return;
    if (d.danger) accept(d.danger.current);
    if (d.state && d.state.current !== "in_progress") {
      chrome.downloads.onChanged.removeListener(onChanged);
      setTimeout(() => URL.revokeObjectURL(url), 60000);
      if (d.state.current === "interrupted") status.textContent = "Установка прервана.";
    }
  });
  const [item] = await chrome.downloads.search({ id });
  if (item) accept(item.danger);
}

function fail(e) {
  status.textContent = "Не получилось: " + (e && e.message ? e.message : e);
  pick.hidden = false;
}

pick.addEventListener("click", () => file.click());
file.addEventListener("change", () => {
  const f = file.files && file.files[0];
  if (!f) return;
  pick.hidden = true;
  status.textContent = "Открываю " + f.name + "…";
  f.arrayBuffer().then((b) => install(b, f.name)).catch(fail);
});

const m = /^#u=(.+)$/.exec(location.hash);
if (m) {
  const src = decodeURIComponent(m[1]);
  pick.hidden = true;
  status.textContent = "Скачиваю расширение…";
  fetch(src, { credentials: "include" })
    .then((r) => { if (!r.ok) throw new Error("ошибка загрузки " + r.status); return r.arrayBuffer(); })
    .then((b) => install(b, src))
    .catch(fail);
}
EXEOF
python3 - <<'PKEOF'
import hashlib, io, json, os, struct, subprocess, zipfile
def varint(n):
    out = b""
    while True:
        b = n & 0x7F; n >>= 7
        if n: out += bytes([b | 0x80])
        else: return out + bytes([b])
def field(num, data):
    return varint((num << 3) | 2) + varint(len(data)) + data
zbuf = io.BytesIO()
with zipfile.ZipFile(zbuf, "w", zipfile.ZIP_DEFLATED) as z:
    for n in sorted(os.listdir("ext")):
        zi = zipfile.ZipInfo(n, date_time=(2020, 1, 1, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, open(os.path.join("ext", n), "rb").read())
zbytes = zbuf.getvalue()
pub = subprocess.run(["openssl", "rsa", "-in", "ext.pem", "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout
crx_id = hashlib.sha256(pub).digest()[:16]
ext_id = "".join("abcdefghijklmnop"[int(c, 16)] for c in crx_id.hex())
signed_data = field(1, crx_id)
msg = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed_data)) + signed_data + zbytes
open("ext.msg", "wb").write(msg)
sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", "ext.pem", "ext.msg"], capture_output=True, check=True).stdout
header = field(2, field(1, pub) + field(2, sig)) + field(10000, signed_data)
open("truebrowser.crx", "wb").write(b"Cr24" + struct.pack("<II", 3, len(header)) + header + zbytes)
version = json.load(open("ext/manifest.json"))["version"]
bundled = json.loads(zipfile.ZipFile("app.apk").read("assets/extensions/bundled.json"))
bundled[ext_id] = {"external_crx": "truebrowser.crx", "external_version": version}
open("bundled.json", "w").write(json.dumps(bundled, indent=2))
open("ext_id.txt", "w").write(ext_id)
print("helper extension", ext_id, "version", version, "crx", len(b"Cr24") + 8 + len(header) + len(zbytes), "bytes")
PKEOF
TB_EXT_ID=$(cat ext_id.txt); export TB_EXT_ID
REPL+=("--replace=assets/extensions/bundled.json=bundled.json" "--replace=assets/extensions/truebrowser.crx=truebrowser.crx")
echo "::endgroup::"

echo "::group::Patch, align, sign"
python3 tb/patch_apk.py app.apk public.xml p.apk "${REPL[@]}" | tee patch.log
for f in $(grep -oE '^patched [^ ]+' patch.log | cut -d' ' -f2); do
  echo "----- $f"; $BT/aapt2 dump xmltree --file "$f" p.apk | head -80
done > xmltree.log
$BT/zipalign -P 16 -f 4 p.apk a.apk
OUT="out/TrueBrowser-$VER-arm64.apk"
$BT/apksigner sign --ks ks.jks --ks-pass pass:truebrowser --out "$OUT" a.apk
rm -f p.apk a.apk
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "::endgroup::"

echo "::group::Report for Claude"
set +eo pipefail
R=report.txt
echo "$TAG" > $R; cat patch.log xmltree.log >> $R
echo "=== code: $KEEP" >> $R
python3 - >> $R 2>&1 <<'SXEOF'
import sys, zipfile
sys.path.insert(0, "tb")
from axml import AXML
z = zipfile.ZipFile("app.apk")
print("=== SETTINGS: preference XML with the sign-in entry")
for n in z.namelist():
    if not (n.startswith("res/") and n.endswith(".xml")): continue
    d = z.read(n)
    if d[:2] != b"\x03\x00" or b"S\x00i\x00g\x00n\x00I\x00n\x00P" not in d and b"SignInPreference" not in d: continue
    try: x = AXML(d)
    except Exception: continue
    print("#####", n)
    for nd, par in x.elements():
        attrs = []
        for a in nd.attrs:
            v = x.s(a.raw) if a.raw != 0xFFFFFFFF else hex(a.data)
            attrs.append("%s=%s" % (x.s(a.name), v))
        print("  ", x.tag(nd), " ".join(attrs)[:300])
SXEOF
grep -n -A45 'True Browser: hide' "$F" | grep -v '\.line' >> $R
tail -20 codebuild.log >> $R
cat closeall.txt >> $R
cat ntp_iface.txt >> $R
wc -c $R
echo "::endgroup::"
