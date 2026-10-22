#!/usr/bin/env python3
"""True Browser: patches a decoded Titanium APK (apktool -s output).

Usage: patch.py <decoded dir> [--no-layout] [--no-rename]

Changes (layout XML only, code untouched):
  1. Tab grid anchored to the bottom, rows grow upwards
     (recycler rotated 180 + RTL, each card rotated back).
  2. Tab switcher toolbar moved to the bottom.
  3. Package renamed to leshugan.truebrowser, app name "True Browser".
  Always: keep only arm64-v8a native libraries.
"""
import glob, os, re, shutil, sys

DEC = sys.argv[1]
OPTS = set(sys.argv[2:])
OLD_PKG = "io.github.jqssun.helium"
NEW_PKG = "leshugan.truebrowser"
APP_NAME = "True Browser"
log = []


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)


def die(msg):
    print("ERROR:", msg)
    sys.exit(1)


def ns(xml):
    m = re.search(r'xmlns:(\w+)="http://schemas\.android\.com/apk/res/android"', xml)
    return m.group(1) if m else "android"


def root_tag_span(xml):
    m = re.search(r"<(?![?!])[^>]*>", xml, re.S)
    return m.start(), m.end()


def set_attr(tag, p, name, value):
    rx = re.compile(r'\s%s:%s="[^"]*"' % (p, name))
    if rx.search(tag):
        return rx.sub(' %s:%s="%s"' % (p, name, value), tag, count=1)
    close = "/>" if tag.rstrip().endswith("/>") else ">"
    body = tag.rstrip()[: -len(close)]
    return '%s %s:%s="%s"%s' % (body, p, name, value, close)


def patch_root(path, attrs):
    xml = rd(path)
    p = ns(xml)
    s, e = root_tag_span(xml)
    tag = xml[s:e]
    for k, v in attrs.items():
        tag = set_attr(tag, p, k, v)
    wr(path, xml[:s] + tag + xml[e:])


def layout_patches():
    layouts = sorted(glob.glob(os.path.join(DEC, "res", "layout*", "*.xml")))
    texts = {f: rd(f) for f in layouts}

    # 1. Tab grid from the bottom
    rec = [f for f, x in texts.items()
           if re.search(r"<\s*org\.chromium\.chrome\.browser\.tasks\.tab_management\.TabListRecyclerView\b", x[:600])
           and "@id/tab_list_recycler_view" in x[:900]]
    cards = [f for f, x in texts.items() if re.search(r"<\s*[\w.]*TabGridView\b", x[:600])]
    if not rec or not cards:
        die("grid layouts not found rec=%s cards=%s" % (rec, cards))
    for f in rec:
        patch_root(f, {"rotation": "180.0", "layoutDirection": "rtl"})
        log.append("grid recycler: " + os.path.basename(f))
    for f in cards:
        patch_root(f, {"rotation": "180.0", "layoutDirection": "ltr"})
        log.append("grid card: " + os.path.basename(f))

    # 2. Hub toolbar to the bottom
    toolbar_layouts = {os.path.splitext(os.path.basename(f))[0]
                       for f, x in texts.items() if "@id/hub_toolbar" in x}
    hubs = [f for f, x in texts.items() if "@id/hub_pane_host_container" in x]
    if not hubs or not toolbar_layouts:
        die("hub layouts not found %s %s" % (hubs, toolbar_layouts))
    for f in hubs:
        xml = rd(f)
        p = ns(xml)

        def fix_container(m):
            return re.sub(r'\s%s:layout_marginTop="' % p, ' %s:layout_marginBottom="' % p, m.group(0), count=1)

        xml, n1 = re.subn(r'<LinearLayout[^>]*@id/hub_pane_host_container[^>]*>', fix_container, xml, count=1)
        n2 = 0
        for name in toolbar_layouts:
            rx = re.compile(r'<include\s+layout="@layout/%s"\s*/>' % re.escape(name))
            new = ('<include %s:layout_width="fill_parent" %s:layout_height="wrap_content" '
                   '%s:layout_gravity="bottom" layout="@layout/%s" />') % (p, p, p, name)
            xml, k = rx.subn(new, xml)
            n2 += k
        wr(f, xml)
        log.append("hub %s: container=%d toolbar=%d" % (os.path.basename(f), n1, n2))
        if n1 == 0 or n2 == 0:
            die("hub layout not patched " + f)


def rename():
    man = os.path.join(DEC, "AndroidManifest.xml")
    m = rd(man)
    cnt = m.count(OLD_PKG + ".")
    wr(man, m.replace(OLD_PKG + ".", NEW_PKG + "."))
    log.append("manifest authorities/permissions renamed: %d" % cnt)

    yml = os.path.join(DEC, "apktool.yml")
    y = rd(yml)
    y2 = re.sub(r"renameManifestPackage:.*", "renameManifestPackage: " + NEW_PKG, y)
    if y2 == y:
        y2 = y.replace("packageInfo:", "packageInfo:\n  renameManifestPackage: " + NEW_PKG, 1)
    wr(yml, y2)

    names = 0
    for f in glob.glob(os.path.join(DEC, "res", "values*", "strings.xml")):
        s = rd(f)
        names += s.count(">Titanium<")
        wr(f, s.replace(">Titanium<", ">%s<" % APP_NAME))
    log.append("app name strings: %d" % names)


def arm64_only():
    lib = os.path.join(DEC, "lib")
    if not os.path.isdir(lib):
        return
    for abi in os.listdir(lib):
        if abi != "arm64-v8a":
            shutil.rmtree(os.path.join(lib, abi))
            log.append("removed lib/" + abi)


arm64_only()
if "--no-layout" not in OPTS:
    layout_patches()
if "--no-rename" not in OPTS:
    rename()
print("\n".join(log) or "no changes")
