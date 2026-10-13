package main

import (
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func ilKey() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i*5 + 9)
	}
	return k
}

func ilWrongKey() []byte {
	k := ilKey()
	k[0] ^= 0xFF
	return k
}

func ilTunnel(t *testing.T, key []byte, role string, nlanes, window int) *Tunnel {
	t.Helper()
	f, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatalf("devnull: %v", err)
	}
	t.Cleanup(func() { f.Close() })
	return newTunnel(role, f, 4096, nlanes, window, 300*time.Millisecond, 2*time.Millisecond, 30, key)
}

func ilPacket() []byte {
	return []byte{0, 4, 'd', 'a', 't', 'a'}
}

func TestTuplePoolInterleaving(t *testing.T) {
	cd := 80 * time.Millisecond
	s := newTupleSched(40000, 40040, 30001, 30030, cd, 0)
	var held sync.Map
	var mu sync.Mutex
	lastRelease := map[uint64]time.Time{}
	var acq int64
	var wg sync.WaitGroup
	deadline := time.Now().Add(1500 * time.Millisecond)
	for g := 0; g < 24; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(deadline) {
				now := time.Now()
				sp, dp, ok := s.acquire(now)
				if !ok {
					time.Sleep(s.waitHint(now))
					continue
				}
				key := uint64(sp)<<20 | uint64(dp)
				if _, dup := held.LoadOrStore(key, true); dup {
					t.Errorf("tuple %d/%d held by two goroutines at once", sp, dp)
				}
				mu.Lock()
				if prev, seen := lastRelease[key]; seen {
					if gap := now.Sub(prev); gap < cd {
						t.Errorf("tuple %d/%d re-acquired %v after release (< cooldown %v)", sp, dp, gap, cd)
					}
				}
				mu.Unlock()
				atomic.AddInt64(&acq, 1)
				time.Sleep(time.Millisecond)
				rel := time.Now()
				held.Delete(key)
				mu.Lock()
				lastRelease[key] = rel
				mu.Unlock()
				s.release(sp, dp, rel)
			}
		}()
	}
	wg.Wait()
	if acq < 100 {
		t.Fatalf("suspiciously few acquisitions under concurrency: %d", acq)
	}
}

func TestConcurrentApplyRejectsReplayForged(t *testing.T) {
	rcv := ilTunnel(t, ilKey(), "turkey", 1, 1024)
	builder := ilTunnel(t, ilKey(), "relay", 1, 1024)
	atk := ilTunnel(t, ilWrongKey(), "relay", 1, 1024)

	const n = 500
	good := make([][]byte, n)
	forged := make([][]byte, n)
	for i := 0; i < n; i++ {
		good[i] = builder.build(0, 0, uint64(i+1), ilPacket())
		forged[i] = atk.build(0, 0, uint64(i+1), ilPacket())
	}

	var delivered, forgedAccepted int64
	var wg sync.WaitGroup
	for g := 0; g < 6; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < n; i++ {
				if rcv.apply(good[i]) {
					atomic.AddInt64(&delivered, 1)
				}
			}
		}()
	}
	for g := 0; g < 2; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < n; i++ {
				if rcv.apply(forged[i]) {
					atomic.AddInt64(&forgedAccepted, 1)
				}
			}
		}()
	}
	wg.Wait()

	if forgedAccepted != 0 {
		t.Fatalf("%d forged frames accepted under concurrent apply", forgedAccepted)
	}
	if delivered != int64(n) {
		t.Fatalf("expected exactly %d unique deliveries, got %d (replay window not exactly-once under concurrency)", n, delivered)
	}
}

func TestNoRemovalWithoutAckConcurrent(t *testing.T) {
	s := newSender(4096, time.Hour, 1<<30)
	const n = 1500
	var wg sync.WaitGroup
	stop := make(chan struct{})
	prod := make(chan struct{})

	go func() {
		for i := 0; i < n; i++ {
			s.addChunk([]byte{byte(i), byte(i >> 8)})
		}
		close(prod)
	}()
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				seq, buf := s.getSend(time.Millisecond)
				if buf != nil {
					s.requeue(seq)
				}
			}
		}()
	}
	select {
	case <-prod:
	case <-time.After(10 * time.Second):
		close(stop)
		wg.Wait()
		t.Fatal("producer blocked adding chunks within the window")
	}
	close(stop)
	wg.Wait()
	if b := s.backlog(); b != n {
		t.Fatalf("expected all %d chunks still inflight (never ACKed), got %d: %d removed WITHOUT an ACK", n, b, n-b)
	}
}

func TestSenderInterleavedWritersReaders(t *testing.T) {
	s := newSender(128, 10*time.Millisecond, 3)
	var wg sync.WaitGroup
	stop := make(chan struct{})
	const total = 4000
	var ackCum uint64

	wg.Add(1)
	go func() {
		defer wg.Done()
		tk := time.NewTicker(time.Millisecond)
		defer tk.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tk.C:
				c := atomic.AddUint64(&ackCum, 8)
				s.applyAck(c, c+1, make([]byte, sackBytes))
			}
		}
	}()
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				seq, buf := s.getSend(2 * time.Millisecond)
				if buf != nil && seq%3 == 0 {
					s.requeue(seq)
				}
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			s.requeueTimeouts()
			_ = s.backlog()
			time.Sleep(time.Millisecond)
		}
	}()

	prod := make(chan struct{})
	go func() {
		for i := 0; i < total; i++ {
			s.addChunk([]byte{byte(i), byte(i >> 8)})
		}
		close(prod)
	}()
	select {
	case <-prod:
	case <-time.After(10 * time.Second):
		close(stop)
		wg.Wait()
		t.Fatal("producer blocked: window never drained under concurrency (deadlock)")
	}
	close(stop)
	wg.Wait()
	s.applyAck(uint64(total)+1<<20, uint64(total)+1<<20+1, make([]byte, sackBytes))
	if b := s.backlog(); b != 0 {
		t.Fatalf("after acking everything, %d chunks still inflight (lost/stuck under concurrency)", b)
	}
}

func TestClientRTOTracksTimeout(t *testing.T) {
	cases := []struct {
		in   time.Duration
		want time.Duration
	}{
		{0, 10 * time.Second},
		{-1, 10 * time.Second},
		{100 * time.Millisecond, 500 * time.Millisecond},
		{1500 * time.Millisecond, 3 * time.Second},
		{2500 * time.Millisecond, 5 * time.Second},
		{5 * time.Second, 10 * time.Second},
	}
	for _, c := range cases {
		if got := clientRTO(c.in); got != c.want {
			t.Fatalf("clientRTO(%v)=%v want %v", c.in, got, c.want)
		}
	}
	if clientRTO(1500*time.Millisecond) <= 1500*time.Millisecond {
		t.Fatalf("rto must exceed the io timeout so it never races an in-flight round trip")
	}
}

func TestMultiLaneApplyRejectsReplayForged(t *testing.T) {
	const nlanes = 8
	const perLane = 128
	rcv := ilTunnel(t, ilKey(), "turkey", nlanes, 2048)
	builder := ilTunnel(t, ilKey(), "relay", nlanes, 2048)
	atk := ilTunnel(t, ilWrongKey(), "relay", nlanes, 2048)

	var good, forged [][]byte
	for ln := 0; ln < nlanes; ln++ {
		for i := 0; i < perLane; i++ {
			good = append(good, builder.build(ln, 0, uint64(i+1), ilPacket()))
			forged = append(forged, atk.build(ln, 0, uint64(i+1), ilPacket()))
		}
	}

	var delivered, forgedAccepted int64
	var wg sync.WaitGroup
	for g := 0; g < 6; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range good {
				if rcv.apply(good[i]) {
					atomic.AddInt64(&delivered, 1)
				}
			}
		}()
	}
	for g := 0; g < 2; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range forged {
				if rcv.apply(forged[i]) {
					atomic.AddInt64(&forgedAccepted, 1)
				}
			}
		}()
	}
	wg.Wait()

	if forgedAccepted != 0 {
		t.Fatalf("%d forged frames accepted across %d lanes (HMAC auth broken)", forgedAccepted, nlanes)
	}
	if atomic.LoadInt64(&rcv.authFail) == 0 {
		t.Fatalf("expected forged frames to register as auth failures")
	}
	if delivered != int64(nlanes*perLane) {
		t.Fatalf("expected exactly %d unique deliveries across lanes, got %d (replay not exactly-once under concurrency)", nlanes*perLane, delivered)
	}
}
