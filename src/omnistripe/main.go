package main

import (
	"container/heap"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	magic     = 0x5342
	ver       = 3
	hdrFixed  = 54
	sackBytes = 64
	sackBits  = sackBytes * 8
	tailSize  = 6
	macSize   = 16
	headerLen = hdrFixed + sackBytes + tailSize + macSize
	maxChunk  = 16000

	safeSegs    = 5
	mssFloor    = 1360
	hardWireCap = safeSegs * mssFloor
	maxPayload  = hardWireCap - headerLen

	replayWin = 65536

	maxLanes = 64

	labelC2S = "omnistripe/v1/c2s"
	labelS2C = "omnistripe/v1/s2c"

	tunsetiff = 0x400454ca
	iffTun    = 0x0001
	iffNoPI   = 0x1000

	tcpFastopen        = 23
	tcpFastopenConnect = 30
)

var ntTable = "omnistripe"

func sanitizeName(s string) string {
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' {
			b = append(b, c)
		} else {
			b = append(b, '_')
		}
	}
	return string(b)
}

func subkey(psk []byte, label string) []byte {
	m := hmac.New(sha256.New, psk)
	m.Write([]byte(label))
	return m.Sum(nil)
}

func hmacTag(key, data []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(data)
	return m.Sum(nil)[:macSize]
}

func startEpoch() uint64 {
	return uint64(time.Now().UnixNano())
}

type replayWindow struct {
	mu   sync.Mutex
	high uint64
	size uint64
	bits []uint64
}

func newReplayWindow(size uint64) *replayWindow {
	if size < 64 {
		size = 64
	}
	size -= size % 64
	return &replayWindow{size: size, bits: make([]uint64, size/64)}
}

func (w *replayWindow) reset() {
	w.mu.Lock()
	w.high = 0
	for i := range w.bits {
		w.bits[i] = 0
	}
	w.mu.Unlock()
}

func (w *replayWindow) check(nonce uint64) bool {
	if nonce == 0 {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if nonce > w.high {
		diff := nonce - w.high
		if diff >= w.size {
			for i := range w.bits {
				w.bits[i] = 0
			}
		} else {
			for i := uint64(0); i < diff; i++ {
				p := (w.high + 1 + i) % w.size
				w.bits[p>>6] &^= 1 << (p & 63)
			}
		}
		w.high = nonce
		p := nonce % w.size
		w.bits[p>>6] |= 1 << (p & 63)
		return true
	}
	if w.high-nonce >= w.size {
		return false
	}
	p := nonce % w.size
	m := uint64(1) << (p & 63)
	if w.bits[p>>6]&m != 0 {
		return false
	}
	w.bits[p>>6] |= m
	return true
}

type readyTuple struct {
	at time.Time
	sp int
	dp int
}

type tupleHeap []readyTuple

func (h tupleHeap) Len() int           { return len(h) }
func (h tupleHeap) Less(i, j int) bool { return h[i].at.Before(h[j].at) }
func (h tupleHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *tupleHeap) Push(x any)        { *h = append(*h, x.(readyTuple)) }
func (h *tupleHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}

type tupleSched struct {
	mu       sync.Mutex
	srcLo    int
	srcHi    int
	dstLo    int
	dstHi    int
	cooldown time.Duration
	space    int
	cap      int
	ready    tupleHeap
	minted   int
	nextSrc  int
	nextDst  int
}

func newTupleSched(srcLo, srcHi, dstLo, dstHi int, cooldown time.Duration, cap int) *tupleSched {
	if srcHi < srcLo {
		srcHi = srcLo
	}
	if dstHi < dstLo {
		dstHi = dstLo
	}
	space := (srcHi - srcLo + 1) * (dstHi - dstLo + 1)
	if cap <= 0 || cap > space {
		cap = space
	}
	s := &tupleSched{
		srcLo: srcLo, srcHi: srcHi, dstLo: dstLo, dstHi: dstHi,
		cooldown: cooldown, space: space, cap: cap,
		nextSrc: srcLo, nextDst: dstLo,
	}
	heap.Init(&s.ready)
	return s
}

func (s *tupleSched) mint() (int, int, bool) {
	if s.minted >= s.cap {
		return 0, 0, false
	}
	sp, dp := s.nextSrc, s.nextDst
	s.nextDst++
	if s.nextDst > s.dstHi {
		s.nextDst = s.dstLo
		s.nextSrc++
		if s.nextSrc > s.srcHi {
			s.nextSrc = s.srcLo
		}
	}
	s.minted++
	return sp, dp, true
}

func (s *tupleSched) acquire(now time.Time) (int, int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.ready) > 0 && !s.ready[0].at.After(now) {
		rt := heap.Pop(&s.ready).(readyTuple)
		return rt.sp, rt.dp, true
	}
	if sp, dp, ok := s.mint(); ok {
		return sp, dp, true
	}
	if len(s.ready) > 0 && !s.ready[0].at.After(now) {
		rt := heap.Pop(&s.ready).(readyTuple)
		return rt.sp, rt.dp, true
	}
	return 0, 0, false
}

func (s *tupleSched) release(sp, dp int, now time.Time) {
	at := now.Add(s.cooldown)
	s.mu.Lock()
	heap.Push(&s.ready, readyTuple{at: at, sp: sp, dp: dp})
	s.mu.Unlock()
}

func (s *tupleSched) waitHint(now time.Time) time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.ready) == 0 {
		return 10 * time.Millisecond
	}
	d := s.ready[0].at.Sub(now)
	if d < time.Millisecond {
		d = time.Millisecond
	}
	if d > 100*time.Millisecond {
		d = 100 * time.Millisecond
	}
	return d
}

func notrackRuleset(peer string, sLo, sHi, dLo, dHi int) string {
	return fmt.Sprintf(`table ip %s {
	chain pre {
		type filter hook prerouting priority -300; policy accept;
		ip saddr %s tcp sport %d-%d notrack
		ip saddr %s tcp dport %d-%d notrack
		ip saddr %s tcp sport %d-%d notrack
		ip saddr %s tcp dport %d-%d notrack
	}
	chain out {
		type filter hook output priority -300; policy accept;
		ip daddr %s tcp sport %d-%d notrack
		ip daddr %s tcp dport %d-%d notrack
		ip daddr %s tcp sport %d-%d notrack
		ip daddr %s tcp dport %d-%d notrack
	}
}
`, ntTable,
		peer, sLo, sHi, peer, sLo, sHi, peer, dLo, dHi, peer, dLo, dHi,
		peer, sLo, sHi, peer, sLo, sHi, peer, dLo, dHi, peer, dLo, dHi)
}

func removeNotrack() {
	cmd := exec.Command("nft", "delete", "table", "ip", ntTable)
	cmd.Stdout = nil
	cmd.Stderr = nil
	_ = cmd.Run()
}

func installNotrack(peer string, sLo, sHi, dLo, dHi int) {
	if peer == "" {
		fmt.Fprintln(os.Stderr, "omnistripe: no peer IP; skipping NOTRACK (conntrack not exempted)")
		return
	}
	removeNotrack()
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(notrackRuleset(peer, sLo, sHi, dLo, dHi))
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "omnistripe: nft notrack install failed: %v (conntrack not exempted)\n", err)
	}
}

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

func tcRun(args ...string) {
	cmd := exec.Command("tc", args...)
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
	tcRun("qdisc", "replace", "dev", name, "root", "fq_codel")
}

type sEntry struct {
	buf    []byte
	sentAt time.Time
	tries  int
}

type Sender struct {
	mu       sync.Mutex
	notFull  *sync.Cond
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
	s := &Sender{
		nextSeq:  1,
		inflight: make(map[uint64]*sEntry),
		inq:      make(map[uint64]bool),
		q:        make(chan uint64, window*8+64),
		window:   window,
		rto:      rto,
		maxTries: maxTries,
	}
	s.notFull = sync.NewCond(&s.mu)
	return s
}

func (s *Sender) addChunk(buf []byte) {
	s.mu.Lock()
	for len(s.inflight) >= s.window {
		s.notFull.Wait()
	}
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
	s.notFull.Broadcast()
	s.mu.Unlock()
}

func (s *Sender) requeueTimeouts() {
	now := time.Now()
	var due []uint64
	s.mu.Lock()
	for seq, e := range s.inflight {
		if !e.sentAt.IsZero() && now.Sub(e.sentAt) > s.rto && !s.inq[seq] {
			s.inq[seq] = true
			due = append(due, seq)
		}
	}
	s.notFull.Broadcast()
	s.mu.Unlock()
	for _, seq := range due {
		s.q <- seq
	}
}

func (s *Sender) stillInflight(seq uint64) bool {
	s.mu.Lock()
	_, ok := s.inflight[seq]
	s.mu.Unlock()
	return ok
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
	mu       sync.Mutex
	base     uint64
	recv     map[uint64]bool
	reserved map[uint64]bool
	partial  map[uint64]int
	window   int
}

func newRxDedup(window int) *RxDedup {
	return &RxDedup{recv: make(map[uint64]bool), reserved: make(map[uint64]bool), partial: make(map[uint64]int), window: window}
}

func (r *RxDedup) reset() {
	r.mu.Lock()
	r.base = 0
	r.recv = make(map[uint64]bool)
	r.reserved = make(map[uint64]bool)
	r.partial = make(map[uint64]int)
	r.mu.Unlock()
}

func (r *RxDedup) partialSkip(seq uint64) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.partial[seq]
}

func (r *RxDedup) setPartial(seq uint64, n int) {
	r.mu.Lock()
	r.partial[seq] = n
	r.mu.Unlock()
}

func (r *RxDedup) clearPartial(seq uint64) {
	r.mu.Lock()
	delete(r.partial, seq)
	r.mu.Unlock()
}

func (r *RxDedup) have(seq uint64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return seq <= r.base || r.recv[seq]
}

func (r *RxDedup) reserve(seq uint64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.base == 0 && len(r.recv) == 0 && len(r.reserved) == 0 && seq > r.base+sackBits {
		r.base = seq - 1
	}
	if seq <= r.base || r.recv[seq] || r.reserved[seq] {
		return false
	}
	if seq > r.base+sackBits {
		return false
	}
	r.reserved[seq] = true
	return true
}

func (r *RxDedup) commit(seq uint64) {
	r.mu.Lock()
	delete(r.reserved, seq)
	r.recv[seq] = true
	for r.recv[r.base+1] {
		r.base++
		delete(r.recv, r.base)
	}
	r.mu.Unlock()
}

func (r *RxDedup) unreserve(seq uint64) {
	r.mu.Lock()
	delete(r.reserved, seq)
	r.mu.Unlock()
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

type Lane struct {
	tx          *Sender
	rx          *RxDedup
	pktCh       chan []byte
	peerBacklog int64
}

type Tunnel struct {
	txNonce    uint64
	peerEpoch  uint64
	bytesIn    int64
	connOK     int64
	connFail   int64
	dupRx      int64
	authFail   int64
	replayDrop int64
	txEpoch    uint64
	role       string
	tun        *os.File
	wr         func([]byte) error
	chunkOut   int
	flush      time.Duration
	lanes      []*Lane
	writeMu    sync.Mutex
	epochMu    sync.RWMutex
	sendKey    []byte
	recvKey    []byte
	recvDir    byte
	replay     *replayWindow
	sched      *tupleSched
	peerIP     net.IP
	floorPath  string
	floorMu    sync.Mutex
}

func (t *Tunnel) loadFloor(path string) {
	t.floorPath = path
	b, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			atomic.StoreUint64(&t.peerEpoch, ^uint64(0))
		}
		return
	}
	v, perr := strconv.ParseUint(strings.SplitN(strings.TrimSpace(string(b)), "\n", 2)[0], 10, 64)
	if perr != nil {
		atomic.StoreUint64(&t.peerEpoch, ^uint64(0))
		return
	}
	atomic.StoreUint64(&t.peerEpoch, v)
}

var syncParentDir = func(path string) error {
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	serr := d.Sync()
	cerr := d.Close()
	if serr != nil {
		return serr
	}
	return cerr
}

func (t *Tunnel) writeFloorLocked(floor uint64) bool {
	if t.floorPath == "" {
		return true
	}
	tmp := t.floorPath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return false
	}
	_, werr := f.WriteString(strconv.FormatUint(floor, 10) + "\n")
	serr := f.Sync()
	cerr := f.Close()
	if werr != nil || serr != nil || cerr != nil {
		os.Remove(tmp)
		return false
	}
	if os.Rename(tmp, t.floorPath) != nil {
		return false
	}
	return syncParentDir(t.floorPath) == nil
}

func (t *Tunnel) persistFloorLocked(floor uint64) bool {
	t.floorMu.Lock()
	ok := t.writeFloorLocked(floor)
	t.floorMu.Unlock()
	return ok
}

func stripeFloorPath(dev string) string {
	os.MkdirAll("/var/lib/omnitunnel", 0700)
	return "/var/lib/omnitunnel/stripe-" + sanitizeName(dev) + ".floor"
}

func newTunnel(role string, tun *os.File, chunkOut, nlanes, window int, rto, flush time.Duration, maxTries int, psk []byte) *Tunnel {
	t := &Tunnel{role: role, tun: tun, chunkOut: chunkOut, flush: flush, replay: newReplayWindow(replayWin)}
	if role == "turkey" {
		t.sendKey = subkey(psk, labelS2C)
		t.recvKey = subkey(psk, labelC2S)
		t.recvDir = 0
	} else {
		t.sendKey = subkey(psk, labelC2S)
		t.recvKey = subkey(psk, labelS2C)
		t.recvDir = 1
	}
	t.txEpoch = startEpoch()
	for i := 0; i < nlanes; i++ {
		t.lanes = append(t.lanes, &Lane{
			tx:    newSender(window, rto, maxTries),
			rx:    newRxDedup(window),
			pktCh: make(chan []byte, 512),
		})
	}
	return t
}

func laneOf(pkt []byte, n int) int {
	if n <= 1 {
		return 0
	}
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return 0
	}
	ihl := int(pkt[0]&0x0f) * 4
	var h uint32 = 2166136261
	for i := 12; i < 20; i++ {
		h ^= uint32(pkt[i])
		h *= 16777619
	}
	proto := pkt[9]
	h ^= uint32(proto)
	h *= 16777619
	if (proto == 6 || proto == 17) && len(pkt) >= ihl+4 {
		for i := 0; i < 4; i++ {
			h ^= uint32(pkt[ihl+i])
			h *= 16777619
		}
	}
	return int(h % uint32(n))
}

func (t *Tunnel) build(lane int, dir byte, seq uint64, buf []byte) []byte {
	if buf == nil {
		seq = 0
	}
	t.epochMu.RLock()
	defer t.epochMu.RUnlock()
	l := t.lanes[lane]
	cum, base, bits := l.rx.encode()
	backlog := uint32(l.tx.backlog())
	dlen := len(buf)
	out := make([]byte, headerLen+dlen)
	binary.BigEndian.PutUint16(out[0:], magic)
	out[2] = ver
	out[3] = byte(lane<<1) | dir
	binary.BigEndian.PutUint64(out[4:], seq)
	binary.BigEndian.PutUint16(out[12:], uint16(dlen))
	binary.BigEndian.PutUint64(out[14:], cum)
	binary.BigEndian.PutUint64(out[22:], base)
	binary.BigEndian.PutUint64(out[30:], atomic.AddUint64(&t.txNonce, 1))
	binary.BigEndian.PutUint64(out[38:], t.txEpoch)
	binary.BigEndian.PutUint64(out[46:], atomic.LoadUint64(&t.peerEpoch))
	off := hdrFixed
	copy(out[off:], bits)
	off += sackBytes
	copy(out[off:], buf)
	off += dlen
	binary.BigEndian.PutUint32(out[off:], backlog)
	binary.BigEndian.PutUint16(out[off+4:], 0)
	off += tailSize
	copy(out[off:], hmacTag(t.sendKey, out[:off]))
	return out
}

func (t *Tunnel) writeTun(p []byte) error {
	if t.wr != nil {
		return t.wr(p)
	}
	_, err := t.tun.Write(p)
	return err
}

func (t *Tunnel) deliverChunk(payload []byte, skip int) (int, bool) {
	i := 0
	n := len(payload)
	idx := 0
	written := skip
	for i+2 <= n {
		plen := int(payload[i])<<8 | int(payload[i+1])
		i += 2
		if plen <= 0 || i+plen > n {
			break
		}
		if idx >= skip {
			t.writeMu.Lock()
			err := t.writeTun(payload[i : i+plen])
			t.writeMu.Unlock()
			if err != nil {
				return written, false
			}
			written++
		}
		idx++
		i += plen
	}
	return written, true
}

func (t *Tunnel) apply(frame []byte) bool {
	if len(frame) < headerLen {
		return false
	}
	if binary.BigEndian.Uint16(frame[0:]) != magic || frame[2] != ver {
		return false
	}
	if frame[3]&1 != t.recvDir {
		return false
	}
	lane := int(frame[3] >> 1)
	if lane >= len(t.lanes) {
		return false
	}
	seq := binary.BigEndian.Uint64(frame[4:])
	dlen := int(binary.BigEndian.Uint16(frame[12:]))
	cum := binary.BigEndian.Uint64(frame[14:])
	base := binary.BigEndian.Uint64(frame[22:])
	nonce := binary.BigEndian.Uint64(frame[30:])
	peerEp := binary.BigEndian.Uint64(frame[38:])
	echo := binary.BigEndian.Uint64(frame[46:])
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
	if !hmac.Equal(hmacTag(t.recvKey, frame[:off]), frame[off:off+macSize]) {
		atomic.AddInt64(&t.authFail, 1)
		return false
	}
	cur := atomic.LoadUint64(&t.peerEpoch)
	if peerEp != cur {
		if peerEp < cur {
			atomic.AddInt64(&t.replayDrop, 1)
			return false
		}
		t.epochMu.Lock()
		if peerEp > atomic.LoadUint64(&t.peerEpoch) {
			if !t.persistFloorLocked(peerEp) {
				t.epochMu.Unlock()
				atomic.AddInt64(&t.replayDrop, 1)
				return false
			}
			atomic.StoreUint64(&t.peerEpoch, peerEp)
			t.replay.reset()
			for _, l := range t.lanes {
				l.rx.reset()
			}
		}
		t.epochMu.Unlock()
	}
	t.epochMu.RLock()
	defer t.epochMu.RUnlock()
	if atomic.LoadUint64(&t.peerEpoch) != peerEp {
		atomic.AddInt64(&t.replayDrop, 1)
		return false
	}
	if !t.replay.check(nonce) {
		atomic.AddInt64(&t.replayDrop, 1)
		return false
	}
	l := t.lanes[lane]
	if echo == t.txEpoch {
		l.tx.applyAck(cum, base, bits)
	}
	atomic.StoreInt64(&l.peerBacklog, int64(backlog))
	if dlen > 0 && seq > 0 {
		if l.rx.reserve(seq) {
			if written, ok := t.deliverChunk(payload, l.rx.partialSkip(seq)); ok {
				l.rx.clearPartial(seq)
				l.rx.commit(seq)
				atomic.AddInt64(&t.bytesIn, int64(dlen))
			} else {
				l.rx.setPartial(seq, written)
				l.rx.unreserve(seq)
			}
		} else {
			atomic.AddInt64(&t.dupRx, 1)
		}
	}
	return true
}

func frameLaneDlen(frame []byte) (int, int) {
	return int(frame[3] >> 1), int(binary.BigEndian.Uint16(frame[12:]))
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
	rest := make([]byte, sackBytes+dlen+tailSize+macSize)
	if _, err := io.ReadFull(conn, rest); err != nil {
		return nil, false
	}
	frame := make([]byte, hdrFixed+len(rest))
	copy(frame, head)
	copy(frame[hdrFixed:], rest)
	return frame, true
}

func (t *Tunnel) tunReader() {
	go func() {
		b := make([]byte, 65535)
		n := len(t.lanes)
		for {
			r, err := t.tun.Read(b)
			if err != nil {
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					continue
				}
				return
			}
			if r <= 0 {
				continue
			}
			pkt := make([]byte, r)
			copy(pkt, b[:r])
			t.lanes[laneOf(pkt, n)].pktCh <- pkt
		}
	}()
	for i := range t.lanes {
		go t.laneAccumulator(t.lanes[i])
	}
}

func (t *Tunnel) laneAccumulator(l *Lane) {
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
		l.tx.addChunk(cp)
		acc = acc[:0]
		last = time.Now()
	}
	for {
		select {
		case pkt := <-l.pktCh:
			lp := len(pkt)
			if lp > 0 && lp+2 <= t.chunkOut {
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
		for _, l := range t.lanes {
			l.tx.requeueTimeouts()
		}
		time.Sleep(20 * time.Millisecond)
	}
}

type dialerCfg struct {
	peer     string
	timeout  time.Duration
	localIP  net.IP
	fastOpen bool
}

func dialerWithPort(cfg dialerCfg, sp int) *net.Dialer {
	d := &net.Dialer{Timeout: cfg.timeout, LocalAddr: &net.TCPAddr{IP: cfg.localIP, Port: sp}}
	fo := cfg.fastOpen
	d.Control = func(network, address string, c syscall.RawConn) error {
		var se error
		_ = c.Control(func(fd uintptr) {
			_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
			if fo {
				se = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, tcpFastopenConnect, 1)
			}
		})
		return se
	}
	return d
}

func (t *Tunnel) roundTrip(cfg dialerCfg, lane int, seq uint64, buf []byte) (bool, bool) {
	now := time.Now()
	sp, dp, ok := t.sched.acquire(now)
	for !ok {
		time.Sleep(t.sched.waitHint(now))
		now = time.Now()
		sp, dp, ok = t.sched.acquire(now)
	}
	defer func() { t.sched.release(sp, dp, time.Now()) }()
	d := dialerWithPort(cfg, sp)
	conn, err := d.Dial("tcp4", net.JoinHostPort(cfg.peer, strconv.Itoa(dp)))
	if err != nil {
		atomic.AddInt64(&t.connFail, 1)
		return false, false
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetLinger(0)
	}
	_ = conn.SetDeadline(time.Now().Add(cfg.timeout))
	if _, err := conn.Write(t.build(lane, 0, seq, buf)); err != nil {
		atomic.AddInt64(&t.connFail, 1)
		return false, false
	}
	frame, ok2 := readFrame(conn)
	if !ok2 {
		atomic.AddInt64(&t.connFail, 1)
		return false, false
	}
	if !t.apply(frame) {
		atomic.AddInt64(&t.connFail, 1)
		return false, false
	}
	hadData := int(binary.BigEndian.Uint16(frame[12:])) > 0
	atomic.AddInt64(&t.connOK, 1)
	return true, hadData
}

func clientRTO(ioTimeout time.Duration) time.Duration {
	if ioTimeout <= 0 {
		return 10 * time.Second
	}
	rto := 2 * ioTimeout
	if rto < 500*time.Millisecond {
		rto = 500 * time.Millisecond
	}
	return rto
}

func (t *Tunnel) runClient(cfg dialerCfg, upWorkers, dlWorkers int) {
	for _, l := range t.lanes {
		l.tx.rto = clientRTO(cfg.timeout)
	}
	t.tunReader()
	go t.retransmitLoop()
	for li := range t.lanes {
		lane := li
		l := t.lanes[li]
		for i := 0; i < upWorkers; i++ {
			go func() {
				for {
					seq, buf := l.tx.getSend(50 * time.Millisecond)
					if buf == nil {
						continue
					}
					ok, _ := t.roundTrip(cfg, lane, seq, buf)
					if !ok || l.tx.stillInflight(seq) {
						l.tx.requeue(seq)
					}
				}
			}()
		}
		for i := 0; i < dlWorkers; i++ {
			go func() {
				for {
					_, hadData := t.roundTrip(cfg, lane, 0, nil)
					if !hadData && atomic.LoadInt64(&l.peerBacklog) == 0 {
						time.Sleep(100 * time.Millisecond)
					}
				}
			}()
		}
	}
	select {}
}

func (t *Tunnel) handleConn(conn net.Conn, timeout time.Duration) {
	defer conn.Close()
	if t.peerIP != nil {
		host, _, _ := net.SplitHostPort(conn.RemoteAddr().String())
		if ip := net.ParseIP(host); ip == nil || !ip.Equal(t.peerIP) {
			return
		}
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	_ = conn.SetDeadline(time.Now().Add(timeout))
	frame, ok := readFrame(conn)
	if !ok {
		atomic.AddInt64(&t.connFail, 1)
		return
	}
	lane, _ := frameLaneDlen(frame)
	if lane >= len(t.lanes) {
		return
	}
	if !t.apply(frame) {
		atomic.AddInt64(&t.connFail, 1)
		return
	}
	seq, buf := t.lanes[lane].tx.getSend(0)
	if buf != nil {
		_, _ = conn.Write(t.build(lane, 1, seq, buf))
	} else {
		_, _ = conn.Write(t.build(lane, 1, 0, nil))
	}
	atomic.AddInt64(&t.connOK, 1)
}

func (t *Tunnel) runServer(base, count, conc int, timeout time.Duration, fastOpen bool) {
	t.tunReader()
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

func (t *Tunnel) statsLoop(every time.Duration) {
	var lastOK, lastIn int64
	last := time.Now()
	for {
		time.Sleep(every)
		now := time.Now()
		dt := now.Sub(last).Seconds()
		ok := atomic.LoadInt64(&t.connOK)
		in := atomic.LoadInt64(&t.bytesIn)
		var inflight, backlog int
		for _, l := range t.lanes {
			inflight += l.tx.backlog()
			backlog += int(atomic.LoadInt64(&l.peerBacklog))
		}
		fmt.Fprintf(os.Stderr, "omnistripe[%s] conn/s=%.0f rx=%.2fMbit inflight=%d peerbk=%d fail=%d dup=%d auth=%d replay=%d\n",
			t.role, float64(ok-lastOK)/dt, float64(in-lastIn)*8/dt/1e6, inflight, backlog,
			atomic.LoadInt64(&t.connFail), atomic.LoadInt64(&t.dupRx),
			atomic.LoadInt64(&t.authFail), atomic.LoadInt64(&t.replayDrop))
		lastOK, lastIn, last = ok, in, now
	}
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
		fmt.Println("omnistripe 1.0.4")
		return
	}
	localIP := flag.String("L", "", "local source/bind IP")
	peerIP := flag.String("R", "", "peer IP (client dials this)")
	tunAddr := flag.String("A", "", "this box tun address")
	peerAddr := flag.String("P", "", "peer tun address")
	basePort := flag.Int("p", 40000, "base destination port")
	portCount := flag.Int("C", 400, "number of destination ports")
	nconn := flag.Int("N", 90, "connection workers")
	dlConn := flag.Int("dl", 0, "download pool size per lane (0=derive)")
	lanes := flag.Int("lanes", 1, "independent per-flow reliability lanes")
	dev := flag.String("T", "tsstripe0", "tun device name")
	mtu := flag.Int("M", 1400, "tun MTU")
	server := flag.Bool("s", false, "run as server (listener)")
	fastOpen := flag.Bool("F", false, "enable TCP Fast Open")
	key := flag.String("k", "", "pre-shared key for frame authentication (required)")
	srcBase := flag.Int("sb", 20000, "client source-port pool base")
	srcCount := flag.Int("sc", 4096, "client source-port pool size")
	coolSec := flag.Int("cool", 40, "per-tuple cooldown seconds before reuse")
	chunkUp := flag.Int("u", 6600, "client->server chunk bytes")
	chunkDown := flag.Int("d", 6600, "server->client chunk bytes")
	window := flag.Int("w", 400, "in-flight window (total across lanes)")
	rtoMs := flag.Int("rto", 300, "server retransmit timeout ms")
	toMs := flag.Int("to", 5000, "dial/io timeout ms")
	flushMs := flag.Int("fl", 2, "accumulator flush ms")
	maxTries := flag.Int("mt", 30, "max retransmit tries")
	txq := flag.Int("txq", 20000, "tun txqueuelen")
	statsSec := flag.Int("st", 0, "stats interval seconds (0=off)")
	flag.Parse()

	if *key == "" {
		fmt.Fprintln(os.Stderr, "omnistripe: -k pre-shared key is required")
		os.Exit(1)
	}
	if *portCount < 1 {
		*portCount = 1
	}
	if *srcCount < 1 {
		*srcCount = 1
	}
	nl := clamp(*lanes, 1, maxLanes)
	perLaneWin := clamp(*window/nl, 32, sackBits)

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

	ntTable = "omnistripe_" + sanitizeName(*dev)
	tn := newTunnel(role, tun, chunkOut, nl, perLaneWin, rto, flush, *maxTries, []byte(*key))
	if *peerIP != "" {
		tn.peerIP = net.ParseIP(*peerIP)
	}
	tn.loadFloor(stripeFloorPath(*dev))
	dstLo := *basePort
	dstHi := *basePort + *portCount - 1
	srcLo := *srcBase
	srcHi := *srcBase + *srcCount - 1
	tn.sched = newTupleSched(srcLo, srcHi, dstLo, dstHi, time.Duration(*coolSec)*time.Second, 0)

	installNotrack(*peerIP, srcLo, srcHi, dstLo, dstHi)
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		removeNotrack()
		os.Exit(0)
	}()

	if *statsSec > 0 {
		go tn.statsLoop(time.Duration(*statsSec) * time.Second)
	}

	if *server {
		conc := clamp(*nconn*4, 512, 16384)
		tn.runServer(*basePort, *portCount, conc, tmo, *fastOpen)
		return
	}

	perLaneUp := clamp(*nconn/nl, 1, *nconn)
	perLaneDl := *dlConn
	if perLaneDl <= 0 {
		perLaneDl = perLaneUp
	}
	var lip net.IP
	if *localIP != "" && *localIP != "0.0.0.0" {
		lip = net.ParseIP(*localIP)
	}
	cfg := dialerCfg{
		peer:     *peerIP,
		timeout:  tmo,
		localIP:  lip,
		fastOpen: *fastOpen,
	}
	tn.runClient(cfg, perLaneUp, perLaneDl)
}

func hasSlash(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			return true
		}
	}
	return false
}
