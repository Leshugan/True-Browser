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
import re, struct, sys, zipfile
from axml import AXML, T_FLOAT, T_INT_DEC, T_INT_HEX, NONE

SRC, PUBLIC, DST = sys.argv[1:4]
OPTS = set(sys.argv[4:])
OLD_PKG = "io.github.jqssun.helium"
NEW_PKG = "leshugan.truebrowser"
ROT180 = struct.unpack("<I", struct.pack("<f", 180.0))[0]
MATCH_PARENT, WRAP_CONTENT, GRAVITY_BOTTOM = 0xFFFFFFFF, 0xFFFFFFFE, 0x50
RTL, LTR = 1, 0


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


def el_id(x, nd):
    a = x.get(nd, "id")
    return a.data if a is not None else None


def patch_layouts(zin):
    changed = {}
    found = {"recycler": 0, "card": 0, "hub": 0}
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
        if mod:
            out = x.tobytes()
            AXML(out)  # sanity re-parse
            changed[n] = out
            print("patched %s (%s)" % (n, tag))
    print("found:", found)
    if not found["recycler"] or not found["card"] or not found["hub"]:
        die("not all layouts found")
    return changed


def patch_manifest(zin):
    x = AXML(zin.read("AndroidManifest.xml"))
    cnt = 0
    for i, s in enumerate(x.strings):
        if s == OLD_PKG or s.startswith(OLD_PKG + "."):
            x.strings[i] = NEW_PKG + s[len(OLD_PKG):]
            cnt += 1
    print("manifest strings renamed:", cnt)
    out = x.tobytes()
    AXML(out)
    return {"AndroidManifest.xml": out}


with zipfile.ZipFile(SRC) as zin:
    changed = {}
    if "--no-layout" not in OPTS:
        changed.update(patch_layouts(zin))
    if "--no-rename" not in OPTS:
        changed.update(patch_manifest(zin))
    with zipfile.ZipFile(DST, "w", allowZip64=True) as zout:
        for info in zin.infolist():
            n = info.filename
            if n.startswith("META-INF/") and n.upper().endswith((".SF", ".RSA", ".EC", ".DSA", "MANIFEST.MF")):
                continue  # old signature
            data = changed.get(n)
            if data is None:
                data = zin.read(n)
            zi = zipfile.ZipInfo(n, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zout.writestr(zi, data)
print("written", DST)
