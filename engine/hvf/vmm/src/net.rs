//! User-mode networking for a virtio-net port, in the spirit of QEMU's slirp
//! and the Android Emulator. The guest sees one Ethernet segment,
//! 10.0.2.0/24:
//!
//! - 10.0.2.2, the gateway, which is also the Mac itself (its 127.0.0.1, as
//!   in the Android Emulator),
//! - 10.0.2.3, the DNS server; queries go on to the Mac's resolver
//!   (/etc/resolv.conf),
//! - 10.0.2.15, the guest, leased over DHCP.
//!
//! Guest TCP connections end in smoltcp and each goes on over a socket the
//! engine opens like any Mac app would, so the Mac's routes, VPN and firewall
//! apply and nothing needs privileges or an entitlement (vmnet does). The
//! guest gets its SYN-ACK only once the Mac's connection is up, so a refused
//! or unreachable destination looks refused to the guest too. UDP goes
//! datagram by datagram through one host socket per guest port, ICMP echo
//! through the Mac's unprivileged ICMP socket. No ports are opened on the Mac.

use crate::link::{LINK, Lane};
use crate::virtio::net::{Downlink, Uplink};
use mio::net::{TcpStream, UdpSocket};
use mio::{Events, Interest, Poll, Token, Waker};
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::socket::tcp;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, IpListenEndpoint};
use std::collections::{HashMap, VecDeque};
use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, SocketAddrV4};
use std::os::fd::FromRawFd;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const GATEWAY: Ipv4Addr = Ipv4Addr::new(10, 0, 2, 2);
pub const DNS: Ipv4Addr = Ipv4Addr::new(10, 0, 2, 3);
const FIRST_GUEST: Ipv4Addr = Ipv4Addr::new(10, 0, 2, 15);
const NETMASK: Ipv4Addr = Ipv4Addr::new(255, 255, 255, 0);
const SUBNET_BROADCAST: Ipv4Addr = Ipv4Addr::new(10, 0, 2, 255);
const GATEWAY_MAC: [u8; 6] = [0x52, 0x55, 0x0a, 0x00, 0x02, 0x02];
const BROADCAST_MAC: [u8; 6] = [0xff; 6];
const MTU: usize = 1500;
const LEASE_SECONDS: u32 = 24 * 3600;

const ETHERTYPE_IPV4: u16 = 0x0800;
const ETHERTYPE_ARP: u16 = 0x0806;
const PROTOCOL_ICMP: u8 = 1;
const PROTOCOL_TCP: u8 = 6;
const PROTOCOL_UDP: u8 = 17;

const WAKER: Token = Token(0);
const ICMP: Token = Token(1);
const FIRST_FLOW: usize = 2;
const MAX_TCP: usize = 2048;
const MAX_UDP: usize = 1024;
/// smoltcp's buffers per connection: what the guest sends, what it receives.
const TCP_RX_BUFFER: usize = 128 * 1024;
const TCP_TX_BUFFER: usize = 256 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(90);
const UDP_TIMEOUT: Duration = Duration::from_secs(120);
const DNS_TIMEOUT: Duration = Duration::from_secs(15);
const PING_TIMEOUT: Duration = Duration::from_secs(30);

/// The network behind one port; frames reach it through [`Network::uplink`].
pub struct Network {
    inbox: Arc<Mutex<Vec<Vec<u8>>>>,
    waker: Arc<Waker>,
}

impl Network {
    /// Starts the network thread; it answers the guest through `downlink`.
    pub fn start(downlink: Downlink) -> Result<Network, String> {
        let error = |e: std::io::Error| format!("network: {e}");
        let poll = Poll::new().map_err(error)?;
        let waker = Arc::new(Waker::new(poll.registry(), WAKER).map_err(error)?);
        let inbox = Arc::new(Mutex::new(Vec::new()));
        let stack = Stack::new(poll, downlink, inbox.clone());
        std::thread::Builder::new().name("avo-net".into()).spawn(move || stack.run()).map_err(error)?;
        Ok(Network { inbox, waker })
    }

    /// Where the port sends the guest's frames.
    pub fn uplink(&self) -> Uplink {
        let (inbox, waker) = (self.inbox.clone(), self.waker.clone());
        Box::new(move |frames| {
            let mut queue = inbox.lock().unwrap();
            let idle = queue.is_empty();
            queue.extend(frames);
            drop(queue);
            if idle {
                let _ = waker.wake();
            }
        })
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct FlowKey {
    guest: SocketAddrV4,
    remote: SocketAddrV4,
}

struct TcpFlow {
    key: FlowKey,
    socket: SocketHandle,
    host: TcpStream,
    since: Instant,
    connected: bool,
    readable: bool,
    writable: bool,
    /// The host closed its side; the guest gets a FIN after the data.
    host_done: bool,
    /// The guest's FIN went on to the host.
    guest_done: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct UdpKey {
    guest: SocketAddrV4,
    /// Sent to 10.0.2.3:53: answers come back from there.
    dns: bool,
}

struct UdpFlow {
    key: UdpKey,
    socket: UdpSocket,
    last: Instant,
}

/// smoltcp's side of the stack: IP packets in and out (Ethernet, ARP and
/// DHCP are handled here, so smoltcp never answers ARP for the guest's
/// own address, which any-IP mode would).
#[derive(Default)]
struct Packets {
    rx: VecDeque<Vec<u8>>,
    tx: Vec<Vec<u8>>,
}

struct Rx(Vec<u8>);
struct Tx<'a>(&'a mut Vec<Vec<u8>>);

impl RxToken for Rx {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}

impl TxToken for Tx<'_> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut packet = vec![0; len];
        let result = f(&mut packet);
        self.0.push(packet);
        result
    }
}

impl Device for Packets {
    type RxToken<'a> = Rx;
    type TxToken<'a> = Tx<'a>;

    fn receive(&mut self, _: smoltcp::time::Instant) -> Option<(Rx, Tx<'_>)> {
        let packet = self.rx.pop_front()?;
        Some((Rx(packet), Tx(&mut self.tx)))
    }

    fn transmit(&mut self, _: smoltcp::time::Instant) -> Option<Tx<'_>> {
        Some(Tx(&mut self.tx))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = MTU;
        caps
    }
}

struct Stack {
    poll: Poll,
    inbox: Arc<Mutex<Vec<Vec<u8>>>>,
    downlink: Downlink,
    clock: Instant,
    iface: Interface,
    device: Packets,
    sockets: SocketSet<'static>,
    /// DHCP leases, in the order they were given.
    leases: Vec<([u8; 6], Ipv4Addr)>,
    /// Guest addresses and the MAC each was last seen with.
    neighbors: HashMap<Ipv4Addr, [u8; 6]>,
    tcp: HashMap<Token, TcpFlow>,
    tcp_keys: HashMap<FlowKey, Token>,
    udp: HashMap<Token, UdpFlow>,
    udp_keys: HashMap<UdpKey, Token>,
    icmp: Option<UdpSocket>,
    /// Echo identifier to the guest address that is pinging with it.
    pings: HashMap<u16, (Ipv4Addr, Instant)>,
    next_token: usize,
    ip_id: u16,
    /// Frames for the guest, delivered once per round.
    out: Vec<Vec<u8>>,
    /// The link's two directions while its speed or delay is limited (link.rs).
    up: Lane,
    down: Lane,
}

impl Stack {
    fn new(poll: Poll, downlink: Downlink, inbox: Arc<Mutex<Vec<Vec<u8>>>>) -> Stack {
        let mut device = Packets::default();
        let mut config = Config::new(HardwareAddress::Ip);
        config.random_seed = random_seed();
        let mut iface = Interface::new(config, &mut device, smoltcp::time::Instant::from_micros(0));
        iface.update_ip_addrs(|addrs| {
            let _ = addrs.push(IpCidr::new(IpAddress::Ipv4(GATEWAY), 24));
        });
        let _ = iface.routes_mut().add_default_ipv4_route(GATEWAY);
        iface.set_any_ip(true);
        let mut icmp = icmp_socket().ok();
        if let Some(socket) = icmp.as_mut() {
            if poll.registry().register(socket, ICMP, Interest::READABLE).is_err() {
                icmp = None;
            }
        }
        Stack {
            poll,
            inbox,
            downlink,
            clock: Instant::now(),
            iface,
            device,
            sockets: SocketSet::new(Vec::new()),
            leases: Vec::new(),
            neighbors: HashMap::new(),
            tcp: HashMap::new(),
            tcp_keys: HashMap::new(),
            udp: HashMap::new(),
            udp_keys: HashMap::new(),
            icmp,
            pings: HashMap::new(),
            next_token: FIRST_FLOW,
            ip_id: random_seed() as u16,
            out: Vec::new(),
            up: Lane::default(),
            down: Lane::default(),
        }
    }

    fn now(&self) -> smoltcp::time::Instant {
        smoltcp::time::Instant::from_micros(self.clock.elapsed().as_micros() as i64)
    }

    fn token(&mut self) -> Token {
        self.next_token += 1;
        Token(self.next_token)
    }

    fn run(mut self) {
        let mut events = Events::with_capacity(256);
        let mut housekeeping = Instant::now();
        loop {
            let now = self.now();
            let mut delay = self
                .iface
                .poll_delay(now, &self.sockets)
                .map(|d| Duration::from_micros(d.total_micros()))
                .unwrap_or(Duration::from_secs(1))
                .min(Duration::from_secs(1));
            // A limited link's next frame is due then.
            for next in [self.up.next(), self.down.next()].into_iter().flatten() {
                delay = delay.min(next.saturating_duration_since(Instant::now()));
            }
            if let Err(e) = self.poll.poll(&mut events, Some(delay)) {
                if e.kind() == ErrorKind::Interrupted {
                    continue;
                }
                eprintln!("[vmm] network stopped: {e}");
                return;
            }
            for event in events.iter() {
                let token = event.token();
                let readable = event.is_readable() || event.is_read_closed() || event.is_error();
                let writable = event.is_writable() || event.is_write_closed() || event.is_error();
                if token == WAKER {
                    continue;
                }
                if token == ICMP {
                    self.receive_pings();
                } else if let Some(flow) = self.tcp.get_mut(&token) {
                    flow.readable |= readable;
                    flow.writable |= writable;
                } else if readable {
                    self.receive_udp(token);
                }
            }
            let conditions = LINK.get();
            let mut frames = std::mem::take(&mut *self.inbox.lock().unwrap());
            if !conditions.is_unlimited() || !self.up.is_empty() {
                let now = Instant::now();
                for frame in frames {
                    self.up.push(frame, now, conditions.up_kbps, &conditions);
                }
                frames = self.up.due(now);
            }
            for frame in &frames {
                self.guest_frame(frame);
            }
            self.pump();
            if housekeeping.elapsed() >= Duration::from_secs(1) {
                housekeeping = Instant::now();
                // The port went with its machine (a guest reboot starts
                // another network): the flows' Mac sockets go with this one.
                if Arc::strong_count(&self.inbox) == 1 {
                    return;
                }
                self.expire();
            }
            let mut out = std::mem::take(&mut self.out);
            if !conditions.is_unlimited() || !self.down.is_empty() {
                let now = Instant::now();
                for frame in out {
                    self.down.push(frame, now, conditions.down_kbps, &conditions);
                }
                out = self.down.due(now);
            }
            if !out.is_empty() {
                self.downlink.deliver(out);
            }
        }
    }

    // MARK: Ethernet, ARP, DHCP

    fn guest_frame(&mut self, frame: &[u8]) {
        if frame.len() < 14 {
            return;
        }
        let source: [u8; 6] = frame[6..12].try_into().unwrap();
        match u16::from_be_bytes([frame[12], frame[13]]) {
            ETHERTYPE_ARP => self.arp(source, &frame[14..]),
            ETHERTYPE_IPV4 => self.ipv4(source, &frame[14..]),
            _ => {} // IPv6 and the rest: this network is IPv4 only
        }
    }

    /// Answers "who has" for the gateway and the DNS server, nothing else.
    fn arp(&mut self, source: [u8; 6], packet: &[u8]) {
        if packet.len() < 28 || packet[0..6] != [0, 1, 8, 0, 6, 4] || packet[6..8] != [0, 1] {
            return;
        }
        let sender_ip = Ipv4Addr::new(packet[14], packet[15], packet[16], packet[17]);
        let target_ip = Ipv4Addr::new(packet[24], packet[25], packet[26], packet[27]);
        if target_ip != GATEWAY && target_ip != DNS || sender_ip == target_ip {
            return;
        }
        if !sender_ip.is_unspecified() {
            self.neighbors.insert(sender_ip, source);
        }
        let mut reply = vec![0, 1, 8, 0, 6, 4, 0, 2];
        reply.extend_from_slice(&GATEWAY_MAC);
        reply.extend_from_slice(&target_ip.octets());
        reply.extend_from_slice(&packet[8..14]);
        reply.extend_from_slice(&sender_ip.octets());
        self.out.push(ethernet(source, ETHERTYPE_ARP, &reply));
    }

    fn ipv4(&mut self, source_mac: [u8; 6], data: &[u8]) {
        let Some(packet) = Ipv4::parse(data) else { return };
        if packet.fragment {
            return; // guests send whole datagrams (TCP sets DF; DNS and QUIC fit)
        }
        if !packet.source.is_unspecified() {
            self.neighbors.insert(packet.source, source_mac);
        }
        match packet.protocol {
            PROTOCOL_TCP => self.guest_tcp(&packet, &data[..packet.total]),
            PROTOCOL_UDP => self.guest_udp(&packet),
            PROTOCOL_ICMP => self.guest_ping(&packet),
            _ => {}
        }
    }

    fn lease(&mut self, mac: [u8; 6]) -> Ipv4Addr {
        if let Some((_, ip)) = self.leases.iter().find(|(m, _)| *m == mac) {
            return *ip;
        }
        let ip = Ipv4Addr::from(u32::from(FIRST_GUEST) + self.leases.len() as u32);
        self.leases.push((mac, ip));
        ip
    }

    fn dhcp(&mut self, payload: &[u8]) {
        let Some(request) = DhcpRequest::parse(payload) else { return };
        let lease = self.lease(request.mac);
        let reply = match request.kind {
            DHCP_DISCOVER => DHCP_OFFER,
            DHCP_REQUEST => {
                let wanted = request.requested.or((!request.client_ip.is_unspecified()).then_some(request.client_ip));
                let other_server = request.server.is_some_and(|server| server != GATEWAY);
                if other_server {
                    return;
                }
                if wanted.is_some_and(|ip| ip != lease) { DHCP_NAK } else { DHCP_ACK }
            }
            _ => return, // DECLINE, RELEASE, INFORM: nothing to do
        };
        let message = dhcp_reply(&request, reply, lease);
        let (destination, mac) = if !request.client_ip.is_unspecified() && reply == DHCP_ACK {
            (request.client_ip, request.mac)
        } else {
            (Ipv4Addr::BROADCAST, if request.broadcast { BROADCAST_MAC } else { request.mac })
        };
        let datagram = udp_datagram(SocketAddrV4::new(GATEWAY, 67), SocketAddrV4::new(destination, 68), &message);
        let packets = self.ipv4_packets(GATEWAY, destination, PROTOCOL_UDP, &datagram);
        self.out.extend(packets.into_iter().map(|p| ethernet(mac, ETHERTYPE_IPV4, &p)));
    }

    /// Wraps IP packets for the guest address they are going to.
    fn to_guest(&mut self, packets: Vec<Vec<u8>>) {
        for packet in packets {
            if packet.len() < 20 {
                continue;
            }
            let destination = Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]);
            let mac = self.neighbors.get(&destination).copied().unwrap_or(BROADCAST_MAC);
            self.out.push(ethernet(mac, ETHERTYPE_IPV4, &packet));
        }
    }

    /// One IPv4 packet, or fragments of it when it is larger than the MTU.
    fn ipv4_packets(&mut self, source: Ipv4Addr, destination: Ipv4Addr, protocol: u8, payload: &[u8]) -> Vec<Vec<u8>> {
        self.ip_id = self.ip_id.wrapping_add(1);
        let room = (MTU - 20) & !7;
        let mut packets = Vec::new();
        let mut offset = 0;
        loop {
            let end = (offset + room).min(payload.len());
            let more = end < payload.len();
            let fragment = if offset == 0 && !more { 0x4000 } else { (offset / 8) as u16 | if more { 0x2000 } else { 0 } };
            let mut packet = ipv4_header(source, destination, protocol, end - offset, self.ip_id, fragment);
            packet.extend_from_slice(&payload[offset..end]);
            packets.push(packet);
            if !more {
                return packets;
            }
            offset = end;
        }
    }

    // MARK: TCP

    fn guest_tcp(&mut self, packet: &Ipv4, raw: &[u8]) {
        let segment = packet.payload(raw);
        if segment.len() < 20 {
            return;
        }
        let flags = segment[13];
        let (syn, ack) = (flags & 0x02 != 0, flags & 0x10 != 0);
        if syn && !ack {
            let key = FlowKey {
                guest: SocketAddrV4::new(packet.source, u16::from_be_bytes([segment[0], segment[1]])),
                remote: SocketAddrV4::new(packet.destination, u16::from_be_bytes([segment[2], segment[3]])),
            };
            if let Some(&token) = self.tcp_keys.get(&key) {
                // A retransmitted SYN, or the address pair is reused after a close.
                let state = self.sockets.get::<tcp::Socket>(self.tcp[&token].socket).state();
                if !matches!(state, tcp::State::Listen | tcp::State::SynReceived) {
                    self.close_tcp(token);
                }
            }
            if !self.tcp_keys.contains_key(&key) && self.open_tcp(key) {
                // The new socket takes this SYN before another one listens on
                // the same address.
                self.device.rx.push_back(raw.to_vec());
                let now = self.now();
                self.iface.poll(now, &mut self.device, &mut self.sockets);
                self.flush_tcp();
                return;
            }
        }
        // Everything else, including SYNs nobody serves (smoltcp resets those).
        self.device.rx.push_back(raw.to_vec());
    }

    /// Where a guest connection goes on the Mac; None refuses it.
    fn host_address(remote: SocketAddrV4, dns_port_only: bool) -> Option<SocketAddr> {
        let ip = *remote.ip();
        if ip == GATEWAY {
            return Some(SocketAddr::from((Ipv4Addr::LOCALHOST, remote.port())));
        }
        if ip == DNS {
            return if remote.port() == 53 || !dns_port_only { nameserver() } else { None };
        }
        let private = u32::from(ip) & u32::from(NETMASK) == u32::from(GATEWAY) & u32::from(NETMASK);
        if private || ip.is_unspecified() || ip.is_broadcast() || ip.is_multicast() || ip.is_loopback() {
            return None;
        }
        Some(SocketAddr::V4(remote))
    }

    fn open_tcp(&mut self, key: FlowKey) -> bool {
        if self.tcp.len() >= MAX_TCP {
            return false;
        }
        let Some(address) = Self::host_address(key.remote, true) else { return false };
        let Ok(mut host) = TcpStream::connect(address) else { return false };
        let _ = host.set_nodelay(true);
        let token = self.token();
        if self.poll.registry().register(&mut host, token, Interest::READABLE | Interest::WRITABLE).is_err() {
            return false;
        }
        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0; TCP_RX_BUFFER]),
            tcp::SocketBuffer::new(vec![0; TCP_TX_BUFFER]),
        );
        socket.pause_synack(true);
        socket.set_nagle_enabled(false);
        let endpoint = IpListenEndpoint { addr: Some(IpAddress::Ipv4(*key.remote.ip())), port: key.remote.port() };
        if socket.listen(endpoint).is_err() {
            let _ = self.poll.registry().deregister(&mut host);
            return false;
        }
        let handle = self.sockets.add(socket);
        self.tcp.insert(
            token,
            TcpFlow {
                key,
                socket: handle,
                host,
                since: Instant::now(),
                connected: false,
                readable: false,
                writable: false,
                host_done: false,
                guest_done: false,
            },
        );
        self.tcp_keys.insert(key, token);
        true
    }

    fn close_tcp(&mut self, token: Token) {
        let Some(mut flow) = self.tcp.remove(&token) else { return };
        self.tcp_keys.remove(&flow.key);
        let _ = self.poll.registry().deregister(&mut flow.host);
        self.sockets.remove(flow.socket);
    }

    /// smoltcp's packets out to the guest.
    fn flush_tcp(&mut self) {
        let packets = std::mem::take(&mut self.device.tx);
        self.to_guest(packets);
    }

    /// Runs smoltcp and moves data between its sockets and the Mac's until
    /// neither side has anything more right now.
    fn pump(&mut self) {
        for _ in 0..16 {
            let now = self.now();
            self.iface.poll(now, &mut self.device, &mut self.sockets);
            self.flush_tcp();
            if !self.service_tcp() {
                break;
            }
        }
    }

    /// One pass over every connection; true when something moved.
    fn service_tcp(&mut self) -> bool {
        let mut progress = false;
        let mut finished = Vec::new();
        for (&token, flow) in self.tcp.iter_mut() {
            let socket = self.sockets.get_mut::<tcp::Socket>(flow.socket);
            if !flow.connected {
                if flow.readable || flow.writable {
                    match (flow.host.take_error(), flow.host.peer_addr()) {
                        (Ok(None), Ok(_)) => {
                            flow.connected = true;
                            socket.pause_synack(false);
                            progress = true;
                        }
                        (Ok(None), Err(e)) if e.kind() == ErrorKind::NotConnected => {
                            flow.readable = false;
                            flow.writable = false;
                        }
                        _ => {
                            socket.abort(); // refused or unreachable: RST to the guest
                            progress = true;
                        }
                    }
                } else if flow.since.elapsed() > CONNECT_TIMEOUT {
                    socket.abort();
                    progress = true;
                }
                if !flow.connected {
                    if socket.state() == tcp::State::Closed && socket.remote_endpoint().is_none() {
                        finished.push(token);
                    }
                    continue;
                }
            }

            // Guest to Mac.
            while flow.writable && socket.can_recv() {
                let host = &mut flow.host;
                match socket.recv(|data| match host.write(data) {
                    Ok(n) => (n, Ok(n)),
                    Err(e) => (0, Err(e)),
                }) {
                    Ok(Ok(0)) => break,
                    Ok(Ok(_)) => progress = true,
                    Ok(Err(e)) if e.kind() == ErrorKind::WouldBlock => flow.writable = false,
                    Ok(Err(e)) if e.kind() == ErrorKind::Interrupted => {}
                    Ok(Err(_)) => {
                        socket.abort();
                        progress = true;
                        break;
                    }
                    Err(_) => break,
                }
            }
            let state = socket.state();
            let guest_closed = matches!(state, tcp::State::CloseWait | tcp::State::LastAck | tcp::State::Closing | tcp::State::TimeWait);
            if guest_closed && !flow.guest_done && socket.recv_queue() == 0 {
                let _ = flow.host.shutdown(Shutdown::Write);
                flow.guest_done = true;
            }

            // Mac to guest.
            while flow.readable && !flow.host_done && socket.can_send() {
                let host = &mut flow.host;
                match socket.send(|room| match host.read(room) {
                    Ok(n) => (n, Ok(n)),
                    Err(e) => (0, Err(e)),
                }) {
                    Ok(Ok(0)) => {
                        flow.host_done = true;
                        socket.close();
                        progress = true;
                    }
                    Ok(Ok(_)) => progress = true,
                    Ok(Err(e)) if e.kind() == ErrorKind::WouldBlock => flow.readable = false,
                    Ok(Err(e)) if e.kind() == ErrorKind::Interrupted => {}
                    Ok(Err(_)) => {
                        flow.host_done = true;
                        socket.abort(); // reset by the server: reset the guest too
                        progress = true;
                    }
                    Err(_) => break,
                }
            }

            let state = socket.state();
            if state == tcp::State::TimeWait || state == tcp::State::Closed && socket.remote_endpoint().is_none() {
                finished.push(token);
            }
        }
        for token in finished {
            self.close_tcp(token);
        }
        progress
    }

    // MARK: UDP

    fn guest_udp(&mut self, packet: &Ipv4) {
        let datagram = &packet.data;
        if datagram.len() < 8 {
            return;
        }
        let source_port = u16::from_be_bytes([datagram[0], datagram[1]]);
        let destination_port = u16::from_be_bytes([datagram[2], datagram[3]]);
        let length = (u16::from_be_bytes([datagram[4], datagram[5]]) as usize).clamp(8, datagram.len());
        let payload = &datagram[8..length];
        if destination_port == 67 {
            return self.dhcp(payload);
        }
        let destination = packet.destination;
        if destination.is_broadcast() || destination == SUBNET_BROADCAST || destination.is_multicast() || packet.source.is_unspecified() {
            return;
        }
        let Some(target) = Self::host_address(SocketAddrV4::new(destination, destination_port), true) else { return };
        let key = UdpKey { guest: SocketAddrV4::new(packet.source, source_port), dns: destination == DNS };
        let token = match self.udp_keys.get(&key) {
            Some(&token) => token,
            None => {
                let Some(token) = self.open_udp(key, &target) else { return };
                token
            }
        };
        let flow = self.udp.get_mut(&token).unwrap();
        flow.last = Instant::now();
        let _ = flow.socket.send_to(payload, target); // a full buffer drops it, as a network would
    }

    fn open_udp(&mut self, key: UdpKey, target: &SocketAddr) -> Option<Token> {
        if self.udp.len() >= MAX_UDP {
            let oldest = self.udp.iter().min_by_key(|(_, flow)| flow.last).map(|(token, _)| *token)?;
            self.close_udp(oldest);
        }
        let bind: SocketAddr = if target.is_ipv4() { (Ipv4Addr::UNSPECIFIED, 0).into() } else { (std::net::Ipv6Addr::UNSPECIFIED, 0).into() };
        let mut socket = UdpSocket::bind(bind).ok()?;
        let token = self.token();
        self.poll.registry().register(&mut socket, token, Interest::READABLE).ok()?;
        self.udp.insert(token, UdpFlow { key, socket, last: Instant::now() });
        self.udp_keys.insert(key, token);
        Some(token)
    }

    fn close_udp(&mut self, token: Token) {
        if let Some(mut flow) = self.udp.remove(&token) {
            self.udp_keys.remove(&flow.key);
            let _ = self.poll.registry().deregister(&mut flow.socket);
        }
    }

    fn receive_udp(&mut self, token: Token) {
        let mut buffer = vec![0u8; 65536];
        loop {
            let Some(flow) = self.udp.get_mut(&token) else { return };
            let (len, from) = match flow.socket.recv_from(&mut buffer) {
                Ok(received) => received,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return, // WouldBlock, or an ICMP error for an earlier datagram
            };
            flow.last = Instant::now();
            let key = flow.key;
            let source = if key.dns {
                SocketAddrV4::new(DNS, 53)
            } else {
                match from {
                    SocketAddr::V4(from) if from.ip().is_loopback() => SocketAddrV4::new(GATEWAY, from.port()),
                    SocketAddr::V4(from) => from,
                    SocketAddr::V6(_) => continue,
                }
            };
            let datagram = udp_datagram(source, key.guest, &buffer[..len]);
            let packets = self.ipv4_packets(*source.ip(), *key.guest.ip(), PROTOCOL_UDP, &datagram);
            self.to_guest(packets);
        }
    }

    // MARK: ICMP echo

    fn guest_ping(&mut self, packet: &Ipv4) {
        let message = &packet.data;
        if message.len() < 8 || message[0] != 8 {
            return; // only echo requests; the guest's errors stay in the guest
        }
        let Some(icmp) = self.icmp.as_ref() else { return };
        let destination = packet.destination;
        let target = if destination == GATEWAY || destination == DNS {
            Ipv4Addr::LOCALHOST
        } else if Self::host_address(SocketAddrV4::new(destination, 0), false).is_some() {
            destination
        } else {
            return;
        };
        let id = u16::from_be_bytes([message[4], message[5]]);
        self.pings.insert(id, (packet.source, Instant::now()));
        let _ = icmp.send_to(message, SocketAddr::from((target, 0)));
    }

    fn receive_pings(&mut self) {
        let mut buffer = vec![0u8; 65536];
        loop {
            let Some(icmp) = self.icmp.as_ref() else { return };
            let (len, from) = match icmp.recv_from(&mut buffer) {
                Ok(received) => received,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return,
            };
            // macOS hands over the IP header too.
            let mut message = &buffer[..len];
            if message.first().is_some_and(|b| b >> 4 == 4) {
                let header = ((message[0] & 0x0f) as usize) * 4;
                if message.len() < header {
                    continue;
                }
                message = &message[header..];
            }
            if message.len() < 8 || message[0] != 0 {
                continue;
            }
            let id = u16::from_be_bytes([message[4], message[5]]);
            let Some(&(guest, _)) = self.pings.get(&id) else { continue };
            let source = match from {
                SocketAddr::V4(from) if from.ip().is_loopback() => GATEWAY,
                SocketAddr::V4(from) => *from.ip(),
                SocketAddr::V6(_) => continue,
            };
            let mut reply = message.to_vec();
            reply[2] = 0;
            reply[3] = 0;
            let sum = checksum(&reply, 0);
            reply[2..4].copy_from_slice(&sum.to_be_bytes());
            let packets = self.ipv4_packets(source, guest, PROTOCOL_ICMP, &reply);
            self.to_guest(packets);
        }
    }

    // MARK: Housekeeping

    fn expire(&mut self) {
        let idle: Vec<Token> = self
            .udp
            .iter()
            .filter(|(_, flow)| flow.last.elapsed() > if flow.key.dns { DNS_TIMEOUT } else { UDP_TIMEOUT })
            .map(|(token, _)| *token)
            .collect();
        for token in idle {
            self.close_udp(token);
        }
        self.pings.retain(|_, (_, since)| since.elapsed() < PING_TIMEOUT);
    }
}

/// The parts of an IPv4 header this stack uses, and the payload.
struct Ipv4 {
    source: Ipv4Addr,
    destination: Ipv4Addr,
    protocol: u8,
    fragment: bool,
    header: usize,
    total: usize,
    data: Vec<u8>,
}

impl Ipv4 {
    fn parse(data: &[u8]) -> Option<Ipv4> {
        if data.len() < 20 || data[0] >> 4 != 4 {
            return None;
        }
        let header = ((data[0] & 0x0f) as usize) * 4;
        let total = u16::from_be_bytes([data[2], data[3]]) as usize;
        if header < 20 || total < header || total > data.len() || checksum(&data[..header], 0) != 0 {
            return None;
        }
        let flags = u16::from_be_bytes([data[6], data[7]]);
        Some(Ipv4 {
            source: Ipv4Addr::new(data[12], data[13], data[14], data[15]),
            destination: Ipv4Addr::new(data[16], data[17], data[18], data[19]),
            protocol: data[9],
            fragment: flags & 0x2000 != 0 || flags & 0x1fff != 0,
            header,
            total,
            data: data[header..total].to_vec(),
        })
    }

    fn payload<'a>(&self, raw: &'a [u8]) -> &'a [u8] {
        &raw[self.header..self.total]
    }
}

fn ipv4_header(source: Ipv4Addr, destination: Ipv4Addr, protocol: u8, payload: usize, id: u16, fragment: u16) -> Vec<u8> {
    let mut header = Vec::with_capacity(20 + payload);
    header.extend_from_slice(&[0x45, 0]);
    header.extend_from_slice(&((20 + payload) as u16).to_be_bytes());
    header.extend_from_slice(&id.to_be_bytes());
    header.extend_from_slice(&fragment.to_be_bytes());
    header.extend_from_slice(&[64, protocol, 0, 0]);
    header.extend_from_slice(&source.octets());
    header.extend_from_slice(&destination.octets());
    let sum = checksum(&header, 0);
    header[10..12].copy_from_slice(&sum.to_be_bytes());
    header
}

/// A UDP header and payload, checksummed.
fn udp_datagram(source: SocketAddrV4, destination: SocketAddrV4, payload: &[u8]) -> Vec<u8> {
    let length = (8 + payload.len()) as u16;
    let mut datagram = Vec::with_capacity(length as usize);
    datagram.extend_from_slice(&source.port().to_be_bytes());
    datagram.extend_from_slice(&destination.port().to_be_bytes());
    datagram.extend_from_slice(&length.to_be_bytes());
    datagram.extend_from_slice(&[0, 0]);
    datagram.extend_from_slice(payload);
    let mut pseudo = Vec::with_capacity(12);
    pseudo.extend_from_slice(&source.ip().octets());
    pseudo.extend_from_slice(&destination.ip().octets());
    pseudo.extend_from_slice(&[0, PROTOCOL_UDP]);
    pseudo.extend_from_slice(&length.to_be_bytes());
    let sum = match checksum(&datagram, sum16(&pseudo, 0)) {
        0 => 0xffff,
        sum => sum,
    };
    datagram[6..8].copy_from_slice(&sum.to_be_bytes());
    datagram
}

fn ethernet(destination: [u8; 6], ethertype: u16, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(14 + payload.len());
    frame.extend_from_slice(&destination);
    frame.extend_from_slice(&GATEWAY_MAC);
    frame.extend_from_slice(&ethertype.to_be_bytes());
    frame.extend_from_slice(payload);
    frame
}

fn sum16(data: &[u8], mut sum: u32) -> u32 {
    let mut chunks = data.chunks_exact(2);
    for pair in &mut chunks {
        sum += u16::from_be_bytes([pair[0], pair[1]]) as u32;
    }
    if let [last] = chunks.remainder() {
        sum += (*last as u32) << 8;
    }
    sum
}

/// The Internet checksum of `data` on top of a partial sum.
fn checksum(data: &[u8], partial: u32) -> u16 {
    let mut sum = sum16(data, partial);
    while sum > 0xffff {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

const DHCP_DISCOVER: u8 = 1;
const DHCP_OFFER: u8 = 2;
const DHCP_REQUEST: u8 = 3;
const DHCP_ACK: u8 = 5;
const DHCP_NAK: u8 = 6;
const DHCP_COOKIE: [u8; 4] = [99, 130, 83, 99];

struct DhcpRequest {
    kind: u8,
    xid: [u8; 4],
    flags: [u8; 2],
    broadcast: bool,
    client_ip: Ipv4Addr,
    chaddr: [u8; 16],
    mac: [u8; 6],
    requested: Option<Ipv4Addr>,
    server: Option<Ipv4Addr>,
}

impl DhcpRequest {
    fn parse(message: &[u8]) -> Option<DhcpRequest> {
        if message.len() < 240 || message[0] != 1 || message[1] != 1 || message[2] != 6 || message[236..240] != DHCP_COOKIE {
            return None;
        }
        let ip = |at: usize| Ipv4Addr::new(message[at], message[at + 1], message[at + 2], message[at + 3]);
        let mut request = DhcpRequest {
            kind: 0,
            xid: message[4..8].try_into().unwrap(),
            flags: [message[10], message[11]],
            broadcast: message[10] & 0x80 != 0,
            client_ip: ip(12),
            chaddr: message[28..44].try_into().unwrap(),
            mac: message[28..34].try_into().unwrap(),
            requested: None,
            server: None,
        };
        let mut at = 240;
        while at < message.len() {
            let code = message[at];
            if code == 255 {
                break;
            }
            if code == 0 {
                at += 1;
                continue;
            }
            let len = *message.get(at + 1)? as usize;
            let value = message.get(at + 2..at + 2 + len)?;
            match (code, len) {
                (53, 1) => request.kind = value[0],
                (50, 4) => request.requested = Some(Ipv4Addr::new(value[0], value[1], value[2], value[3])),
                (54, 4) => request.server = Some(Ipv4Addr::new(value[0], value[1], value[2], value[3])),
                _ => {}
            }
            at += 2 + len;
        }
        Some(request)
    }
}

fn dhcp_reply(request: &DhcpRequest, kind: u8, lease: Ipv4Addr) -> Vec<u8> {
    let mut message = vec![0u8; 236];
    message[0] = 2; // BOOTREPLY
    message[1] = 1;
    message[2] = 6;
    message[4..8].copy_from_slice(&request.xid);
    message[10..12].copy_from_slice(&request.flags);
    message[12..16].copy_from_slice(&request.client_ip.octets());
    if kind != DHCP_NAK {
        message[16..20].copy_from_slice(&lease.octets());
    }
    message[28..44].copy_from_slice(&request.chaddr);
    message.extend_from_slice(&DHCP_COOKIE);
    let mut option = |code: u8, value: &[u8]| {
        message.push(code);
        message.push(value.len() as u8);
        message.extend_from_slice(value);
    };
    option(53, &[kind]);
    option(54, &GATEWAY.octets());
    if kind != DHCP_NAK {
        option(51, &LEASE_SECONDS.to_be_bytes());
        option(58, &(LEASE_SECONDS / 2).to_be_bytes());
        option(59, &(LEASE_SECONDS / 8 * 7).to_be_bytes());
        option(1, &NETMASK.octets());
        option(3, &GATEWAY.octets());
        option(6, &DNS.octets());
        option(28, &SUBNET_BROADCAST.octets());
        option(26, &(MTU as u16).to_be_bytes());
    }
    message.push(255);
    message.resize(message.len().max(300), 0);
    message
}

/// The Mac's DNS server, from /etc/resolv.conf (read for every new query flow,
/// so it follows network changes).
fn nameserver() -> Option<SocketAddr> {
    let text = std::fs::read_to_string("/etc/resolv.conf").ok()?;
    let servers: Vec<IpAddr> = text
        .lines()
        .filter_map(|line| line.trim().strip_prefix("nameserver"))
        .filter_map(|value| value.trim().parse().ok())
        .collect();
    let server = servers.iter().find(|ip| ip.is_ipv4()).or(servers.first())?;
    Some(SocketAddr::new(*server, 53))
}

/// macOS lets any process send ICMP echo through a datagram socket.
fn icmp_socket() -> std::io::Result<UdpSocket> {
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, libc::IPPROTO_ICMP) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let socket = unsafe { std::net::UdpSocket::from_raw_fd(fd) };
    socket.set_nonblocking(true)?;
    Ok(UdpSocket::from_std(socket))
}

fn random_seed() -> u64 {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0);
    nanos ^ (std::process::id() as u64) << 32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksums_verify() {
        let header = ipv4_header(GATEWAY, FIRST_GUEST, PROTOCOL_UDP, 8, 1, 0x4000);
        assert_eq!(checksum(&header, 0), 0);
        let packet = Ipv4::parse(&[header, vec![0; 8]].concat()).unwrap();
        assert_eq!((packet.source, packet.destination, packet.protocol, packet.fragment), (GATEWAY, FIRST_GUEST, PROTOCOL_UDP, false));
        // A UDP datagram checks out against its pseudo-header.
        let datagram = udp_datagram(SocketAddrV4::new(DNS, 53), SocketAddrV4::new(FIRST_GUEST, 5000), b"odd");
        let mut pseudo = DNS.octets().to_vec();
        pseudo.extend_from_slice(&FIRST_GUEST.octets());
        pseudo.extend_from_slice(&[0, PROTOCOL_UDP, 0, datagram.len() as u8]);
        assert_eq!(checksum(&datagram, sum16(&pseudo, 0)), 0);
    }

    #[test]
    fn dhcp_offers_the_lease_with_gateway_and_dns() {
        let mut discover = vec![0u8; 240];
        discover[0..3].copy_from_slice(&[1, 1, 6]);
        discover[4..8].copy_from_slice(&[1, 2, 3, 4]);
        discover[28..34].copy_from_slice(&[2, 0, 0, 0x55, 0x54, 1]);
        discover[236..240].copy_from_slice(&DHCP_COOKIE);
        discover.extend_from_slice(&[53, 1, DHCP_DISCOVER, 255]);
        let request = DhcpRequest::parse(&discover).unwrap();
        assert_eq!((request.kind, request.mac), (DHCP_DISCOVER, [2, 0, 0, 0x55, 0x54, 1]));
        let offer = dhcp_reply(&request, DHCP_OFFER, FIRST_GUEST);
        assert_eq!(&offer[16..20], &FIRST_GUEST.octets());
        assert_eq!(&offer[4..8], &[1, 2, 3, 4]);
        let options = &offer[240..];
        assert_eq!(&options[..3], &[53, 1, DHCP_OFFER]);
        let find = |code: u8| {
            let mut at = 0;
            while options[at] != 255 {
                if options[at] == code {
                    return Some(options[at + 2..at + 2 + options[at + 1] as usize].to_vec());
                }
                at += 2 + options[at + 1] as usize;
            }
            None
        };
        assert_eq!(find(3), Some(GATEWAY.octets().to_vec()));
        assert_eq!(find(6), Some(DNS.octets().to_vec()));
        assert_eq!(find(1), Some(NETMASK.octets().to_vec()));
    }

    #[test]
    fn large_packets_are_fragmented() {
        let downlink = crate::virtio::net::Net::new([2, 0, 0, 0, 0, 1]).downlink();
        let stack = &mut Stack::new(Poll::new().unwrap(), downlink, Arc::new(Mutex::new(Vec::new())));
        let packets = stack.ipv4_packets(DNS, FIRST_GUEST, PROTOCOL_UDP, &vec![7u8; 4000]);
        assert_eq!(packets.len(), 3);
        let mut offset = 0;
        for (i, packet) in packets.iter().enumerate() {
            assert!(packet.len() <= MTU);
            let flags = u16::from_be_bytes([packet[6], packet[7]]);
            assert_eq!((flags & 0x1fff) as usize * 8, offset);
            assert_eq!(flags & 0x2000 != 0, i < 2);
            offset += packet.len() - 20;
        }
        assert_eq!(offset, 4000);
    }

    #[test]
    fn the_network_stops_once_its_port_is_gone() {
        let downlink = crate::virtio::net::Net::new([2, 0, 0, 0, 0, 1]).downlink();
        let inbox = Arc::new(Mutex::new(Vec::new()));
        let stack = Stack::new(Poll::new().unwrap(), downlink, inbox.clone());
        let thread = std::thread::spawn(move || stack.run());
        std::thread::sleep(Duration::from_millis(1500));
        assert!(!thread.is_finished(), "runs while the port can send");
        drop(inbox);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !thread.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(thread.is_finished());
    }
}
