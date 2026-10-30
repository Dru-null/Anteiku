"""Drive setup.sh through a real pty and render the screen with pyte.

usage: tui_drive.py <workdir> <rows> <cols> <args> <steps-json>
  steps: list of ["key", "<keys>"] | ["type", "text"] | ["wait", secs]
         | ["snap", "label"] | ["resize", "ROWSxCOLS"]
  key tokens: UP DOWN PGUP PGDN HOME END SPACE ENTER CTRLC, or literal characters
Prints each snapshot as plain text. setup.sh's exit code shows as EXIT=<n>.
Needs pyte (pip install pyte); scripts/check.sh --tui sets that up.
"""
import fcntl, json, os, pty, select, struct, sys, termios, time
import pyte

workdir, rows, cols, args, steps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], json.loads(sys.argv[5])

KEYS = {"UP": "\x1b[A", "DOWN": "\x1b[B", "PGDN": "\x1b[6~", "PGUP": "\x1b[5~",
        "HOME": "\x1b[H", "END": "\x1b[F", "SPACE": " ", "ENTER": "\r", "CTRLC": "\x03"}

screen = pyte.Screen(cols, rows)
stream = pyte.ByteStream(screen)
raw = bytearray()

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workdir)
    env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8")
    os.execvpe("bash", ["bash", "-c", "./setup.sh " + args + "; rc=$?; echo; echo EXIT=$rc; sleep 0.3"], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def pump(t=0.4):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            raw.extend(data)
            stream.feed(data)
    return True

def snap(label):
    print("=" * 12, label, "=" * 12)
    for line in screen.display:
        print(line.rstrip())

pump(2.5)
for kind, val in steps:
    if kind == "key":
        for tok in val.split():
            os.write(fd, KEYS.get(tok, tok).encode())
            pump(0.25)
    elif kind == "type":
        os.write(fd, val.encode()); pump(0.3)
    elif kind == "wait":
        pump(float(val))
    elif kind == "snap":
        pump(0.3); snap(val)
    elif kind == "resize":
        r, c = map(int, val.split("x"))
        screen.resize(r, c)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", r, c, 0, 0))
        os.kill(pid, 28)  # SIGWINCH to the bash -c wrapper's group
        pump(0.5)
pump(3)
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
open(os.environ.get("RAW_OUT", "/dev/null"), "wb").write(bytes(raw))
