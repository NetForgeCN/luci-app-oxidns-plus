package main

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"
)

// Config is the complete runtime configuration. The OpenWrt init script reads
// UCI and passes every value as a command-line flag, so this binary has no
// dependency on libuci or on the OxiDNS main config file.
type Config struct {
	APIBase       string
	APIUser       string
	APIPass       string
	CacheTag      string
	DNSTarget     string
	WatchList     string
	Mode          string // "list" (watch list) or "all" (every cached entry)
	TickSec       int
	GraceSec      int // delay AFTER fresh expiry, to land inside the stale window
	RefreshDelay  int // milliseconds to wait for the async refresh to complete
	MinTTLSec     int // TTLs below this are not adaptively rescheduled
	MinInterval   int // hard floor between two probes of the same key
	MaxInterval   int // upper bound for backoff retries
	JitterSec     int // random extra delay added to every deadline (>= 0)
	RetryBaseSec  int
	RetryMaxSec   int
	RetryMaxCount int
	StatusFile    string
	LogLevel      string
}

// FlexInt accepts both JSON numbers and JSON strings. OxiDNS has changed the
// wire type of TTL-like fields between releases; accepting both avoids a hard
// failure on a minor upgrade.
type FlexInt int64

func (f *FlexInt) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "" || s == "null" {
		*f = 0
		return nil
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		// tolerate floats such as 120.0
		fv, ferr := strconv.ParseFloat(s, 64)
		if ferr != nil {
			return err
		}
		v = int64(fv)
	}
	*f = FlexInt(v)
	return nil
}

// CacheEntry is one row of GET /api/plugins/<tag>/entries.
type CacheEntry struct {
	Domain       string          `json:"domain"`
	RecordType   string          `json:"record_type"`
	TTL          FlexInt         `json:"ttl"`
	RemainingTTL FlexInt         `json:"remaining_ttl"`
	Answers      json.RawMessage `json:"answers_json"`
	LastAccessMS FlexInt         `json:"last_access_unix_ms"`
}

// NormalizedDomain strips the trailing dot and lowercases for stable keys.
func (e *CacheEntry) NormalizedDomain() string {
	return strings.ToLower(strings.TrimSuffix(e.Domain, "."))
}

// answerObjects decodes answers_json in every wire form OxiDNS has shipped:
// a JSON array, or a JSON string containing that array (possibly encoded
// twice). The LuCI cache page does the same JSON.parse-on-string dance.
func (e *CacheEntry) answerObjects() []map[string]interface{} {
	raw := e.Answers
	// Unwrap up to two layers of JSON-string encoding.
	for i := 0; i < 2; i++ {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			raw = []byte(s)
			continue
		}
		break
	}
	var answers []map[string]interface{}
	if err := json.Unmarshal(raw, &answers); err != nil {
		return nil
	}
	return answers
}

// HasUsableAnswer reports whether the entry carries a real A/AAAA record.
// Negative-cache / black-hole rows (0.0.0.0, ::) are skipped: they have no
// meaningful TTL lifecycle to prewarm.
func (e *CacheEntry) HasUsableAnswer() bool {
	q := strings.ToUpper(e.RecordType)
	if q != "A" && q != "AAAA" {
		return false
	}
	answers := e.answerObjects()
	if len(answers) == 0 {
		return false
	}
	for _, a := range answers {
		// OxiDNS answer rows use "address" (and sometimes "data"/"ip").
		for _, k := range []string{"address", "data", "ip", "value"} {
			v, ok := a[k]
			if !ok {
				continue
			}
			if str, ok2 := v.(string); ok2 {
				t := strings.ToLower(strings.TrimSpace(str))
				if t == "" || t == "0.0.0.0" || t == "::" {
					continue
				}
				return true
			}
		}
		// Some answer rows only expose the type; a parsed non-empty row with
		// the matching qtype is still usable.
		if t, ok := a["type"]; ok {
			ts := strings.ToUpper(stringify(t))
			if ts == q || ts == strconv.Itoa(qtypeNumber(q)) {
				if len(a) > 1 {
					return true
				}
			}
		}
	}
	return false
}

func stringify(v interface{}) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatInt(int64(x), 10)
	case json.Number:
		return x.String()
	default:
		return ""
	}
}

func qtypeNumber(q string) int {
	if q == "A" {
		return 1
	}
	if q == "AAAA" {
		return 28
	}
	return 0
}

// Key uniquely identifies a scheduled (domain, qtype) pair.
type Key struct {
	Domain string
	QType  string
}

func (k Key) String() string { return k.Domain + "|" + k.QType }

// TaskState is the per-key adaptive scheduling state.
type TaskState struct {
	Key           Key
	Deadline      time.Time
	LastTTL       int64
	LastRemaining int64
	Backoff       int
	Inflight      bool
	LastProbe     time.Time
	LastResult    string // "ok", "failed", "seeded", "skipped-short-ttl", ...
	LastError     string
	Updated       time.Time
	InWatchList   bool
}

// Status is serialized to StatusFile so LuCI/rpcd can render live state.
type Status struct {
	Enabled   bool       `json:"enabled"`
	Mode      string     `json:"mode"`
	APIBase   string     `json:"api_base"`
	DNSTarget string     `json:"dns_target"`
	StartedAt time.Time  `json:"started_at"`
	UpdatedAt time.Time  `json:"updated_at"`
	Tasks     []TaskView `json:"tasks"`
	Stats     Stats      `json:"stats"`
}

type TaskView struct {
	Domain       string `json:"domain"`
	QType        string `json:"qtype"`
	TTL          int64  `json:"ttl"`
	RemainingTTL int64  `json:"remaining_ttl"`
	NextProbe    string `json:"next_probe"`
	In           string `json:"in"` // "watch-list" / "auto-discovered"
	LastResult   string `json:"last_result"`
	LastError    string `json:"last_error"`
	Backoff      int    `json:"backoff"`
}

type Stats struct {
	Probes        int64 `json:"probes"`
	RefreshOK     int64 `json:"refresh_ok"`
	RefreshFailed int64 `json:"refresh_failed"`
	Seeds         int64 `json:"seeds"`
	SkippedShort  int64 `json:"skipped_short_ttl"`
}
