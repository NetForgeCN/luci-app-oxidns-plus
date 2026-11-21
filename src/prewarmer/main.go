package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	var cfg Config
	flag.StringVar(&cfg.APIBase, "api", "http://127.0.0.1:9199/", "OxiDNS management API base URL")
	flag.StringVar(&cfg.APIUser, "api-user", "", "API basic-auth username (empty = no auth)")
	flag.StringVar(&cfg.APIPass, "api-pass", "", "API basic-auth password")
	flag.StringVar(&cfg.CacheTag, "cache-tag", "cache_main", "cache plugin tag")
	flag.StringVar(&cfg.DNSTarget, "dns", "127.0.0.1:5333", "OxiDNS local DNS listener to probe")
	flag.StringVar(&cfg.WatchList, "watch-list", "/etc/oxidnsplus/watch.list", "domain watch list file")
	flag.StringVar(&cfg.Mode, "mode", "list", "list (watch list) or all (all cached entries)")
	flag.IntVar(&cfg.TickSec, "tick", 5, "reconcile interval in seconds")
	flag.IntVar(&cfg.GraceSec, "grace", 3, "seconds after fresh expiry before probe (land in stale)")
	flag.IntVar(&cfg.RefreshDelay, "refresh-delay", 1200, "ms to wait for async refresh before verifying")
	flag.IntVar(&cfg.MinTTLSec, "min-ttl", 30, "TTL below this uses fixed lead (no short-TTL hammering)")
	flag.IntVar(&cfg.MinInterval, "min-interval", 10, "minimum seconds between probes of one key")
	flag.IntVar(&cfg.MaxInterval, "max-interval", 3600, "backoff upper bound in seconds")
	flag.IntVar(&cfg.JitterSec, "jitter", 5, "random extra seconds added to each deadline")
	flag.IntVar(&cfg.RetryBaseSec, "retry-base", 15, "initial retry backoff in seconds")
	flag.IntVar(&cfg.RetryMaxSec, "retry-max", 300, "maximum retry backoff in seconds")
	flag.IntVar(&cfg.RetryMaxCount, "retry-max-count", 8, "retry attempts before giving up on a key (0 = forever)")
	flag.StringVar(&cfg.StatusFile, "status-file", "/tmp/oxidnsplus.status.json", "status JSON path")
	flag.StringVar(&cfg.LogLevel, "log-level", "info", "info or debug")
	flag.Parse()

	logf := func(f string, a ...interface{}) {
		log.Printf("[prewarmer] "+f, a...)
	}

	// Load watch list: one "domain [A|AAAA]" per line. Blank / # lines skipped.
	watched, err := loadWatchList(cfg.WatchList)
	if err != nil {
		logf("watch list: %v", err)
	}
	if cfg.Mode == "list" && len(watched) == 0 {
		logf("watch list is empty and mode=list: nothing to prewarm")
	}

	api := NewOxiAPI(cfg.APIBase, cfg.APIUser, cfg.APIPass, cfg.CacheTag)
	prober := NewUDPProber(2 * time.Second)
	sched := NewScheduler(cfg, api, prober, watched)

	// Status writer: snapshot every 2s. Atomic replace to avoid partial reads.
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			writeStatus(cfg.StatusFile, sched.Status(), logf)
			<-t.C
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		logf("signal received, stopping")
		sched.Stop()
	}()

	logf("starting: api=%s dns=%s mode=%s watched=%d cache=%s grace=%ds",
		cfg.APIBase, cfg.DNSTarget, cfg.Mode, len(watched), cfg.CacheTag, cfg.GraceSec)
	sched.Run(logf)
}

func loadWatchList(path string) ([]Key, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	var out []Key
	seen := map[Key]bool{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		domain := strings.ToLower(strings.TrimSuffix(fields[0], "."))
		if domain == "" {
			continue
		}
		qtypes := []string{"A", "AAAA"}
		if len(fields) >= 2 {
			qtypes = []string{normalizeQType(fields[1])}
		}
		for _, q := range qtypes {
			k := Key{Domain: domain, QType: q}
			if !seen[k] {
				seen[k] = true
				out = append(out, k)
			}
		}
	}
	return out, sc.Err()
}

func writeStatus(path string, st Status, logf func(string, ...interface{})) {
	if path == "" {
		return
	}
	b, err := json.Marshal(st)
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		logf("status write failed: %v", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		logf("status rename failed: %v", err)
	}
}

func init() {
	// Deterministic-enough jitter without pulling in crypto/rand.
	// math/rand is auto-seeded from Go 1.20; no action needed here.
	_ = fmt.Sprintf
}
