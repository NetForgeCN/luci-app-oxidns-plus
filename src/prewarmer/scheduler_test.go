package main

import (
	"sync"
	"testing"
	"time"
)

// fakeSource models OxiDNS cache entries with a mutable remaining TTL. A test
// can simulate the native lazy refresh by raising remaining back to ttl.
type fakeSource struct {
	mu      sync.Mutex
	entries map[Key]CacheEntry
	calls   int
}

func newFakeSource() *fakeSource {
	return &fakeSource{entries: map[Key]CacheEntry{}}
}

func (f *fakeSource) put(domain, qtype string, ttl, remaining int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	// String-encoded answers_json, matching what the real OxiDNS API returns.
	f.entries[Key{domain, qtype}] = CacheEntry{
		Domain: domain, RecordType: qtype, TTL: FlexInt(ttl), RemainingTTL: FlexInt(remaining),
		Answers: []byte(`"[{\"address\":\"1.2.3.4\"}]"`),
	}
}

func (f *fakeSource) remove(domain, qtype string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.entries, Key{domain, qtype})
}

func (f *fakeSource) Entries(qname string, limit int) ([]CacheEntry, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	out := []CacheEntry{}
	for k, e := range f.entries {
		if qname != "" && k.Domain != qname {
			continue
		}
		out = append(out, e)
	}
	return out, nil
}

// countingProber records triggers. It does not mutate cache on its own — the
// test decides whether the refresh "succeeded" by calling put() afterwards.
type countingProber struct {
	mu      sync.Mutex
	count   int
	onProbe func()
}

func (p *countingProber) Probe(target, domain, qtype string) error {
	p.mu.Lock()
	p.count++
	fn := p.onProbe
	p.mu.Unlock()
	if fn != nil {
		fn()
	}
	return nil
}

func (p *countingProber) Count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.count
}

func testConfig() Config {
	return Config{
		APIBase: "http://127.0.0.1:9199/", DNSTarget: "127.0.0.1:5333",
		Mode: "list", TickSec: 1, GraceSec: 0, RefreshDelay: 5,
		MinTTLSec: 30, MinInterval: 1, MaxInterval: 60, JitterSec: 0,
		RetryBaseSec: 1, RetryMaxSec: 4, RetryMaxCount: 3,
	}
}

func nopLog(string, ...interface{}) {}

func TestWarmSeedOnColdCache(t *testing.T) {
	cfg := testConfig()
	src := newFakeSource()
	prober := &countingProber{}
	// On first probe, simulate upstream writing a fresh answer into OxiDNS.
	prober.onProbe = func() { src.put("a.example.com", "A", 120, 120) }
	watched := []Key{{Domain: "a.example.com", QType: "A"}}
	s := NewScheduler(cfg, src, prober, watched)

	go s.Run(nopLog)
	defer s.Stop()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		st := s.Status()
		if len(st.Tasks) > 0 && st.Tasks[0].LastResult == "seeded" {
			if st.Stats.Seeds != 1 {
				t.Fatalf("expected 1 seed, got %d", st.Stats.Seeds)
			}
			if prober.Count() < 1 {
				t.Fatalf("expected >=1 probe")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("seed never happened; status=%+v", s.Status())
}

func TestStaleHitRefreshesAndFollowsNewTTL(t *testing.T) {
	cfg := testConfig()
	src := newFakeSource()
	// Entry is stale: remaining ~0, original TTL was 120.
	src.put("b.example.com", "A", 120, 0)

	prober := &countingProber{}
	prober.onProbe = func() {
		// Upstream returned a longer TTL: 120 -> 300. Native lazy refresh
		// writes it back, so API now reports remaining=300.
		src.put("b.example.com", "A", 300, 300)
	}
	watched := []Key{{Domain: "b.example.com", QType: "A"}}
	s := NewScheduler(cfg, src, prober, watched)

	go s.Run(nopLog)
	defer s.Stop()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		st := s.Status()
		if st.Stats.RefreshOK >= 1 {
			if st.Tasks[0].TTL != 300 {
				t.Fatalf("expected TTL to follow to 300, got %d", st.Tasks[0].TTL)
			}
			// Next deadline must be ~300s out (adaptive), not the old 120.
			next, err := time.Parse(time.RFC3339, st.Tasks[0].NextProbe)
			if err != nil {
				t.Fatalf("bad next_probe: %v", err)
			}
			if d := time.Until(next); d < 250*time.Second || d > 310*time.Second {
				t.Fatalf("next probe not adaptive: %s (d=%s)", next, d)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("refresh never detected; status=%+v", s.Status())
}

func TestFailureBackoffKeepsOldCache(t *testing.T) {
	cfg := testConfig()
	src := newFakeSource()
	src.put("c.example.com", "A", 120, 0)
	prober := &countingProber{} // no refresh: remaining stays 0
	watched := []Key{{Domain: "c.example.com", QType: "A"}}
	s := NewScheduler(cfg, src, prober, watched)

	go s.Run(nopLog)
	defer s.Stop()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		st := s.Status()
		if st.Stats.RefreshFailed >= 1 {
			if st.Tasks[0].LastResult != "refresh-failed" {
				t.Fatalf("expected refresh-failed, got %s", st.Tasks[0].LastResult)
			}
			// The entry must still be present (we never delete anything).
			if _, err := src.Entries("c.example.com", 10); err != nil {
				t.Fatalf("source should be untouched: %v", err)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("failure path never hit; status=%+v", s.Status())
}

func TestShortTTLUsesFixedLead(t *testing.T) {
	lead, kind := (&Scheduler{cfg: testConfig()}).leadFor(10, 5)
	if kind != "short-ttl-fixed" {
		t.Fatalf("expected short-ttl-fixed, got %s", kind)
	}
	// min_interval=1s, grace=0 -> fixed floor = 1s (grace+1s)
	if lead < time.Second {
		t.Fatalf("fixed lead too short: %s", lead)
	}
}

func TestSingleFlight(t *testing.T) {
	cfg := testConfig()
	src := newFakeSource()
	src.put("d.example.com", "A", 120, 0)
	prober := &countingProber{}
	watched := []Key{{Domain: "d.example.com", QType: "A"}}
	s := NewScheduler(cfg, src, prober, watched)

	go s.Run(nopLog)
	defer s.Stop()
	// Multiple reconciles in a row must not stack probes on the same key.
	for i := 0; i < 5; i++ {
		s.reconcile(nopLog)
		s.dispatch(nopLog)
	}
	time.Sleep(100 * time.Millisecond)
	if prober.Count() > 1 {
		t.Fatalf("single-flight violated: %d probes for one key", prober.Count())
	}
}
