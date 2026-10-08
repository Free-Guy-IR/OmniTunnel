package main

import (
	"context"
	"encoding/binary"
	"flag"
	"fmt"
	"hash/crc32"
	"io"
	"math/rand/v2"
	"net"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	magic     = 0x5342
	ver       = 1
	hdrFixed  = 30
	sackBytes = 64
	sackBits  = sackBytes * 8
	tailSize  = 6
	crcSize   = 4
	headerLen = hdrFixed + sackBytes + tailSize + crcSize
	maxChunk  = 16000

	hardWireCap = 8760
	maxPayload  = hardWireCap - headerLen

	tunsetiff = 0x400454ca
	iffTun    = 0x0001
	iffNoPI   = 0x1000

	tcpFastopen        = 23
	tcpFastopenConnect = 30
)

type ifreq struct {
	name  [16]byte
	flags uint16
	pad   [22]byte
}

func openTun(name string) (*os.File, error) {
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	var ifr ifreq
	copy(ifr.name[:], name)
	ifr.flags = iffTun | iffNoPI
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), tunsetiff, uintptr(unsafe.Pointer(&ifr)))
	if errno != 0 {
		syscall.Close(fd)
		return nil, errno
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	return os.NewFile(uintptr(fd), "tun"), nil
}

func run(args ...string) {
	cmd := exec.Command("ip", args...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	_ = cmd.Run()
}

func configTun(name string, mtu, txq int, addr, peer string) {
	run("addr", "flush", "dev", name)
	if peer != "" {
		run("addr", "add", addr, "peer", peer, "dev", name)
	} else {
		run("addr", "add", addr, "dev", name)
	}
	run("link", "set", name, "txqueuelen", fmt.Sprint(txq))
	run("link", "set", name, "mtu", fmt.Sprint(mtu), "up")
}

type sEntry struct {
	buf    []byte
	sentAt time.Time
	tries  int
}

type Sender struct {
	mu       sync.Mutex
	nextSeq  uint64
	inflight map[uint64]*sEntry
	inq      map[uint64]bool
	q        chan uint64
	window   int
	rto      time.Duration
	maxTries int
	gaveup   int64
}

func newSender(window int, rto time.Duration, maxTries int) *Sender {
	return &Sender{
		nextSeq:  1,
		inflight: make(map[uint64]*sEntry),
		inq:      make(map[uint64]bool),
		q:        make(chan uint64, window*8+64),
		window:   window,
		rto:      rto,
		maxTries: maxTries,
	}
}

func (s *Sender) canAccept() bool {
	s.mu.Lock()
	ok := len(s.inflight) < s.window
	s.mu.Unlock()
	return ok
}

func (s *Sender) addChunk(buf []byte) {
	s.mu.Lock()
	seq := s.nextSeq
	s.nextSeq++
	s.inflight[seq] = &sEntry{buf: buf}
	s.inq[seq] = true
	s.mu.Unlock()
	s.q <- seq
}

func (s *Sender) getSend(timeout time.Duration) (uint64, []byte) {
	var seq uint64
	if timeout <= 0 {
		select {
		case seq = <-s.q:
		default:
			return 0, nil
		}
	} else {
		t := time.NewTimer(timeout)
		select {
		case seq = <-s.q:
			t.Stop()
		case <-t.C:
			return 0, nil
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.inq, seq)
	e := s.inflight[seq]
	if e == nil {
		return 0, nil
	}
	e.sentAt = time.Now()
	e.tries++
	return seq, e.buf
}

func (s *Sender) applyAck(cum, base uint64, bits []byte) {
	s.mu.Lock()
	if cum > 0 {
		for seq := range s.inflight {
			if seq <= cum {
				delete(s.inflight, seq)
			}
		}
	}
	for seq := range s.inflight {
		if seq >= base {
			d := seq - base
			if d < sackBits && (bits[d>>3]>>(uint(d)&7))&1 == 1 {
				delete(s.inflight, seq)
			}
		}
	}
	s.mu.Unlock()
}

func (s *Sender) requeueTimeouts() {
	now := time.Now()
	var due []uint64
	s.mu.Lock()
	for seq, e := range s.inflight {
		if !e.sentAt.IsZero() && now.Sub(e.sentAt) > s.rto && !s.inq[seq] {
			if e.tries >= s.maxTries {
				delete(s.inflight, seq)
				atomic.AddInt64(&s.gaveup, 1)
			} else {
				s.inq[seq] = true
				due = append(due, seq)
			}
		}
	}
	s.mu.Unlock()
	for _, seq := range due {
		s.q <- seq
	}
}

func (s *Sender) complete(seq uint64) {
	s.mu.Lock()
	delete(s.inflight, seq)
	delete(s.inq, seq)
	s.mu.Unlock()
}

func (s *Sender) requeue(seq uint64) {
	s.mu.Lock()
	if _, ok := s.inflight[seq]; ok && !s.inq[seq] {
		s.inq[seq] = true
		s.mu.Unlock()
		s.q <- seq
		return
	}
	s.mu.Unlock()
}

func (s *Sender) backlog() int {
	s.mu.Lock()
	n := len(s.inflight)
	s.mu.Unlock()
	return n
}

type RxDedup struct {
	mu     sync.Mutex
	base   uint64
	recv   map[uint64]bool
	window int
}

func newRxDedup(window int) *RxDedup {
	return &RxDedup{recv: make(map[uint64]bool), window: window}
}

func (r *RxDedup) accept(seq uint64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if seq <= r.base || r.recv[seq] {
		return false
	}
	r.recv[seq] = true
	for r.recv[r.base+1] {
		r.base++
		delete(r.recv, r.base)
	}
	if len(r.recv) > r.window*8 {
		min := ^uint64(0)
		for k := range r.recv {
			if k < min {
				min = k
			}
		}
		if min > r.base {
			r.base = min
			delete(r.recv, min)
			for r.recv[r.base+1] {
				r.base++
				delete(r.recv, r.base)
			}
		}
	}
	return true
}

func (r *RxDedup) encode() (uint64, uint64, []byte) {
	r.mu.Lock()
	base := r.base + 1
	bits := make([]byte, sackBytes)
	for k := range r.recv {
		if k >= base {
			d := k - base
			if d < sackBits {
				bits[d>>3] |= 1 << (uint(d) & 7)
			}
		}
	}
	cum := r.base
	r.mu.Unlock()
	return cum, base, bits
}

type Tunnel struct {
	role        string
	tun         *os.File
	chunkOut    int
	flush       time.Duration
	tx          *Sender
	rx          *RxDedup
	writeMu     sync.Mutex
	bytesIn     int64
	connOK      int64
	connFail    int64
	drops       int64
	dupRx       int64
	peerBacklog int64
}

func newTunnel(role string, tun *os.File, chunkOut, window int, rto, flush time.Duration, maxTries int) *Tunnel {
	return &Tunnel{
		role:     role,
		tun:      tun,
		chunkOut: chunkOut,
		flush:    flush,
		tx:       newSender(window, rto, maxTries),
		rx:       newRxDedup(window),
	}
}

func (t *Tunnel) build(ptype byte, seq uint64, buf []byte) []byte {
	if buf == nil {
		seq = 0
	}
	cum, base, bits := t.rx.encode()
	backlog := uint32(t.tx.backlog())
	dlen := len(buf)
	out := make([]byte, headerLen+dlen)
	binary.BigEndian.PutUint16(out[0:], magic)
	out[2] = ver
	out[3] = ptype
	binary.BigEndian.PutUint64(out[4:], seq)
	binary.BigEndian.PutUint16(out[12:], uint16(dlen))
	binary.BigEndian.PutUint64(out[14:], cum)
	binary.BigEndian.PutUint64(out[22:], base)
	off := hdrFixed
	copy(out[off:], bits)
	off += sackBytes
	copy(out[off:], buf)
	off += dlen
	binary.BigEndian.PutUint32(out[off:], backlog)
	binary.BigEndian.PutUint16(out[off+4:], 0)
	off += tailSize
	crc := crc32.ChecksumIEEE(out[:off])
	binary.BigEndian.PutUint32(out[off:], crc)
	return out
}

func (t *Tunnel) deliverChunk(payload []byte) {
	i := 0
	n := len(payload)
	for i+2 <= n {
		plen := int(payload[i])<<8 | int(payload[i+1])
		i += 2
		if plen <= 0 || i+plen > n {
			break
		}
		t.writeMu.Lock()
		_, _ = t.tun.Write(payload[i : i+plen])
		t.writeMu.Unlock()
		i += plen
	}
}

func (t *Tunnel) apply(frame []byte) bool {
	if len(frame) < headerLen {
		return false
	}
	if binary.BigEndian.Uint16(frame[0:]) != magic || frame[2] != ver {
		return false
	}
	seq := binary.BigEndian.Uint64(frame[4:])
	dlen := int(binary.BigEndian.Uint16(frame[12:]))
	cum := binary.BigEndian.Uint64(frame[14:])
	base := binary.BigEndian.Uint64(frame[22:])
	if dlen > maxChunk || len(frame) != headerLen+dlen {
		return false
	}
	off := hdrFixed
	bits := frame[off : off+sackBytes]
	off += sackBytes
	payload := frame[off : off+dlen]
	off += dlen
	backlog := binary.BigEndian.Uint32(frame[off:])
	off += tailSize
	want := binary.BigEndian.Uint32(frame[off:])
	if crc32.ChecksumIEEE(frame[:off]) != want {
		return false
	}
	t.tx.applyAck(cum, base, bits)
	atomic.StoreInt64(&t.peerBacklog, int64(backlog))
	if dlen > 0 && seq > 0 {
		if t.rx.accept(seq) {
			atomic.AddInt64(&t.bytesIn, int64(dlen))
			t.deliverChunk(payload)
		} else {
			atomic.AddInt64(&t.dupRx, 1)
		}
	}
	return true
}

func readFrame(conn net.Conn) ([]byte, bool) {
	head := make([]byte, hdrFixed)
	if _, err := io.ReadFull(conn, head); err != nil {
		return nil, false
	}
	if binary.BigEndian.Uint16(head[0:]) != magic || head[2] != ver {
		return nil, false
	}
	dlen := int(binary.BigEndian.Uint16(head[12:]))
	if dlen > maxChunk {
		return nil, false
	}
	rest := make([]byte, sackBytes+dlen+tailSize+crcSize)
	if _, err := io.ReadFull(conn, rest); err != nil {
		return nil, false
	}
	frame := make([]byte, hdrFixed+len(rest))
	copy(frame, head)
	copy(frame[hdrFixed:], rest)
	return frame, true
}

func (t *Tunnel) tunReader() {
	pktCh := make(chan []byte, 2048)
	go func() {
		b := make([]byte, 65535)
		for {
			n, err := t.tun.Read(b)
			if err != nil {
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					continue
				}
				return
			}
			if n <= 0 {
				continue
			}
			pkt := make([]byte, n)
			copy(pkt, b[:n])
			pktCh <- pkt
		}
	}()
	acc := make([]byte, 0, t.chunkOut)
	last := time.Now()
	flushHi := t.chunkOut - 1500
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	flushAcc := func() {
		if len(acc) == 0 {
			return
		}
		cp := make([]byte, len(acc))
		copy(cp, acc)
		t.tx.addChunk(cp)
		acc = acc[:0]
		last = time.Now()
	}
	for {
		select {
		case pkt := <-pktCh:
			lp := len(pkt)
			if lp > 0 && lp+2 <= t.chunkOut {
				if !t.tx.canAccept() {
					atomic.AddInt64(&t.drops, 1)
					continue
				}
				if len(acc)+2+lp > t.chunkOut {
					flushAcc()
				}
				acc = append(acc, byte(lp>>8), byte(lp))
				acc = append(acc, pkt...)
				if len(acc) >= flushHi {
					flushAcc()
				}
			}
		case <-ticker.C:
			if len(acc) > 0 && time.Since(last) >= t.flush {
				flushAcc()
			}
		}
	}
}

func (t *Tunnel) retransmitLoop() {
	for {
		t.tx.requeueTimeouts()
		time.Sleep(20 * time.Millisecond)
	}
}

type dialerCfg struct {
	peer     string
	base     int
	count    int
	timeout  time.Duration
	localIP  net.IP
	fastOpen bool
}

func newDialer(cfg dialerCfg) *net.Dialer {
	d := &net.Dialer{Timeout: cfg.timeout}
	if cfg.localIP != nil {
		d.LocalAddr = &net.TCPAddr{IP: cfg.localIP}
	}
	if cfg.fastOpen {
		d.Control = func(network, address string, c syscall.RawConn) error {
			var se error
			_ = c.Control(func(fd uintptr) {
				se = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, tcpFastopenConnect, 1)
			})
			return se
		}
	}
	return d
}

func (t *Tunnel) roundTrip(d *net.Dialer, cfg dialerCfg, ptype byte, seq uint64, buf []byte) bool {
	port := cfg.base + rand.IntN(cfg.count)
	conn, err := d.Dial("tcp4", net.JoinHostPort(cfg.peer, strconv.Itoa(port)))
	if err != nil {
		atomic.AddInt64(&t.connFail, 1)
		return false
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetLinger(0)
	}
	_ = conn.SetDeadline(time.Now().Add(cfg.timeout))
	if _, err := conn.Write(t.build(ptype, seq, buf)); err != nil {
		atomic.AddInt64(&t.connFail, 1)
		return false
	}
	frame, ok := readFrame(conn)
	if !ok {
		atomic.AddInt64(&t.connFail, 1)
		return false
	}
	t.apply(frame)
	atomic.AddInt64(&t.connOK, 1)
	return true
}

func (t *Tunnel) runClient(cfg dialerCfg, upWorkers, dlWorkers int) {
	t.tx.rto = 10 * time.Second
	go t.tunReader()
	go t.retransmitLoop()
	d := newDialer(cfg)
	for i := 0; i < upWorkers; i++ {
		go func() {
			for {
				seq, buf := t.tx.getSend(0)
				if buf != nil {
					if t.roundTrip(d, cfg, 0, seq, buf) {
						t.tx.complete(seq)
					} else {
						t.tx.requeue(seq)
					}
				} else {
					t.roundTrip(d, cfg, 0, 0, nil)
				}
			}
		}()
	}
	for i := 0; i < dlWorkers; i++ {
		go func() {
			for {
				t.roundTrip(d, cfg, 0, 0, nil)
			}
		}()
	}
	select {}
}

func (t *Tunnel) handleConn(conn net.Conn, timeout time.Duration) {
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetLinger(0)
	}
	_ = conn.SetDeadline(time.Now().Add(timeout))
	frame, ok := readFrame(conn)
	if !ok {
		atomic.AddInt64(&t.connFail, 1)
		return
	}
	t.apply(frame)
	seq, buf := t.tx.getSend(0)
	if buf != nil {
		_, _ = conn.Write(t.build(1, seq, buf))
	} else {
		_, _ = conn.Write(t.build(1, 0, nil))
	}
	atomic.AddInt64(&t.connOK, 1)
}

func (t *Tunnel) runServer(base, count, conc int, timeout time.Duration, fastOpen bool) {
	go t.tunReader()
	go t.retransmitLoop()
	sem := make(chan struct{}, conc)
	lc := net.ListenConfig{}
	if fastOpen {
		lc.Control = func(network, address string, c syscall.RawConn) error {
			var se error
			_ = c.Control(func(fd uintptr) {
				se = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, tcpFastopen, 256)
			})
			return se
		}
	}
	for p := base; p < base+count; p++ {
		addr := net.JoinHostPort("0.0.0.0", strconv.Itoa(p))
		ln, err := lc.Listen(context.Background(), "tcp4", addr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "omnistripe: listen %s: %v\n", addr, err)
			continue
		}
		go func(ln net.Listener) {
			for {
				conn, err := ln.Accept()
				if err != nil {
					continue
				}
				sem <- struct{}{}
				go func() {
					defer func() { <-sem }()
					t.handleConn(conn, timeout)
				}()
			}
		}(ln)
	}
	select {}
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "version" || os.Args[1] == "-V" || os.Args[1] == "--version") {
		fmt.Println("omnistripe 1.0.0")
		return
	}
	localIP := flag.String("L", "", "local source/bind IP")
	peerIP := flag.String("R", "", "peer IP (client dials this)")
	tunAddr := flag.String("A", "", "this box tun address")
	peerAddr := flag.String("P", "", "peer tun address")
	basePort := flag.Int("p", 40000, "base destination port")
	portCount := flag.Int("C", 400, "number of destination ports")
	nconn := flag.Int("N", 90, "connection workers")
	dlConn := flag.Int("dl", 0, "download pool size (0=derive from N)")
	dev := flag.String("T", "tsstripe0", "tun device name")
	mtu := flag.Int("M", 1400, "tun MTU")
	server := flag.Bool("s", false, "run as server (listener)")
	fastOpen := flag.Bool("F", false, "enable TCP Fast Open")
	chunkUp := flag.Int("u", 6800, "client->server chunk bytes")
	chunkDown := flag.Int("d", 8600, "server->client chunk bytes")
	window := flag.Int("w", 400, "in-flight window")
	rtoMs := flag.Int("rto", 300, "server retransmit timeout ms")
	toMs := flag.Int("to", 5000, "dial/io timeout ms")
	flushMs := flag.Int("fl", 2, "accumulator flush ms")
	maxTries := flag.Int("mt", 30, "max retransmit tries")
	txq := flag.Int("txq", 20000, "tun txqueuelen")
	flag.Parse()

	if *portCount < 1 {
		*portCount = 1
	}
	if *window < 1 {
		*window = 1
	}

	if _, err := net.InterfaceByName(*dev); err == nil {
		fmt.Fprintf(os.Stderr, "omnistripe: tun device %s already exists; refusing to start\n", *dev)
		os.Exit(1)
	}
	tun, err := openTun(*dev)
	if err != nil {
		fmt.Fprintf(os.Stderr, "omnistripe: open tun %s: %v\n", *dev, err)
		os.Exit(1)
	}
	addr := *tunAddr
	if *peerAddr == "" && addr != "" && !hasSlash(addr) {
		addr = addr + "/30"
	}
	configTun(*dev, *mtu, *txq, addr, *peerAddr)

	role := "relay"
	chunkOut := *chunkUp
	if *server {
		role = "turkey"
		chunkOut = *chunkDown
	}
	if chunkOut > maxPayload {
		chunkOut = maxPayload
	}
	rto := time.Duration(*rtoMs) * time.Millisecond
	flush := time.Duration(*flushMs) * time.Millisecond
	tmo := time.Duration(*toMs) * time.Millisecond

	tn := newTunnel(role, tun, chunkOut, *window, rto, flush, *maxTries)

	if *server {
		conc := clamp(*nconn*4, 512, 16384)
		tn.runServer(*basePort, *portCount, conc, tmo, *fastOpen)
		return
	}

	dlWorkers := *dlConn
	if dlWorkers <= 0 {
		dlWorkers = *nconn
	}
	var lip net.IP
	if *localIP != "" && *localIP != "0.0.0.0" {
		lip = net.ParseIP(*localIP)
	}
	cfg := dialerCfg{
		peer:     *peerIP,
		base:     *basePort,
		count:    *portCount,
		timeout:  tmo,
		localIP:  lip,
		fastOpen: *fastOpen,
	}
	tn.runClient(cfg, *nconn, dlWorkers)
}

func hasSlash(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			return true
		}
	}
	return false
}
