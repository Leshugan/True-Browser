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
    "layoutDirection": 0x010103B2,
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
