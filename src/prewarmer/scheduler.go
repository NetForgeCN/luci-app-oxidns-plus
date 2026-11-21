package main

import (
	"math/rand"
	"sort"
	"sync"
	"time"
)

// Scheduler is the adaptive prewarmer core. It owns one independent deadline
// per (domain, qtype). It never stores answers and never queries an upstream:
// it only (1) reads TTL truth from the OxiDNS cache API and (2) fires a DNS
// query at OxiDNS's own listener so the native lazy cache refreshes.
type Scheduler struct {
	cfg     Config
	src     EntrySource
	prober  Prober
	watched []Key // from watch.list

	mu      sync.Mutex
	tasks   map[Key]*TaskState
	stats   Stats
	started time.Time

	results chan probeResult
	stop    chan struct{}
}

type probeResult struct {
	key        Key
	oldRemain  int64
	newRemain  int64
	newTTL     int64
	hadEntry   bool
	nowEntry   bool
	err        error
	finishedAt time.Time
}

func NewScheduler(cfg Config, src EntrySource, prober Prober, watched []Key) *Scheduler {
	return &Scheduler{
		cfg: cfg, src: src, prober: prober, watched: watched,
		tasks:   make(map[Key]*TaskState),
		results: make(chan probeResult, 256),
		stop:    make(chan struct{}),
		started: time.Now(),
	}
}

func (s *Scheduler) Stop() { close(s.stop) }

// Run blocks: reconcile on every tick, dispatch due probes, consume results.
func (s *Scheduler) Run(logf func(string, ...interface{})) {
	tick := time.Duration(s.cfg.TickSec)
	if tick <= 0 {
		tick = time.Second
	}
	ticker := time.NewTicker(tick)
	defer ticker.Stop()

	s.reconcile(logf)
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
			s.reconcile(logf)
			s.dispatch(logf)
		case r := <-s.results:
			s.applyResult(r, logf)
		}
	}
}

// TTL lead policy, mirroring the spec:
//
//	ttl < min_ttl        -> fixed minimum lead (avoid short-TTL hammering)
//	min_ttl <= ttl       -> expire at original TTL, add grace (land in stale)
//	every deadline       -> add jitter so many domains don't fire together
func (s *Scheduler) leadFor(ttl, remaining int64) (time.Duration, string) {
	grace := time.Duration(s.cfg.GraceSec) * time.Second
	jitter := time.Duration(rand.Intn(s.cfg.JitterSec+1)) * time.Second

	base := time.Duration(remaining) * time.Second
	if base < 0 {
		base = 0
	}
	if ttl > 0 && ttl < int64(s.cfg.MinTTLSec) {
		fixed := time.Duration(s.cfg.MinInterval) * time.Second
		if fixed < grace+time.Second {
			fixed = grace + time.Second
		}
		return fixed, "short-ttl-fixed"
	}
	return base + grace + jitter, "adaptive"
}

// reconcile refreshes TTL truth from the API. It does NOT reset a deadline on
// natural TTL decay — only on a genuine upward TTL jump (120 -> 300), which is
// how it follows upstream TTL changes without ever drifting from repeated
// re-reads.
func (s *Scheduler) reconcile(logf func(string, ...interface{})) {
	// Build the desired key set.
	desired := make(map[Key]bool)
	for _, k := range s.watched {
		desired[k] = true
	}

	observed := make(map[Key]CacheEntry)
	if s.cfg.Mode == "all" {
		list, err := s.src.Entries("", 5000)
		if err != nil {
			logf("reconcile: entries(all) failed: %v", err)
		} else {
			for _, e := range list {
				k := Key{Domain: e.NormalizedDomain(), QType: normalizeQType(e.RecordType)}
				if k.Domain == "" || !e.HasUsableAnswer() {
					continue
				}
				observed[k] = e
				desired[k] = true
			}
		}
	} else {
		// One exact-ish query per watched domain (qname is a substring filter;
		// we match exactly below).
		for _, k := range s.watched {
			list, err := s.src.Entries(k.Domain, 50)
			if err != nil {
				logf("reconcile: entries(%s) failed: %v", k.Domain, err)
				continue
			}
			for _, e := range list {
				if e.NormalizedDomain() != k.Domain || normalizeQType(e.RecordType) != k.QType {
					continue
				}
				if !e.HasUsableAnswer() {
					continue
				}
				observed[k] = e
			}
		}
	}

	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()

	// Create / update tasks.
	for k := range desired {
		t := s.tasks[k]
		if t == nil {
			t = &TaskState{Key: k, Updated: now}
			s.tasks[k] = t
		}
		for _, wk := range s.watched {
			if wk == k {
				t.InWatchList = true
				break
			}
		}
		e, ok := observed[k]
		if !ok {
			// No cache entry (cold start or expired-and-gone): seed immediately.
			t.LastResult = "seed"
			if t.Deadline.IsZero() {
				t.Deadline = now
			}
			continue
		}
		rem := int64(e.RemainingTTL)
		ttl := int64(e.TTL)
		if rem < 0 {
			rem = 0
		}
		// Genuine upward jump = somebody refreshed this entry (by us or by a
		// real query). Follow the new TTL. Natural decay never resets deadline.
		if rem > t.LastRemaining+2 && t.LastRemaining > 0 && !t.Inflight {
			lead, _ := s.leadFor(ttl, rem)
			t.Deadline = now.Add(lead)
			t.Backoff = 0
			t.LastResult = "ttl-changed"
		}
		if t.Deadline.IsZero() {
			lead, kind := s.leadFor(ttl, rem)
			t.Deadline = now.Add(lead)
			if kind == "short-ttl-fixed" {
				t.LastResult = "short-ttl-fixed"
				s.stats.SkippedShort++
			}
		}
		t.LastTTL = ttl
		t.LastRemaining = rem
		t.Updated = now
	}

	// Remove tasks no longer desired (only relevant in "all" mode).
	for k := range s.tasks {
		if !desired[k] && !s.tasks[k].Inflight {
			delete(s.tasks, k)
		}
	}
}

// dispatch fires all due, non-inflight probes. Single-flight is enforced by
// the Inflight flag set under the mutex before the goroutine starts.
func (s *Scheduler) dispatch(logf func(string, ...interface{})) {
	now := time.Now()
	s.mu.Lock()
	var due []*TaskState
	for _, t := range s.tasks {
		if t.Inflight || t.Deadline.IsZero() || now.Before(t.Deadline) {
			continue
		}
		// Hard floor between two probes of the same key.
		if !t.LastProbe.IsZero() && now.Sub(t.LastProbe) < time.Duration(s.cfg.MinInterval)*time.Second {
			t.Deadline = t.LastProbe.Add(time.Duration(s.cfg.MinInterval) * time.Second)
			continue
		}
		t.Inflight = true
		t.LastProbe = now
		due = append(due, t)
	}
	s.mu.Unlock()

	for _, t := range due {
		go s.probe(t, logf)
	}
}

// probe: read current entry -> fire DNS trigger -> wait -> re-read -> report.
func (s *Scheduler) probe(t *TaskState, logf func(string, ...interface{})) {
	s.mu.Lock()
	oldRemain := t.LastRemaining
	hadEntry := oldRemain > 0 || t.LastTTL > 0
	s.mu.Unlock()

	var oldEntry bool
	list, err := s.src.Entries(t.Key.Domain, 50)
	if err == nil {
		for _, e := range list {
			if e.NormalizedDomain() == t.Key.Domain && normalizeQType(e.RecordType) == t.Key.QType {
				oldEntry = true
				oldRemain = int64(e.RemainingTTL)
				break
			}
		}
	}

	err = s.prober.Probe(s.cfg.DNSTarget, t.Key.Domain, t.Key.QType)
	if err != nil {
		s.results <- probeResult{key: t.Key, oldRemain: oldRemain, hadEntry: oldEntry, err: err, finishedAt: time.Now()}
		return
	}

	time.Sleep(time.Duration(s.cfg.RefreshDelay) * time.Millisecond)

	var after CacheEntry
	nowEntry := false
	if list, err2 := s.src.Entries(t.Key.Domain, 50); err2 == nil {
		for _, e := range list {
			if e.NormalizedDomain() == t.Key.Domain && normalizeQType(e.RecordType) == t.Key.QType {
				after = e
				nowEntry = true
				break
			}
		}
	}
	s.results <- probeResult{
		key: t.Key, oldRemain: oldRemain, newRemain: int64(after.RemainingTTL),
		newTTL: int64(after.TTL), hadEntry: hadEntry, nowEntry: nowEntry,
		finishedAt: time.Now(),
	}
}

// applyResult decides success from a remaining_ttl jump. last_access is not
// used: our own trigger query updates it, so it would be a false positive.
func (s *Scheduler) applyResult(r probeResult, logf func(string, ...interface{})) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tasks[r.key]
	if t == nil {
		return
	}
	t.Inflight = false
	now := r.finishedAt

	if r.err != nil {
		s.stats.Probes++
		s.stats.RefreshFailed++
		t.LastResult = "failed"
		t.LastError = r.err.Error()
		t.Backoff++
		t.Deadline = now.Add(s.backoffDelay(t.Backoff))
		logf("probe %s: trigger error: %v -> retry in %s", r.key, r.err, s.backoffDelay(t.Backoff))
		return
	}

	s.stats.Probes++
	if !r.hadEntry && r.nowEntry {
		// Cold-start seed succeeded: a real answer is now in OxiDNS cache.
		s.stats.Seeds++
		t.LastResult = "seeded"
		t.LastError = ""
		t.Backoff = 0
		lead, _ := s.leadFor(r.newTTL, r.newRemain)
		t.Deadline = now.Add(lead)
		logf("seed %s: cached ttl=%d remaining=%d -> next in %s", r.key, r.newTTL, r.newRemain, lead)
		return
	}

	// Success = remaining_ttl jumped back up (stale ~0 -> fresh TTL).
	if r.nowEntry && r.newRemain > r.oldRemain+2 {
		s.stats.RefreshOK++
		t.LastResult = "refresh-ok"
		t.LastError = ""
		t.Backoff = 0
		lead, _ := s.leadFor(r.newTTL, r.newRemain)
		t.Deadline = now.Add(lead)
		t.LastTTL = r.newTTL
		t.LastRemaining = r.newRemain
		logf("refresh %s: ttl=%d remaining %d->%d -> next in %s", r.key, r.newTTL, r.oldRemain, r.newRemain, lead)
		return
	}

	// No jump within the wait window: treat as failed, keep the OLD cache
	// untouched (OxiDNS still serves it stale), retry with backoff.
	s.stats.RefreshFailed++
	t.LastResult = "refresh-failed"
	t.LastError = "remaining_ttl did not recover"
	t.Backoff++
	t.Deadline = now.Add(s.backoffDelay(t.Backoff))
	logf("refresh %s: no ttl recovery (remain %d->%d) -> retry in %s",
		r.key, r.oldRemain, r.newRemain, s.backoffDelay(t.Backoff))
}

func (s *Scheduler) backoffDelay(n int) time.Duration {
	if n <= 0 {
		n = 1
	}
	d := time.Duration(s.cfg.RetryBaseSec) * time.Second
	for i := 1; i < n; i++ {
		d *= 2
		if d >= time.Duration(s.cfg.RetryMaxSec)*time.Second {
			return time.Duration(s.cfg.RetryMaxSec) * time.Second
		}
	}
	if d > time.Duration(s.cfg.RetryMaxSec)*time.Second {
		d = time.Duration(s.cfg.RetryMaxSec) * time.Second
	}
	return d
}

func normalizeQType(s string) string {
	switch {
	case len(s) == 0:
		return "A"
	case s[0] == 'a' || s[0] == 'A':
		return "A"
	default:
		return "AAAA"
	}
}

// Status renders a stable snapshot for the status file.
func (s *Scheduler) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := Status{
		Enabled: true, Mode: s.cfg.Mode, APIBase: s.cfg.APIBase,
		DNSTarget: s.cfg.DNSTarget, StartedAt: s.started,
		UpdatedAt: time.Now(), Stats: s.stats,
	}
	keys := make([]Key, 0, len(s.tasks))
	for k := range s.tasks {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].String() < keys[j].String() })
	for _, k := range keys {
		t := s.tasks[k]
		in := "auto-discovered"
		if t.InWatchList {
			in = "watch-list"
		}
		next := "-"
		if !t.Deadline.IsZero() {
			next = t.Deadline.Format(time.RFC3339)
		}
		st.Tasks = append(st.Tasks, TaskView{
			Domain: k.Domain, QType: k.QType, TTL: t.LastTTL,
			RemainingTTL: t.LastRemaining, NextProbe: next, In: in,
			LastResult: t.LastResult, LastError: t.LastError, Backoff: t.Backoff,
		})
	}
	return st
}
