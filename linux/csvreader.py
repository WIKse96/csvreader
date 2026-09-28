#!/usr/bin/env python3
"""CSV Reader — lekki edytor plików CSV dla Linuksa (Python 3 + Tk).

Funkcje: siatka jak w LibreOffice (zaznaczanie komórek, uchwyt wypełniania,
edycja w miejscu), filtry kolumn, sortowanie, różne separatory i kodowania,
edycja nagłówków, widok tekstowy, cofanie/ponawianie.
"""

import bisect
import csv
import datetime
import io
import locale
import os
import re
import sys
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter import font as tkfont

APP_NAME = "CSV Reader"
VERSION = "1.0"

DELIMITERS = [
    ("Tabulator", "\t"),
    ("Średnik  ;", ";"),
    ("Przecinek  ,", ","),
    ("Pionowa kreska  |", "|"),
    ("Spacja", " "),
]
ENCODINGS = [
    ("UTF-8", "utf-8"),
    ("UTF-8 z BOM (Excel)", "utf-8-sig"),
    ("UTF-16", "utf-16"),
    ("Windows-1250 (środkowoeuropejskie)", "cp1250"),
    ("ISO-8859-2", "iso8859-2"),
    ("Windows-1252 (zachodnie)", "cp1252"),
    ("ISO-8859-1", "latin-1"),
]
FILETYPES = [
    ("Pliki CSV", "*.csv *.CSV"),
    ("Pliki TSV", "*.tsv *.tab *.TSV"),
    ("Pliki tekstowe", "*.txt"),
    ("Wszystkie pliki", "*"),
]

# Colors
GRID_BG = "#ffffff"
GRID_LINE = "#dadce0"
HEADER_BG = "#f1f3f4"
HEADER_SEL = "#d3e3fd"
HEADER_FG = "#202124"
ROWNUM_FG = "#5f6368"
SEL_BG = "#e8f0fe"
ACCENT = "#1a73e8"

# Like a spreadsheet the grid extends past the data; typing there grows the document.
MAX_ROWS = 1_048_576
MIN_COLUMNS = 26
MAX_COLUMNS = 16_384

csv.field_size_limit(2**31 - 1)
try:
    locale.setlocale(locale.LC_COLLATE, "")
except locale.Error:
    pass


# ---------------------------------------------------------------------------
# CSV core
# ---------------------------------------------------------------------------

def decode(data):
    """Returns (text, encoding) guessing the encoding like the macOS version."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", "replace"), "utf-8-sig"
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", "replace"), "utf-16"
    for enc in ("utf-8", "cp1250"):
        try:
            return data.decode(enc), enc
        except UnicodeDecodeError:
            pass
    return data.decode("latin-1"), "latin-1"


def parse(text, delimiter):
    return list(csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, quotechar='"', strict=False))


def pad(rows):
    width = max((len(r) for r in rows), default=0) or 1
    if not rows:
        return [[""] * width], width
    return [r + [""] * (width - len(r)) if len(r) < width else r for r in rows], width


def serialize(rows, delimiter, eol, trim):
    rows = list(rows)
    width = max((len(r) for r in rows), default=0)
    if trim:
        while rows and not any(rows[-1]):
            rows.pop()
        width = 0
        for r in rows:
            for i in range(len(r) - 1, -1, -1):
                if r[i]:
                    width = max(width, i + 1)
                    break
    out = io.StringIO()
    writer = csv.writer(out, delimiter=delimiter, quotechar='"', quoting=csv.QUOTE_MINIMAL, lineterminator=eol)
    for r in rows:
        writer.writerow((list(r) + [""] * width)[:width])
    return out.getvalue()


def detect_delimiter(text):
    """Picks the delimiter whose per-line count (outside quotes) is most consistent."""
    limit = 128 * 1024
    sample = text[:limit]
    cands = ["\t", ";", ",", "|"]
    lines, counts = [], [0] * 4
    in_quotes = has_content = False
    for ch in sample:
        if ch == '"':
            in_quotes = not in_quotes
            continue
        if not in_quotes and ch in "\r\n":
            if has_content:
                lines.append(counts)
            counts, has_content = [0] * 4, False
            if len(lines) >= 200:
                break
            continue
        has_content = True
        if not in_quotes and ch in cands:
            counts[cands.index(ch)] += 1
    if has_content and (len(text) <= limit or not lines):
        lines.append(counts)
    if not lines:
        return ","
    best = None
    for k, cand in enumerate(cands):
        freq = {}
        for line in lines:
            freq[line[k]] = freq.get(line[k], 0) + 1
        freq.pop(0, None)
        if not freq:
            continue
        mode, hits = max(freq.items(), key=lambda kv: kv[1])
        consistency = hits / len(lines)
        if consistency >= 0.9:
            return cand  # first consistent candidate in priority order wins
        score = consistency * 100 + min(mode, 20)
        if best is None or score > best[0]:
            best = (score, cand)
    return best[1] if best else ","


def number(s):
    t = s.strip()
    if not t or not (t[0].isdigit() or t[0] in "+-.,"):
        return None
    try:
        return float(t.replace(",", "."))
    except ValueError:
        return None


def guess_header(rows):
    if len(rows) < 2:
        return False
    filled = [v for v in rows[0] if v.strip()]
    if not filled or len(filled) * 2 < len(rows[0]):
        return False
    return not any(number(v) is not None for v in filled)


def column_letter(i):
    n, s = i + 1, ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def delimiter_name(d):
    return {"\t": "Tab", " ": "Spacja"}.get(d, d)


def encoding_name(enc):
    return {"utf-8": "UTF-8", "utf-8-sig": "UTF-8 BOM", "utf-16": "UTF-16", "cp1250": "Windows-1250",
            "iso8859-2": "ISO-8859-2", "cp1252": "Windows-1252", "latin-1": "ISO-8859-1"}.get(enc, enc)


def sort_key(s):
    """Natural ordering: numbers numerically before text, text with digit runs compared as numbers."""
    n = number(s)
    if n is not None:
        return (0, n, ())
    parts = re.split(r"(\d+)", s.casefold())
    return (1, 0, tuple(int(p) if i % 2 else locale.strxfrm(p) for i, p in enumerate(parts)))


# ---------------------------------------------------------------------------
# Fill-handle series (like LibreOffice)
# ---------------------------------------------------------------------------

def _decimals(s):
    i = max(s.rfind("."), s.rfind(","))
    return len(s) - i - 1 if i >= 0 else 0


def _number_series(src, count):
    nums = [number(s) for s in src]
    if any(n is None for n in nums):
        return None
    step = 1.0 if len(nums) == 1 else (nums[-1] - nums[0]) / (len(nums) - 1)
    places = max(_decimals(s) for s in src)
    comma = any("," in s for s in src)
    out = []
    for j in range(1, count + 1):
        v = f"{nums[-1] + step * j:.{places}f}"
        out.append(v.replace(".", ",") if comma else v)
    return out


_DATE_FORMATS = ["%Y-%m-%d", "%d.%m.%Y", "%d/%m/%Y", "%d-%m-%Y"]


def _date_series(src, count):
    for fmt in _DATE_FORMATS:
        try:
            if any(len(s) != 10 for s in src):
                return None
            ds = [datetime.datetime.strptime(s, fmt) for s in src]
        except ValueError:
            continue
        days = 1 if len(ds) == 1 else round((ds[-1] - ds[0]).days / (len(ds) - 1))
        return [(ds[-1] + datetime.timedelta(days=days * j)).strftime(fmt) for j in range(1, count + 1)]
    return None


def _text_series(src, count):
    prefix, values, width = None, [], 0
    for s in src:
        m = re.fullmatch(r"(.*\D)(\d{1,17})", s, re.S)
        if not m or (prefix is not None and m.group(1) != prefix):
            return None
        prefix = m.group(1)
        values.append(int(m.group(2)))
        width = len(m.group(2))
    step = 1 if len(values) == 1 else (values[-1] - values[0]) // (len(values) - 1)
    return [prefix + str(max(values[-1] + step * j, 0)).zfill(width) for j in range(1, count + 1)]


def extend_series(src, count, copy_only=False):
    if not src or count <= 0:
        return []
    if not copy_only:
        for f in (_number_series, _date_series, _text_series):
            s = f(src, count)
            if s is not None:
                return s
    return [src[i % len(src)] for i in range(count)]


# ---------------------------------------------------------------------------
# Document model with undo
# ---------------------------------------------------------------------------

class Document:
    MAX_UNDO = 300

    def __init__(self):
        self.rows = [[""]]
        self.width = 1
        self.has_header = False
        self.delimiter = ","
        self.encoding = "utf-8"
        self.eol = "\n"
        self.path = None
        self.dirty = False
        self.raw_text = None
        self.undo_stack, self.redo_stack = [], []
        self.listener = lambda kind, cols_changed=False: None

    @property
    def data_start(self):
        return 1 if self.has_header else 0

    # I/O

    def load(self, path):
        with open(path, "rb") as f:
            data = f.read()
        text, self.encoding = decode(data)
        self.eol = "\r\n" if "\r" in text[:65536] else "\n"
        self.delimiter = detect_delimiter(text)
        if self.delimiter != "\t" and path.lower().endswith((".tsv", ".tab")) and "\t" in text[:65536]:
            self.delimiter = "\t"
        self.raw_text = text
        self.rows, self.width = pad(parse(text, self.delimiter))
        self.has_header = guess_header(self.rows)
        self.path = path
        self.dirty = False
        self.undo_stack.clear()
        self.redo_stack.clear()

    def encode(self):
        text = serialize(self.rows, self.delimiter, self.eol, trim=True)
        return text.encode(self.encoding)

    def save(self, path):
        data = self.encode()  # raises UnicodeEncodeError before touching the file
        tmp = path + ".tmp~"
        with open(tmp, "wb") as f:
            f.write(data)
        if os.path.exists(path):
            try:
                os.chmod(tmp, os.stat(path).st_mode & 0o7777)
            except OSError:
                pass
        os.replace(tmp, path)
        self.path = path
        self.dirty = False
        self.listener("meta")

    @property
    def text(self):
        return serialize(self.rows, self.delimiter, "\n", trim=True)

    # Interpretation

    def change_delimiter(self, d):
        if d == self.delimiter:
            return
        source = self.raw_text if self.raw_text is not None else serialize(self.rows, self.delimiter, "\n", False)
        self.delimiter = d
        self.rows, self.width = pad(parse(source, d))
        if self.raw_text is not None:
            self.has_header = guess_header(self.rows)
        self.undo_stack.clear()
        self.redo_stack.clear()
        self.listener("reloaded")

    def set_has_header(self, value):
        if value != self.has_header:
            self.has_header = value
            self.listener("structure", False)

    # Undoable edits

    def _push(self, entry):
        self.undo_stack.append(entry)
        if len(self.undo_stack) > self.MAX_UNDO:
            del self.undo_stack[0]
        self.redo_stack.clear()
        self.dirty = True
        self.raw_text = None

    def set_cells(self, changes, name="Edycja"):
        # Clearing a cell outside the data is a no-op, not a reason to grow.
        changes = [ch for ch in changes if ch[2] or (ch[0] < len(self.rows) and ch[1] < self.width)]
        if not changes:
            return
        max_r = max(c[0] for c in changes)
        max_c = max(c[1] for c in changes)
        if max_r >= len(self.rows) or max_c >= self.width:
            w = max(self.width, max_c + 1)
            rows = [r + [""] * (w - len(r)) for r in self.rows]
            while len(rows) <= max_r:
                rows.append([""] * w)
            for r, c, v in changes:
                rows[r][c] = v
            self.replace_all(rows, w, name=name)
            return
        applied = []
        for r, c, v in changes:
            old = self.rows[r][c]
            if old != v:
                self.rows[r][c] = v
                applied.append((r, c, old, v))
        if applied:
            self._push(("cells", applied, name))
            self.listener("cells")

    def replace_all(self, rows, width, header=None, name="Edycja"):
        before = (self.rows, self.width, self.has_header)
        if header is not None:
            self.has_header = header
        cols_changed = width != self.width
        self.rows, self.width = rows, width
        self._push(("full", before, (self.rows, self.width, self.has_header), name))
        self.listener("structure", cols_changed)

    def _restore(self, entry, forward):
        if entry[0] == "cells":
            for r, c, old, new in entry[1]:
                self.rows[r][c] = new if forward else old
            self.listener("cells")
        else:
            rows, width, header = entry[2] if forward else entry[1]
            cols_changed = width != self.width
            self.rows, self.width, self.has_header = rows, width, header
            self.listener("structure", cols_changed)
        self.dirty = True
        self.raw_text = None

    def undo(self):
        if self.undo_stack:
            entry = self.undo_stack.pop()
            self.redo_stack.append(entry)
            self._restore(entry, forward=False)

    def redo(self):
        if self.redo_stack:
            entry = self.redo_stack.pop()
            self.undo_stack.append(entry)
            self._restore(entry, forward=True)

    def insert_row(self, i):
        rows = list(self.rows)
        rows.insert(max(0, min(i, len(rows))), [""] * self.width)
        self.replace_all(rows, self.width, name="Wstaw wiersz")

    def delete_rows(self, indexes):
        if not indexes:
            return
        rows = [r for i, r in enumerate(self.rows) if i not in indexes] or [[""] * self.width]
        self.replace_all(rows, self.width, name="Usuń wiersze")

    def insert_column(self, c):
        c = max(0, min(c, self.width))
        self.replace_all([r[:c] + [""] + r[c:] for r in self.rows], self.width + 1, name="Wstaw kolumnę")

    def delete_column(self, c):
        if self.width > 1 and c < self.width:
            self.replace_all([r[:c] + r[c + 1:] for r in self.rows], self.width - 1, name="Usuń kolumnę")

    def sort(self, c, ascending):
        if c >= self.width:
            return
        start = self.data_start
        body = self.rows[start:]
        if len(body) < 2:
            return
        filled = [r for r in body if r[c]]
        empty = [r for r in body if not r[c]]
        filled.sort(key=lambda r: sort_key(r[c]), reverse=not ascending)
        self.replace_all(self.rows[:start] + filled + empty, self.width, name="Sortowanie")

    def rename_column(self, c, name):
        if self.has_header:
            self.set_cells([(0, c, name)], "Zmień nazwę kolumny")
        elif name:
            width = max(self.width, c + 1)
            header = [column_letter(i) for i in range(width)]
            header[c] = name
            body = [r + [""] * (width - len(r)) for r in self.rows]
            self.replace_all([header] + body, width, header=True, name="Zmień nazwę kolumny")

    def replace_text(self, text):
        rows, width = pad(parse(text, self.delimiter))
        self.replace_all(rows, width, header=self.has_header and len(rows) > 1, name="Edycja tekstu")
        self.raw_text = text


# ---------------------------------------------------------------------------
# Spreadsheet-like grid widget
# ---------------------------------------------------------------------------

SHIFT, CONTROL = 0x0001, 0x0004


class Grid(tk.Frame):
    """Virtualised grid: only visible cells are drawn, so large files stay fast."""

    def __init__(self, master, owner):
        super().__init__(master, bg=GRID_BG)
        self.owner = owner
        self.font = tkfont.nametofont("TkDefaultFont")
        self.header_font = self.font.copy()
        self.header_font.configure(weight="bold")
        self.small_font = self.font.copy()
        self.small_font.configure(size=max(self.font.cget("size") - 1, 8) if self.font.cget("size") > 0 else -11)
        self.rh = self.font.metrics("linespace") + 8
        self.hh = self.rh + 2

        self.corner = tk.Canvas(self, width=50, height=self.hh, bg=HEADER_BG, highlightthickness=0)
        self.header = tk.Canvas(self, height=self.hh, bg=HEADER_BG, highlightthickness=0)
        self.rownums = tk.Canvas(self, width=50, bg=HEADER_BG, highlightthickness=0)
        self.body = tk.Canvas(self, bg=GRID_BG, highlightthickness=0, takefocus=1)
        self.vbar = ttk.Scrollbar(self, orient="vertical", command=self._vscroll)
        self.hbar = ttk.Scrollbar(self, orient="horizontal", command=self._hscroll)
        self.corner.grid(row=0, column=0, sticky="nsew")
        self.header.grid(row=0, column=1, sticky="nsew")
        self.rownums.grid(row=1, column=0, sticky="nsew")
        self.body.grid(row=1, column=1, sticky="nsew")
        self.vbar.grid(row=1, column=2, sticky="ns")
        self.hbar.grid(row=2, column=1, sticky="ew")
        self.grid_rowconfigure(1, weight=1)
        self.grid_columnconfigure(1, weight=1)

        self.top = 0
        self.xoff = 0
        self.widths = []
        self.xs = [0]
        self.anchor = [0, 0]
        self.cursor = [0, 0]
        self.drag = None
        self.fill_source = None
        self.fill_target = None
        self.last_mouse = (0, 0)
        self.auto_job = None
        self.editor = None
        self.resize = None
        self.fit_cache = {}

        b = self.body
        b.bind("<Configure>", lambda e: self.redraw())
        b.bind("<Button-1>", self._press)
        b.bind("<B1-Motion>", self._motion)
        b.bind("<ButtonRelease-1>", self._release)
        b.bind("<Double-Button-1>", lambda e: self.start_edit())
        b.bind("<Motion>", self._hover)
        b.bind("<Key>", self._key)
        for seq in ("<Button-3>", "<Control-Button-1>"):
            b.bind(seq, self._context)
        for w in (b, self.rownums, self.header):
            w.bind("<MouseWheel>", self._wheel)
            w.bind("<Shift-MouseWheel>", lambda e: self._hwheel(-1 if e.delta > 0 else 1))
            w.bind("<Button-4>", lambda e: self._scroll_rows(-3))
            w.bind("<Button-5>", lambda e: self._scroll_rows(3))
            w.bind("<Shift-Button-4>", lambda e: self._hwheel(-1))
            w.bind("<Shift-Button-5>", lambda e: self._hwheel(1))
        self.header.bind("<Button-1>", self._header_press)
        self.header.bind("<B1-Motion>", self._header_motion)
        self.header.bind("<ButtonRelease-1>", self._header_release)
        self.header.bind("<Double-Button-1>", self._header_double)
        self.header.bind("<Motion>", self._header_hover)
        self.header.bind("<Button-3>", self._header_context)
        self.rownums.bind("<Button-1>", self._rownum_press)
        self.rownums.bind("<B1-Motion>", self._rownum_motion)
        self.rownums.bind("<ButtonRelease-1>", self._release)
        self.corner.bind("<Button-1>", lambda e: self.select_all())

    # -- data helpers ------------------------------------------------------

    @property
    def nrows(self):
        return self.owner.grid_nrows()

    @property
    def ncols(self):
        return len(self.widths)

    def has_cells(self):
        return self.nrows > 0 and self.ncols > 0

    def set_widths(self, widths):
        self.widths = list(widths)
        self._recalc_x()

    def _recalc_x(self):
        self.xs = [0]
        for w in self.widths:
            self.xs.append(self.xs[-1] + w)

    def selection(self):
        return (min(self.anchor[0], self.cursor[0]), max(self.anchor[0], self.cursor[0]),
                min(self.anchor[1], self.cursor[1]), max(self.anchor[1], self.cursor[1]))

    def _visible_rows(self):
        return max(1, self.body.winfo_height() // self.rh)

    # -- selection ---------------------------------------------------------

    def select(self, r, c, extend=False, scroll=True):
        if not self.has_cells():
            return
        r = max(0, min(r, self.nrows - 1))
        c = max(0, min(c, self.ncols - 1))
        self.cursor = [r, c]
        if not extend:
            self.anchor = [r, c]
        if scroll:
            self.ensure_visible(r, c)
        self.redraw()
        self.owner.grid_selection_changed()

    def select_range(self, a, b):
        if not self.has_cells():
            return
        self.anchor = [max(0, min(a[0], self.nrows - 1)), max(0, min(a[1], self.ncols - 1))]
        self.select(b[0], b[1], extend=True)

    def select_all(self):
        self.commit_edit()
        self.select_range((0, 0), (self.nrows - 1, self.ncols - 1))

    def clamp(self):
        if self.has_cells():
            self.anchor = [min(self.anchor[0], self.nrows - 1), min(self.anchor[1], self.ncols - 1)]
            self.select(self.cursor[0], self.cursor[1], extend=True, scroll=False)
        else:
            self.redraw()

    def move(self, dr, dc, extend=False):
        self.select(self.cursor[0] + dr, self.cursor[1] + dc, extend)

    def ensure_visible(self, r, c):
        if self.body.winfo_width() <= 1:  # not laid out yet; nothing to scroll
            return
        vis = self._visible_rows()
        if r < self.top:
            self.top = r
        elif r >= self.top + vis:
            self.top = r - vis + 1
        w = self.body.winfo_width()
        if c < len(self.widths):
            if self.xs[c] < self.xoff:
                self.xoff = self.xs[c]
            elif self.xs[c + 1] > self.xoff + w:
                self.xoff = max(0, self.xs[c + 1] - w)

    # -- scrolling ---------------------------------------------------------

    def _max_top(self):
        return max(0, self.nrows - self._visible_rows())

    def _scroll_rows(self, n):
        self.top = max(0, min(self.top + n, self._max_top()))
        self.redraw()

    def _hwheel(self, direction):
        self._set_xoff(self.xoff + direction * 80)

    def _set_xoff(self, x):
        self.xoff = int(max(0, min(x, max(0, self.xs[-1] - self.body.winfo_width()))))
        self.redraw()

    def _wheel(self, e):
        if e.delta == 0:
            return
        steps = -e.delta // 120 if abs(e.delta) >= 120 else (-1 if e.delta > 0 else 1)
        self._scroll_rows(steps * 3)

    def _vscroll(self, *args):
        if args[0] == "moveto":
            self.top = int(float(args[1]) * self.nrows)
        elif args[0] == "scroll":
            n = int(args[1])
            self.top += n * (self._visible_rows() - 1 if args[2] == "pages" else 1)
        self.top = max(0, min(self.top, self._max_top()))
        self.redraw()

    def _hscroll(self, *args):
        total = max(self.xs[-1], 1)
        if args[0] == "moveto":
            self._set_xoff(float(args[1]) * total)
        elif args[0] == "scroll":
            n = int(args[1])
            self._set_xoff(self.xoff + n * (self.body.winfo_width() - 40 if args[2] == "pages" else 40))

    # -- geometry ----------------------------------------------------------

    def cell_rect(self, r, c):
        x0 = self.xs[c] - self.xoff
        y0 = (r - self.top) * self.rh
        return x0, y0, self.xs[c + 1] - self.xoff, y0 + self.rh

    def range_rect(self, sel):
        r0, r1, c0, c1 = sel
        return (self.xs[c0] - self.xoff, (r0 - self.top) * self.rh,
                self.xs[c1 + 1] - self.xoff, (r1 + 1 - self.top) * self.rh)

    def cell_at(self, x, y, clamp=False):
        r = self.top + int(y // self.rh)
        c = bisect.bisect_right(self.xs, x + self.xoff) - 1
        if clamp:
            return [max(0, min(r, self.nrows - 1)), max(0, min(c, self.ncols - 1))]
        if 0 <= r < self.nrows and 0 <= c < self.ncols:
            return [r, c]
        return None

    def _in_fill_handle(self, x, y):
        if not self.has_cells():
            return False
        _, _, x1, y1 = self.range_rect(self.selection())
        return abs(x - x1) <= 5 and abs(y - y1) <= 5

    def _fit(self, text, width, fnt=None):
        fnt = fnt or self.font
        key = (text, width, str(fnt))
        hit = self.fit_cache.get(key)
        if hit is not None:
            return hit
        t = text.replace("\r\n", " ⏎ ").replace("\n", " ⏎ ")
        if len(t) > 300:
            t = t[:300]
        if fnt.measure(t) > width:
            lo, hi = 0, len(t)
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if fnt.measure(t[:mid] + "…") <= width:
                    lo = mid
                else:
                    hi = mid - 1
            t = t[:lo] + "…" if lo > 0 else ""
        if len(self.fit_cache) > 20000:
            self.fit_cache.clear()
        self.fit_cache[key] = t
        return t

    # -- drawing -----------------------------------------------------------

    def redraw(self):
        b = self.body
        b.delete("all")
        W, H = b.winfo_width(), b.winfo_height()
        n, m, rh = self.nrows, self.ncols, self.rh
        self.top = max(0, min(self.top, self._max_top()))
        first, last = self.top, min(n, self.top + H // rh + 1)
        c_first = max(0, bisect.bisect_right(self.xs, self.xoff) - 1)
        c_last = min(m, bisect.bisect_left(self.xs, self.xoff + W) + 1)
        right = min(W, self.xs[-1] - self.xoff)
        sel = self.selection() if self.has_cells() else None

        if sel and (sel[1] > sel[0] or sel[3] > sel[2]):
            b.create_rectangle(*self.range_rect(sel), fill=SEL_BG, width=0)
            b.create_rectangle(*self.cell_rect(*self.cursor), fill=GRID_BG, width=0)

        for i in range(H // rh + 2):
            y = i * rh
            b.create_line(0, y, right, y, fill=GRID_LINE)
        for c in range(c_first, c_last):
            x = self.xs[c + 1] - self.xoff
            b.create_line(x, 0, x, H, fill=GRID_LINE)

        for r in range(first, last):
            yc = (r - first) * rh + rh / 2
            for c in range(c_first, c_last):
                t = self.owner.grid_cell(r, c)
                if not t:
                    continue
                w = self.widths[c] - 8
                shown = self._fit(t, w)
                if not shown:
                    continue
                if number(t) is not None:
                    b.create_text(self.xs[c + 1] - self.xoff - 4, yc, text=shown, anchor="e", font=self.font)
                else:
                    b.create_text(self.xs[c] - self.xoff + 4, yc, text=shown, anchor="w", font=self.font)

        if sel:
            x0, y0, x1, y1 = self.range_rect(sel)
            b.create_rectangle(x0 + 1, y0 + 1, x1 - 1, y1 - 1, outline=ACCENT, width=2)
            b.create_rectangle(x1 - 4, y1 - 4, x1 + 3, y1 + 3, fill=ACCENT, outline=GRID_BG)
        if self.fill_target:
            full = self._fill_union()
            b.create_rectangle(*self.range_rect(full), outline=ACCENT, dash=(4, 3), width=1)

        self._draw_header(c_first, c_last, sel)
        self._draw_rownums(first, last, sel)
        self._place_editor()

        vis = max(1, H // rh)
        self.vbar.set(*((self.top / n, min(1.0, (self.top + vis) / n)) if n else (0, 1)))
        total = max(self.xs[-1], 1)
        self.hbar.set(self.xoff / total, min(1.0, (self.xoff + W) / total))

    def _draw_header(self, c_first, c_last, sel):
        h = self.header
        h.delete("all")
        W, hh = h.winfo_width(), self.hh
        for c in range(c_first, c_last):
            x0, x1 = self.xs[c] - self.xoff, self.xs[c + 1] - self.xoff
            selected = sel and sel[2] <= c <= sel[3]
            h.create_rectangle(x0, 0, x1, hh, fill=HEADER_SEL if selected else HEADER_BG, outline="")
            h.create_line(x1, 0, x1, hh, fill=GRID_LINE)
            filtered = self.owner.grid_col_filtered(c)
            arrow = "▼" if filtered else "▾"
            fnt = self.header_font
            title = self._fit(self.owner.grid_col_title(c), max(self.widths[c] - 26, 0), fnt)
            h.create_text(x0 + 6, hh / 2, text=title, anchor="w", font=fnt, fill=ACCENT if filtered else HEADER_FG)
            h.create_text(x1 - 6, hh / 2, text=arrow, anchor="e", font=self.small_font,
                          fill=ACCENT if filtered else ROWNUM_FG)
        h.create_line(0, hh - 1, W, hh - 1, fill=GRID_LINE)

    def _draw_rownums(self, first, last, sel):
        rn = self.rownums
        rn.delete("all")
        digits = len(str(max(self.owner.grid_max_label(), 10)))
        width = digits * self.small_font.measure("0") + 16
        if int(rn.cget("width")) != width:
            rn.configure(width=width)
            self.corner.configure(width=width)
        H = rn.winfo_height()
        for r in range(first, last):
            y0 = (r - first) * self.rh
            if sel and sel[0] <= r <= sel[1]:
                rn.create_rectangle(0, y0, width, y0 + self.rh, fill=HEADER_SEL, outline="")
            rn.create_line(0, y0 + self.rh, width, y0 + self.rh, fill=GRID_LINE)
            rn.create_text(width - 6, y0 + self.rh / 2, text=self.owner.grid_row_label(r), anchor="e",
                           font=self.small_font, fill=ROWNUM_FG)
        rn.create_line(width - 1, 0, width - 1, H, fill=GRID_LINE)

    # -- mouse ---------------------------------------------------------------

    def _press(self, e):
        self.body.focus_set()
        self.commit_edit()
        if not self.has_cells():
            return
        if self._in_fill_handle(e.x, e.y):
            self.drag = "fill"
            self.fill_source = self.selection()
            self.fill_target = None
            return
        cell = self.cell_at(e.x, e.y)
        if cell is None:
            return
        self.drag = "select"
        self.select(cell[0], cell[1], extend=bool(e.state & SHIFT))

    def _motion(self, e):
        self.last_mouse = (e.x, e.y)
        if not self.drag:
            return
        self._drag_update(e.x, e.y)
        W, H = self.body.winfo_width(), self.body.winfo_height()
        if (e.x < 0 or e.y < 0 or e.x > W or e.y > H) and not self.auto_job:
            self.auto_job = self.after(50, self._autoscroll)

    def _autoscroll(self):
        self.auto_job = None
        if not self.drag:
            return
        x, y = self.last_mouse
        W, H = self.body.winfo_width(), self.body.winfo_height()
        moved = False
        if y > H:
            self.top = min(self.top + 1, self._max_top()); moved = True
        elif y < 0 and self.top > 0:
            self.top -= 1; moved = True
        if x > W:
            self.xoff = min(self.xoff + 30, max(0, self.xs[-1] - W)); moved = True
        elif x < 0 and self.xoff > 0:
            self.xoff = max(0, self.xoff - 30); moved = True
        if moved:
            self._drag_update(x, y)
            self.auto_job = self.after(50, self._autoscroll)

    def _drag_update(self, x, y):
        pos = self.cell_at(x, y, clamp=True)
        if self.drag == "select":
            if pos != self.cursor:
                self.select(pos[0], pos[1], extend=True, scroll=False)
        elif self.drag == "rows":
            self.select_range((self.anchor[0], 0), (pos[0], self.ncols - 1))
        elif self.drag == "fill":
            r0, r1, c0, c1 = self.fill_source
            down, up = pos[0] - r1, r0 - pos[0]
            right, left = pos[1] - c1, c0 - pos[1]
            best = max(down, up, right, left)
            if best <= 0:
                self.fill_target = None
            elif best == down:
                self.fill_target = ((r1 + 1, pos[0], c0, c1), True, True)
            elif best == up:
                self.fill_target = ((pos[0], r0 - 1, c0, c1), True, False)
            elif best == right:
                self.fill_target = ((r0, r1, c1 + 1, pos[1]), False, True)
            else:
                self.fill_target = ((r0, r1, pos[1], c0 - 1), False, False)
            self.redraw()

    def _fill_union(self):
        (t0, t1, u0, u1), _, _ = self.fill_target
        r0, r1, c0, c1 = self.fill_source
        return (min(t0, r0), max(t1, r1), min(u0, c0), max(u1, c1))

    def _release(self, e):
        if self.drag == "fill" and self.fill_target:
            full = self._fill_union()
            target, vertical, forward = self.fill_target
            self.fill_target = None
            self.owner.grid_fill(self.fill_source, target, vertical, forward, copy_only=bool(e.state & CONTROL))
            self.select_range((full[0], full[2]), (full[1], full[3]))
        else:
            self.fill_target = None
            self.redraw()
        self.drag = None

    def _hover(self, e):
        self.body.configure(cursor="crosshair" if self._in_fill_handle(e.x, e.y) else "")

    def _context(self, e):
        self.body.focus_set()
        self.commit_edit()
        cell = self.cell_at(e.x, e.y)
        if cell:
            r0, r1, c0, c1 = self.selection()
            if not (r0 <= cell[0] <= r1 and c0 <= cell[1] <= c1):
                self.select(cell[0], cell[1])
        self.owner.grid_context_menu(e)

    def _rownum_press(self, e):
        self.body.focus_set()
        self.commit_edit()
        if not self.has_cells():
            return
        r = max(0, min(self.top + int(e.y // self.rh), self.nrows - 1))
        start = self.anchor[0] if e.state & SHIFT else r
        self.drag = "rows"
        self.select_range((start, 0), (r, self.ncols - 1))

    def _rownum_motion(self, e):
        self.last_mouse = (max(e.x, 0), e.y)
        if self.drag == "rows":
            self._drag_update(0, e.y)

    # header: click opens filter, drag on border resizes, double-click border autosizes
    def _border_at(self, x):
        for c in range(self.ncols):
            if abs(self.xs[c + 1] - self.xoff - x) <= 4:
                return c
        return None

    def _header_hover(self, e):
        self.header.configure(cursor="sb_h_double_arrow" if self._border_at(e.x) is not None else "")

    def _header_press(self, e):
        self.commit_edit()
        c = self._border_at(e.x)
        if c is not None:
            self.resize = (c, e.x, self.widths[c])
            return
        self.resize = None
        col = bisect.bisect_right(self.xs, e.x + self.xoff) - 1
        if 0 <= col < self.ncols:
            self.header_click = col

    def _header_motion(self, e):
        if self.resize:
            c, x0, w0 = self.resize
            self.widths[c] = max(30, w0 + e.x - x0)
            self._recalc_x()
            self.redraw()

    def _header_release(self, e):
        if self.resize:
            self.resize = None
            return
        col = getattr(self, "header_click", None)
        self.header_click = None
        if col is not None:
            self.cursor[1] = self.anchor[1] = col
            self.redraw()
            self.owner.grid_header_click(col, e.x_root, e.y_root)

    def _header_double(self, e):
        c = self._border_at(e.x)
        if c is not None:
            self.widths[c] = self.owner.grid_autosize(c)
            self._recalc_x()
            self.redraw()

    def _header_context(self, e):
        col = bisect.bisect_right(self.xs, e.x + self.xoff) - 1
        if 0 <= col < self.ncols:
            self.select_range((0, col), (self.nrows - 1, col)) if self.nrows else None
            self.owner.grid_context_menu(e)

    # -- keyboard ------------------------------------------------------------

    def _key(self, e):
        if not self.has_cells():
            return None
        ks = e.keysym
        shift, ctrl = bool(e.state & SHIFT), bool(e.state & CONTROL)
        page = max(self._visible_rows() - 1, 1)
        r, c = self.cursor
        if ks == "Up":
            self.select(0 if ctrl else r - 1, c, shift)
        elif ks == "Down":
            self.select(self.nrows - 1 if ctrl else r + 1, c, shift)
        elif ks == "Left":
            self.select(r, 0 if ctrl else c - 1, shift)
        elif ks == "Right":
            self.select(r, self.ncols - 1 if ctrl else c + 1, shift)
        elif ks in ("Return", "KP_Enter"):
            self.move(-1 if shift else 1, 0)
        elif ks == "Tab":
            self.move(0, -1 if shift else 1)
        elif ks == "ISO_Left_Tab":
            self.move(0, -1)
        elif ks == "Prior":
            self.select(r - page, c, shift)
        elif ks == "Next":
            self.select(r + page, c, shift)
        elif ks == "Home":
            self.select(0 if ctrl else r, 0, shift)
        elif ks == "End":
            self.select(self.nrows - 1 if ctrl else r, self.ncols - 1, shift)
        elif ks == "F2":
            self.start_edit()
        elif ks in ("Delete", "BackSpace"):
            self.owner.grid_clear(self.selection())
        elif ks == "Escape":
            self.select(r, c)
        elif e.char and e.char.isprintable() and not ctrl:
            self.start_edit(e.char)
        else:
            return None
        return "break"

    # -- in-place editing ----------------------------------------------------

    def start_edit(self, initial=None):
        if not self.has_cells():
            return
        self.commit_edit()
        r, c = self.cursor
        self.ensure_visible(r, c)
        self.redraw()
        entry = tk.Entry(self.body, font=self.font, relief="solid", bd=1, highlightthickness=2,
                         highlightcolor=ACCENT, highlightbackground=ACCENT)
        text = self.owner.grid_cell(r, c) if initial is None else initial
        entry.insert(0, text)
        entry.icursor("end")
        self.editor = {"entry": entry, "row": r, "col": c, "typed": initial is not None}
        self._place_editor()
        entry.focus_set()
        entry.bind("<Return>", lambda e: self._editor_key(1, 0, e))
        entry.bind("<KP_Enter>", lambda e: self._editor_key(1, 0, e))
        entry.bind("<Tab>", lambda e: self._editor_key(0, 1, e))
        entry.bind("<ISO_Left_Tab>", lambda e: self._editor_key(0, -1, e))
        entry.bind("<Shift-Tab>", lambda e: self._editor_key(0, -1, e))
        entry.bind("<Escape>", lambda e: self.cancel_edit())
        entry.bind("<FocusOut>", lambda e: self.commit_edit(refocus=False))
        entry.bind("<Up>", lambda e: self._editor_arrow(-1, e))
        entry.bind("<Down>", lambda e: self._editor_arrow(1, e))
        entry.bind("<KeyRelease>", lambda e: self._place_editor())

    def _editor_key(self, dr, dc, e):
        if dr and e.state & SHIFT:
            dr = -dr
        self.commit_edit()
        self.move(dr, dc)
        return "break"

    def _editor_arrow(self, dr, e):
        if self.editor and self.editor["typed"]:
            return self._editor_key(dr, 0, e)
        return None

    def _place_editor(self):
        if not self.editor:
            return
        ed = self.editor
        if ed["row"] >= self.nrows or ed["col"] >= self.ncols:
            return
        x0, y0, x1, y1 = self.cell_rect(ed["row"], ed["col"])
        want = self.font.measure(ed["entry"].get()) + 24
        width = min(max(x1 - x0 + 1, want), max(self.body.winfo_width() - x0, x1 - x0 + 1))
        ed["entry"].place(x=x0, y=y0, width=width, height=y1 - y0 + 1)

    def commit_edit(self, refocus=True):
        ed, self.editor = self.editor, None
        if not ed:
            return
        text = ed["entry"].get()
        ed["entry"].destroy()
        self.owner.grid_commit(ed["row"], ed["col"], text)
        if refocus:
            self.body.focus_set()

    def cancel_edit(self):
        ed, self.editor = self.editor, None
        if ed:
            ed["entry"].destroy()
            self.body.focus_set()
        return "break"


# ---------------------------------------------------------------------------
# Dialogs
# ---------------------------------------------------------------------------

class FilterPopup(tk.Toplevel):
    """AutoFilter-style window: column name, sorting, value search and checkboxes."""
    MAX_SHOWN = 5000

    def __init__(self, win, col, x, y, focus_name=False):
        super().__init__(win)
        self.win, self.col = win, col
        self.title(f"Kolumna {column_letter(col)}")
        self.transient(win)
        self.resizable(False, True)
        self.values, self.counts = win.column_values(col)
        selected = win.filters.get(col)
        self.checked = set(self.values) if selected is None else set(v for v in self.values if v in selected)
        self.matching = list(range(len(self.values)))
        self.original_name = win.header_name(col)

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)
        name_row = ttk.Frame(frame)
        name_row.pack(fill="x")
        ttk.Label(name_row, text=f"Kolumna {column_letter(col)}:").pack(side="left")
        self.name_var = tk.StringVar(value=self.original_name)
        self.name_entry = ttk.Entry(name_row, textvariable=self.name_var, font=win.grid.header_font)
        self.name_entry.pack(side="left", fill="x", expand=True, padx=(6, 0))

        sort_row = ttk.Frame(frame)
        sort_row.pack(fill="x", pady=(8, 0))
        ttk.Button(sort_row, text="↑  Sortuj rosnąco", command=lambda: self._sort(True)).pack(side="left", fill="x", expand=True)
        ttk.Button(sort_row, text="↓  Sortuj malejąco", command=lambda: self._sort(False)).pack(side="left", fill="x", expand=True, padx=(6, 0))

        self.search_var = tk.StringVar()
        self.search_var.trace_add("write", lambda *a: self._refill())
        search = ttk.Entry(frame, textvariable=self.search_var)
        search.pack(fill="x", pady=(8, 4))
        ttk.Label(frame, text="Szukaj wartości ↑", foreground=ROWNUM_FG).pack(anchor="w")

        list_frame = ttk.Frame(frame)
        list_frame.pack(fill="both", expand=True, pady=(4, 0))
        self.tree = ttk.Treeview(list_frame, show="tree", selectmode="browse", height=14)
        sb = ttk.Scrollbar(list_frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.column("#0", width=300)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.tree.bind("<Button-1>", self._toggle_click)
        self.tree.bind("<space>", self._toggle_key)

        sel_row = ttk.Frame(frame)
        sel_row.pack(fill="x", pady=(6, 0))
        ttk.Button(sel_row, text="Zaznacz wszystkie", command=lambda: self._check_all(True)).pack(side="left", fill="x", expand=True)
        ttk.Button(sel_row, text="Odznacz wszystkie", command=lambda: self._check_all(False)).pack(side="left", fill="x", expand=True, padx=(6, 0))
        self.summary = ttk.Label(frame, foreground=ROWNUM_FG)
        self.summary.pack(anchor="w", pady=(6, 0))

        bottom = ttk.Frame(frame)
        bottom.pack(fill="x", pady=(8, 0))
        ttk.Button(bottom, text="Usuń filtr", command=self._clear).pack(side="left")
        ttk.Button(bottom, text="OK", command=self._apply).pack(side="right")
        ttk.Button(bottom, text="Anuluj", command=self.destroy).pack(side="right", padx=6)

        self.bind("<Escape>", lambda e: self.destroy())
        self.bind("<Return>", lambda e: self._apply())
        self._refill()
        self.geometry(f"+{max(x - 20, 0)}+{y + 10}")
        self.update_idletasks()
        (self.name_entry if focus_name else search).focus_set()
        if focus_name:
            self.name_entry.select_range(0, "end")
        try:
            self.grab_set()
        except tk.TclError:
            pass

    def _label(self, i):
        v = self.values[i]
        text = "(puste)" if v == "" else v.replace("\n", " ")
        return f"{'☑' if v in self.checked else '☐'}  {text}   ({self.counts[v]})"

    def _refill(self):
        q = self.search_var.get().casefold()
        self.matching = [i for i, v in enumerate(self.values) if q in v.casefold()] if q else list(range(len(self.values)))
        self.tree.delete(*self.tree.get_children())
        for i in self.matching[:self.MAX_SHOWN]:
            self.tree.insert("", "end", iid=str(i), text=self._label(i))
        self._update_summary()

    def _update_summary(self):
        extra = ""
        if len(self.matching) > self.MAX_SHOWN:
            extra = f" — pokazano {self.MAX_SHOWN} z {len(self.matching)}, zawęź wyszukiwanie"
        self.summary.configure(text=f"Zaznaczono {len(self.checked)} z {len(self.values)} wartości{extra}")

    def _toggle(self, iid):
        v = self.values[int(iid)]
        self.checked.symmetric_difference_update({v})
        self.tree.item(iid, text=self._label(int(iid)))
        self._update_summary()

    def _toggle_click(self, e):
        iid = self.tree.identify_row(e.y)
        if iid:
            self._toggle(iid)
            self.tree.focus(iid)
        return "break"

    def _toggle_key(self, e):
        iid = self.tree.focus()
        if iid:
            self._toggle(iid)
        return "break"

    def _check_all(self, on):
        for i in self.matching:
            (self.checked.add if on else self.checked.discard)(self.values[i])
        for iid in self.tree.get_children():
            self.tree.item(iid, text=self._label(int(iid)))
        self._update_summary()

    def _commit_name(self):
        name = self.name_var.get().replace("\n", " ")
        if name != self.original_name:
            self.win.doc.rename_column(self.col, name)

    def _apply(self):
        self._commit_name()
        result = set(self.checked)
        if self.search_var.get():
            result &= {self.values[i] for i in self.matching}
        self.destroy()
        self.win.set_filter(self.col, None if len(result) == len(self.values) else result)

    def _clear(self):
        self._commit_name()
        self.destroy()
        self.win.set_filter(self.col, None)

    def _sort(self, ascending):
        self._commit_name()
        self.destroy()
        self.win.doc.sort(self.col, ascending)


class SaveOptionsDialog(tk.Toplevel):
    def __init__(self, parent, delimiter, encoding):
        super().__init__(parent)
        self.title("Opcje zapisu")
        self.transient(parent)
        self.resizable(False, False)
        self.result = None
        frame = ttk.Frame(self, padding=14)
        frame.pack(fill="both", expand=True)
        names = [n.strip() for n, _ in DELIMITERS]
        self.delims = [d for _, d in DELIMITERS]
        if delimiter not in self.delims:
            names.append(f"Inny: {delimiter}")
            self.delims.append(delimiter)
        ttk.Label(frame, text="Separator pól:").grid(row=0, column=0, sticky="e", padx=(0, 8), pady=4)
        self.delim_box = ttk.Combobox(frame, values=names, state="readonly", width=30)
        self.delim_box.current(self.delims.index(delimiter))
        self.delim_box.grid(row=0, column=1, pady=4)
        ttk.Label(frame, text="Kodowanie znaków:").grid(row=1, column=0, sticky="e", padx=(0, 8), pady=4)
        codes = [c for _, c in ENCODINGS]
        self.codes = codes
        self.enc_box = ttk.Combobox(frame, values=[n for n, _ in ENCODINGS], state="readonly", width=30)
        self.enc_box.current(codes.index(encoding) if encoding in codes else 0)
        self.enc_box.grid(row=1, column=1, pady=4)
        buttons = ttk.Frame(frame)
        buttons.grid(row=2, column=0, columnspan=2, sticky="e", pady=(10, 0))
        ttk.Button(buttons, text="Anuluj", command=self.destroy).pack(side="right")
        ttk.Button(buttons, text="Zapisz", command=self._ok).pack(side="right", padx=6)
        self.bind("<Return>", lambda e: self._ok())
        self.bind("<Escape>", lambda e: self.destroy())
        self.update_idletasks()
        self.geometry(f"+{parent.winfo_rootx() + 120}+{parent.winfo_rooty() + 120}")
        try:
            self.grab_set()
        except tk.TclError:
            pass
        self.wait_window()

    def _ok(self):
        self.result = (self.delims[self.delim_box.current()], self.codes[self.enc_box.current()])
        self.destroy()


def ask_string(parent, title, prompt, initial=""):
    dlg = tk.Toplevel(parent)
    dlg.title(title)
    dlg.transient(parent)
    dlg.resizable(False, False)
    result = {"value": None}
    frame = ttk.Frame(dlg, padding=14)
    frame.pack()
    ttk.Label(frame, text=prompt).pack(anchor="w")
    var = tk.StringVar(value=initial)
    entry = ttk.Entry(frame, textvariable=var, width=20)
    entry.pack(fill="x", pady=8)

    def ok(_=None):
        result["value"] = var.get()
        dlg.destroy()

    row = ttk.Frame(frame)
    row.pack(fill="x")
    ttk.Button(row, text="Anuluj", command=dlg.destroy).pack(side="right")
    ttk.Button(row, text="OK", command=ok).pack(side="right", padx=6)
    dlg.bind("<Return>", ok)
    dlg.bind("<Escape>", lambda e: dlg.destroy())
    dlg.geometry(f"+{parent.winfo_rootx() + 160}+{parent.winfo_rooty() + 100}")
    entry.focus_set()
    try:
        dlg.grab_set()
    except tk.TclError:
        pass
    dlg.wait_window()
    return result["value"]


# ---------------------------------------------------------------------------
# Document window
# ---------------------------------------------------------------------------

class Window(tk.Toplevel):
    def __init__(self, app, path=None):
        super().__init__(app.root)
        self.app = app
        self.doc = Document()
        self.doc.listener = self._doc_changed
        self.filters = {}
        self.search = ""
        self.visible = []
        self.pending_row = None
        self.text_mode = False
        self.loaded_text = ""
        self._search_job = None
        self.extra_cols = 10

        self.geometry("1100x700")
        self.minsize(640, 320)
        self.protocol("WM_DELETE_WINDOW", self.close)
        self._build()
        if path:
            try:
                self.doc.load(path)
            except OSError as exc:
                messagebox.showerror(APP_NAME, f"Nie można otworzyć pliku:\n{exc}", parent=self)
        self._reset_columns()
        self.recompute_visible()
        self._sync_controls()
        self.grid.select(0, 0)
        self.grid.body.focus_set()

    # -- UI ------------------------------------------------------------------

    def _build(self):
        self._build_menu()
        bar = ttk.Frame(self, padding=(10, 6))
        bar.pack(fill="x")
        self.mode_var = tk.StringVar(value="table")
        for label, value in (("Tabela", "table"), ("Tekst", "text")):
            ttk.Radiobutton(bar, text=label, value=value, variable=self.mode_var, style="Toolbutton",
                            command=lambda: self.set_text_mode(self.mode_var.get() == "text")).pack(side="left")
        ttk.Label(bar, text="Separator:").pack(side="left", padx=(18, 4))
        self.delim_box = ttk.Combobox(bar, state="readonly", width=18)
        self.delim_box.pack(side="left")
        self.delim_box.bind("<<ComboboxSelected>>", self._delimiter_selected)
        self.header_var = tk.BooleanVar()
        self.header_check = ttk.Checkbutton(bar, text="Pierwszy wiersz jako nagłówek", variable=self.header_var,
                                            command=self.toggle_header)
        self.header_check.pack(side="left", padx=12)
        self.search_var = tk.StringVar()
        self.search_entry = ttk.Entry(bar, textvariable=self.search_var, width=28)
        self.search_entry.pack(side="right")
        ttk.Label(bar, text="Szukaj:").pack(side="right", padx=(10, 4))
        self.clear_button = ttk.Button(bar, text="Wyczyść filtry", command=self.clear_filters)
        self.clear_button.pack(side="right")
        self.search_var.trace_add("write", lambda *a: self._schedule_search())
        ttk.Separator(self).pack(fill="x")

        self.input_line = ttk.Frame(self, padding=(6, 4))
        self.input_line.pack(fill="x")
        self.ref_label = ttk.Label(self.input_line, width=12, anchor="center", font="TkFixedFont")
        self.ref_label.pack(side="left")
        self.input_var = tk.StringVar()
        self.input_entry = ttk.Entry(self.input_line, textvariable=self.input_var)
        self.input_entry.pack(side="left", fill="x", expand=True)
        self.input_entry.bind("<Return>", self._input_commit)
        self.input_entry.bind("<Escape>", lambda e: (self._update_input_line(force=True), self.grid.body.focus_set()))
        self.input_sep = ttk.Separator(self)
        self.input_sep.pack(fill="x")

        self.status = ttk.Label(self, padding=(10, 3), foreground=ROWNUM_FG)
        self.status.pack(side="bottom", fill="x")
        ttk.Separator(self).pack(side="bottom", fill="x")

        self.content = ttk.Frame(self)
        self.content.pack(fill="both", expand=True)
        self.grid = Grid(self.content, self)
        self.grid.pack(fill="both", expand=True)

        self.text_frame = ttk.Frame(self.content)
        self.text = tk.Text(self.text_frame, wrap="none", undo=True, font="TkFixedFont", padx=8, pady=8,
                            relief="flat", highlightthickness=0)
        ys = ttk.Scrollbar(self.text_frame, orient="vertical", command=self.text.yview)
        xs = ttk.Scrollbar(self.text_frame, orient="horizontal", command=self.text.xview)
        self.text.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        self.text.grid(row=0, column=0, sticky="nsew")
        ys.grid(row=0, column=1, sticky="ns")
        xs.grid(row=1, column=0, sticky="ew")
        self.text_frame.grid_rowconfigure(0, weight=1)
        self.text_frame.grid_columnconfigure(0, weight=1)
        self.text.bind("<<Modified>>", self._text_modified)

        g = self.grid.body
        for key, fn in (("c", self.copy), ("x", self.cut), ("v", self.paste), ("a", lambda: self.grid.select_all())):
            g.bind(f"<Control-{key}>", lambda e, fn=fn: (fn(), "break")[1])
            g.bind(f"<Control-{key.upper()}>", lambda e, fn=fn: (fn(), "break")[1])

        self.context = tk.Menu(self, tearoff=0)
        for item in (("Wytnij", self.cut), ("Kopiuj", self.copy), ("Wklej", self.paste), None,
                          ("Wstaw wiersz powyżej", self.insert_row_above), ("Wstaw wiersz poniżej", self.insert_row_below),
                          ("Usuń zaznaczone wiersze", self.delete_rows), None,
                          ("Wstaw kolumnę po lewej", self.insert_column_left), ("Wstaw kolumnę po prawej", self.insert_column_right),
                          ("Usuń kolumnę", self.delete_column), ("Zmień nazwę kolumny…", self.rename_column), None,
                          ("Filtruj kolumnę…", self.filter_column), ("Sortuj rosnąco", lambda: self.sort_column(True)),
                          ("Sortuj malejąco", lambda: self.sort_column(False))):
            if item is None:
                self.context.add_separator()
            else:
                self.context.add_command(label=item[0], command=item[1])

    def _build_menu(self):
        menubar = tk.Menu(self)
        m = tk.Menu(menubar, tearoff=0)
        m.add_command(label="Nowy", accelerator="Ctrl+N", command=lambda: self.app.new_window())
        m.add_command(label="Otwórz…", accelerator="Ctrl+O", command=self.open_file)
        m.add_separator()
        m.add_command(label="Zapisz", accelerator="Ctrl+S", command=self.save)
        m.add_command(label="Zapisz jako…", accelerator="Ctrl+Shift+S", command=self.save_as)
        m.add_command(label="Przywróć zapisaną wersję", command=self.revert)
        m.add_separator()
        m.add_command(label="Zamknij okno", accelerator="Ctrl+W", command=self.close)
        m.add_command(label="Zakończ", accelerator="Ctrl+Q", command=self.app.quit)
        menubar.add_cascade(label="Plik", menu=m)

        m = tk.Menu(menubar, tearoff=0)
        m.add_command(label="Cofnij", accelerator="Ctrl+Z", command=self.undo)
        m.add_command(label="Ponów", accelerator="Ctrl+Y", command=self.redo)
        m.add_separator()
        m.add_command(label="Wytnij", accelerator="Ctrl+X", command=self.cut)
        m.add_command(label="Kopiuj", accelerator="Ctrl+C", command=self.copy)
        m.add_command(label="Wklej", accelerator="Ctrl+V", command=self.paste)
        m.add_command(label="Zaznacz wszystko", accelerator="Ctrl+A", command=lambda: self.grid.select_all())
        m.add_separator()
        m.add_command(label="Znajdź…", accelerator="Ctrl+F", command=self.focus_search)
        m.add_separator()
        m.add_command(label="Wstaw wiersz powyżej", command=self.insert_row_above)
        m.add_command(label="Wstaw wiersz poniżej", command=self.insert_row_below)
        m.add_command(label="Dodaj wiersz na końcu", accelerator="Ctrl+Shift+Enter", command=self.append_row)
        m.add_command(label="Usuń zaznaczone wiersze", accelerator="Ctrl+-", command=self.delete_rows)
        m.add_separator()
        m.add_command(label="Wstaw kolumnę po lewej", command=self.insert_column_left)
        m.add_command(label="Wstaw kolumnę po prawej", command=self.insert_column_right)
        m.add_command(label="Usuń kolumnę", command=self.delete_column)
        m.add_command(label="Zmień nazwę kolumny…", command=self.rename_column)
        menubar.add_cascade(label="Edycja", menu=m)

        m = tk.Menu(menubar, tearoff=0)
        m.add_command(label="Tabela", accelerator="Ctrl+1", command=lambda: self.set_text_mode(False))
        m.add_command(label="Tekst", accelerator="Ctrl+2", command=lambda: self.set_text_mode(True))
        m.add_separator()
        m.add_command(label="Pierwszy wiersz jako nagłówek", accelerator="Ctrl+Shift+H", command=self.toggle_header_menu)
        m.add_command(label="Filtruj bieżącą kolumnę…", accelerator="Ctrl+Shift+L", command=self.filter_column)
        m.add_command(label="Wyczyść filtry", accelerator="Ctrl+Alt+F", command=self.clear_filters)
        menubar.add_cascade(label="Widok", menu=m)

        m = tk.Menu(menubar, tearoff=0)
        m.add_command(label=f"O programie {APP_NAME}", command=lambda: messagebox.showinfo(
            APP_NAME, f"{APP_NAME} {VERSION}\nLekki edytor plików CSV.", parent=self))
        menubar.add_cascade(label="Pomoc", menu=m)
        self.configure(menu=menubar)

        def bind(seq, fn, allow_in_text=False):
            def handler(e):
                if not allow_in_text and isinstance(e.widget, (tk.Entry, ttk.Entry, tk.Text)):
                    return None
                fn()
                return "break"
            self.bind(seq, handler)

        for seq, fn, anywhere in (
            ("<Control-n>", self.app.new_window, True), ("<Control-o>", self.open_file, True),
            ("<Control-s>", self.save, True), ("<Control-S>", self.save_as, True),
            ("<Control-Shift-s>", self.save_as, True), ("<Control-w>", self.close, True),
            ("<Control-q>", self.app.quit, True), ("<Control-z>", self.undo, False),
            ("<Control-y>", self.redo, False), ("<Control-Z>", self.redo, False),
            ("<Control-f>", self.focus_search, True), ("<Control-Key-1>", lambda: self.set_text_mode(False), True),
            ("<Control-Key-2>", lambda: self.set_text_mode(True), True),
            ("<Control-H>", self.toggle_header_menu, True), ("<Control-L>", self.filter_column, True),
            ("<Control-Alt-f>", self.clear_filters, True), ("<Control-minus>", self.delete_rows, False),
            ("<Control-Shift-Return>", self.append_row, False),
        ):
            bind(seq, fn, anywhere)

    # -- grid data provider -------------------------------------------------

    def grid_nrows(self):
        return len(self.visible)

    def grid_cell(self, v, c):
        if v < len(self.visible) and c < self.doc.width:
            r = self.visible[v]
            if r < len(self.doc.rows):
                return self.doc.rows[r][c]
        return ""

    def grid_row_label(self, v):
        return str(self.visible[v] + 1) if v < len(self.visible) else ""

    def grid_max_label(self):
        return self.visible[-1] + 1 if len(self.visible) else len(self.doc.rows)

    def header_name(self, c):
        d = self.doc
        return d.rows[0][c] if d.has_header and d.rows and c < len(d.rows[0]) else ""

    def grid_col_title(self, c):
        return self.header_name(c).replace("\n", " ") or column_letter(c)

    def grid_col_filtered(self, c):
        return c in self.filters

    def grid_selection_changed(self):
        # Reaching the right edge adds more empty columns, like an endless sheet.
        if self.grid.cursor[1] >= self.grid.ncols - 2 and self.grid.ncols < MAX_COLUMNS:
            self.extra_cols += 26
            self._grow_columns()
            self.grid.redraw()
        self._update_input_line()
        self._update_status()

    def grid_commit(self, v, c, text):
        if v < len(self.visible):
            self.doc.set_cells([(self.visible[v], c, text)], "Edycja komórki")

    def used_part(self, sel):
        """Selection limited to cells holding data (select-all spans a million empty rows)."""
        r0, r1, c0, c1 = sel
        r1 = min(r1, bisect.bisect_left(self.visible, len(self.doc.rows)) - 1)
        c1 = min(c1, self.doc.width - 1)
        return (r0, r1, c0, c1) if r1 >= r0 and c1 >= c0 else None

    def grid_clear(self, sel):
        sel = self.used_part(sel)
        if not sel:
            return
        r0, r1, c0, c1 = sel
        self.doc.set_cells([(self.visible[v], c, "") for v in range(r0, r1 + 1) if v < len(self.visible)
                            for c in range(c0, c1 + 1)], "Wyczyść zawartość")

    def grid_fill(self, source, target, vertical, forward, copy_only):
        r0, r1, c0, c1 = source
        t0, t1, u0, u1 = target
        changes = []
        if vertical:
            targets = list(range(t0, t1 + 1)) if forward else list(range(t1, t0 - 1, -1))
            for c in range(c0, c1 + 1):
                src = [self.grid_cell(v, c) for v in range(r0, r1 + 1)]
                if not forward:
                    src.reverse()
                for v, val in zip(targets, extend_series(src, len(targets), copy_only)):
                    changes.append((self.visible[v], c, val))
        else:
            targets = list(range(u0, u1 + 1)) if forward else list(range(u1, u0 - 1, -1))
            for v in range(r0, r1 + 1):
                src = [self.grid_cell(v, c) for c in range(c0, c1 + 1)]
                if not forward:
                    src.reverse()
                for c, val in zip(targets, extend_series(src, len(targets), copy_only)):
                    changes.append((self.visible[v], c, val))
        self.doc.set_cells(changes, "Wypełnij")

    def grid_header_click(self, c, x, y):
        FilterPopup(self, c, x, y)

    def grid_context_menu(self, e):
        try:
            self.context.tk_popup(e.x_root, e.y_root)
        finally:
            self.context.grab_release()

    def grid_autosize(self, c):
        fnt = self.grid.font
        w = self.grid.header_font.measure(self.grid_col_title(c)) + 34
        for v in range(min(len(self.visible), 500)):
            t = self.grid_cell(v, c)
            if t:
                w = max(w, fnt.measure(t[:120]) + 16)
        return min(max(w, 40), 600)

    # -- columns / filtering -------------------------------------------------

    def _display_columns(self):
        return min(max(self.doc.width + self.extra_cols, MIN_COLUMNS), max(MAX_COLUMNS, self.doc.width))

    def _grow_columns(self):
        """Adds (or drops) display columns while keeping existing widths."""
        n = self._display_columns()
        widths = self.grid.widths[:n]
        widths += [80] * (n - len(widths))
        self.grid.set_widths(widths)

    def _reset_columns(self):
        fnt, hfnt = self.grid.font, self.grid.header_font
        widths = [60] * self.doc.width
        for i, row in enumerate(self.doc.rows[:150]):
            header = i == 0 and self.doc.has_header
            for c, v in enumerate(row):
                if v:
                    w = (hfnt if header else fnt).measure(v[:80]) + (34 if header else 16)
                    if w > widths[c]:
                        widths[c] = w
        widths = [min(w, 360) for w in widths]
        self.grid.set_widths(widths + [80] * (self._display_columns() - len(widths)))

    def _passes(self, row, except_col=None):
        for c, allowed in self.filters.items():
            if c != except_col and c < len(row) and row[c] not in allowed:
                return False
        if self.search:
            q = self.search
            return any(q in v.casefold() for v in row)
        return True

    def recompute_visible(self):
        rows, start = self.doc.rows, self.doc.data_start
        if len(rows) <= start:
            self.visible = []
        elif not self.filters and not self.search:
            self.visible = range(start, max(MAX_ROWS, len(rows) + 1000))
        else:
            self.visible = [i for i in range(start, len(rows)) if self._passes(rows[i])]
        p = self.pending_row
        if p is not None and start <= p < len(rows):
            i = bisect.bisect_left(self.visible, p)
            if isinstance(self.visible, list) and (i == len(self.visible) or self.visible[i] != p):
                self.visible.insert(i, p)
        self.grid.clamp()
        self._update_status()

    def column_values(self, c):
        counts = {}
        if c >= self.doc.width:
            return [], counts
        rows = self.doc.rows
        for i in range(self.doc.data_start, len(rows)):
            if self._passes(rows[i], except_col=c):
                v = rows[i][c]
                counts[v] = counts.get(v, 0) + 1
        values = sorted((v for v in counts if v), key=sort_key)
        if "" in counts:
            values.append("")
        return values, counts

    def set_filter(self, c, allowed):
        if allowed is None:
            self.filters.pop(c, None)
        else:
            self.filters[c] = allowed
        self.recompute_visible()
        self._sync_controls()

    def clear_filters(self):
        self.filters.clear()
        self.search = ""
        self.search_var.set("")
        self.recompute_visible()
        self._sync_controls()

    def _schedule_search(self):
        if self._search_job:
            self.after_cancel(self._search_job)
        self._search_job = self.after(200, self._apply_search)

    def _apply_search(self):
        self._search_job = None
        q = self.search_var.get().casefold()
        if q != self.search:
            self.search = q
            self.recompute_visible()
            self._sync_controls()

    def focus_search(self):
        if self.text_mode:
            self.text.focus_set()
            return
        self.search_entry.focus_set()
        self.search_entry.select_range(0, "end")

    # -- document notifications ---------------------------------------------

    def _doc_changed(self, kind, cols_changed=False):
        if self.text_mode:
            if kind != "meta":
                self._load_text()
            self._sync_controls()
            return
        if kind == "cells":
            self.grid.redraw()
        elif kind == "structure":
            if cols_changed:
                self._grow_columns()
            self.recompute_visible()
            if self.pending_row is not None:
                i = bisect.bisect_left(self.visible, self.pending_row)
                if i < len(self.visible) and self.visible[i] == self.pending_row:
                    self.grid.select(i, self.grid.cursor[1])
            self.pending_row = None
        elif kind == "reloaded":
            self.filters.clear()
            self._reset_columns()
            self.recompute_visible()
        self._update_input_line()
        self._sync_controls()

    def _sync_controls(self):
        d = self.doc
        name = os.path.basename(d.path) if d.path else "Bez tytułu"
        self.title(f"{name}{' *' if d.dirty else ''} — {APP_NAME}")
        self.header_var.set(d.has_header)
        state = ["disabled"] if self.text_mode else ["!disabled"]
        self.header_check.state(state)
        self.search_entry.state(state)
        self.clear_button.state(["!disabled"] if not self.text_mode and (self.filters or self.search) else ["disabled"])
        self.mode_var.set("text" if self.text_mode else "table")
        names = [n for n, _ in DELIMITERS]
        delims = [dl for _, dl in DELIMITERS]
        if d.delimiter not in delims:
            names.append(f"Inny: {d.delimiter}")
            delims.append(d.delimiter)
        self._delims = delims
        self.delim_box.configure(values=names + ["Inny…"])
        self.delim_box.current(delims.index(d.delimiter))
        self._update_status()

    def _update_status(self):
        d = self.doc
        if self.text_mode:
            parts = ["Widok tekstowy — zmiany zostaną wczytane do tabeli po przełączeniu"]
        else:
            total = max(len(d.rows) - d.data_start, 0)
            filtered = bool(self.filters or self.search)
            parts = [f"Wiersze: {len(self.visible)} z {total} (filtr)" if filtered else f"Wiersze: {total}"]
            if self.grid.has_cells():
                r0, r1, c0, c1 = self.grid.selection()
                if (r1 - r0 + 1) * (c1 - c0 + 1) > 1:
                    info = f"Zaznaczono: {r1 - r0 + 1} × {c1 - c0 + 1}"
                    used = self.used_part((r0, r1, c0, c1))
                    if used and (used[1] - used[0] + 1) * (used[3] - used[2] + 1) <= 200000:
                        r0, r1, c0, c1 = used
                        nums = [number(self.grid_cell(v, c)) for v in range(r0, r1 + 1) for c in range(c0, c1 + 1)]
                        nums = [x for x in nums if x is not None]
                        if nums:
                            s = sum(nums)
                            info += f"   Suma: {s:,.4g}   Średnia: {s / len(nums):,.4g}".replace(",", " ")
                    parts.append(info)
        parts += [f"Kolumny: {d.width}", f"Separator: {delimiter_name(d.delimiter)}",
                  f"Kodowanie: {encoding_name(d.encoding)}"]
        self.status.configure(text="   ·   ".join(parts))

    def _ref(self, v, c):
        return f"{column_letter(c)}{self.visible[v] + 1}" if v < len(self.visible) else ""

    def _update_input_line(self, force=False):
        if not self.grid.has_cells():
            self.ref_label.configure(text="")
            self.input_var.set("")
            return
        r0, r1, c0, c1 = self.grid.selection()
        ref = self._ref(*self.grid.cursor) if (r0, c0) == (r1, c1) else f"{self._ref(r0, c0)}:{self._ref(r1, c1)}"
        self.ref_label.configure(text=ref)
        if force or self.focus_get() is not self.input_entry:
            self.input_var.set(self.grid_cell(*self.grid.cursor))

    def _input_commit(self, e=None):
        v, c = self.grid.cursor
        if v < len(self.visible):
            self.doc.set_cells([(self.visible[v], c, self.input_var.get())], "Edycja komórki")
        self.grid.body.focus_set()
        return "break"

    # -- toolbar ---------------------------------------------------------------

    def _delimiter_selected(self, e=None):
        i = self.delim_box.current()
        self.grid.commit_edit()
        self._commit_text()
        if i < len(self._delims):
            self.doc.change_delimiter(self._delims[i])
        else:
            value = ask_string(self, "Własny separator", "Wpisz jeden znak, np.  :  ~  #")
            if value and value[0] not in '"\r\n':
                self.doc.change_delimiter(value[0])
        self._sync_controls()

    def toggle_header(self):
        if not self.text_mode:
            self.doc.set_has_header(self.header_var.get())

    def toggle_header_menu(self):
        if not self.text_mode:
            self.doc.set_has_header(not self.doc.has_header)

    # -- table / text mode ---------------------------------------------------

    def set_text_mode(self, on):
        if on == self.text_mode:
            self._sync_controls()
            return
        if on:
            self.grid.commit_edit()
            self.text_mode = True
            self._load_text()
            self.grid.pack_forget()
            self.input_line.pack_forget()
            self.input_sep.pack_forget()
            self.text_frame.pack(fill="both", expand=True)
            self.text.focus_set()
        else:
            self._commit_text()
            self.text_mode = False
            self.text_frame.pack_forget()
            self.input_line.pack(fill="x", before=self.content)
            self.input_sep.pack(fill="x", before=self.content)
            self.grid.pack(fill="both", expand=True)
            self.filters.clear()
            self._reset_columns()
            self.recompute_visible()
            self.grid.body.focus_set()
        self._sync_controls()

    def _load_text(self):
        self.loaded_text = self.doc.text
        self.text.delete("1.0", "end")
        self.text.insert("1.0", self.loaded_text)
        self.text.edit_reset()
        self.text.edit_modified(False)

    def _current_text(self):
        return self.text.get("1.0", "end-1c")

    def _commit_text(self):
        if not self.text_mode:
            return
        t = self._current_text()
        if t != self.loaded_text:
            self.loaded_text = t
            self.doc.replace_text(t)

    def _text_modified(self, e=None):
        if self.text.edit_modified() and not self.doc.dirty and self._current_text() != self.loaded_text:
            self.doc.dirty = True
            self._sync_controls()

    # -- editing commands ----------------------------------------------------

    def undo(self):
        self.grid.commit_edit()
        self.doc.undo()

    def redo(self):
        self.grid.commit_edit()
        self.doc.redo()

    def _abs(self, v):
        return self.visible[v] if 0 <= v < len(self.visible) else None

    def _sel_rows(self):
        r0, r1, _, _ = self.grid.selection()
        return {self.visible[v] for v in range(r0, r1 + 1) if v < len(self.visible)}

    def insert_row_above(self):
        if self.text_mode:
            return
        r = self._abs(self.grid.selection()[0])
        r = self.doc.data_start if r is None else r
        self.pending_row = r
        self.doc.insert_row(r)

    def insert_row_below(self):
        if self.text_mode:
            return
        r = self._abs(self.grid.selection()[1])
        r = len(self.doc.rows) if r is None else r + 1
        self.pending_row = r
        self.doc.insert_row(r)

    def append_row(self):
        if not self.text_mode:
            self.pending_row = len(self.doc.rows)
            self.doc.insert_row(len(self.doc.rows))

    def delete_rows(self):
        if not self.text_mode and self.grid.has_cells():
            self.doc.delete_rows(self._sel_rows())

    def _columns_shifted(self):
        """Column indexes moved: filters and widths no longer line up."""
        self.filters.clear()
        self._reset_columns()
        self.recompute_visible()
        self._sync_controls()

    def insert_column_left(self):
        if not self.text_mode:
            self.doc.insert_column(self.grid.cursor[1] if self.grid.has_cells() else 0)
            self._columns_shifted()

    def insert_column_right(self):
        if not self.text_mode:
            self.doc.insert_column((self.grid.cursor[1] if self.grid.has_cells() else self.doc.width - 1) + 1)
            self._columns_shifted()

    def delete_column(self):
        if not self.text_mode and self.grid.has_cells() and self.grid.cursor[1] < self.doc.width:
            self.doc.delete_column(self.grid.cursor[1])
            self._columns_shifted()

    def _column_popup(self, focus_name=False):
        if self.text_mode or not self.grid.ncols:
            return
        c = self.grid.cursor[1]
        x = self.grid.header.winfo_rootx() + self.grid.xs[c] - self.grid.xoff
        y = self.grid.header.winfo_rooty() + self.grid.hh
        FilterPopup(self, c, max(x, self.winfo_rootx()), y, focus_name=focus_name)

    def rename_column(self):
        self._column_popup(focus_name=True)

    def filter_column(self):
        self._column_popup()

    def sort_column(self, ascending):
        if not self.text_mode and self.grid.ncols:
            self.doc.sort(self.grid.cursor[1], ascending)

    # -- clipboard -------------------------------------------------------------

    def copy(self):
        if self.text_mode or not self.grid.has_cells():
            return
        r, c = self.grid.cursor
        r0, r1, c0, c1 = self.used_part(self.grid.selection()) or (r, r, c, c)

        def q(f):
            return '"' + f.replace('"', '""') + '"' if any(ch in f for ch in '\t\n"') else f
        text = "\n".join("\t".join(q(self.grid_cell(v, c)) for c in range(c0, c1 + 1)) for v in range(r0, r1 + 1))
        self.clipboard_clear()
        self.clipboard_append(text)

    def cut(self):
        if self.text_mode or not self.grid.has_cells():
            return
        self.copy()
        self.grid_clear(self.grid.selection())

    def paste(self):
        if self.text_mode or not self.grid.has_cells():
            return
        try:
            text = self.clipboard_get()
        except tk.TclError:
            return
        clip = parse(text, "\t")
        if len(clip) > 1 and clip[-1] in ([], [""]):
            clip.pop()
        if not clip:
            return
        r0, r1, c0, c1 = self.grid.selection()
        changes = []
        single = len(clip) == 1 and len(clip[0]) == 1
        if single and (r0, c0) != (r1, c1):
            if (r1 - r0 + 1) * (c1 - c0 + 1) > 1_000_000:
                r0, r1, c0, c1 = self.used_part((r0, r1, c0, c1)) or (r0, r0, c0, c0)
            for v in range(r0, r1 + 1):
                for c in range(c0, c1 + 1):
                    changes.append((self.visible[v], c, clip[0][0]))
        else:
            extra = 0
            for i, line in enumerate(clip):
                r = self._abs(r0 + i)
                if r is None:
                    r = len(self.doc.rows) + extra
                    extra += 1
                for j, val in enumerate(line):
                    changes.append((r, c0 + j, val))
        self.doc.set_cells(changes, "Wklej")
        if not single:
            h, w = len(clip) - 1, max(len(line) for line in clip) - 1
            self.grid.select_range((r0, c0), (r0 + h, c0 + w))

    # -- files -----------------------------------------------------------------

    def is_blank(self):
        return self.doc.path is None and not self.doc.dirty

    def open_file(self):
        path = filedialog.askopenfilename(parent=self, title="Otwórz plik", filetypes=FILETYPES)
        if path:
            self.app.open_path(path, reuse=self if self.is_blank() else None)

    def load_into(self, path):
        self.doc.load(path)
        self.filters.clear()
        self.search_var.set("")
        self.search = ""
        self.text_mode = True
        self.set_text_mode(False)
        self._reset_columns()
        self.recompute_visible()
        self.grid.select(0, 0)
        self._sync_controls()

    def _prepare_save(self):
        self.grid.commit_edit()
        self._commit_text()

    def save(self):
        self._prepare_save()
        if not self.doc.path:
            return self.save_as()
        return self._write(self.doc.path)

    def save_as(self):
        self._prepare_save()
        d = self.doc
        initial = os.path.basename(d.path) if d.path else "Bez tytułu.csv"
        path = filedialog.asksaveasfilename(parent=self, title="Zapisz jako", initialfile=initial,
                                            initialdir=os.path.dirname(d.path) if d.path else None,
                                            defaultextension=".csv", filetypes=FILETYPES)
        if not path:
            return False
        delim = "\t" if path.lower().endswith((".tsv", ".tab")) and d.delimiter in ",;" else d.delimiter
        opts = SaveOptionsDialog(self, delim, d.encoding).result
        if not opts:
            return False
        if opts[0] != d.delimiter:
            d.raw_text = None
        d.delimiter, d.encoding = opts
        return self._write(path)

    def _write(self, path):
        try:
            self.doc.save(path)
        except UnicodeEncodeError:
            messagebox.showerror(APP_NAME, f"Nie można zapisać pliku w kodowaniu {encoding_name(self.doc.encoding)}.\n"
                                 "Plik zawiera znaki spoza tego kodowania. Użyj „Zapisz jako…” i wybierz UTF-8.",
                                 parent=self)
            return False
        except OSError as exc:
            messagebox.showerror(APP_NAME, f"Nie można zapisać pliku:\n{exc}", parent=self)
            return False
        if self.text_mode:
            self.loaded_text = self._current_text()
        self._sync_controls()
        return True

    def revert(self):
        if not self.doc.path:
            return
        if self.doc.dirty and not messagebox.askyesno(APP_NAME, "Odrzucić zmiany i wczytać plik ponownie?", parent=self):
            return
        try:
            self.load_into(self.doc.path)
        except OSError as exc:
            messagebox.showerror(APP_NAME, f"Nie można otworzyć pliku:\n{exc}", parent=self)

    def close(self):
        self._prepare_save()
        if self.doc.dirty:
            name = os.path.basename(self.doc.path) if self.doc.path else "Bez tytułu"
            answer = messagebox.askyesnocancel(APP_NAME, f"Zapisać zmiany w pliku „{name}”?", parent=self)
            if answer is None or (answer and not self.save()):
                return False
        self.app.window_closed(self)
        self.destroy()
        return True


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

class App:
    def __init__(self, paths):
        self.root = tk.Tk(className="csvreader")
        self.root.withdraw()
        self._setup_style()
        self.windows = []
        for p in paths:
            self.open_path(p)
        if not self.windows:
            self.new_window()

    def _setup_style(self):
        style = ttk.Style(self.root)
        if "clam" in style.theme_names() and sys.platform.startswith("linux"):
            style.theme_use("clam")
        base = tkfont.nametofont("TkDefaultFont")
        if sys.platform.startswith("linux") and 0 < base.cget("size") < 10:
            for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont", "TkHeadingFont"):
                try:
                    tkfont.nametofont(name).configure(size=10)
                except tk.TclError:
                    pass
        icon = os.path.join(os.path.dirname(os.path.abspath(__file__)), "csvreader.png")
        if os.path.exists(icon):
            try:
                self.icon = tk.PhotoImage(file=icon)
                self.root.iconphoto(True, self.icon)
            except tk.TclError:
                pass

    def new_window(self, path=None):
        w = Window(self, path)
        self.windows.append(w)
        return w

    def open_path(self, path, reuse=None):
        path = os.path.abspath(path)
        for w in self.windows:
            if w.doc.path == path:
                w.lift()
                w.focus_force()
                return w
        if reuse is not None:
            try:
                reuse.load_into(path)
            except OSError as exc:
                messagebox.showerror(APP_NAME, f"Nie można otworzyć pliku:\n{exc}", parent=reuse)
            return reuse
        if not os.path.exists(path):
            messagebox.showerror(APP_NAME, f"Plik nie istnieje:\n{path}")
            return None
        return self.new_window(path)

    def window_closed(self, w):
        if w in self.windows:
            self.windows.remove(w)
        if not self.windows:
            self.root.after_idle(self.root.destroy)

    def quit(self):
        for w in list(self.windows):
            if not w.close():
                return

    def run(self):
        self.root.mainloop()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if "--version" in sys.argv:
        print(f"{APP_NAME} {VERSION}")
        return
    App(args).run()


if __name__ == "__main__":
    main()
