# Quic installation guidelines (Kali Linux)

Build notes for mvfst commit `881f296d6` plus the uncommitted manifest edits, on Kali Rolling 2026.2, GCC 15.3.0, CMake 4.3.4, Python 3.13.12.

## 1. Status

The build succeeded and compiled this local checkout, not the upstream clone. Verified on 2026-11-01.

| Check | Result |
| --- | --- |
| Correct source | `CMakeCache.txt` shows `CMAKE_HOME_DIRECTORY=/home/dev/Desktop/mvfst` |
| Real exit status | getdeps exited `0`, read from the log rather than the background task status, which came from a trailing `echo` |
| Compile output | All 434 steps ran in 7m27s with 5 jobs, with no `error:` or `FAILED:` lines, only 88 warnings |
| Install output | `_build/mvfst` has `.built-by-getdeps`, `include/` and `lib/`, including `libmvfst.a` |
| mvfst C++ changes needed | None. All changes are in the build tooling under `build/fbcode_builder` |
| End-to-end QUIC | Handshake completed over `::1:6666` and the client logged `Client received data=echo hello mvfst` |
| Test suite | `ctest -j8 --timeout 300 --output-on-failure` passed 2113 of 2113 tests, with 0 failures |

Limits of this verification:

- Only mvfst was compiled in the verified run. Its dependencies were reused from `_build`, so a from-scratch build was not tested and its duration is unknown.
- 4 of the 2117 registered tests did not run because they are marked `DISABLED_` in the source. They are the two `RejectsDraft02Frame...` tests in each of `QuicClientTransportLiteTest` and `ServerStateMachineTest`.
- The `ctest` count is lower than the 2542 individual cases the test binaries list, because `ctest` groups parameterised tests into one entry.

## 2. Build commands

### One-time setup

Install the system packages (needs sudo). This list reflects what was present for the verified build; it was not tested on a clean machine.

```bash
sudo apt-get install g++ cmake ninja-build make pkg-config libssl-dev openssl \
    libevent-dev libdouble-conversion-dev libgoogle-glog-dev libgflags-dev \
    libiberty-dev liblz4-dev liblzma-dev libsnappy-dev zlib1g-dev binutils-dev \
    libjemalloc-dev libsodium-dev libunwind-dev libaio-dev
```

Keep these uncommitted edits in the working tree:

- `getdeps_platform.py`: `"kali"` added to the deb-based distro list.
- `manifests/boost` and `manifests/boost-python`: `--with-python` commented out.

If mvfst was ever built here without `--current-project mvfst`, move the old build directory aside once, because its `CMakeCache.txt` points at the upstream clone. This has already been done on this machine.

```bash
S=$(ls -d ~/mvfst-tmp/fbcode_builder_getdeps-*)
mv "$S/build/mvfst" "$S/build/mvfst.stale-upstream-clone"
```

### Build mvfst

Always use the same `TMPDIR` and flags, so finished dependencies are reused instead of rebuilt.

- `--allow-system-packages` lets existing Kali packages stand in for dependencies mvfst would otherwise build itself.
- `--current-project mvfst` is the key fix, because without it getdeps builds its own clone of upstream (see blocker 1).

```bash
cd /home/dev/Desktop/mvfst
mkdir -p "$HOME/mvfst-tmp"
export TMPDIR="$HOME/mvfst-tmp"

./build/fbcode_builder/getdeps.py \
    --allow-system-packages \
    build mvfst \
    --current-project mvfst \
    --num-jobs 5 \
    --install-prefix="$PWD/_build"
```

Lower `--num-jobs` if the machine runs out of memory. Every `getdeps.py` command needs the same flags, and zsh does not split a flag list stored in a plain variable, so write them out in full.

### Find the build directory

Run this from the repository root, with `TMPDIR` still exported.

```bash
BUILD_DIR=$(./build/fbcode_builder/getdeps.py --allow-system-packages \
    show-build-dir mvfst --current-project mvfst \
    --install-prefix="$PWD/_build" 2>/dev/null | tail -1)
```

### Run the tests

```bash
cd "$BUILD_DIR"
ctest -j8 --timeout 300 --output-on-failure
```

### Build the echo sample

Repeat this after every `getdeps.py build`, which drops the setting (see blocker 3). The binary stays in the build directory and is not installed to `_build`.

```bash
cd "$BUILD_DIR"
cmake -DBUILD_SAMPLES=ON .
ninja -j5 echo
```

### Run the echo sample

The port defaults to 6666 and the host to `::1`. Add `--logtostderr=1` to both commands, because the client prints nothing to the terminal without it.

```bash
# Terminal 1
"$BUILD_DIR/quic/samples/echo" --mode=server --logtostderr=1

# Terminal 2: type a message and press Enter
"$BUILD_DIR/quic/samples/echo" --mode=client --logtostderr=1
```

Success looks like `Client received data=echo <your message> on stream=0`. Stop both programs with Ctrl+C (see blocker 4).

## 3. Blockers and fixes

Each blocker is labelled by how it is known:

- **Observed:** reproduced or measured directly during the 2026-11-01 build.
- **Inferred:** worked out from earlier edits and `patch_for_installation.sh`. The original error output was not available, so the stated cause may not be exact.

### Blockers observed in the 2026-11-01 build

#### 1. getdeps compiled a clone instead of this checkout (Observed, the main blocker)

- **Symptom:** the earlier build log stopped at `cmake --build` with no result, and `_build/mvfst` did not exist. The run was cut off rather than failing on a compiler error.
- **Cause:** without `--current-project mvfst`, `getdeps.py build mvfst` clones mvfst from GitHub and compiles that clone. It used upstream `1c7dfc8c` (Oct 29), not this checkout at `881f296d` (Aug 23). folly and fizz stayed pinned to Aug 22, so the build also mixed a newer mvfst with older dependencies. No error warns about this.
- **Fix:** added `--current-project mvfst`, as `getdeps.sh` already does. `show-source-dir` then reported `/home/dev/Desktop/mvfst`, and dependency hashes did not change, so nothing else was rebuilt.
- **How to check:** `grep CMAKE_HOME_DIRECTORY "$BUILD_DIR/CMakeCache.txt"` must show this checkout.

#### 2. Stale build directory still pointed at the clone (Observed, prevented)

- **Risk:** `build/mvfst` kept a `CMakeCache.txt` for the clone's source path, which could cause a CMake source mismatch or a rebuild of the wrong source.
- **Fix:** moved it to `build/mvfst.stale-upstream-clone` in the scratch directory, so the build started clean. This was done before building, so the failure itself was never seen.
- **Clean-up:** that directory is 3.2 GB and nothing uses it, so it can be deleted.

#### 3. Options that look right but cause damage (Observed)

| Option | What goes wrong | Use instead |
| --- | --- | --- |
| `--clean` | Deletes the shared `build`, `installed`, `extracted` and `shipit` scratch directories, which removes every dependency build. Found by reading `clean_dirs` in `cli.py`; not run | Remove only the mvfst build directory |
| `--extra-cmake-defines '{"BUILD_SAMPLES":"ON"}'` | Changes every dependency hash except folly and fizz, forcing a rebuild of boost, zstd, fmt and others | `cmake -DBUILD_SAMPLES=ON .` in the build directory |
| `BUILD_SAMPLES` set once | Each `getdeps.py build` regenerates `CMakeCache.txt` and removes the setting, and the `echo` target disappears | Repeat the sample step after each build |

#### 4. The echo client never exits by itself (Observed)

- **Symptom:** the client ran until a `timeout` killed it (exit code `124`), even though the message had already been echoed. It looks like a hang. Without `--logtostderr=1` it also prints nothing.
- **Cause:** `EchoClient::start` blocks at `quic/samples/echo/EchoClient.h:245` until a connection error occurs. Sending `/close` closes the connection, but `onConnectionEnd` only logs, so the wait never ends. This was tested: the client still timed out after `/close`.
- **Fix:** none needed for the build. Confirm success from the `Client received data=` line and stop with Ctrl+C. The stack trace printed on a kill signal is folly's signal handler, not a crash.

#### 5. `libaio` download URL is dead (Observed, still open)

- **Symptom:** both URLs return HTTP 404: the original `pagure.io/libaio/archive/...` one and the replacement `releases.pagure.org/libaio/libaio-0.3.113.tar.gz` now in the manifests. The response is an HTML "Not Found" page, and the directory index lists no libaio tarball.
- **Effect:** none on this build. `libaio-dev` is installed and `--allow-system-packages` uses it, so nothing is downloaded.
- **Fix:** keep `libaio-dev` installed. The manifest edit no longer helps, and the sha256 in it could not be re-verified.

### Blockers inferred from earlier work

#### 6. Kali was not recognised as a deb-based distro (Inferred)

- **Cause:** the package-manager check in `getdeps_platform.py` matched only debian, ubuntu, pop!_os and mint, so getdeps could not map dependencies to apt packages on Kali.
- **Fix:** added `"kali"` to that list. getdeps reports the distro as `kali_gnu/`, which the prefix match accepts.

#### 7. Boost failed to build its Python module (Inferred)

- **Likely cause:** Boost.Python 1.83 does not build against this Python/numpy combination. This is unconfirmed, since the original error was not kept.
- **Fix:** commented out `--with-python` in `manifests/boost` and `manifests/boost-python`. The verified boost log contains no `--with-python`, `_build/boost-*/lib` contains no Python library, and mvfst builds and passes its tests without it.
- **No longer needed:** the `~/boost183-venv` environment and `pip install "numpy<2"` were for this module.
- **Do not replace with apt:** boost is built from source on purpose. The manifest explains that the Ubuntu packages lack `-fPIC`, so `libboost-all-dev` is neither installed nor required.

#### 8. Build scratch location (Inferred)

- **Fix:** `TMPDIR=$HOME/mvfst-tmp` moves the getdeps scratch directory out of `/tmp`. It holds about 6.5 GB of dependencies and related files, plus 11 GB for mvfst. `/tmp` is on the root disk on this machine, so the original reason is unclear, but the variable must stay set because it decides where the build directories are found.

#### 9. Earlier low parallelism (Inferred)

- **Earlier setting:** `--num-jobs 2` and `CMAKE_BUILD_PARALLEL_LEVEL=1`, probably to avoid running out of memory.
- **Now:** `--num-jobs 5` completed with 16 cores and 23 GB RAM. Peak memory was not measured.

#### 10. `xz` download workaround (Inferred, no longer needed)

The `xz-5.2.5.tar.gz` copy steps are obsolete. `xz` is not in the current dependency list because `liblzma-dev` satisfies it, and that tarball is not in the repository.

### Harmless issue

`manifests/yaml-cpp` has a stray edit: `[cmake.defines]boost`. It still parses, and yaml-cpp is not a direct dependency of mvfst, folly or fizz. It should be reverted to `[cmake.defines]`.

### Problems in `patch_for_installation.sh`

Do not run this script as it stands. It was left unchanged, so follow section 2 instead.

| Line | Problem |
| --- | --- |
| 27-32 | Creates paths for another user and copies an `xz` tarball that does not exist |
| 46 | `cp` has no destination, so it fails |
| 58-62 | Build command lacks `--current-project mvfst` (blocker 1) |
| 65 | `cd` uses another user's path, and the directory does not exist here |
| 70 | `./getdeps.sh` omits `--allow-system-packages`, so it resolves dependencies differently |

## 4. Overview of every command run

### Earlier commands (`patch_for_installation.sh`)

Purposes are inferred from the script and its comments.

| Command | Purpose |
| --- | --- |
| `sudo apt install cmake`, `libssl-dev openssl` | Install the build system and OpenSSL headers |
| `sudo apt-get install g++ ... libsodium-dev` | Install the compiler and C++ library headers so getdeps need not build them |
| `export OPENSSL_ROOT_DIR=/usr` | Point CMake at the system OpenSSL |
| `mkdir tmp ...`, `cp .../xz-5.2.5.tar.gz ...` | Pre-seed the getdeps download cache with xz (obsolete) |
| `python3 -m venv ~/boost183-venv`, `source .../activate` | Isolated Python for building Boost |
| `pip install "numpy<2"` | Older numpy for Boost.Python (obsolete) |
| `cp .../libaio-libaio-libaio-0.3.113.tar.gz` | Unfinished manual libaio download step |
| `mkdir -p ~/mvfst-tmp`, `export TMPDIR=...` | Move the getdeps scratch directory out of `/tmp` |
| `export CMAKE_BUILD_PARALLEL_LEVEL=1` | Limit parallel compile jobs |
| `getdeps.py --allow-system-packages build mvfst --num-jobs 2 ...` | Build dependencies and mvfst (compiled the clone; see blocker 1) |
| `cmake -DBUILD_SAMPLES=ON .`, `ninja -j1 echo` | Enable and compile the echo sample |
| `./getdeps.sh` | Upstream wrapper for the build |

### Commands run on 2026-11-01

In the order they were run.

**Inspect the current state**

| Command | Purpose | Result |
| --- | --- | --- |
| `git diff`, `ls -la`, read `patch.md` and the script | See what had been changed and tried | Six modified build files; `_build` had no mvfst |
| `cat /etc/os-release`, `nproc`, `free`, `df`, tool version checks | Check the OS, resources and toolchain | Kali 2026.2, 16 cores, 23 GB RAM, 57 GB free |
| `sudo -n true` | Check for passwordless sudo | Not available, so no packages were installed |
| `ls` of `~/mvfst-tmp` scratch, `tail` of `getdeps_build.log` | Find how far the last build got | Log stopped at `cmake --build` with no result |
| Python `configparser` on `manifests/yaml-cpp` | Test whether the stray edit breaks parsing | Parses correctly |
| `dpkg -l` | List installed development packages | Most present; `libboost-all-dev` absent |
| `pgrep`, `ninja -n install`, `grep CMakeCache.txt` | Check for running builds and the configured source | Nothing running; source was the clone |
| `git log` on the clone, local repo and pins | Compare the revisions being built | Found the clone/checkout mismatch |

**Plan the fix safely**

| Command | Purpose | Result |
| --- | --- | --- |
| `grep` through `getdeps/*.py` | Find how getdeps picks its source tree | Found `--current-project` and `--src-dir` |
| `getdeps.py show-source-dir` etc. using a variable for flags | Dry-run source selection | Failed because zsh does not split the variable; no effect on the build |
| `getdeps.py show-source-dir`, `show-build-dir`, `show-inst-dir --recursive` | Repeat the dry run with flags written out | Source is this checkout; hashes unchanged |
| `sed` of `getdeps/cli.py` | Read `--clean` and the cmake define handling | Found the `--clean` risk |
| `show-inst-dir` with `--extra-cmake-defines` | Check the effect on hashes | Hashes change, so this approach was rejected |
| `mv build/mvfst build/mvfst.stale-upstream-clone` | Remove the clone's CMake state, reversibly | Clean start for the build |

**Build and verify**

| Command | Purpose | Result |
| --- | --- | --- |
| `getdeps.py ... build mvfst --current-project mvfst --num-jobs 5 ...` | Build this checkout | Passed: exit 0 in 7m27s |
| Monitor on `CMakeCache.txt` and the build log | Confirm the source path and catch failures early | Showed the checkout path; no failures |
| `grep` of `build1.log`, `ls _build/mvfst` | Confirm the true result, since the wrapper's exit code came from `echo` | No errors; libraries installed |
| `grep CMakeCache.txt`, warning count | Confirm tests were on and review warnings | Tests on; 88 warnings, none blocking |
| `cmake -DBUILD_SAMPLES=ON .`, `ninja -j5 echo` | Enable and build the sample | Passed |
| `echo --mode=server`, `echo --mode=client` | First loopback test | Client timed out, no output |
| The same with `--logtostderr=1 --v=2` | Find out why | Handshake and echo succeeded |
| `ctest -j8 --timeout 300 --output-on-failure` | Run the test suite | 2113 of 2113 passed |
| Largest test binary run directly; `--gtest_list_tests` on all | Confirm the fast `ctest` run really executed tests | 138 passed; 2542 cases listed |
| `grep DISABLED_` | Check why 4 tests did not run | Disabled in the source |
| `getdeps.py install-system-deps --dry-run`, `dpkg -l`, `apt-cache policy` | Check how system packages are used | Boost not installed via apt, as intended |
| `grep` of the boost log and `_build/boost-*/lib` | Confirm Python support was dropped | No `--with-python`; no Python library |
| `curl` on both libaio URLs and the directory index; `sha256sum`, `file` | Test whether the libaio fix still works | Both 404 (blocker 5) |
| `du -sh` of the build directories | Measure disk use | Stale 3.2 GB; mvfst 11 GB; `_build` 2.3 GB |
| Repeat the final `getdeps.py build` | Confirm the documented command works when re-run | Passed; `BUILD_SAMPLES` was dropped |
| Echo test sending `/close` | Check for a clean client exit | Echo worked; client still timed out (blocker 4) |
| `grep BUILD_SAMPLES`, `grep samples/echo build.ninja` | Confirm the setting was lost | Confirmed |
| `cmake -DBUILD_SAMPLES=ON .`, `ninja -j5 echo` | Restore the sample in the final state | Passed |
| `ninja -n install` | Confirm nothing is left to build | Up to date |


# Failure Detection
1. How logs were accessed for the inferred failures

The inferred failures (Kali distro recognition, Boost Python, etc.) were not directly logged anywhere — that's what "inferred" means. Here is exactly what was done:

What was accessible:

```
~/mvfst-tmp/fbcode_builder_getdeps-ZhomeZdevZDesktopZmvfstZbuildZfbcode_builder/
├── build/
│   ├── mvfst/getdeps_build.log         ← 259 KB, the main log
│   ├── boost-<hash>/getdeps_build.log  ← 12 KB each
│   ├── folly/getdeps_build.log
│   ├── fizz/getdeps_build.log
│   └── ...one log per dependency
```
How the log was read: tail -60 and grep were used on these logs. The getdeps_build.log per dependency records the exact shell commands getdeps ran — it starts with a +-prefixed set -x trace showing every cmake invocation, environment variable, ninja --build, etc. For the inferred blockers (Boost Python, Kali distro):

- The earlier build had already been completed using your patch_for_installation.sh. That session's log file was already gone (it was in /tmp, which can be wiped). The inferences were made by reading the diff of the six changed files (git diff) and reverse-engineering why each change must have been made:
  - getdeps_platform.py adding "kali" → the old code would have printed "unsupported platform" or failed to map apt packages.
  - Commenting out --with-python in the boost manifests → the boost b2 build must have crashed on the Python module.
- The ~/boost183-venv venv + pip install "numpy<2" in the script were a clue that Boost.Python was attempted and failed with a numpy version error, but that specific error output was not available.

---

2. Which directory the code is built into

There are two separate directories — do not confuse them:
```
┌─────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────┬───────────────────┐
│                      Directory                      │                        What it contains                         │    Persistent?    │
├─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────┼───────────────────┤
│ ~/mvfst-tmp/fbcode_builder_getdeps-.../build/mvfst/ │ Build tree — object files, .ninja rules, test binaries, the     │ Scratch, tied to  │
│                                                     │ echo binary, CMakeCache.txt, getdeps_build.log                  │ TMPDIR            │
├─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────┼───────────────────┤
│ /home/dev/Desktop/mvfst/_build/mvfst/               │ Install tree — final .a libraries and public headers only       │ Your repo's       │
│                                                     │                                                                 │ _build/           │
└─────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────┴───────────────────┘
```
# Get the exact build tree path at any time:
```
export TMPDIR=$HOME/mvfst-tmp
BUILD_DIR=$(./build/fbcode_builder/getdeps.py --allow-system-packages \
    show-build-dir mvfst --current-project mvfst \
    --install-prefix="$PWD/_build" 2>/dev/null | tail -1)
echo $BUILD_DIR
```
# → /home/dev/mvfst-tmp/fbcode_builder_getdeps-ZhomeZdevZDesktopZmvfstZbuildZfbcode_builder/build/mvfst

The install tree only has 343 files (headers + static libs). The build tree has everything including the 47 test binaries and the echo sample.

---

3. Significance of .built-by-getdeps

_build/mvfst/.built-by-getdeps
→ contents: Ak-1Sf4uNf7MYZSDQSMXNjMaO6M_erpua0ukSw_lfW0

This file is a build-identity marker that getdeps uses as

- Cache invalidation. The hash inside is derived from theency versions, and build flags. If you change a manifest
  (e.g. add a cmake flag), the expected hash changes. getdeps compares the file's hash to the newly computed hash at the start of each run — if
  they differ, it rebuilds that component.
- Skip-if-fresh logic. This is the check at cli.py:507 (compute_source_change_status). If the marker exists and the hash matches, getdeps skips
  the component entirely with "Assessing mvfst... [up to d build in this session only took seconds — all nine
  dependencies were up to date.
- What it is NOT. It is not a lock file, not a checksum omeaningful outside of getdeps. You can delete it to force
  a full rebuild of just that component without touching its dependencies.

---

4. Where the binaries are

# The only user-facing executable:
$BUILD_DIR/quic/samples/echo          ← 228 MB (debug sym

# 47 test binaries (used by ctest):
$BUILD_DIR/quic/.../test/*Test        ← one binary per test suite

# Installed libraries (no executables installed):
_build/mvfst/lib/libmvfst.a           ← 446 MB monolithic
_build/mvfst/lib/libmvfst_*.a         ← ~80 granular per-module archives
_build/mvfst/include/quic/**/*.h      ← public headers

The echo binary is not installed to _build/ — it stays inall only copies libraries and headers.

---

5. How to create a testbed to simulate flows

The echo sample is the right starting point. It is a fullizz), real UDP sockets, and real congestion control. Here
are the progression levels:

Level 1 — Single machine, loopback (already working)

export BUILD=$BUILD_DIR  # from above

# Terminal 1: server
$BUILD/quic/samples/echo --mode=server --host=::1 --port=

# Terminal 2: client
$BUILD/quic/samples/echo --mode=client --host=::1 --port=6666 --logtostderr=1
# type messages, Ctrl+C to stop both

LogQuicStats.h (already linked into echo) logs every pack stream open/close, and migration events.

Level 2 — Simulate network conditions with tc / netem

Apply impairments on the loopback or a virtual interface ry. No code changes needed.

# Add 50ms RTT + 1% loss on loopback (needs sudo)
sudo tc qdisc add dev lo root netem delay 50ms loss 1%

# Verify
ping -c 4 ::1

# Run your test, then remove
sudo tc qdisc del dev lo root

You can also simulate bandwidth limits:

# 10 Mbit/s cap + 20ms delay
sudo tc qdisc add dev lo root handle 1: tbf rate 10mbit b
sudo tc qdisc add dev lo parent 1:1 handle 10: netem delay 20ms loss 0.5%

Level 3 — Multiple concurrent streams / connections

The client opens a new bidirectional stream for each line of stdin (EchoClient.h:228). You can drive multiple parallel clients:

# Start server once
$BUILD/quic/samples/echo --mode=server --logtostderr=1 &

# Run 5 parallel clients, each sending 100 messages
for i in $(seq 5); do
  (for j in $(seq 100); do echo "client-$i msg-$j"; done;
    $BUILD/quic/samples/echo --mode=client --logtostderr=1 &
done
wait

Level 4 — Modify the EchoHandler for flow-specific logic

EchoHandler.h:130 is the place to change what the server does per-stream. For traffic measurement:

void readAvailable(quic::StreamId id) noexcept override {
    auto res = sock->read(id, 0);
    // res.value() = {BufPtr, bool eof}
    // BufPtr->computeChainDataLength() = bytes received
    // QuicSocket::getConnectionStats() = RTT, cwnd, loss, bytes in/out
    auto stats = sock->getConnectionStats();
    MVLOG_INFO << "rttUs=" << stats.srtt.count()
               << " cwndBytes=" << stats.congestionWindow
               << " lostPackets=" << stats.lostPackets;
}

Rebuild after changes:

cd $BUILD_DIR && ninja -j5 echo

Level 5 — Two separate machines

The only change is the --host flag. The TLS certificates ked into TestUtils.h, so no PKI setup is needed for a
testbed.

# Machine A (server)
$ECHO --mode=server --host=0.0.0.0 --port=6666 --logtostd

# Machine B (client)
$ECHO --mode=client --host=<machine-A-IP> --port=6666 --logtostderr=1

Use --enable_migration=true (the default) to test connection migration by changing the client's IP mid-connection.

Level 6 — Datagram mode (no stream ordering)

Swap to QUIC datagrams for latency-sensitive flows — the server already handles both paths (EchoHandler::echoDg):

# Both sides need the flag
$ECHO --mode=server --use_datagrams=true --logtostderr=1
$ECHO --mode=client --use_datagrams=true --logtostderr=1

This bypasses stream-level flow control and HOL blocking, useful for comparing QUIC stream vs. datagram behaviour under the same tc netem impairments.t.
- Skip-if-fresh logic. This is the check at cli.py:507 (compute_source_change_status). If the marker exists and the hash matches, getdeps skips
  the component entirely with "Assessing mvfst... [up to d build in this session only took seconds — all nine
  dependencies were up to date.
- What it is NOT. It is not a lock file, not a checksum omeaningful outside of getdeps. You can delete it to force
  a full rebuild of just that component without touching its dependencies.

---

4. Where the binaries are

# The only user-facing executable:
$BUILD_DIR/quic/samples/echo          ← 228 MB (debug sym

# 47 test binaries (used by ctest):
$BUILD_DIR/quic/.../test/*Test        ← one binary per test suite

# Installed libraries (no executables installed):
_build/mvfst/lib/libmvfst.a           ← 446 MB monolithic
_build/mvfst/lib/libmvfst_*.a         ← ~80 granular per-module archives
_build/mvfst/include/quic/**/*.h      ← public headers

The echo binary is not installed to _build/ — it stays inall only copies libraries and headers.

---

5. How to create a testbed to simulate flows

The echo sample is the right starting point. It is a fullizz), real UDP sockets, and real congestion control. Here
are the progression levels:

Level 1 — Single machine, loopback (already working)

export BUILD=$BUILD_DIR  # from above

# Terminal 1: server
$BUILD/quic/samples/echo --mode=server --host=::1 --port=

# Terminal 2: client
$BUILD/quic/samples/echo --mode=client --host=::1 --port=6666 --logtostderr=1
# type messages, Ctrl+C to stop both

LogQuicStats.h (already linked into echo) logs every pack stream open/close, and migration events.

Level 2 — Simulate network conditions with tc / netem

Apply impairments on the loopback or a virtual interface ry. No code changes needed.

# Add 50ms RTT + 1% loss on loopback (needs sudo)
sudo tc qdisc add dev lo root netem delay 50ms loss 1%

# Verify
ping -c 4 ::1

# Run your test, then remove
sudo tc qdisc del dev lo root

You can also simulate bandwidth limits:

# 10 Mbit/s cap + 20ms delay
sudo tc qdisc add dev lo root handle 1: tbf rate 10mbit b
sudo tc qdisc add dev lo parent 1:1 handle 10: netem delay 20ms loss 0.5%

Level 3 — Multiple concurrent streams / connections

The client opens a new bidirectional stream for each line of stdin (EchoClient.h:228). You can drive multiple parallel clients:

# Start server once
$BUILD/quic/samples/echo --mode=server --logtostderr=1 &

# Run 5 parallel clients, each sending 100 messages
for i in $(seq 5); do
  (for j in $(seq 100); do echo "client-$i msg-$j"; done;
    $BUILD/quic/samples/echo --mode=client --logtostderr=1 &
done
wait

Level 4 — Modify the EchoHandler for flow-specific logic

EchoHandler.h:130 is the place to change what the server does per-stream. For traffic measurement:

void readAvailable(quic::StreamId id) noexcept override {
    auto res = sock->read(id, 0);
    // res.value() = {BufPtr, bool eof}
    // BufPtr->computeChainDataLength() = bytes received
    // QuicSocket::getConnectionStats() = RTT, cwnd, loss, bytes in/out
    auto stats = sock->getConnectionStats();
    MVLOG_INFO << "rttUs=" << stats.srtt.count()
               << " cwndBytes=" << stats.congestionWindow
               << " lostPackets=" << stats.lostPackets;
}

Rebuild after changes:

cd $BUILD_DIR && ninja -j5 echo

Level 5 — Two separate machines

The only change is the --host flag. The TLS certificates ked into TestUtils.h, so no PKI setup is needed for a
testbed.

# Machine A (server)
$ECHO --mode=server --host=0.0.0.0 --port=6666 --logtostd

# Machine B (client)
$ECHO --mode=client --host=<machine-A-IP> --port=6666 --logtostderr=1

Use --enable_migration=true (the default) to test connection migration by changing the client's IP mid-connection.

Level 6 — Datagram mode (no stream ordering)

Swap to QUIC datagrams for latency-sensitive flows — the server already handles both paths (EchoHandler::echoDg):

# Both sides need the flag
$ECHO --mode=server --use_datagrams=true --logtostderr=1
$ECHO --mode=client --use_datagrams=true --logtostderr=1

This bypasses stream-level flow control and HOL blocking, useful for comparing QUIC stream vs. datagram behaviour under the same tc netem impairments.