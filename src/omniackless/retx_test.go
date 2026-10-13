package main

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func nackedOnce(rx *arqRx, seq uint32, nackAgo time.Duration) {
	rx.mu.Lock()
	mi := rx.miss[seq]
	mi.first = time.Now().Add(-nackAgo - nackGuardMin)
	mi.last = time.Now().Add(-nackAgo)
	mi.wait = nackRetryMin
	mi.tries = 1
	rx.mu.Unlock()
}

func contains(list []uint32, s uint32) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func TestOldTimingIsTheFloorWithoutEvidence(t *testing.T) {
	rx, _ := mkRx(t)
	now := time.Now()
	rx.mu.Lock()
	g := rx.guardNow(now, nackGuardMin)
	w := rx.retryNow(nackRetryMin)
	rx.miss[10] = &missInfo{first: now.Add(-nackGuardMin)}
	rx.miss[11] = &missInfo{first: now.Add(-time.Second), last: now.Add(-nackRetryMin), wait: nackRetryMin, tries: 1}
	rx.mu.Unlock()
	if g != nackGuardMin || w != nackRetryMin {
		t.Fatalf("with no reorder or RTT evidence the timing must equal the old fixed 6ms/55ms: guard=%v retry=%v", g, w)
	}
	list := rx.nackDue(now, nackGuardMin, nackRetryMin)
	if !contains(list, 10) || !contains(list, 11) {
		t.Fatalf("a fresh flow must NACK exactly as early as before: list=%v", list)
	}
}

func TestLateFillBeforeNackWidensGuard(t *testing.T) {
	rx, aadTx := mkRx(t)
	const ep = uint64(9100)
	body := []byte("d")
	rx.handle(buildFrame(aadTx, tData, ep, 1, body))
	rx.handle(buildFrame(aadTx, tData, ep, 3, body))
	rx.mu.Lock()
	rx.miss[2].first = time.Now().Add(-20 * time.Millisecond)
	rx.mu.Unlock()
	rx.handle(buildFrame(aadTx, tData, ep, 2, body))
	now := time.Now()
	rx.mu.Lock()
	g := rx.guardNow(now, nackGuardMin)
	rx.miss[50] = &missInfo{first: now.Add(-22 * time.Millisecond)}
	rx.miss[51] = &missInfo{first: now.Add(-40 * time.Millisecond)}
	rx.mu.Unlock()
	if g < 25*time.Millisecond || g > 30*time.Millisecond {
		t.Fatalf("a frame that arrived 20ms late must widen the first-NACK guard to about 1.25x that: guard=%v", g)
	}
	list := rx.nackDue(now, nackGuardMin, nackRetryMin)
	if contains(list, 50) {
		t.Fatal("a hole younger than the measured reorder window must not be NACKed yet")
	}
	if !contains(list, 51) {
		t.Fatal("a hole older than the reorder window must still be NACKed")
	}
}

func TestDuplicateAfterSingleNackMarksSpuriousAndWidensGuard(t *testing.T) {
	rx, aadTx := mkRx(t)
	const ep = uint64(9200)
	body := []byte("d")
	rx.handle(buildFrame(aadTx, tData, ep, 1, body))
	rx.handle(buildFrame(aadTx, tData, ep, 3, body))
	nackedOnce(rx, 2, 3*time.Millisecond)
	rx.mu.Lock()
	rx.miss[2].first = time.Now().Add(-30 * time.Millisecond)
	rx.mu.Unlock()
	rx.handle(buildFrame(aadTx, tData, ep, 2, body))
	if n := atomic.LoadUint64(&rx.nSpurious); n != 0 {
		t.Fatalf("a single fill is not evidence of a spurious NACK: nSpurious=%d", n)
	}
	rx.handle(buildFrame(aadTx, tData, ep, 2, body))
	if n := atomic.LoadUint64(&rx.nSpurious); n != 1 {
		t.Fatalf("a second copy after exactly one NACK proves the NACK was spurious: nSpurious=%d", n)
	}
	rx.handle(buildFrame(aadTx, tData, ep, 2, body))
	if n := atomic.LoadUint64(&rx.nSpurious); n != 1 {
		t.Fatalf("one spurious NACK must be counted once: nSpurious=%d", n)
	}
	rx.mu.Lock()
	g := rx.guardNow(time.Now(), nackGuardMin)
	rx.mu.Unlock()
	if g < 37*time.Millisecond || g > 45*time.Millisecond {
		t.Fatalf("the guard must grow to cover the 30ms lateness the spurious NACK revealed: guard=%v", g)
	}
	if d := atomic.LoadUint64(&rx.nDup); d != 2 {
		t.Fatalf("duplicate accounting must be unchanged: nDup=%d", d)
	}
}

func TestSpuriousRecordIgnoredAcrossEpoch(t *testing.T) {
	rx, aadTx := mkRx(t)
	body := []byte("d")
	rx.handle(buildFrame(aadTx, tData, 9300, 1, body))
	rx.handle(buildFrame(aadTx, tData, 9300, 3, body))
	nackedOnce(rx, 2, 3*time.Millisecond)
	rx.handle(buildFrame(aadTx, tData, 9300, 2, body))
	rx.handle(buildFrame(aadTx, tData, 9301, 1, body))
	rx.handle(buildFrame(aadTx, tData, 9301, 2, body))
	rx.handle(buildFrame(aadTx, tData, 9301, 2, body))
	if n := atomic.LoadUint64(&rx.nSpurious); n != 0 {
		t.Fatalf("a fill record from an older epoch must never be matched by a new-epoch duplicate: nSpurious=%d", n)
	}
}

func TestReorderSampleAboveCapIgnored(t *testing.T) {
	rx, _ := mkRx(t)
	now := time.Now()
	rx.mu.Lock()
	rx.noteReorder(500*time.Millisecond, now)
	g := rx.guardNow(now, nackGuardMin)
	rx.noteReorder(nackGuardMax, now)
	g2 := rx.guardNow(now, nackGuardMin)
	rx.mu.Unlock()
	if g != nackGuardMin {
		t.Fatalf("a lateness above the cap is not reordering evidence: guard=%v", g)
	}
	if g2 != nackGuardMax {
		t.Fatalf("the guard must never exceed its cap: guard=%v", g2)
	}
}

func TestReorderWindowDecays(t *testing.T) {
	rx, _ := mkRx(t)
	t0 := time.Now()
	rx.mu.Lock()
	defer rx.mu.Unlock()
	rx.noteReorder(40*time.Millisecond, t0)
	if g := rx.guardNow(t0, nackGuardMin); g != 50*time.Millisecond {
		t.Fatalf("guard must be 1.25x the reorder window: %v", g)
	}
	rx.noteReorder(10*time.Millisecond, t0.Add(time.Second))
	if g := rx.guardNow(t0.Add(reoDecay), nackGuardMin); g != 25*time.Millisecond {
		t.Fatalf("a much smaller sample must not keep the window alive; it halves per decay period: %v", g)
	}
	if g := rx.guardNow(t0.Add(3*reoDecay), nackGuardMin); g != 6250*time.Microsecond {
		t.Fatalf("window must keep halving: %v", g)
	}
	if g := rx.guardNow(t0.Add(time.Hour), nackGuardMin); g != nackGuardMin {
		t.Fatalf("without reordering the guard must return to the 6ms floor: %v", g)
	}
	if rx.reo != 0 {
		t.Fatalf("a long quiet period must clear the window: %v", rx.reo)
	}
}

func TestComparableReorderKeepsWindowAlive(t *testing.T) {
	rx, _ := mkRx(t)
	t0 := time.Now()
	rx.mu.Lock()
	defer rx.mu.Unlock()
	rx.noteReorder(40*time.Millisecond, t0)
	for i := 1; i <= 10; i++ {
		rx.noteReorder(25*time.Millisecond, t0.Add(time.Duration(i)*time.Second))
	}
	if g := rx.guardNow(t0.Add(11*time.Second), nackGuardMin); g != 50*time.Millisecond {
		t.Fatalf("ongoing reordering of comparable size must hold the window: %v", g)
	}
}

func TestRetryTracksRepairRTT(t *testing.T) {
	rx, aadTx := mkRx(t)
	const ep = uint64(9400)
	body := []byte("d")
	rx.handle(buildFrame(aadTx, tData, ep, 1, body))
	seq := uint32(3)
	for i := 0; i < 24; i++ {
		rx.handle(buildFrame(aadTx, tData, ep, seq, body))
		nackedOnce(rx, seq-1, 200*time.Millisecond)
		rx.handle(buildFrame(aadTx, tData, ep, seq-1, body))
		seq += 2
	}
	now := time.Now()
	rx.mu.Lock()
	srtt := rx.srtt
	w := rx.retryNow(nackRetryMin)
	rx.miss[90000] = &missInfo{first: now.Add(-time.Second), last: now.Add(-150 * time.Millisecond), wait: nackRetryMin, tries: 1}
	rx.miss[90001] = &missInfo{first: now.Add(-time.Second), last: now.Add(-w - time.Millisecond), wait: nackRetryMin, tries: 1}
	rx.mu.Unlock()
	if srtt < 195*time.Millisecond || srtt > 215*time.Millisecond {
		t.Fatalf("SRTT must converge to the 200ms NACK->repair time: %v", srtt)
	}
	if w < srtt+nackTick || w > nackRetryMax {
		t.Fatalf("re-NACK interval must sit above SRTT: rto=%v srtt=%v", w, srtt)
	}
	list := rx.nackDue(now, nackGuardMin, nackRetryMin)
	if contains(list, 90000) {
		t.Fatal("a NACK whose repair is still within one repair RTT must not be repeated (the old 55ms re-NACK duplicated it)")
	}
	if !contains(list, 90001) {
		t.Fatal("a NACK older than the adaptive interval must be repeated")
	}
}

func TestKarnNoSampleFromRepeatedNack(t *testing.T) {
	rx, aadTx := mkRx(t)
	const ep = uint64(9500)
	body := []byte("d")
	rx.handle(buildFrame(aadTx, tData, ep, 1, body))
	rx.handle(buildFrame(aadTx, tData, ep, 3, body))
	rx.mu.Lock()
	rx.miss[2] = &missInfo{first: time.Now().Add(-time.Second), last: time.Now().Add(-10 * time.Millisecond), wait: nackRetryMin, tries: 2}
	rx.mu.Unlock()
	rx.handle(buildFrame(aadTx, tData, ep, 2, body))
	rx.handle(buildFrame(aadTx, tData, ep, 2, body))
	rx.mu.Lock()
	srtt, rto := rx.srtt, rx.rto
	rx.mu.Unlock()
	if srtt != 0 || rto != 0 {
		t.Fatalf("a fill after two NACKs is ambiguous and must not feed the RTT estimator: srtt=%v rto=%v", srtt, rto)
	}
	if n := atomic.LoadUint64(&rx.nSpurious); n != 0 {
		t.Fatalf("a duplicate after several NACKs is expected, not spurious evidence: %d", n)
	}
}

func TestBackoffWhenRetryShorterThanRepair(t *testing.T) {
	rx, _ := mkRx(t)
	now := time.Now()
	rx.mu.Lock()
	rx.miss[7] = &missInfo{first: now.Add(-time.Second), last: now.Add(-60 * time.Millisecond), wait: nackRetryMin, tries: 1}
	rx.miss[8] = &missInfo{first: now.Add(-time.Second), last: now.Add(-60 * time.Millisecond), wait: nackRetryMin, tries: 1}
	rx.mu.Unlock()
	list := rx.nackDue(now, nackGuardMin, nackRetryMin)
	rx.mu.Lock()
	rto := rx.rto
	w7, w8 := rx.miss[7].wait, rx.miss[8].wait
	rx.mu.Unlock()
	if len(list) != 1 {
		t.Fatalf("after one re-NACK proves the interval too short, the flow must back off before re-NACKing the next hole in the same pass: list=%v", list)
	}
	if rto != 2*nackRetryMin {
		t.Fatalf("flow interval must double on a re-NACK: %v", rto)
	}
	if w7 != 2*nackRetryMin && w8 != 2*nackRetryMin {
		t.Fatalf("the re-NACKed hole must wait twice as long before its next NACK: %v %v", w7, w8)
	}
	rx.mu.Lock()
	rx.noteRTT(80 * time.Millisecond)
	rto = rx.rto
	rx.mu.Unlock()
	if rto != 80*time.Millisecond+40*time.Millisecond*4 {
		t.Fatalf("a valid sample must recompute the interval from SRTT/RTTVAR: %v", rto)
	}
}

func TestLongMissingSeqStillNackedAtCappedInterval(t *testing.T) {
	rx, _ := mkRx(t)
	now := time.Now()
	rx.mu.Lock()
	rx.rto = nackRetryMax
	rx.miss[5] = &missInfo{first: now.Add(-time.Minute), last: now.Add(-nackRetryMax - time.Millisecond), wait: nackRetryMax, tries: 40}
	rx.mu.Unlock()
	for i := 0; i < 5; i++ {
		list := rx.nackDue(now, nackGuardMin, nackRetryMin)
		if !contains(list, 5) {
			t.Fatalf("round %d: a missing seq must keep being NACKed at most every %v, never abandoned", i, nackRetryMax)
		}
		rx.mu.Lock()
		w := rx.miss[5].wait
		rx.mu.Unlock()
		if w > nackRetryMax {
			t.Fatalf("per-hole backoff must be capped at %v: %v", nackRetryMax, w)
		}
		now = now.Add(nackRetryMax + time.Millisecond)
	}
}

func TestRTOClampedToBounds(t *testing.T) {
	rx, _ := mkRx(t)
	rx.mu.Lock()
	defer rx.mu.Unlock()
	rx.noteRTT(time.Millisecond)
	if rx.retryNow(nackRetryMin) != nackRetryMin {
		t.Fatalf("a tiny RTT must never NACK more often than the old 55ms: %v", rx.retryNow(nackRetryMin))
	}
	for i := 0; i < 50; i++ {
		rx.noteRTT(5 * time.Second)
	}
	if rx.retryNow(nackRetryMin) != nackRetryMax {
		t.Fatalf("a huge RTT must cap the interval at %v: %v", nackRetryMax, rx.retryNow(nackRetryMin))
	}
	rx.noteRTT(0)
	rx.noteRTT(-time.Second)
	if rx.retryNow(nackRetryMin) != nackRetryMax {
		t.Fatal("non-positive samples must be ignored")
	}
}

func mkTx(t *testing.T) *txbuf {
	t.Helper()
	snd, err := newSender(ip4("10.0.0.1"), ip4("10.0.0.2"), 49001, 49002)
	if err != nil {
		t.Skip("raw socket needs root:", err)
	}
	tx := newTxbuf(snd, aadFor(0, ip4("10.0.0.1"), 49001, ip4("10.0.0.2"), 49002))
	tx.initSendBase(nil, 0)
	return tx
}

func stage(tx *txbuf, n int, sentAt, movedAt int64) {
	tx.mu.Lock()
	for i := 0; i < n; i++ {
		tx.seq++
		tx.seqOf[tx.seq%arqW] = tx.seq
		tx.buf[tx.seq%arqW] = []byte{byte(i)}
	}
	tx.lastSent = tx.seq
	tx.lastSendNanos = sentAt
	tx.cumMoveNanos = movedAt
	tx.mu.Unlock()
}

func TestTailProbeSendsOnlyNewestFrame(t *testing.T) {
	tx := mkTx(t)
	now := time.Now().UnixNano()
	stage(tx, 300, now-int64(200*time.Millisecond), now-int64(300*time.Millisecond))
	list := tx.tailDue(now)
	tx.mu.Lock()
	last := tx.lastSent
	tx.mu.Unlock()
	if len(list) != 1 || list[0] != last {
		t.Fatalf("an idle flow with unacked frames must probe with only its newest frame, not resend 128 the peer likely holds: %v", list)
	}
	if again := tx.tailDue(now + int64(50*time.Millisecond)); again != nil {
		t.Fatalf("probes must stay rate limited: %v", again)
	}
}

func TestTailProbeIdleAndAckedGates(t *testing.T) {
	tx := mkTx(t)
	now := time.Now().UnixNano()
	stage(tx, 10, now-int64(50*time.Millisecond), now-int64(5*time.Second))
	if l := tx.tailDue(now); l != nil {
		t.Fatalf("a flow that is still sending must not probe: %v", l)
	}
	tx.mu.Lock()
	ls := tx.lastSent
	tx.mu.Unlock()
	tx.setAckedCum(ls)
	if l := tx.tailDue(now + int64(time.Second)); l != nil {
		t.Fatalf("a fully acked flow must not probe: %v", l)
	}
}

func TestTailProbeFallsBackToGoBackNAfterStall(t *testing.T) {
	tx := mkTx(t)
	now := time.Now().UnixNano()
	stage(tx, 300, now-int64(200*time.Millisecond), now-int64(tailStall)-1)
	tx.mu.Lock()
	first := tx.ackedCum + 1
	tx.mu.Unlock()
	list := tx.tailDue(now)
	if len(list) != tailBurst || list[0] != first || list[tailBurst-1] != first+tailBurst-1 {
		t.Fatalf("after %v without ack progress the probe must fall back to the old go-back-N burst: len=%d", tailStall, len(list))
	}
	tx.setAckedCum(first + tailBurst - 1)
	now += int64(150 * time.Millisecond)
	list = tx.tailDue(now)
	if len(list) != tailBurst || list[0] != first+tailBurst {
		t.Fatalf("once in go-back-N recovery the crawl must continue at the old pace: len=%d", len(list))
	}
	tx.mu.Lock()
	ls := tx.lastSent
	tx.mu.Unlock()
	tx.setAckedCum(ls)
	if l := tx.tailDue(now + int64(150*time.Millisecond)); l != nil {
		t.Fatalf("a fully acked flow must leave recovery: %v", l)
	}
	tx.mu.Lock()
	gbn := tx.tailGBN
	tx.mu.Unlock()
	if gbn {
		t.Fatal("go-back-N mode must clear once everything is acked")
	}
}

func TestTailStallClockStartsAtFirstOutstandingFrame(t *testing.T) {
	tx := mkTx(t)
	tx.mu.Lock()
	tx.cumMoveNanos = time.Now().Add(-time.Hour).UnixNano()
	tx.mu.Unlock()
	for i := 0; i < 5; i++ {
		tx.sendData(make([]byte, 40))
	}
	tx.mu.Lock()
	moved := tx.cumMoveNanos
	tx.mu.Unlock()
	if time.Since(time.Unix(0, moved)) > time.Minute {
		t.Fatal("the stall clock must restart when data becomes outstanding after an all-acked period")
	}
	list := tx.tailDue(time.Now().Add(200 * time.Millisecond).UnixNano())
	if len(list) != 1 {
		t.Fatalf("the first probe after a quiet period must be a single-frame probe, not go-back-N: %v", list)
	}
}

func TestNackTimingConcurrentHandleNackLoopAndStats(t *testing.T) {
	rx, aadTx := mkRx(t)
	const ep = uint64(9600)
	const n = 6000
	frames := make([][]byte, n+1)
	for s := 1; s <= n; s++ {
		frames[s] = buildFrame(aadTx, tData, ep, uint32(s), []byte("d"))
	}
	newer := buildFrame(aadTx, tData, ep+1, 1, []byte("d"))
	stop := make(chan struct{})
	var bg sync.WaitGroup
	bg.Add(2)
	go func() {
		defer bg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			rx.nackDue(time.Now(), nackGuardMin, nackRetryMin)
		}
	}()
	go func() {
		defer bg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			rx.mu.Lock()
			g := rx.guardNow(time.Now(), nackGuardMin)
			w := rx.retryNow(nackRetryMin)
			rx.mu.Unlock()
			if g < nackGuardMin || g > nackGuardMax || w < nackRetryMin || w > nackRetryMax {
				t.Errorf("timing escaped its bounds under concurrency: guard=%v retry=%v", g, w)
				return
			}
		}
	}()
	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for s := 1 + w; s <= n; s += 4 {
				if s%7 != 0 {
					rx.handle(frames[s])
				}
			}
			for s := 7; s <= n; s += 7 {
				if s%4 == w {
					rx.handle(frames[s])
					rx.handle(frames[s])
				}
			}
		}(w)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(5 * time.Millisecond)
		rx.handle(newer)
	}()
	wg.Wait()
	close(stop)
	bg.Wait()
	if sp, dup := atomic.LoadUint64(&rx.nSpurious), atomic.LoadUint64(&rx.nDup); sp > dup {
		t.Fatalf("spurious detections must be a subset of duplicates: spurious=%d dup=%d", sp, dup)
	}
	rx.mu.Lock()
	for s, mi := range rx.miss {
		if mi.wait > nackRetryMax || mi.tries < 0 {
			t.Fatalf("hole %d has corrupt timing state: %+v", s, *mi)
		}
	}
	rx.mu.Unlock()
}

func TestTailProbeConcurrentWithSendAndAck(t *testing.T) {
	tx := mkTx(t)
	stop := make(chan struct{})
	var bg sync.WaitGroup
	bg.Add(2)
	go func() {
		defer bg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			tx.mu.Lock()
			ls := tx.lastSent
			tx.mu.Unlock()
			tx.setAckedCum(ls - 3)
		}
	}()
	go func() {
		defer bg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			list := tx.tailDue(time.Now().Add(time.Duration(i%3) * time.Second).UnixNano())
			tx.mu.Lock()
			ls := tx.lastSent
			tx.mu.Unlock()
			for _, s := range list {
				if seqGt(s, ls) {
					t.Errorf("probe chose seq %d beyond lastSent %d", s, ls)
					return
				}
			}
		}
	}()
	for i := 0; i < 3000; i++ {
		tx.sendData(make([]byte, 40))
	}
	close(stop)
	bg.Wait()
}
