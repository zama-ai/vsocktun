# vsocktun

`vsocktun` is a small utility that relays packets between a Linux TUN device
and one or more VSOCK streams.

It is designed for the Nitro Enclave deployment in this repository, where the
enclave gets an IP address on a private point-to-point subnet and all of its
traffic is forwarded through the parent instance over VSOCK. The parent now
also serves the enclave's tunnel CIDR, shard count, MTU, and rewritten
resolver config over an initial bootstrap exchange on that same VSOCK port.

## Architecture

`vsocktun` is a packet tunnel, not a TCP proxy.

That means:
- the inner gRPC peer connections stay end-to-end TCP connections
- `vsocktun` does not terminate or re-originate inner TCP flows
- packet boundaries are preserved explicitly by a small framing layer on top of
  the stream-oriented VSOCK transport
- when both ends support Linux virtio-net headers, `vsocktun` forwards raw TUN
  frames end-to-end so GSO and checksum metadata survive across VSOCK

The tunnel is organized around two levels:

- A **session** is one logical tunnel between enclave and parent.
- A **shard** is one TUN queue paired with one VSOCK stream.

Each shard carries a subset of the tunnel traffic. Using multiple shards avoids
forcing every inner flow through one ordered outer stream, which reduces head
of-line blocking under concurrent MPC traffic.

The TUN device is configured with Linux offload support through `tun-rs`. When
that succeeds on both sides, the tunnel carries raw TUN frames, including the
virtio-net metadata needed for TCP segmentation and checksum offload. If both
sides fall back to plain L3 TUN packets, the relay still works, but without the
same offload preservation.

## Responsibilities

`vsocktun` owns:
- creating the local multiqueue TUN device
- serving bootstrap tunnel configuration from the parent to the enclave
- connecting or accepting the VSOCK shard streams
- grouping the shard streams into one logical session
- forwarding packets between TUN queues and VSOCK streams
- installing enclave-side routes through the parent tunnel IP
- writing the enclave `/etc/resolv.conf` received from the parent bootstrap
- reconnecting from the enclave side when a session breaks

`vsocktun` does **not** own:
- IP address allocation policy
- NAT / masquerading
- ingress DNAT
- DNS forwarding

Those pieces are intentionally left to the surrounding shell scripts and Helm
templates used by the KMS deployment.

## Modes

`vsocktun` has two modes.

### Parent mode

The parent side creates the TUN device once, serves bootstrap requests on the
shared VSOCK port, and then listens for shard streams from the enclave. The
parent derives the enclave-side CIDR from `--tun-address` and
`--enclave-address` before returning it in bootstrap.

```bash
vsocktun parent \
  --tun-name vsocktun \
  --tun-address 10.118.0.1/24 \
  --enclave-address 10.118.0.2/24 \
  --vsock-port 2100 \
  --queues 32 \
  --tokio-worker-threads 8
```

### Enclave mode

The enclave side first bootstraps its TUN address, queue count, MTU, routes,
and resolver config from the parent, then creates its TUN device once and
repeatedly dials the parent until a full session is established.

```bash
vsocktun enclave \
  --parent-cid 3 \
  --tun-name vsocktun \
  --vsock-port 2100 \
  --tokio-worker-threads 8
```

## Key flags

- `--tun-name`: local TUN interface name
- `--vsock-port`: parent-side VSOCK port used first for bootstrap and then for
  shard sessions
- `--tokio-worker-threads`: number of Tokio runtime worker threads used to
  drive all shard tasks in the process
- `-v, --verbose`: raise log level from `info` to `debug`
- `-vv`: raise log level to `trace` and include per-packet forwarding summaries
- `--stats-interval-ms <N>` (both commands): log the packet counters every `N` ms as one `VSOCKTUN_STATS_V1` line at the `info` level. `0`, the default, means never.

Parent-only:
- `--tun-address`: parent-side IPv4 address and prefix for the tunnel interface
- `--enclave-address`: enclave-side IPv4 address and prefix for the tunnel interface
- `--queues`: number of shards / TUN queues / VSOCK streams in the session
- `--mtu`: optional TUN MTU override propagated to the enclave bootstrap
- `--session-timeout-secs`: how long the parent waits for all shards of a new
  session to arrive and complete their initial session headers

Enclave-only:
- `--parent-cid`: VSOCK CID of the parent instance, normally `3` on Nitro
- `--reconnect-delay-ms`: delay before retrying a failed session

## Operational notes

- Both sides must use the same `--vsock-port`.
- The parent is the source of truth for enclave tunnel addressing, shard count,
  MTU, and resolver contents.
- Both sides must run compatible `vsocktun` protocol versions. Newer binaries
  reject older handshake versions during session setup.
- If peer TUN offload framing support differs between parent and enclave,
  session setup is rejected with an explicit log message instead of silently
  downgrading.
- The parent and enclave TUN addresses must be on the same point-to-point
  subnet.
- The parent-side runtime still needs IP forwarding and NAT configured outside
  `vsocktun`.
- The parent-side runtime still needs `dnsproxy` (or equivalent) configured
  outside `vsocktun`.

## Development

The repository includes a Nix flake with a self-contained development shell:

```sh
nix develop
cargo test
cargo clippy --all-targets
```

The shell provides the pinned Rust toolchain, `rustfmt`, `clippy`,
`rust-analyzer`, the C linker, `iproute2`, and `strace`. `nix build`
builds the release binary with the same toolchain.

The end-to-end tests are marked `#[ignore]` because they need root,
`/dev/net/tun`, VSOCK loopback support, and `iproute2`.

## Enclave image builders

The flake also provides the generic Nitro enclave plumbing used by service
repositories such as KMS:

- `packages.<system>.nitro-cli`, `enclave-kernel`, `enclave-bootstrap`,
  `enclave-eif-build`, and `enclave-parent-tools`
- `lib.<system>.enclave.mkRuntimeImage` adds vsocktun and an entrypoint to an
  application image, producing the image that becomes the EIF
- `lib.<system>.enclave.mkEifDerivation` unpacks the image tarball with
  `skopeo`/`umoci`, writes the bootstrap and customer initrds with `cpio`, and
  assembles the EIF with AWS's `eif_build`; no Docker daemon or external image
  cache is involved. The EIF artifacts are available directly in the Nix store.
- `lib.<system>.enclave.mkLauncherImage` builds a parent-side image containing
  nitro-cli, vsocktun, the parent networking tools, and an embedded EIF.
  Pass `eif = "${eifBuild}/enclave.eif";` to embed the output of
  `eifBuild = mkEifDerivation { inherit image; };`.

The EIF builder consumes the same docker-archive tarball that `mkRuntimeImage`
produces. It emits `enclave.eif`, `pcr.json` (PCR0-PCR2), and `sha256.txt`.
Because the image tar is an ordinary Nix input and the initrds and EIF are
separate derivations, the build is sandboxed, reproducible, and served from a
binary cache.

A service repository supplies its application image, entrypoint, and EIF; this
flake supplies the kernel, bootstrap, EIF tooling, nitro-cli, vsocktun, and the
image templates.

### Build both Linux image architectures locally

On x86_64 Linux, build x86_64 images natively and cross-build aarch64 images.
On Apple Silicon, run Nix **inside a local aarch64 Linux VM**: build aarch64
images natively and cross-build x86_64 images inside that same VM. No remote
builder or x86_64 VM is needed. Run from a checkout of the consumer flake in
the guest and copy the resulting archive back to macOS if needed. The Darwin
flake outputs build standalone Linux binaries only, not EIFs or images.

A consumer such as KMS uses the same three builder functions for both
targets. Here `system` is the Linux system running the build and
`targetSystem` is the system that will run the image:

```nix
enclave =
  if system == targetSystem then
    vsocktun.lib.${system}.enclave
  else
    vsocktun.lib.${system}.cross.${targetSystem}.enclave;
```

Build the application binaries and base image for that same target. For a
cross build, use `pkgs.pkgsCross.aarch64-multiplatform` from x86_64 Linux
or `pkgs.pkgsCross.gnu64` from aarch64 Linux. The kernel, bootstrap, and
image contents target Linux on the selected architecture; `eif_build` and
archive tools run on the build machine.

From this repo, smoke-test both complete image pipelines on your Linux
machine or inside the Linux guest:

```sh
system="$(uname -m)-linux"
nix build --builders '' --no-link \
  ".#checks.$system.enclave-images" ".#checks.$system.enclave-images-cross"
```

The checks inspect both archives, check representative ELF binaries, and
verify the launcher contains the generated EIF. They don't boot an enclave.

## Packet counters

With `--stats-interval-ms <N>`, each side logs one line every `N` ms at the
`info` level. The line starts with `VSOCKTUN_STATS_V1`, then holds `key=value`
pairs:

```
VSOCKTUN_STATS_V1 role=enclave t_ms=1700000000000 shards=2 sessions=1 ... tun_to_vsock_packets=3 ...
```

All values are running totals since the process started, unless the table says
otherwise. They continue when the tunnel reconnects. To get a rate, subtract
the values of two lines and divide by the difference of their `t_ms`.

Values for the process:

| Key | Meaning |
| --- | --- |
| `role` | `parent` or `enclave`: the side that wrote the line. |
| `t_ms` | Wall clock of that side when it wrote the line, in milliseconds since the Unix epoch. |
| `shards` | Number of shards. Constant. |
| `sessions` | Sessions established. 1 in a healthy run; each reconnect adds 1. |
| `session_errors` | Sessions that ended with an error. |
| `connect_failures` | Attempts to connect (enclave) or accept (parent) a session that produced none. |
| `cpu_user_ms`, `cpu_system_ms` | CPU time of the `vsocktun` process in user mode and in the kernel, from `/proc/self/stat`. Absent where that file does not exist. |

Values for each direction. `<dir>` is `tun_to_vsock` (read from the TUN queue,
written to the VSOCK stream) or `vsock_to_tun` (the reverse). In the enclave,
`tun_to_vsock` is traffic that leaves the enclave. On the parent it is traffic
that goes into the enclave. Each value is the sum over all shards, unless the
table says otherwise.

| Key | Meaning |
| --- | --- |
| `<dir>_packets` | Packets forwarded. A packet counts when the destination has accepted its last byte. With raw TUN frames, one packet can carry several TCP segments. |
| `<dir>_bytes` | Bytes of those packets as read from the source, without the 4-byte length that `vsocktun` adds on the VSOCK stream. |
| `<dir>_writes` | Write calls that those packets needed. Equal to `<dir>_packets` when the destination takes each packet in one call. A higher value means that the destination took some packets in parts, because its buffer was almost full. |
| `<dir>_write_us` | Time from the end of the read of a packet until the destination had accepted all of it, in microseconds, added up over the packets. It includes the write calls, the wait for the destination to accept data, and the wait of the task for a worker thread. It does not include the read, or the time the packet waited in a kernel queue before the read. |
| `<dir>_large_packets` | Packets that carry more than one segment. See `<dir>_segments`. |
| `<dir>_segments` | Segments that the packets carry: the number of packets that the same data needs on the wire. `vsocktun` reads it from the virtio-net header of each frame. Equal to `<dir>_packets` when the kernel batches nothing, and on a tunnel without raw TUN frames. |
| `<dir>_max_packet_bytes` | Size of the largest packet since the process started. Maximum over the shards. Not a sum. |
| `<dir>_write_max_us` | Longest time of one packet, measured like `<dir>_write_us`, **since the previous line**. Maximum over the shards. Not a running total. |
| `<dir>_packets_shard<i>` | `<dir>_packets` of shard `i` alone. |
| `<dir>_write_us_shard<i>` | `<dir>_write_us` of shard `i` alone. |

Useful ratios:

- `<dir>_bytes / <dir>_packets`: mean packet size.
- `<dir>_segments / <dir>_packets`: how many segments the kernel batches into one packet.
- `<dir>_write_us / <dir>_packets`: mean time that `vsocktun` holds a packet.
- `<dir>_writes - <dir>_packets`: number of partial writes.

`vsocktun` does not drop packets, and it holds one packet for each shard and
direction. So it has no drop or queue-length counters. The kernel drops packets
when a TUN queue is full, and the drop counters of the TUN interface show that.

The counters cost two clock reads for each packet, also when no lines are
logged.

## Debugging

When traffic does not appear to flow through the tunnel:

- default output uses `info` for lifecycle and `error` for failures
- use `-v` to enable `debug` logs for session assembly, shard startup, and cancellation decisions
- use `-vv` to enable `trace` logs for packet direction and byte counts per shard
- packet logs intentionally omit payload contents and only report metadata

In this repository, those surrounding concerns are handled by:
- `docker/core/service/start_parent_proxies.sh`
- `docker/core/service/init_enclave.sh`
- `charts/kms-core/templates/_helpers.tpl`

## Example deployment shape

The current KMS deployment uses `vsocktun` like this:

- parent side:
  - bring up `vsocktun`
  - enable IP forwarding
  - add NAT / FORWARD rules
  - DNAT ingress ports into the enclave IP
  - run `dnsproxy`

- enclave side:
  - bring up `vsocktun`
  - fetch tunnel config and rewritten `resolv.conf` from the parent
  - let `vsocktun` install the local routes and resolver settings

This keeps `vsocktun` focused on one job: carrying packet traffic efficiently
between the enclave and its parent over VSOCK.
