"""Render the setup.sh picker to an SVG for the README.

usage: screenshot.py <workdir> <rows> <cols> <args> <keys> <out.svg>
  keys: DOWN UP SPACE ENTER, or w:<secs> to wait for output
Runs setup.sh in a real pty, sends the keys, renders the screen with pyte,
then quits the picker with q. Use a throwaway copy, a demo prefix and
--dry-run, so nothing personal is on screen and nothing is written:

  env -i PATH=/usr/bin:/bin HOME="$T" STACK_PREFIX=demo- \\
    COMPOSE_PROJECT_NAME=demo DOCKER_NETWORK=demo \\
    venv/bin/python -I tests/screenshot.py "$T" 34 104 --dry-run \\
    "DOWN DOWN DOWN DOWN DOWN DOWN DOWN DOWN DOWN DOWN" assets/picker.svg

Colours are mapped onto the project palette: charcoal, off-white, greys,
crimson. Needs pyte (pip install pyte==0.8.2).
"""
import fcntl, html, os, pty, select, struct, sys, termios, time
import pyte

workdir, rows, cols, args, keys, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
KEYS = {"UP": "\x1b[A", "DOWN": "\x1b[B", "SPACE": " ", "ENTER": "\r"}

screen = pyte.Screen(cols, rows)
stream = pyte.ByteStream(screen)
pid, fd = pty.fork()
if pid == 0:
    os.chdir(workdir)
    env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8")
    os.execvpe("bash", ["bash", "-c", "./setup.sh " + args], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def pump(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            # pyte drops SGR 2 (dim); make it an explicit grey so it survives
            stream.feed(data.replace(b"\x1b[2m", b"\x1b[38;2;140;138;133m"))

pump(2.5)
for tok in keys.split():
    if tok.startswith("w:"):
        pump(float(tok[2:]))
        continue
    os.write(fd, KEYS.get(tok, tok).encode())
    pump(0.25)
pump(0.5)

BG, FG, DIM = "#141414", "#e4e1da", "#8c8a85"
PAL = {"default": FG, "white": FG, "cyan": FG, "green": "#9db58f", "brown": "#c9a45c",
       "yellow": "#c9a45c", "red": "#c8323c", "magenta": "#c8323c", "blue": "#8fa3b5",
       "brightblack": "#6a6a6a",
       "d7005f": "#c8323c", "c8323c": "#c8323c", "af8787": "#b26e72", "b26e72": "#b26e72"}
CW, LH, FS, PAD = 8.4, 18, 14, 22

def colour(ch):
    c = ch.fg
    return PAL.get(c, "#" + c if len(c) == 6 else FG)

def text_of(y):
    return "".join(screen.buffer[y][x].data for x in range(cols))

nrows = max((y for y in range(rows) if text_of(y).strip()), default=0) + 1
W, H = int(cols * CW + 2 * PAD), int(nrows * LH + 2 * PAD)
o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
     f'font-family="\'JetBrains Mono\', ui-monospace, \'SF Mono\', Menlo, Consolas, monospace" font-size="{FS}">',
     f'<rect width="{W}" height="{H}" rx="8" fill="{BG}"/>']
for y in range(nrows):
    line, x = screen.buffer[y], 0
    while x < cols:
        key = (colour(line[x]), line[x].bold, line[x].reverse)
        start, text = x, ""
        while x < cols and (colour(line[x]), line[x].bold, line[x].reverse) == key:
            text += line[x].data or " "
            x += 1
        fill, bold, rev = key
        px, py = PAD + start * CW, PAD + y * LH
        if rev:
            o.append(f'<rect x="{px:.1f}" y="{py:.1f}" width="{len(text) * CW:.1f}" height="{LH}" fill="{fill}"/>')
            fill = BG
        if text.strip():
            lead, t = len(text) - len(text.lstrip()), text.strip()
            weight = ' font-weight="700"' if bold else ""
            o.append(f'<text x="{px + lead * CW:.1f}" y="{py + LH * 0.75:.1f}" fill="{fill}"{weight} '
                     f'textLength="{len(t) * CW:.1f}" lengthAdjust="spacingAndGlyphs" xml:space="preserve">{html.escape(t)}</text>')
o.append("</svg>")
with open(out, "w") as f:
    f.write("\n".join(o) + "\n")

os.write(fd, b"q")
pump(1)
_, status = os.waitpid(pid, 0)
print("EXIT=%d" % os.waitstatus_to_exitcode(status))
