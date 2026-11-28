//! Counters of the packets that each shard forwards, and their periodic
//! report.
//!
//! The forwarding loops record one event per packet into a [`ShardStats`],
//! but only when reports are requested: without them [`TunnelStats::shard`]
//! returns `None`, and a loop does no work for the counters.
//! The counters are running totals since the process started. They continue
//! across sessions, so a reader can take differences without knowing when the
//! tunnel reconnected. The one exception is the longest write time, which
//! covers the time since the previous report.
//!
//! [`report`] logs the totals as one line of `key=value` pairs at a fixed
//! interval.

use std::fmt::Write as _;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tun_rs::VIRTIO_NET_HDR_LEN;

/// The unit of the CPU times in `/proc/self/stat`, in milliseconds.
///
/// The kernel gives those times as a count of "clock ticks" of 1/100 s (`USER_HZ`, a constant of the Linux interface to
/// user space). So the CPU time of the process has a resolution of 10 ms.
const MILLIS_PER_CPU_TICK: u64 = 10;

/// Stats line are prefixed with this. The number is the version of the line format.
pub(crate) const STATS_LINE_PREFIX: &str = "VSOCKTUN_STATS_V1";

/// Totals and max values of one direction of one shard.
#[derive(Debug, Default)]
pub(crate) struct DirectionStats {
    /// Packets forwarded. With raw TUN frames one packet can carry several TCP segments.
    packets: AtomicU64,
    /// Bytes of those packets, without the framing header.
    bytes: AtomicU64,
    /// Write calls that those packets needed. More writes than packets means that the destination accepted some packets
    /// only in parts.
    writes: AtomicU64,
    /// Time from the end of the read of a packet until the destination accepted all of it, in nanoseconds. It grows
    /// when the destination is slow to accept data. The reports give it in microseconds; the total is kept in
    /// nanoseconds because a single write can take less than a microsecond more or less than a whole number of them.
    write_nanos: AtomicU64,
    /// Size of the largest packet, in bytes.
    max_packet_bytes: AtomicU64,
    /// Packets that carry more than one segment. See [`segments_in_frame`].
    large_packets: AtomicU64,
    /// Segments that the packets carry: the number of packets that the same data needs on the wire. Equal to `packets`
    /// when no packet is large.
    segments: AtomicU64,
    /// Longest write time of one packet since the previous [`Self::snapshot`], in nanoseconds. Not a running total.
    longest_write_nanos: AtomicU64,
}

/// The values of a [`DirectionStats`] at one moment.
#[derive(Clone, Copy, Debug, Default)]
struct DirectionSnapshot {
    packets: u64,
    bytes: u64,
    writes: u64,
    write_micros: u64,
    max_packet_bytes: u64,
    large_packets: u64,
    segments: u64,
    longest_write_micros: u64,
}

impl DirectionStats {
    /// Records one forwarded packet of `bytes` bytes that carries `segments` segments and took `writes` write calls and
    /// `write_time` to hand over.
    pub(crate) fn record_packet(
        &self,
        bytes: usize,
        segments: u64,
        writes: u64,
        write_time: Duration,
    ) {
        let bytes = bytes as u64;
        let write_nanos = u64::try_from(write_time.as_nanos()).unwrap_or(u64::MAX);
        self.packets.fetch_add(1, Ordering::Relaxed);
        self.bytes.fetch_add(bytes, Ordering::Relaxed);
        self.writes.fetch_add(writes, Ordering::Relaxed);
        self.write_nanos.fetch_add(write_nanos, Ordering::Relaxed);
        self.max_packet_bytes.fetch_max(bytes, Ordering::Relaxed);
        if segments > 1 {
            self.large_packets.fetch_add(1, Ordering::Relaxed);
        }
        self.segments.fetch_add(segments, Ordering::Relaxed);
        self.longest_write_nanos
            .fetch_max(write_nanos, Ordering::Relaxed);
    }

    /// Reads each counter once, and starts the next interval of the longest write time. A report takes its sums and
    /// its values for each shard from the same snapshot, so that they agree while packets flow.
    fn snapshot(&self) -> DirectionSnapshot {
        DirectionSnapshot {
            packets: self.packets.load(Ordering::Relaxed),
            bytes: self.bytes.load(Ordering::Relaxed),
            writes: self.writes.load(Ordering::Relaxed),
            write_micros: self.write_nanos.load(Ordering::Relaxed) / 1_000,
            max_packet_bytes: self.max_packet_bytes.load(Ordering::Relaxed),
            large_packets: self.large_packets.load(Ordering::Relaxed),
            segments: self.segments.load(Ordering::Relaxed),
            longest_write_micros: self.longest_write_nanos.swap(0, Ordering::Relaxed) / 1_000,
        }
    }
}

// Background for the two constants below. To save work, the kernel can pass one large frame through a TUN device in
// place of many packets of wire size, with a note that says "cut this into pieces of N bytes before it goes on a wire".
// Linux calls this generic segmentation offload (GSO). The note is the virtio-net header at the start of the frame. Its
// `gso_type` field says which kind of cutting the frame needs, and its `gso_size` field is N.

/// The `gso_type` of a frame that needs no cutting: it is one packet (`VIRTIO_NET_HDR_GSO_NONE` in
/// `linux/virtio_net.h`).
const GSO_NONE: u8 = 0;
/// A bit that the kernel can set in `gso_type` in addition to the kind of cutting (`VIRTIO_NET_HDR_GSO_ECN`). It says
/// nothing about the number of segments, so [`segments_in_frame`] clears it before it looks at the kind.
const GSO_ECN_FLAG: u8 = 0x80;

/// Returns the length of the IPv4 header and the TCP or UDP header at the start of `packet`. Returns `None` for
/// another kind of packet, and for one that is too short for its own header fields.
fn ipv4_header_bytes(packet: &[u8]) -> Option<usize> {
    const TCP: u8 = 6;
    const UDP: u8 = 17;
    const UDP_HEADER_BYTES: usize = 8;
    // First byte: the IP version, then the length of the IP header in units of 4 bytes.
    let first = *packet.first()?;
    if first >> 4 != 4 {
        return None;
    }
    let ip_header_bytes = usize::from(first & 0x0f) * 4;
    let transport_header_bytes = match *packet.get(9)? {
        // Byte 12 of the TCP header: the length of the TCP header in units of 4 bytes, in the upper half.
        TCP => usize::from(*packet.get(ip_header_bytes + 12)? >> 4) * 4,
        UDP => UDP_HEADER_BYTES,
        _ => return None,
    };
    Some(ip_header_bytes + transport_header_bytes)
}

/// Returns the number of segments that one frame of a TUN queue carries.
///
/// With `raw_tun_frames`, a frame starts with a virtio-net header. The kernel can batch several TCP or UDP segments
/// into one frame. The header then names the segment size, and the kernel on the other side cuts the frame into
/// segments of that size.
///
/// A frame counts as one segment in three cases: the tunnel has no such header, the header names no segment size, or
/// the frame is too short for what its headers claim.
///
/// The fields of the virtio-net header are in the byte order of the machine that made the frame. Both ends of a
/// tunnel run on the same machine, so that is the native byte order.
///
/// The cost for each packet is small: it reads a few bytes of a frame that the caller just read or wrote, and it makes
/// one division for a frame that carries several segments.
pub(crate) fn segments_in_frame(frame: &[u8], raw_tun_frames: bool) -> u64 {
    if !raw_tun_frames || frame.len() < VIRTIO_NET_HDR_LEN {
        return 1;
    }
    // struct virtio_net_hdr: flags, gso_type, hdr_len (u16), gso_size (u16),
    // then two checksum fields.
    let gso_type = frame[1] & !GSO_ECN_FLAG;
    let segment_bytes = usize::from(u16::from_ne_bytes([frame[4], frame[5]]));
    if gso_type == GSO_NONE || segment_bytes == 0 {
        return 1;
    }
    let packet = &frame[VIRTIO_NET_HDR_LEN..];
    // Each segment gets a copy of the IP and transport headers. The rest is payload, cut into pieces of `gso_size`.
    // The length of the headers comes from the packet. The `hdr_len` field is not that length: Linux fills it with
    // the length of the part of the packet that it holds in one piece, which can include payload. It is the fallback
    // for a packet that is not IPv4 with TCP or UDP, where it can give too few segments.
    let header_bytes = ipv4_header_bytes(packet)
        .unwrap_or_else(|| usize::from(u16::from_ne_bytes([frame[2], frame[3]])));
    let payload = packet.len().saturating_sub(header_bytes);
    (payload.div_ceil(segment_bytes) as u64).max(1)
}

/// Returns the CPU time of this process in user mode and in kernel mode, in
/// milliseconds. Returns `None` where `/proc/self/stat` does not exist or
/// does not parse.
///
/// [`report`] calls this once for each stats line, not for each packet. The process must report the value itself:
/// nothing outside an enclave can see the CPU time of a process inside it.
fn process_cpu_millis() -> Option<(u64, u64)> {
    parse_process_cpu_millis(&fs::read_to_string("/proc/self/stat").ok()?)
}

fn parse_process_cpu_millis(stat: &str) -> Option<(u64, u64)> {
    // The process name is in parentheses and can hold spaces and
    // parentheses, so count the fields from the last `)`. `utime` and `stime`
    // are fields 14 and 15 of the line: the 12th and 13th after the name.
    let mut fields = stat.rsplit_once(')')?.1.split_ascii_whitespace().skip(11);
    let user_ticks: u64 = fields.next()?.parse().ok()?;
    let system_ticks: u64 = fields.next()?.parse().ok()?;
    Some((
        user_ticks * MILLIS_PER_CPU_TICK,
        system_ticks * MILLIS_PER_CPU_TICK,
    ))
}

/// Totals of one shard.
#[derive(Debug, Default)]
pub(crate) struct ShardStats {
    /// Packets read from the TUN queue and written to the VSOCK stream.
    pub(crate) tun_to_vsock: DirectionStats,
    /// Packets read from the VSOCK stream and written to the TUN queue.
    pub(crate) vsock_to_tun: DirectionStats,
}

/// Selects one direction of a shard.
type DirectionOf = fn(&ShardStats) -> &DirectionStats;

/// Totals of all shards of this process.
#[derive(Debug)]
pub(crate) struct TunnelStats {
    shards: Box<[ShardStats]>,
    /// Whether the forwarding loops record packets. See [`Self::shard`].
    packet_counters: bool,
    /// Sessions started. More than one means that the tunnel reconnected. The [crate documentation](crate) says
    /// what a session is.
    sessions: AtomicU64,
    /// Sessions that ended with an error.
    session_errors: AtomicU64,
    /// Attempts to connect or accept a session that did not produce one.
    connect_failures: AtomicU64,
}

impl TunnelStats {
    /// Creates the counters for `shards` shards, all zero. With `packet_counters` the forwarding loops record each
    /// packet; without it only the session counters change.
    pub(crate) fn new(shards: usize, packet_counters: bool) -> Self {
        Self {
            shards: (0..shards).map(|_| ShardStats::default()).collect(),
            packet_counters,
            sessions: AtomicU64::new(0),
            session_errors: AtomicU64::new(0),
            connect_failures: AtomicU64::new(0),
        }
    }

    /// Returns the counters of `shard` for a forwarding loop, or `None` when packets are not counted. A loop that
    /// gets `None` must skip all work that only serves the counters, such as the clock reads around a write.
    ///
    /// Panics if `shard` is not below the shard count given to [`Self::new`]. That cannot occur for a shard of a
    /// session: a session has one shard for each TUN queue, and the caller gives the queue count to [`Self::new`].
    pub(crate) fn shard(&self, shard: usize) -> Option<&ShardStats> {
        self.packet_counters.then(|| &self.shards[shard])
    }

    /// Records the start of a session.
    pub(crate) fn record_session(&self) {
        self.sessions.fetch_add(1, Ordering::Relaxed);
    }

    /// Records a session that ended with an error.
    pub(crate) fn record_session_error(&self) {
        self.session_errors.fetch_add(1, Ordering::Relaxed);
    }

    /// Records an attempt to connect or accept a session that failed.
    pub(crate) fn record_connect_failure(&self) {
        self.connect_failures.fetch_add(1, Ordering::Relaxed);
    }

    /// Renders the counters as one line without a line end: the prefix, `role`, the wall clock in milliseconds since
    /// the Unix epoch, then `key=value` pairs. `process_cpu_millis` is the user and kernel CPU time of the process,
    /// left out when `None`. For each direction the line gives the sums over all shards, then the packets and the write
    /// time of each shard.
    ///
    /// Each call starts the next interval of the longest write time. Only [`report`] must call it.
    ///
    /// The write time of a direction is the sum of the times of its shards after each is cut down to whole
    /// microseconds, so the sum and the shard values of one line agree.
    fn render(
        &self,
        role: &str,
        unix_millis: u128,
        process_cpu_millis: Option<(u64, u64)>,
    ) -> String {
        let mut line = format!(
            "{STATS_LINE_PREFIX} role={role} t_ms={unix_millis} shards={} sessions={} \
             session_errors={} connect_failures={}",
            self.shards.len(),
            self.sessions.load(Ordering::Relaxed),
            self.session_errors.load(Ordering::Relaxed),
            self.connect_failures.load(Ordering::Relaxed),
        );
        // Writing to a String cannot fail.
        if let Some((user, system)) = process_cpu_millis {
            let _ = write!(line, " cpu_user_ms={user} cpu_system_ms={system}");
        }
        let directions: [(&str, DirectionOf); 2] = [
            ("tun_to_vsock", |shard| &shard.tun_to_vsock),
            ("vsock_to_tun", |shard| &shard.vsock_to_tun),
        ];
        for (name, direction) in directions {
            let shards: Vec<DirectionSnapshot> = self
                .shards
                .iter()
                .map(|shard| direction(shard).snapshot())
                .collect();
            let sum =
                |value: fn(&DirectionSnapshot) -> u64| -> u64 { shards.iter().map(value).sum() };
            let max = |value: fn(&DirectionSnapshot) -> u64| -> u64 {
                shards.iter().map(value).max().unwrap_or(0)
            };
            let _ = write!(
                line,
                " {name}_packets={} {name}_bytes={} {name}_writes={} {name}_write_us={} \
                 {name}_large_packets={} {name}_segments={} \
                 {name}_max_packet_bytes={} {name}_write_max_us={}",
                sum(|shard| shard.packets),
                sum(|shard| shard.bytes),
                sum(|shard| shard.writes),
                sum(|shard| shard.write_micros),
                sum(|shard| shard.large_packets),
                sum(|shard| shard.segments),
                max(|shard| shard.max_packet_bytes),
                max(|shard| shard.longest_write_micros),
            );
            for (index, shard) in shards.iter().enumerate() {
                let _ = write!(
                    line,
                    " {name}_packets_shard{index}={} {name}_write_us_shard{index}={}",
                    shard.packets, shard.write_micros,
                );
            }
        }
        line
    }
}

/// Logs `stats` at the `info` level every `interval`, until the task is dropped.
///
/// `info` is the level that `vsocktun` prints without `-v`. So the lines appear when `--stats-interval-ms` asks for
/// them and need no higher verbosity, which would also switch on the session and packet logs.
pub(crate) async fn report(stats: &'static TunnelStats, role: &'static str, interval: Duration) {
    let mut tick = tokio::time::interval(interval);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        let unix_millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|since_epoch| since_epoch.as_millis())
            .unwrap_or(0);
        tracing::info!("{}", stats.render(role, unix_millis, process_cpu_millis()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_sums_the_shards_and_lists_each() {
        let stats = TunnelStats::new(2, true);
        stats.record_session();
        stats.record_session();
        stats.record_session_error();
        stats.record_connect_failure();
        stats.record_connect_failure();
        stats.record_connect_failure();
        let micros = Duration::from_micros;
        let shard = |index| stats.shard(index).expect("packets are counted");
        shard(0).tun_to_vsock.record_packet(1_000, 1, 1, micros(40));
        shard(1)
            .tun_to_vsock
            .record_packet(60_000, 44, 3, micros(900));
        shard(1).tun_to_vsock.record_packet(500, 1, 1, micros(10));
        shard(1).vsock_to_tun.record_packet(1_500, 1, 1, micros(7));

        assert_eq!(
            stats.render("enclave", 1_700_000_000_000, Some((1_230, 4_560))),
            "VSOCKTUN_STATS_V1 role=enclave t_ms=1700000000000 shards=2 sessions=2 \
             session_errors=1 connect_failures=3 cpu_user_ms=1230 cpu_system_ms=4560 \
             tun_to_vsock_packets=3 tun_to_vsock_bytes=61500 tun_to_vsock_writes=5 \
             tun_to_vsock_write_us=950 tun_to_vsock_large_packets=1 tun_to_vsock_segments=46 \
             tun_to_vsock_max_packet_bytes=60000 tun_to_vsock_write_max_us=900 \
             tun_to_vsock_packets_shard0=1 tun_to_vsock_write_us_shard0=40 \
             tun_to_vsock_packets_shard1=2 tun_to_vsock_write_us_shard1=910 \
             vsock_to_tun_packets=1 vsock_to_tun_bytes=1500 vsock_to_tun_writes=1 \
             vsock_to_tun_write_us=7 vsock_to_tun_large_packets=0 vsock_to_tun_segments=1 \
             vsock_to_tun_max_packet_bytes=1500 vsock_to_tun_write_max_us=7 \
             vsock_to_tun_packets_shard0=0 vsock_to_tun_write_us_shard0=0 \
             vsock_to_tun_packets_shard1=1 vsock_to_tun_write_us_shard1=7"
        );
    }

    #[test]
    fn longest_write_covers_one_report_interval_and_totals_do_not() {
        let stats = TunnelStats::new(1, true);
        let shard = stats.shard(0).expect("packets are counted");
        shard
            .tun_to_vsock
            .record_packet(100, 1, 1, Duration::from_micros(800));
        let first = stats.render("parent", 0, None);
        assert!(first.contains(" tun_to_vsock_write_max_us=800 "));
        assert!(!first.contains("cpu_user_ms"));

        shard
            .tun_to_vsock
            .record_packet(100, 1, 1, Duration::from_micros(30));
        let second = stats.render("parent", 0, None);
        assert!(second.contains(" tun_to_vsock_write_max_us=30 "));
        assert!(second.contains(" tun_to_vsock_write_us=830 "));

        assert!(
            stats
                .render("parent", 0, None)
                .contains(" tun_to_vsock_write_max_us=0 ")
        );
    }

    #[test]
    fn write_time_keeps_the_parts_below_a_microsecond() {
        let stats = TunnelStats::new(1, true);
        let shard = stats.shard(0).expect("packets are counted");
        for _ in 0..1_000 {
            shard
                .tun_to_vsock
                .record_packet(100, 1, 1, Duration::from_nanos(1_900));
        }
        let line = stats.render("parent", 0, None);
        assert!(line.contains(" tun_to_vsock_write_us=1900 "), "{line}");
        assert!(
            line.contains(" tun_to_vsock_write_us_shard0=1900"),
            "{line}"
        );
        assert!(line.contains(" tun_to_vsock_write_max_us=1 "), "{line}");
    }

    #[test]
    fn no_shard_counters_without_packet_counters() {
        let stats = TunnelStats::new(2, false);
        assert!(stats.shard(0).is_none());
        stats.record_session();
        let line = stats.render("parent", 0, None);
        assert!(line.contains(" sessions=1 "), "{line}");
        assert!(line.contains(" tun_to_vsock_packets=0 "), "{line}");
    }

    /// Builds a frame with a virtio-net header, then an IPv4 header and a TCP header of 20 bytes each, then
    /// `payload` bytes. `hdr_len` is the value of that field of the virtio-net header.
    fn frame(gso_type: u8, gso_size: u16, hdr_len: u16, payload: usize) -> Vec<u8> {
        const HEADERS: usize = 40;
        let mut frame = vec![0_u8; VIRTIO_NET_HDR_LEN + HEADERS + payload];
        frame[1] = gso_type;
        frame[2..4].copy_from_slice(&hdr_len.to_ne_bytes());
        frame[4..6].copy_from_slice(&gso_size.to_ne_bytes());
        let packet = &mut frame[VIRTIO_NET_HDR_LEN..];
        packet[0] = 0x45; // IPv4, header of 5 * 4 bytes
        packet[9] = 6; // TCP
        packet[20 + 12] = 0x50; // TCP header of 5 * 4 bytes
        frame
    }

    #[test]
    fn segments_follow_the_virtio_net_header() {
        // VIRTIO_NET_HDR_GSO_TCPV4 in linux/virtio_net.h.
        const TCPV4: u8 = 1;
        // 40 bytes of headers, then payload cut into pieces of 1,448 bytes.
        let segments = |frame: Vec<u8>| segments_in_frame(&frame, true);
        assert_eq!(segments(frame(TCPV4, 1_448, 40, 1_448 * 44)), 44);
        assert_eq!(segments(frame(TCPV4, 1_448, 40, 1_448 * 44 + 1)), 45);
        assert_eq!(
            segments(frame(TCPV4 | GSO_ECN_FLAG, 1_448, 40, 1_448 * 2)),
            2
        );
        assert_eq!(segments(frame(TCPV4, 1_448, 40, 100)), 1);
        // The kernel did not batch.
        assert_eq!(segments(frame(GSO_NONE, 0, 40, 1_448)), 1);
        // No virtio-net header on this tunnel: the same bytes are one packet.
        assert_eq!(
            segments_in_frame(&frame(TCPV4, 1_448, 40, 1_448 * 44), false),
            1
        );
        // Damaged frames count as one segment.
        assert_eq!(segments(vec![0_u8; 3]), 1);
        assert_eq!(segments(frame(TCPV4, 0, 40, 5_000)), 1);
    }

    #[test]
    fn segments_do_not_depend_on_the_hdr_len_field() {
        const TCPV4: u8 = 1;
        let segments = |frame: Vec<u8>| segments_in_frame(&frame, true);
        // Linux sets `hdr_len` to the length of the part of the packet that it holds in one piece. Here that part
        // is the whole packet, payload included.
        let whole_packet = 40 + 1_448 * 4;
        assert_eq!(segments(frame(TCPV4, 1_448, whole_packet, 1_448 * 4)), 4);
        assert_eq!(segments(frame(TCPV4, 1_448, 0, 1_448 * 4)), 4);
        // IP and TCP options make the headers longer than 40 bytes.
        let mut with_options = frame(TCPV4, 1_448, 40, 12 + 1_448 * 2);
        with_options[VIRTIO_NET_HDR_LEN + 20 + 12] = 0x80; // TCP header of 8 * 4 bytes
        assert_eq!(segments(with_options), 2);
    }

    #[test]
    fn segments_of_other_packets_fall_back_to_the_hdr_len_field() {
        const TCPV6: u8 = 4;
        let mut ipv6 = frame(TCPV6, 1_000, 60, 20 + 3_000);
        ipv6[VIRTIO_NET_HDR_LEN] = 0x60;
        assert_eq!(segments_in_frame(&ipv6, true), 3);
        assert_eq!(ipv4_header_bytes(&[0x45, 0, 0]), None);
        // A UDP header has 8 bytes.
        let mut udp = [0_u8; 28];
        udp[0] = 0x45;
        udp[9] = 17;
        assert_eq!(ipv4_header_bytes(&udp), Some(28));
    }

    #[test]
    fn process_cpu_time_is_read_after_the_process_name() {
        // The name holds a space and a parenthesis.
        let stat = "4242 (vsock tun) x) S 1 4242 4242 0 -1 4194560 100 0 0 0 123 456 0 0 20 0 9 0";
        assert_eq!(parse_process_cpu_millis(stat), Some((1_230, 4_560)));
        assert_eq!(parse_process_cpu_millis("4242 (vsocktun) S 1 2"), None);
        assert_eq!(parse_process_cpu_millis("no parenthesis"), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn process_cpu_time_of_this_process_is_available() {
        assert!(process_cpu_millis().is_some());
    }
}
