package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"flag"
	"fmt"
	"hash"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	magic0  = 0xAC
	magic1  = 0x4B
	tData   = 0
	tNack   = 2
	tAck    = 3
	tBase   = 4
	hdrLen  = 18
	macLen  = 8
	arqW    = 1 << 16
	nackMax = 128
)

const (
	nackTick     = 15 * time.Millisecond
	nackGuardMin = 6 * time.Millisecond
	nackGuardMax = 60 * time.Millisecond
	nackRetryMin = 55 * time.Millisecond
	nackRetryMax = time.Second
	reoDecay     = 2 * time.Second
	fillRingN    = 1024
	tailIdle     = 120 * time.Millisecond
	tailGap      = 100 * time.Millisecond
	tailStall    = time.Second
	tailBurst    = 128
)

var (
	localIP   = flag.String("L", "", "local source/bind IP")
	peerIP    = flag.String("R", "", "peer IP")
	tunAddr   = flag.String("A", "", "this box tun address")
	peerAddr  = flag.String("P", "", "peer tun address")
	basePort  = flag.Int("p", 49000, "base port")
	tunDev    = flag.String("T", "tsackless0", "tun device name")
	mtu       = flag.Int("M", 1400, "tun MTU")
	server    = flag.Bool("s", false, "run as server")
	fStart    = flag.Int("F", 2, "initial active flows")
	fMin      = flag.Int("Fmin", 1, "min flows")
	fMax      = flag.Int("Fmax", 6, "max flows")
	autoFlag  = flag.Bool("auto", true, "auto scale flows")
	statsSec  = flag.Int("st", 0, "stats seconds")
	reorderMs = flag.Int("ro", 0, "reorder hold ms (0=immediate)")
	psk       = flag.String("k", "", "pre-shared key")
)

var (
	activeN int32
	macKey  []byte
	epoch   uint64
	macPool = sync.Pool{New: func() any { return hmac.New(sha256.New, macKey) }}
)

func computeMac(aad, data, out []byte) {
	h := macPool.Get().(hash.Hash)
	h.Reset()
	h.Write(aad)
	h.Write(data)
	var sum [32]byte
	s := h.Sum(sum[:0])
	copy(out, s[:macLen])
	macPool.Put(h)
}

func verifyMac(aad, data, mac []byte) bool {
	var exp [macLen]byte
	computeMac(aad, data, exp[:])
	return hmac.Equal(exp[:], mac)
}

func aadFor(dir byte, sIP uint32, sPort uint16, dIP uint32, dPort uint16) []byte {
	a := make([]byte, 13)
	a[0] = dir
	binary.BigEndian.PutUint32(a[1:], sIP)
	binary.BigEndian.PutUint16(a[5:], sPort)
	binary.BigEndian.PutUint32(a[7:], dIP)
	binary.BigEndian.PutUint16(a[11:], dPort)
	return a
}

func ip4(s string) uint32 {
	p := net.ParseIP(strings.SplitN(s, "/", 2)[0]).To4()
	return binary.BigEndian.Uint32(p)
}

func bare(s string) string { return strings.SplitN(s, "/", 2)[0] }

func seqGt(a, b uint32) bool { return int32(a-b) > 0 }

func ipcsum(h []byte) uint16 {
	var s uint32
	for i := 0; i+1 < len(h); i += 2 {
		s += uint32(h[i])<<8 | uint32(h[i+1])
	}
	if len(h)%2 == 1 {
		s += uint32(h[len(h)-1]) << 8
	}
	for s>>16 != 0 {
		s = (s >> 16) + (s & 0xFFFF)
	}
	return ^uint16(s)
}

func tcpcsum(src, dst uint32, tcp []byte) uint16 {
	var s uint32
	ph := make([]byte, 12)
	binary.BigEndian.PutUint32(ph[0:], src)
	binary.BigEndian.PutUint32(ph[4:], dst)
	ph[9] = 6
	binary.BigEndian.PutUint16(ph[10:], uint16(len(tcp)))
	for i := 0; i+1 < len(ph); i += 2 {
		s += uint32(ph[i])<<8 | uint32(ph[i+1])
	}
	for i := 0; i+1 < len(tcp); i += 2 {
		s += uint32(tcp[i])<<8 | uint32(tcp[i+1])
	}
	if len(tcp)%2 == 1 {
		s += uint32(tcp[len(tcp)-1]) << 8
	}
	for s>>16 != 0 {
		s = (s >> 16) + (s & 0xFFFF)
	}
	return ^uint16(s)
}

type sender struct {
	fd       int
	sa       syscall.SockaddrInet4
	lip, pip uint32
	sport    uint16
	dport    uint16
	ident    uint32
}

func newSender(lip, pip uint32, sport, dport uint16) (*sender, error) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
	if err != nil {
		return nil, err
	}
	syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1)
	syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 1<<21)
	s := &sender{fd: fd, lip: lip, pip: pip, sport: sport, dport: dport}
	binary.BigEndian.PutUint32(s.sa.Addr[:], pip)
	return s, nil
}

func (s *sender) send(payload []byte) {
	total := 40 + len(payload)
	pkt := make([]byte, total)
	pkt[0] = 0x45
	binary.BigEndian.PutUint16(pkt[2:], uint16(total))
	id := atomic.AddUint32(&s.ident, 1)
	binary.BigEndian.PutUint16(pkt[4:], uint16(id))
	binary.BigEndian.PutUint16(pkt[6:], 0x4000)
	pkt[8] = 64
	pkt[9] = 6
	binary.BigEndian.PutUint32(pkt[12:], s.lip)
	binary.BigEndian.PutUint32(pkt[16:], s.pip)
	binary.BigEndian.PutUint16(pkt[10:], ipcsum(pkt[:20]))
	tcp := pkt[20:40]
	binary.BigEndian.PutUint16(tcp[0:], s.sport)
	binary.BigEndian.PutUint16(tcp[2:], s.dport)
	binary.BigEndian.PutUint32(tcp[4:], id)
	tcp[12] = 0x50
	tcp[13] = 0x00
	binary.BigEndian.PutUint16(tcp[14:], 0xFFFF)
	copy(pkt[40:], payload)
	binary.BigEndian.PutUint16(tcp[16:], tcpcsum(s.lip, s.pip, pkt[20:]))
	syscall.Sendto(s.fd, pkt, 0, &s.sa)
}

func putHdr(h []byte, typ byte, ep uint64, seq uint32, plen uint16) {
	h[0] = magic0
	h[1] = magic1
	h[2] = typ
	h[3] = 0
	binary.BigEndian.PutUint64(h[4:], ep)
	binary.BigEndian.PutUint32(h[12:], seq)
	binary.BigEndian.PutUint16(h[16:], plen)
}

func frameMac(aad, frame []byte) {
	n := len(frame)
	computeMac(aad, frame[:n-macLen], frame[n-macLen:])
}

const txWindow = arqW - 1

const seqReserveStride = 1 << 20
const seqReserveLow = 1 << 19

type txbuf struct {
	snd           *sender
	aadTx         []byte
	mu            sync.Mutex
	notAcked      *sync.Cond
	seqOf         []uint32
	buf           [][]byte
	seq           uint32
	nData         uint64
	nRe           uint64
	lastSent      uint32
	lastSendNanos int64
	ackedCum      uint32
	lastTailNanos int64
	base          uint32
	reserved      uint32
	sb            *sendBase
	nBaseFail     uint64
	cumMoveNanos  int64
	tailGBN       bool
}

func newTxbuf(snd *sender, aadTx []byte) *txbuf {
	t := &txbuf{snd: snd, aadTx: aadTx, seqOf: make([]uint32, arqW), buf: make([][]byte, arqW)}
	t.notAcked = sync.NewCond(&t.mu)
	return t
}

func (t *txbuf) initSendBase(sb *sendBase, start uint32) bool {
	if start < arqW {
		start += arqW
	}
	t.mu.Lock()
	t.sb = sb
	t.seq = start
	t.ackedCum = start
	t.lastSent = start
	t.base = start
	t.reserved = start + seqReserveStride
	t.mu.Unlock()
	if sb == nil {
		return true
	}
	return sb.persist(uint64(t.reserved))
}

func (t *txbuf) ensureReserve(next uint32) {
	if t.sb == nil {
		return
	}
	for seqGt(next+seqReserveLow, t.reserved) {
		nr := t.reserved + seqReserveStride
		if t.sb.persist(uint64(nr)) {
			t.reserved = nr
			return
		}
		atomic.AddUint64(&t.nBaseFail, 1)
		if seqGt(next, t.reserved) {
			time.Sleep(20 * time.Millisecond)
			continue
		}
		return
	}
}

func (t *txbuf) sendBaseAdvert() {
	t.mu.Lock()
	b := t.base
	hasBase := t.sb != nil
	t.mu.Unlock()
	if !hasBase {
		return
	}
	var body [4]byte
	binary.BigEndian.PutUint32(body[:], b)
	p := make([]byte, hdrLen+4+macLen)
	putHdr(p, tBase, epoch, 0, 4)
	copy(p[hdrLen:], body[:])
	frameMac(t.aadTx, p)
	t.snd.send(p)
}

func (t *txbuf) sendData(ip []byte) {
	t.mu.Lock()
	for {
		d := t.seq - t.ackedCum
		if d < txWindow || d > arqW {
			break
		}
		t.notAcked.Wait()
	}
	next := t.seq + 1
	t.mu.Unlock()
	t.ensureReserve(next)
	t.mu.Lock()
	t.seq++
	seq := t.seq
	p := make([]byte, hdrLen+len(ip)+macLen)
	putHdr(p, tData, epoch, seq, uint16(len(ip)))
	copy(p[hdrLen:], ip)
	frameMac(t.aadTx, p)
	slot := seq % arqW
	t.seqOf[slot] = seq
	t.buf[slot] = p
	now := time.Now().UnixNano()
	if t.lastSent == t.ackedCum {
		t.cumMoveNanos = now
	}
	t.lastSent = seq
	t.lastSendNanos = now
	t.mu.Unlock()
	t.snd.send(p)
	atomic.AddUint64(&t.nData, 1)
}

func (t *txbuf) retransmit(seq uint32) {
	slot := seq % arqW
	t.mu.Lock()
	var p []byte
	if t.seqOf[slot] == seq && t.buf[slot] != nil {
		p = t.buf[slot]
	}
	t.mu.Unlock()
	if p != nil {
		t.snd.send(p)
		atomic.AddUint64(&t.nRe, 1)
	}
}

func (t *txbuf) setAckedCum(c uint32) {
	t.mu.Lock()
	if seqGt(c, t.ackedCum) && !seqGt(c, t.lastSent) {
		t.ackedCum = c
		t.cumMoveNanos = time.Now().UnixNano()
		t.notAcked.Broadcast()
	}
	t.mu.Unlock()
}

func (t *txbuf) rtoLoop() {
	tk := time.NewTicker(40 * time.Millisecond)
	defer tk.Stop()
	for range tk.C {
		t.sendBaseAdvert()
		for _, s := range t.tailDue(time.Now().UnixNano()) {
			t.retransmit(s)
		}
	}
}

func (t *txbuf) held(s uint32) bool {
	return t.seqOf[s%arqW] == s && t.buf[s%arqW] != nil
}

func (t *txbuf) tailDue(now int64) []uint32 {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !seqGt(t.lastSent, t.ackedCum) {
		t.tailGBN = false
		return nil
	}
	if now-t.lastSendNanos <= int64(tailIdle) || now-t.lastTailNanos <= int64(tailGap) {
		return nil
	}
	t.lastTailNanos = now
	if !t.tailGBN && now-t.cumMoveNanos < int64(tailStall) {
		if t.held(t.lastSent) {
			return []uint32{t.lastSent}
		}
		return nil
	}
	t.tailGBN = true
	var list []uint32
	s := t.ackedCum + 1
	for n := 0; n < tailBurst; n++ {
		if t.held(s) {
			list = append(list, s)
		}
		if s == t.lastSent {
			break
		}
		s++
	}
	return list
}

type missInfo struct {
	first time.Time
	last  time.Time
	wait  time.Duration
	tries int
}

type fillRec struct {
	seq   uint32
	gen   uint32
	first time.Time
	fill  time.Time
	ok    bool
}

type epochGuard struct {
	mu    sync.Mutex
	floor uint64
	path  string
}

func loadDurableUint64(path string) (uint64, bool, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, false, true
		}
		return 0, false, false
	}
	v, perr := strconv.ParseUint(strings.SplitN(strings.TrimSpace(string(b)), "\n", 2)[0], 10, 64)
	if perr != nil {
		return 0, true, false
	}
	return v, true, true
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

func writeDurableUint64(path string, v uint64) bool {
	if path == "" {
		return true
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return false
	}
	_, werr := f.WriteString(strconv.FormatUint(v, 10) + "\n")
	serr := f.Sync()
	cerr := f.Close()
	if werr != nil || serr != nil || cerr != nil {
		os.Remove(tmp)
		return false
	}
	if os.Rename(tmp, path) != nil {
		return false
	}
	return syncParentDir(path) == nil
}

func (g *epochGuard) load(path string) {
	g.path = path
	v, present, ok := loadDurableUint64(path)
	if !ok {
		g.floor = ^uint64(0)
		return
	}
	if present {
		g.floor = v
	}
}

func (g *epochGuard) writeLocked(floor uint64) bool {
	return writeDurableUint64(g.path, floor)
}

type sendBase struct {
	path string
}

func (s *sendBase) load(path string) (uint32, bool) {
	s.path = path
	v, present, ok := loadDurableUint64(path)
	if !ok {
		return 0, false
	}
	if !present {
		return 0, true
	}
	return uint32(v), true
}

var durableWrite = writeDurableUint64

func (s *sendBase) persist(v uint64) bool {
	return durableWrite(s.path, v)
}

func (g *epochGuard) below(ep uint64) bool {
	g.mu.Lock()
	b := ep < g.floor
	g.mu.Unlock()
	return b
}

func (g *epochGuard) admit(ep uint64) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if ep < g.floor {
		return false
	}
	if ep == g.floor {
		return true
	}
	if !g.writeLocked(ep) {
		return false
	}
	g.floor = ep
	return true
}

type arqRx struct {
	tunFD        int
	wr           func([]byte) error
	snd          *sender
	tx           *txbuf
	eg           *epochGuard
	aadRx        []byte
	aadTxCtrl    []byte
	mu           sync.Mutex
	gen          uint32
	seqOf        []uint32
	genOf        []uint32
	maxSeq       uint32
	have         bool
	cumAck       uint32
	miss         map[uint32]*missInfo
	next         uint32
	haveNext     bool
	pend         map[uint32][]byte
	missingSince time.Time
	curEpoch     uint64
	rxBase       uint32
	rxBaseKnown  bool
	rxDeferred   bool
	rxFirstSeq   uint32
	ctrlCapture  func([]byte)
	rxNackNonce  uint32
	rxAckNonce   uint32
	txCtrlNonce  uint32
	nDeliv       uint64
	nDup         uint64
	nRxNack      uint64
	nSkip        uint64
	nAuthFail    uint64
	nReplay      uint64
	nEpochReset  uint64
	nCtrlDrop    uint64
	nSpurious    uint64
	srtt         time.Duration
	rttvar       time.Duration
	rto          time.Duration
	backoffAt    time.Time
	reo          time.Duration
	reoAt        time.Time
	fills        []fillRec
}

func newArqRx(tunFD int, snd *sender, tx *txbuf, aadRx, aadTxCtrl []byte, eg *epochGuard) *arqRx {
	if eg == nil {
		eg = &epochGuard{}
	}
	return &arqRx{tunFD: tunFD, snd: snd, tx: tx, eg: eg, aadRx: aadRx, aadTxCtrl: aadTxCtrl,
		seqOf: make([]uint32, arqW), genOf: make([]uint32, arqW), miss: make(map[uint32]*missInfo), pend: make(map[uint32][]byte),
		fills: make([]fillRec, fillRingN)}
}

func (r *arqRx) writeTun(ip []byte) error {
	if r.wr != nil {
		return r.wr(ip)
	}
	_, err := syscall.Write(r.tunFD, ip)
	return err
}

func (r *arqRx) resetEpochState(ep uint64) {
	r.curEpoch = ep
	r.gen++
	r.maxSeq = 0
	r.have = false
	r.cumAck = 0
	r.rxBase = 0
	r.rxBaseKnown = false
	r.rxDeferred = false
	r.rxFirstSeq = 0
	r.next = 0
	r.haveNext = false
	r.miss = make(map[uint32]*missInfo)
	r.pend = make(map[uint32][]byte)
	r.missingSince = time.Time{}
	r.rxNackNonce = 0
	r.rxAckNonce = 0
	atomic.AddUint64(&r.nEpochReset, 1)
}

func (r *arqRx) present(seq uint32) bool {
	slot := seq % arqW
	return r.genOf[slot] == r.gen && r.seqOf[slot] == seq
}

func (r *arqRx) advanceCum() {
	for r.present(r.cumAck + 1) {
		r.cumAck++
	}
}

func (r *arqRx) recordGap(from, to uint32) {
	g := from
	n := 0
	for seqGt(to, g) && n < 2048 {
		if !r.present(g) {
			r.miss[g] = &missInfo{first: time.Now()}
		}
		g++
		n++
	}
}

func clampDur(v, lo, hi time.Duration) time.Duration {
	if v > hi {
		v = hi
	}
	if v < lo {
		v = lo
	}
	return v
}

func (r *arqRx) noteRTT(s time.Duration) {
	if s <= 0 {
		return
	}
	if r.srtt == 0 {
		r.srtt = s
		r.rttvar = s / 2
	} else {
		d := r.srtt - s
		if d < 0 {
			d = -d
		}
		r.rttvar += (d - r.rttvar) / 4
		r.srtt += (s - r.srtt) / 8
	}
	v := 4 * r.rttvar
	if v < nackTick {
		v = nackTick
	}
	r.rto = clampDur(r.srtt+v, nackRetryMin, nackRetryMax)
}

func (r *arqRx) retryNow(floor time.Duration) time.Duration {
	if r.rto > floor {
		return r.rto
	}
	return floor
}

func (r *arqRx) backoff(now time.Time, floor time.Duration) {
	cur := r.retryNow(floor)
	if !r.backoffAt.IsZero() && now.Sub(r.backoffAt) < cur {
		return
	}
	r.rto = clampDur(2*cur, floor, nackRetryMax)
	r.backoffAt = now
}

func (r *arqRx) reoNow(now time.Time) time.Duration {
	if r.reo == 0 {
		return 0
	}
	k := now.Sub(r.reoAt) / reoDecay
	if k <= 0 {
		return r.reo
	}
	if k >= 32 {
		r.reo = 0
		return 0
	}
	r.reo >>= uint(k)
	r.reoAt = r.reoAt.Add(k * reoDecay)
	return r.reo
}

func (r *arqRx) noteReorder(l time.Duration, now time.Time) {
	if l <= 0 || l > nackGuardMax {
		return
	}
	cur := r.reoNow(now)
	if l > cur {
		r.reo = l
		r.reoAt = now
	} else if 2*l >= cur {
		r.reoAt = now
	}
}

func (r *arqRx) guardNow(now time.Time, floor time.Duration) time.Duration {
	g := r.reoNow(now)
	g += g / 4
	if g > nackGuardMax {
		g = nackGuardMax
	}
	if g < floor {
		g = floor
	}
	return g
}

func (r *arqRx) sampleFill(seq uint32, mi *missInfo, now time.Time) {
	switch mi.tries {
	case 0:
		r.noteReorder(now.Sub(mi.first), now)
	case 1:
		r.noteRTT(now.Sub(mi.last))
		r.fills[seq%fillRingN] = fillRec{seq: seq, gen: r.gen, first: mi.first, fill: now, ok: true}
	}
}

func (r *arqRx) noteDup(seq uint32) {
	f := &r.fills[seq%fillRingN]
	if !f.ok || f.seq != seq || f.gen != r.gen {
		return
	}
	f.ok = false
	atomic.AddUint64(&r.nSpurious, 1)
	r.noteReorder(f.fill.Sub(f.first), time.Now())
}

func (r *arqRx) noteSeq(seq uint32) {
	if mi, ok := r.miss[seq]; ok {
		r.sampleFill(seq, mi, time.Now())
		delete(r.miss, seq)
	}
	if !r.have {
		r.have = true
		r.maxSeq = seq
		if r.rxBaseKnown && seqGt(seq, r.rxBase) && seqGt(r.rxBase+arqW, seq) {
			r.cumAck = r.rxBase
			r.recordGap(r.rxBase+1, seq)
		} else if r.rxBaseKnown {
			r.cumAck = seq - 1
		} else if seq > arqW/32 {
			r.rxDeferred = true
			r.rxFirstSeq = seq
		} else {
			r.recordGap(r.cumAck+1, seq)
		}
	} else if seqGt(seq, r.maxSeq) {
		r.recordGap(r.maxSeq+1, seq)
		r.maxSeq = seq
	}
}

func (r *arqRx) commitWritten(seq, slot uint32) {
	if r.genOf[slot] != r.gen || r.seqOf[slot] != seq {
		r.genOf[slot] = r.gen
		r.seqOf[slot] = seq
	}
	r.advanceCum()
}

func (r *arqRx) markReceived(seq, slot uint32) {
	r.noteSeq(seq)
	r.commitWritten(seq, slot)
}

type dentry struct {
	seq  uint32
	body []byte
}

func (r *arqRx) flushDeliver(deliver []dentry, gen uint32) int {
	n := 0
	for _, d := range deliver {
		r.mu.Lock()
		if r.gen != gen {
			r.mu.Unlock()
			break
		}
		if r.writeTun(d.body) != nil {
			r.mu.Unlock()
			break
		}
		if d.seq == r.next {
			r.next++
		}
		delete(r.pend, d.seq)
		if len(r.pend) == 0 {
			r.missingSince = time.Time{}
		}
		r.commitWritten(d.seq, d.seq%arqW)
		r.mu.Unlock()
		atomic.AddUint64(&r.nDeliv, 1)
		n++
	}
	return n
}

func (r *arqRx) handle(payload []byte) {
	if len(payload) < hdrLen+macLen || payload[0] != magic0 || payload[1] != magic1 {
		return
	}
	typ := payload[2]
	ep := binary.BigEndian.Uint64(payload[4:])
	seq := binary.BigEndian.Uint32(payload[12:])
	plen := int(binary.BigEndian.Uint16(payload[16:]))
	if hdrLen+plen+macLen > len(payload) {
		return
	}
	if !verifyMac(r.aadRx, payload[:hdrLen+plen], payload[hdrLen+plen:hdrLen+plen+macLen]) {
		atomic.AddUint64(&r.nAuthFail, 1)
		return
	}
	body := payload[hdrLen : hdrLen+plen]
	r.mu.Lock()
	if r.eg.below(ep) {
		r.mu.Unlock()
		atomic.AddUint64(&r.nReplay, 1)
		return
	}
	if ep != r.curEpoch {
		if ep < r.curEpoch || !r.eg.admit(ep) {
			r.mu.Unlock()
			atomic.AddUint64(&r.nReplay, 1)
			return
		}
		r.resetEpochState(ep)
	}
	if typ == tData {
		if r.have && !seqGt(seq, r.cumAck) {
			r.noteDup(seq)
			r.mu.Unlock()
			atomic.AddUint64(&r.nDup, 1)
			return
		}
		if r.have && int32(r.maxSeq-seq) >= arqW {
			r.mu.Unlock()
			atomic.AddUint64(&r.nReplay, 1)
			return
		}
		slot := seq % arqW
		dup := r.genOf[slot] == r.gen && r.seqOf[slot] == seq
		if *reorderMs <= 0 {
			if dup {
				r.noteDup(seq)
				r.mu.Unlock()
				atomic.AddUint64(&r.nDup, 1)
				return
			}
			if r.eg.below(ep) {
				r.mu.Unlock()
				atomic.AddUint64(&r.nReplay, 1)
				return
			}
			b := make([]byte, plen)
			copy(b, body)
			if r.writeTun(b) != nil {
				r.mu.Unlock()
				return
			}
			r.markReceived(seq, slot)
			r.mu.Unlock()
			atomic.AddUint64(&r.nDeliv, 1)
			return
		}
		var deliver []dentry
		gen := r.gen
		r.noteSeq(seq)
		if !r.rxDeferred && !r.haveNext {
			r.haveNext = true
			r.next = r.cumAck + 1
		}
		if dup || !seqGt(seq, r.next-1) {
			if dup {
				r.noteDup(seq)
				atomic.AddUint64(&r.nDup, 1)
			}
		} else if seq == r.next {
			b := make([]byte, plen)
			copy(b, body)
			deliver = append(deliver, dentry{seq, b})
			nx := r.next + 1
			for {
				if bb, ok := r.pend[nx]; ok {
					deliver = append(deliver, dentry{nx, bb})
					nx++
				} else {
					break
				}
			}
		} else {
			if _, ok := r.pend[seq]; !ok {
				b := make([]byte, plen)
				copy(b, body)
				r.pend[seq] = b
				if r.missingSince.IsZero() {
					r.missingSince = time.Now()
				}
			}
		}
		r.mu.Unlock()
		r.flushDeliver(deliver, gen)
	} else if typ == tNack {
		if seqGt(seq, r.rxNackNonce) {
			r.rxNackNonce = seq
			r.mu.Unlock()
			atomic.AddUint64(&r.nRxNack, 1)
			for i := 0; i+4 <= plen; i += 4 {
				r.tx.retransmit(binary.BigEndian.Uint32(body[i:]))
			}
		} else {
			r.mu.Unlock()
			atomic.AddUint64(&r.nCtrlDrop, 1)
		}
	} else if typ == tAck {
		if seqGt(seq, r.rxAckNonce) {
			r.rxAckNonce = seq
			r.mu.Unlock()
			if plen >= 4 {
				r.tx.setAckedCum(binary.BigEndian.Uint32(body))
			}
		} else {
			r.mu.Unlock()
			atomic.AddUint64(&r.nCtrlDrop, 1)
		}
	} else if typ == tBase {
		if plen >= 4 {
			nb := binary.BigEndian.Uint32(body)
			r.rxBase = nb
			r.rxBaseKnown = true
			if !r.have {
				r.cumAck = nb
			} else if r.rxDeferred {
				r.rxDeferred = false
				if seqGt(r.rxFirstSeq, nb) && seqGt(nb+arqW, r.rxFirstSeq) {
					r.cumAck = nb
					r.recordGap(nb+1, r.maxSeq)
				} else {
					r.cumAck = r.rxFirstSeq - 1
				}
				r.advanceCum()
				if *reorderMs > 0 {
					r.haveNext = true
					r.next = r.cumAck + 1
					for {
						bb, ok := r.pend[r.next]
						if !ok {
							break
						}
						if r.writeTun(bb) != nil {
							break
						}
						delete(r.pend, r.next)
						r.commitWritten(r.next, r.next%arqW)
						atomic.AddUint64(&r.nDeliv, 1)
						r.next++
					}
					if len(r.pend) == 0 {
						r.missingSince = time.Time{}
					}
				}
			}
		}
		r.mu.Unlock()
	} else {
		r.mu.Unlock()
	}
}

func (r *arqRx) sendCtrl(typ byte, body []byte) {
	r.mu.Lock()
	r.txCtrlNonce++
	nonce := r.txCtrlNonce
	r.mu.Unlock()
	p := make([]byte, hdrLen+len(body)+macLen)
	putHdr(p, typ, epoch, nonce, uint16(len(body)))
	copy(p[hdrLen:], body)
	frameMac(r.aadTxCtrl, p)
	r.snd.send(p)
}

func (r *arqRx) reorderTimeout(now time.Time) {
	if *reorderMs <= 0 {
		return
	}
	r.mu.Lock()
	if r.haveNext && !r.missingSince.IsZero() && now.Sub(r.missingSince) > time.Duration(*reorderMs)*time.Millisecond {
		if r.have && seqGt(r.maxSeq+1, r.next) && !r.present(r.next) {
			if _, ok := r.miss[r.next]; !ok {
				r.miss[r.next] = &missInfo{first: now}
			}
		}
	}
	r.mu.Unlock()
}

func (r *arqRx) nackDue(now time.Time, guard, retry time.Duration) []uint32 {
	var list []uint32
	r.mu.Lock()
	g := r.guardNow(now, guard)
	for s, mi := range r.miss {
		if now.Sub(mi.first) < g {
			continue
		}
		wait := r.retryNow(retry)
		if !mi.last.IsZero() {
			if mi.wait > wait {
				wait = mi.wait
			}
			if now.Sub(mi.last) < wait {
				continue
			}
			r.backoff(now, retry)
			wait = clampDur(2*wait, retry, nackRetryMax)
		}
		list = append(list, s)
		mi.last = now
		mi.wait = wait
		mi.tries++
		if len(list) >= 4096 {
			break
		}
	}
	r.mu.Unlock()
	return list
}

func (r *arqRx) nackLoop() {
	tk := time.NewTicker(nackTick)
	defer tk.Stop()
	ackEvery := 0
	for range tk.C {
		now := time.Now()
		r.reorderTimeout(now)
		list := r.nackDue(now, nackGuardMin, nackRetryMin)
		r.mu.Lock()
		snapGen := r.gen
		r.mu.Unlock()
		for off := 0; off < len(list); off += nackMax {
			end := off + nackMax
			if end > len(list) {
				end = len(list)
			}
			chunk := list[off:end]
			body := make([]byte, len(chunk)*4)
			for i, s := range chunk {
				binary.BigEndian.PutUint32(body[i*4:], s)
			}
			r.sendCtrl(tNack, body)
		}
		ackEvery++
		if ackEvery >= 2 {
			ackEvery = 0
			r.emitAck(snapGen)
		}
	}
}

func (r *arqRx) emitAck(snapGen uint32) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.have || r.gen != snapGen {
		return
	}
	r.txCtrlNonce++
	nonce := r.txCtrlNonce
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], r.cumAck)
	if r.ctrlCapture != nil {
		r.ctrlCapture(b[:])
		return
	}
	p := make([]byte, hdrLen+4+macLen)
	putHdr(p, tAck, epoch, nonce, 4)
	copy(p[hdrLen:], b[:])
	frameMac(r.aadTxCtrl, p)
	r.snd.send(p)
}

type sockFilter struct {
	code uint16
	jt   uint8
	jf   uint8
	k    uint32
}

func bpfProg(peer, local uint32, rsrc, rdst uint16) []sockFilter {
	return []sockFilter{
		{0x28, 0, 0, 12},
		{0x15, 0, 11, 0x0800},
		{0x30, 0, 0, 23},
		{0x15, 0, 9, 6},
		{0x20, 0, 0, 26},
		{0x15, 0, 7, peer},
		{0x20, 0, 0, 30},
		{0x15, 0, 5, local},
		{0x28, 0, 0, 34},
		{0x15, 0, 3, uint32(rsrc)},
		{0x28, 0, 0, 36},
		{0x15, 0, 1, uint32(rdst)},
		{0x06, 0, 0, 262144},
		{0x06, 0, 0, 0},
	}
}

func htons(v uint16) uint16 { return (v<<8)&0xff00 | v>>8 }

func attachFilter(fd int, prog []sockFilter) error {
	var buf []byte
	ptr := uintptr(unsafe.Pointer(&prog[0]))
	if unsafe.Sizeof(uintptr(0)) == 8 {
		buf = make([]byte, 16)
		binary.LittleEndian.PutUint16(buf[0:], uint16(len(prog)))
		binary.LittleEndian.PutUint64(buf[8:], uint64(ptr))
	} else {
		buf = make([]byte, 8)
		binary.LittleEndian.PutUint16(buf[0:], uint16(len(prog)))
		binary.LittleEndian.PutUint32(buf[4:], uint32(ptr))
	}
	_, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, uintptr(fd), uintptr(syscall.SOL_SOCKET), 26,
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0)
	runtime.KeepAlive(prog)
	runtime.KeepAlive(buf)
	if e != 0 {
		return fmt.Errorf("attach filter: %v", e)
	}
	return nil
}

func openRx(dev string, peer, local uint32, rsrc, rdst uint16) (int, error) {
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, int(htons(0x0003)))
	if err != nil {
		return -1, err
	}
	if err := attachFilter(fd, bpfProg(peer, local, rsrc, rdst)); err != nil {
		syscall.Close(fd)
		return -1, err
	}
	syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 1<<23)
	ifi, err := net.InterfaceByName(dev)
	if err != nil {
		syscall.Close(fd)
		return -1, err
	}
	ll := syscall.SockaddrLinklayer{Protocol: htons(0x0003), Ifindex: ifi.Index}
	if err := syscall.Bind(fd, &ll); err != nil {
		syscall.Close(fd)
		return -1, err
	}
	return fd, nil
}

func openTun(name string) (int, error) {
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR, 0)
	if err != nil {
		return -1, err
	}
	var ifr [40]byte
	copy(ifr[:16], []byte(name))
	binary.LittleEndian.PutUint16(ifr[16:], uint16(0x0001|0x1000))
	_, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(0x400454ca), uintptr(unsafe.Pointer(&ifr)))
	if e != 0 {
		syscall.Close(fd)
		return -1, fmt.Errorf("TUNSETIFF: %v", e)
	}
	return fd, nil
}

func sh(name string, args ...string) { exec.Command(name, args...).Run() }

func devForIP(ip string) string {
	ifaces, _ := net.Interfaces()
	for _, i := range ifaces {
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.String() == ip {
				return i.Name
			}
		}
	}
	return ""
}

func configTun(name, addr, peer string) {
	sh("ip", "addr", "flush", "dev", name)
	sh("ip", "addr", "add", addr, "peer", peer, "dev", name)
	sh("ip", "link", "set", name, "mtu", fmt.Sprintf("%d", *mtu))
	sh("ip", "link", "set", name, "txqueuelen", "1000")
	sh("ip", "link", "set", name, "up")
}

func nftTable() string {
	s := make([]byte, 0, len(*tunDev))
	for i := 0; i < len(*tunDev); i++ {
		c := (*tunDev)[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' {
			s = append(s, c)
		} else {
			s = append(s, '_')
		}
	}
	return "ackless_" + string(s)
}

func nftRange(base, capN int) (int, int) {
	hi := base + 99
	if base+4*capN+4 > hi {
		hi = base + 4*capN + 4
	}
	return base, hi
}

var nftRun = func(args ...string) error { return exec.Command("nft", args...).Run() }

func setupNft(peer string, lo, hi int) error {
	teardownNft()
	tbl := nftTable()
	pr := fmt.Sprintf("%d-%d", lo, hi)
	rules := [][]string{
		{"add", "table", "ip", tbl},
		{"add", "chain", "ip", tbl, "out", "{", "type", "filter", "hook", "output", "priority", "0", ";", "policy", "accept", ";", "}"},
		{"add", "rule", "ip", tbl, "out", "ip", "daddr", peer, "tcp", "sport", pr, "tcp", "flags", "rst", "drop"},
		{"add", "rule", "ip", tbl, "out", "ip", "daddr", peer, "tcp", "dport", pr, "tcp", "flags", "rst", "drop"},
		{"add", "chain", "ip", tbl, "in", "{", "type", "filter", "hook", "input", "priority", "0", ";", "policy", "accept", ";", "}"},
		{"add", "rule", "ip", tbl, "in", "ip", "saddr", peer, "tcp", "dport", pr, "drop"},
		{"add", "rule", "ip", tbl, "in", "ip", "saddr", peer, "tcp", "sport", pr, "drop"},
	}
	for _, r := range rules {
		if err := nftRun(r...); err != nil {
			teardownNft()
			return fmt.Errorf("nft %s: %w", strings.Join(r, " "), err)
		}
	}
	return nil
}

func teardownNft() { nftRun("delete", "table", "ip", nftTable()) }

func epochFloorPath() string {
	os.MkdirAll("/var/lib/omnitunnel", 0700)
	return "/var/lib/omnitunnel/" + nftTable() + ".floor"
}

func sendBasePath(idx int) string {
	os.MkdirAll("/var/lib/omnitunnel", 0700)
	return "/var/lib/omnitunnel/" + nftTable() + ".sendbase." + strconv.Itoa(idx)
}

type flow struct {
	idx  int
	snd  *sender
	tx   *txbuf
	rx   *arqRx
	rxfd int
	q    chan []byte
}

func (f *flow) enqueue(ip []byte) { f.q <- ip }

func dispatchIndex(ip []byte, capN int) int {
	n := capN
	if n < 1 {
		n = 1
	}
	return int(flowHash(ip) % uint32(n))
}

func flowHash(ip []byte) uint32 {
	if len(ip) < 20 {
		return 0
	}
	var h uint32 = 2166136261
	mix := func(b byte) { h ^= uint32(b); h *= 16777619 }
	for i := 12; i < 20; i++ {
		mix(ip[i])
	}
	proto := ip[9]
	mix(proto)
	ihl := int(ip[0]&0x0F) * 4
	if (proto == 6 || proto == 17) && len(ip) >= ihl+4 {
		for i := ihl; i < ihl+4; i++ {
			mix(ip[i])
		}
	}
	return h
}

func main() {
	flag.Parse()
	if *localIP == "" || *peerIP == "" || *tunAddr == "" || *peerAddr == "" {
		fmt.Fprintln(os.Stderr, "omniackless: need -L -R -A -P")
		os.Exit(2)
	}
	if *psk == "" {
		fmt.Fprintln(os.Stderr, "omniackless: need -k <psk>")
		os.Exit(2)
	}
	k := sha256.Sum256([]byte(*psk))
	macKey = k[:]
	var eb [8]byte
	rand.Read(eb[:])
	epoch = uint64(time.Now().UnixNano())&0xFFFFFFFFFFFF0000 | uint64(binary.BigEndian.Uint16(eb[:]))
	lip := ip4(*localIP)
	pip := ip4(*peerIP)
	base := *basePort
	capN := *fMax
	if capN < 1 {
		capN = 1
	}
	if _, err := net.InterfaceByName(*tunDev); err == nil {
		fmt.Fprintf(os.Stderr, "omniackless: tun device %s already exists; refusing to start\n", *tunDev)
		os.Exit(1)
	}
	dev := devForIP(bare(*localIP))
	if dev == "" {
		fmt.Fprintf(os.Stderr, "omniackless: no interface owns -L %s\n", bare(*localIP))
		os.Exit(1)
	}
	tunFD, err := openTun(*tunDev)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tun:", err)
		os.Exit(1)
	}
	configTun(*tunDev, bare(*tunAddr), bare(*peerAddr))
	nlo, nhi := nftRange(base, capN)
	if err := setupNft(bare(*peerIP), nlo, nhi); err != nil {
		fmt.Fprintln(os.Stderr, "omniackless: nft RST-suppression setup failed:", err)
		sh("ip", "link", "set", *tunDev, "down")
		os.Exit(1)
	}

	var dirTx, dirRx byte
	if *server {
		dirTx, dirRx = 1, 0
	} else {
		dirTx, dirRx = 0, 1
	}
	eg := &epochGuard{}
	eg.load(epochFloorPath())
	flows := make([]*flow, capN)
	for i := 0; i < capN; i++ {
		var txs, txd, rxp, rxd uint16
		if *server {
			txs, txd, rxp, rxd = uint16(base+3+i*4), uint16(base+4+i*4), uint16(base+1+i*4), uint16(base+2+i*4)
		} else {
			txs, txd, rxp, rxd = uint16(base+1+i*4), uint16(base+2+i*4), uint16(base+3+i*4), uint16(base+4+i*4)
		}
		snd, err := newSender(lip, pip, txs, txd)
		if err != nil {
			fmt.Fprintln(os.Stderr, "tx:", err)
			os.Exit(1)
		}
		rxfd, err := openRx(dev, pip, lip, rxp, rxd)
		if err != nil {
			fmt.Fprintln(os.Stderr, "rx:", err)
			os.Exit(1)
		}
		aadTx := aadFor(dirTx, lip, txs, pip, txd)
		aadRx := aadFor(dirRx, pip, rxp, lip, rxd)
		tx := newTxbuf(snd, aadTx)
		sb := &sendBase{}
		start, ok := sb.load(sendBasePath(i))
		if !ok {
			fmt.Fprintf(os.Stderr, "omniackless: send-base for flow %d is malformed; refusing to start to avoid sequence reuse\n", i)
			os.Exit(1)
		}
		if !tx.initSendBase(sb, start) {
			fmt.Fprintf(os.Stderr, "omniackless: send-base for flow %d could not be durably reserved; refusing to start to avoid sequence reuse\n", i)
			os.Exit(1)
		}
		for k := 0; k < 3; k++ {
			tx.sendBaseAdvert()
		}
		rx := newArqRx(tunFD, snd, tx, aadRx, aadTx, eg)
		flows[i] = &flow{idx: i, snd: snd, tx: tx, rx: rx, rxfd: rxfd, q: make(chan []byte, 1024)}
	}
	for i := 0; i < capN; i++ {
		f := flows[i]
		go func(f *flow) {
			for ip := range f.q {
				f.tx.sendData(ip)
			}
		}(f)
		go func(f *flow) {
			buf := make([]byte, 65535)
			for {
				n, _, err := syscall.Recvfrom(f.rxfd, buf, 0)
				if err != nil || n < 54 {
					continue
				}
				ihl := int(buf[14]&0x0F) * 4
				l4 := 14 + ihl
				if l4+20 > n {
					continue
				}
				p := make([]byte, n-(l4+20))
				copy(p, buf[l4+20:n])
				f.rx.handle(p)
			}
		}(f)
		go f.rx.nackLoop()
		go f.tx.rtoLoop()
	}
	atomic.StoreInt32(&activeN, int32(capN))

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		teardownNft()
		sh("ip", "link", "set", *tunDev, "down")
		os.Exit(0)
	}()

	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := syscall.Read(tunFD, buf)
			if err != nil || n <= 0 {
				continue
			}
			ip := make([]byte, n)
			copy(ip, buf[:n])
			flows[dispatchIndex(ip, capN)].enqueue(ip)
		}
	}()

	if *statsSec > 0 {
		go statsLoop(flows)
	}
	select {}
}

func statsLoop(flows []*flow) {
	tk := time.NewTicker(time.Duration(*statsSec) * time.Second)
	defer tk.Stop()
	var lastDeliv uint64
	for range tk.C {
		var data, re, deliv, dup, nk, af, rp, er, cd, sp uint64
		var gMax, rMax time.Duration
		now := time.Now()
		for _, f := range flows {
			sp += atomic.LoadUint64(&f.rx.nSpurious)
			f.rx.mu.Lock()
			if g := f.rx.guardNow(now, nackGuardMin); g > gMax {
				gMax = g
			}
			if rt := f.rx.retryNow(nackRetryMin); rt > rMax {
				rMax = rt
			}
			f.rx.mu.Unlock()
			data += atomic.LoadUint64(&f.tx.nData)
			re += atomic.LoadUint64(&f.tx.nRe)
			deliv += atomic.LoadUint64(&f.rx.nDeliv)
			dup += atomic.LoadUint64(&f.rx.nDup)
			nk += atomic.LoadUint64(&f.rx.nRxNack)
			af += atomic.LoadUint64(&f.rx.nAuthFail)
			rp += atomic.LoadUint64(&f.rx.nReplay)
			er += atomic.LoadUint64(&f.rx.nEpochReset)
			cd += atomic.LoadUint64(&f.rx.nCtrlDrop)
		}
		dd := deliv - lastDeliv
		lastDeliv = deliv
		fmt.Printf("stats N=%d txData=%d txRe=%d rxDeliv=%d rxDup=%d rxNack=%d authFail=%d replay=%d epochReset=%d ctrlDrop=%d rxMbit~=%.1f reRatio=%.3f rxSpur=%d nackGuardMs=%.1f nackRtoMs=%.1f\n",
			atomic.LoadInt32(&activeN), data, re, deliv, dup, nk, af, rp, er, cd,
			float64(dd)*float64(*mtu)*8/1e6/float64(*statsSec),
			ratio(re, data), sp, float64(gMax)/1e6, float64(rMax)/1e6)
	}
}

func ratio(a, b uint64) float64 {
	if a+b == 0 {
		return 0
	}
	return float64(a) / float64(a+b)
}
