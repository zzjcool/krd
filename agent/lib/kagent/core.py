"""Where the agent's commands actually run, and what they leave behind.

Two targets matter and they are not interchangeable:

  vm    the headless tart guest — pixels, input and Accessibility all work there, and nothing the
        agent does can disturb the person using this Mac. **This is the default.**
  host  the machine in front of the user — useful for `krd ax` reads and for building, never for
        `see`: the screen is usually locked, so a capture returns the lock screen, and a click would
        land in whatever the user left open.

Both targets are addressed with the same verbs, so a scenario written against the VM can be pointed
at a real Mac by changing one flag.
"""

import hashlib
import json
import os
import shlex
import subprocess
import sys
import tarfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
DRIVER_DIR = REPO / "agent" / "driver"

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_REFUSED = 3
EXIT_ENVIRONMENT = 4
EXIT_UNKNOWN = 5


class KagentError(Exception):
    def __init__(self, message, code=EXIT_FAIL):
        super().__init__(message)
        self.code = code


class Result:
    def __init__(self, rc, out, err, argv):
        self.rc = rc
        self.out = out
        self.err = err
        self.argv = argv

    @property
    def text(self):
        return self.out.decode("utf-8", "replace")

    @property
    def error_text(self):
        return self.err.decode("utf-8", "replace")

    def json(self):
        try:
            return json.loads(self.out)
        except ValueError:
            raise KagentError(
                "expected JSON from %s, got:\n%s\n%s"
                % (" ".join(shlex.quote(a) for a in self.argv), self.text[:2000], self.error_text[:2000]),
                EXIT_ENVIRONMENT,
            )

    def raise_on_error(self, what=""):
        if self.rc != 0:
            raise KagentError(
                (what + ": " if what else "") + "exit %d\n%s%s" % (self.rc, self.text, self.error_text),
                self.rc if self.rc in (2, 3, 4) else EXIT_FAIL,
            )
        return self


class Target:
    def __init__(self, name="vm"):
        self.name = name if name in ("vm", "host") else "vm"
        self.host = os.environ.get("KAGENT_VM", "krd-vm")
        self.ssh_options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "LogLevel=ERROR"]
        self._home = None

    # -- transport ---------------------------------------------------------

    @property
    def remote(self):
        return self.name == "vm"

    def _ssh(self, command):
        return ["ssh"] + self.ssh_options + [self.host, command]

    def run(self, argv, timeout=90, stdin=None, env=None, cwd=None):
        if self.remote:
            full = self._ssh(" ".join(shlex.quote(a) for a in argv))
            cwd = None
        else:
            full = list(argv)
        try:
            proc = subprocess.run(full, input=stdin, timeout=timeout, env=env, cwd=cwd,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except subprocess.TimeoutExpired:
            raise KagentError("%s timed out after %ss: %s"
                              % (self.name, timeout, " ".join(shlex.quote(a) for a in argv)),
                              EXIT_ENVIRONMENT)
        except FileNotFoundError as error:
            raise KagentError("cannot run %s" % error, EXIT_ENVIRONMENT)
        return Result(proc.returncode, proc.stdout, proc.stderr, argv)

    def run_sh(self, script, timeout=120, stdin=None):
        """A shell one-liner on the target. Only for things with no argv form (pipes, `&&`)."""
        if self.remote:
            full = self._ssh(script)
        else:
            full = ["/bin/sh", "-c", script]
        proc = subprocess.run(full, input=stdin, timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return Result(proc.returncode, proc.stdout, proc.stderr, [script])

    def put(self, data, remote_path):
        if self.remote:
            res = self.run_sh("mkdir -p \"$(dirname %s)\" && cat > %s"
                              % (shlex.quote(remote_path), shlex.quote(remote_path)), stdin=data)
            res.raise_on_error("write %s" % remote_path)
        else:
            Path(remote_path).parent.mkdir(parents=True, exist_ok=True)
            Path(remote_path).write_bytes(data)

    def get(self, remote_path):
        if self.remote:
            res = self.run(["cat", remote_path], timeout=180)
            res.raise_on_error("read %s" % remote_path)
            return res.out
        return Path(remote_path).read_bytes()

    def exists(self, path):
        return self.run(["test", "-e", path], timeout=30).rc == 0

    @property
    def home(self):
        """The target's home directory, asked once.

        Every argv goes through `shlex.quote`, which is right — and which is also why a literal
        `~/bin/krd` never expanded and every command on the VM answered "no such file". The fix is
        to never send a tilde: resolve it once, then quote the absolute path like any other.
        """
        if self._home is None:
            result = self.run_sh('printf %s "$HOME"', timeout=20)
            self._home = result.text.strip() or os.path.expanduser("~")
        return self._home

    def expand(self, path):
        if path.startswith("~/"):
            return self.home + path[1:]
        if path == "~":
            return self.home
        return path

    # -- tools on the target ----------------------------------------------

    @property
    def krd(self):
        return self.expand(os.environ.get("KAGENT_KRD") or
                           ("~/bin/krd" if self.remote else self._local_krd()))

    @staticmethod
    def _local_krd():
        candidate = REPO / ".build" / "release" / "krd"
        return str(candidate) if candidate.exists() else "krd"

    @property
    def driver(self):
        return self.expand(os.environ.get("KAGENT_DRIVER") or "~/.kagent/bin/kagent-driver")

    def driver_source_hash(self):
        digest = hashlib.sha256()
        for path in sorted(DRIVER_DIR.glob("*.swift")):
            digest.update(path.name.encode())
            digest.update(path.read_bytes())
        return digest.hexdigest()[:16]

    def ensure_driver(self, rebuild=False):
        """Build the driver on the target once per source revision.

        The build is a 10-second `swiftc` call, so it is cached by source hash: a stale binary that
        silently lacks a verb is a much worse failure than a rebuild.
        """
        want = self.driver_source_hash()
        marker = self.home + "/.kagent/driver.sha"
        have = self.run(["cat", marker], timeout=30)
        if not rebuild and have.rc == 0 and have.text.strip() == want:
            return

        archive = _driver_archive()
        if self.remote:
            script = (
                "set -e; rm -rf ~/.kagent/src; mkdir -p ~/.kagent/src ~/.kagent/bin; "
                "tar xzf - -C ~/.kagent/src; "
                "cd ~/.kagent/src/agent/driver && swiftc -O *.swift -o ~/.kagent/bin/kagent-driver.new; "
                "codesign --force --sign - --identifier com.kkrt.kagent-driver "
                "~/.kagent/bin/kagent-driver.new 2>/dev/null; "
                "mv ~/.kagent/bin/kagent-driver.new ~/.kagent/bin/kagent-driver; "
                "echo %s > ~/.kagent/driver.sha" % want
            )
            res = self.run_sh(script, stdin=archive, timeout=600)
        else:
            dest = Path(os.path.expanduser("~/.kagent"))
            (dest / "src").mkdir(parents=True, exist_ok=True)
            with tarfile.open(fileobj=_bytes_io(archive)) as tar:
                tar.extractall(dest / "src", filter="data")
            out = dest / "bin" / "kagent-driver"
            out.parent.mkdir(parents=True, exist_ok=True)
            res = subprocess.run(["swiftc", "-O"] + [str(p) for p in sorted(DRIVER_DIR.glob("*.swift"))]
                                 + ["-o", str(out)], capture_output=True)
            subprocess.run(["codesign", "--force", "--sign", "-",
                            "--identifier", "com.kkrt.kagent-driver", str(out)], capture_output=True)
            res = Result(res.returncode, res.stdout, res.stderr, ["swiftc"])
            if res.rc != 0:
                raise KagentError("cannot build the driver locally:\n" + res.error_text, EXIT_ENVIRONMENT)
            (dest / "driver.sha").write_text(want + "\n")
            return
        if res.rc != 0:
            raise KagentError("cannot build the driver on %s:\n%s%s"
                              % (self.name, res.text, res.error_text), EXIT_ENVIRONMENT)


def _bytes_io(data):
    import io
    return io.BytesIO(data)


def _driver_archive():
    import io
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for path in sorted(DRIVER_DIR.glob("*.swift")):
            tar.add(str(path), arcname="agent/driver/" + path.name)
    return buf.getvalue()


class Artifacts:
    """One directory per run: frames, transcripts and the report, all referenced by path.

    The rule borrowed from the harnesses that work: images live on disk and the log carries the
    path, never the bytes. A transcript with inline base64 is unusable a day later.
    """

    def __init__(self, name=None):
        if name is None:
            name = os.environ.get("KAGENT_RUN") or "latest"
        self.name = name
        self.dir = REPO / "artifacts" / name
        self.dir.mkdir(parents=True, exist_ok=True)
        self.transcript = self.dir / "transcript.jsonl"
        self.counter = 0

    def path(self, kind, ext, label=None):
        self.counter += 1
        stamp = time.strftime("%H%M%S")
        stem = label or "%s-%03d" % (stamp, self.counter)
        target = self.dir / ("%s-%s.%s" % (kind, stem, ext)) if label is None else self.dir / label
        if target.suffix != "." + ext:
            target = target.with_suffix("." + ext)
        return target

    def record(self, entry):
        entry = dict(entry)
        entry.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        with self.transcript.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")

    def clear(self):
        for path in self.dir.glob("*"):
            if path.is_file():
                path.unlink()
        self.counter = 0


def jprint(value):
    sys.stdout.write(json.dumps(value, indent=2, sort_keys=True) + "\n")
