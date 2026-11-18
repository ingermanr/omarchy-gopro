# Review notes: process ownership

Notes kept with the code so the reasoning outlives the patch. Written after the third
review round on omacom/omarchy-plugin-marketplace#15102 reported that `start` and `stop`
could kill an unrelated FFmpeg session.

## The finding

`stop_stream()` located the stream by searching the process table: `pgrep -f "udp://@:8554"`
filtered down to processes whose executable is `ffmpeg`. Any other ffmpeg reading the same
UDP pattern — a recording, a second viewer, a command someone ran by hand — was treated as
this plugin's stream and received `SIGTERM`, followed by `SIGKILL` a few seconds later.

Reproduced before the fix: with the previous script loaded and a foreign ffmpeg holding a
matching command line, `stop_stream()` killed that process.

## The ownership model now

`start` records the PID of the ffmpeg it launches in `$XDG_RUNTIME_DIR/gopro-webcam.ffmpeg`
and the plugin only ever signals that PID. Identity is re-checked immediately before any
signal, because the kernel recycles PIDs:

1. the PID refers to a live process;
2. its executable is `ffmpeg`;
3. its command line still carries this plugin's loopback device and UDP port.

If any check fails the answer is "not my stream" and nothing is signalled. `stop_stream()`
removes the PID file after stopping and never removes, rewrites or follows anything it did
not create.

## Why the construction review missed it

The fix alone would only move the next bug, so the causes are written down.

**1. The trust boundary was drawn around inputs, not around the process table.**
Both earlier findings were about untrusted *data*: file names chosen by the camera, packets
arriving on UDP 8554. Both are attacker-controlled input and both got validation. The process
table was treated as our own namespace. It is not: it is global, shared state that any local
process can enter, and `kill` is a destructive operation on it. Nothing in the review asked
"who owns this PID?" because the question was never framed.

**2. The earlier fix narrowed a predicate instead of re-deriving ownership.**
`cf0ae0f` answered a real observation: `pgrep -f` matched editors, greps and shell wrappers
that merely mentioned the pattern. The fix added an executable filter. That removed the false
positives we could see and left the underlying inference untouched: *if a process matches the
pattern, it is mine.* A symptom-driven patch feels finished because the reported symptom
disappears, and it hides the real question behind a patch that makes the neighbouring case
correct.

**3. The names encoded the assumption.**
`webcam_pids()` and `webcam_running()` read as statements about ownership. A function called
`pid_of_stream_we_started()` would have exposed the gap on the first read. Names are
documentation, and a wrong name is documentation that lies.

**4. Verification was behavioral, on the happy path, with a single stream.**
The stream was verified on real hardware: start, lens, resolution, stop. That validates the
functional contract and cannot observe interference from a second matching process, because
the test never created one. Negative tests need a hostile setup, not a working one.

**5. There was no rule for destructive operations.**
The review covered input validation and privilege, not "what can this command destroy, and is
the target provably mine?". Every `kill`, `rm`, `mv` and overwrite now needs an answer to that
question before the code counts as reviewed.

## Rules adopted

- Destructive operations target a handle this process created — a PID we spawned, a file we
  opened — never something rediscovered by searching. Verify identity immediately before use.
- A recorded identifier is untrusted when it is reused: PIDs, temporary names and paths are
  re-checked, not trusted because we wrote them earlier.
- Fix the model, not the symptom: when a predicate produces false positives, ask what it was
  trying to prove instead of tightening its pattern.
- Every fix ships with the test that fails on the old code.
- Review each destructive operation by asking, out loud, what it can destroy.

## Running the test

```bash
./test/process-ownership.sh
```

It loads the plugin's shell functions without running the CLI dispatch, redirects their paths
to a temporary directory, and uses real ffmpeg processes as stand-ins for "our stream", "a
foreign ffmpeg that matches the old pattern", and "a recycled PID". Seven assertions; exits 77
when ffmpeg is not installed.
