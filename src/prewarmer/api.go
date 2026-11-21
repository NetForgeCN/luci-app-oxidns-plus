package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// EntrySource is the narrow interface the scheduler needs. Keeping it small
// lets the tests inject a fake source without running an OxiDNS instance.
type EntrySource interface {
	Entries(qname string, limit int) ([]CacheEntry, error)
}

// OxiAPI talks to the OxiDNS management API. Only the read-only cache entries
// endpoint is used. API base is derived from api.http.listen in config.yaml by
// the init script and passed as a flag; basic credentials come from UCI.
type OxiAPI struct {
	base   string
	user   string
	pass   string
	tag    string
	client *http.Client
}

func NewOxiAPI(base, user, pass, tag string) *OxiAPI {
	base = strings.TrimSuffix(base, "/")
	if !strings.Contains(base, "://") {
		base = "http://" + base
	}
	return &OxiAPI{
		base: base, user: user, pass: pass, tag: tag,
		client: &http.Client{Timeout: 6 * time.Second},
	}
}

// Entries returns cache entries. qname is a case-insensitive substring filter
// on the cache-key domain; empty qname returns the whole (first) page.
func (o *OxiAPI) Entries(qname string, limit int) ([]CacheEntry, error) {
	if limit <= 0 {
		limit = 1000
	}
	q := url.Values{}
	if qname != "" {
		q.Set("qname", qname)
	}
	q.Set("limit", fmt.Sprintf("%d", limit))

	endpoint := fmt.Sprintf("%s/api/plugins/%s/entries?%s", o.base, o.tag, q.Encode())
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	if o.user != "" {
		req.SetBasicAuth(o.user, o.pass)
	}
	resp, err := o.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("api status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}

	// Two accepted envelopes:
	//   {"entries":[...]}                 (current 1.7.x)
	//   {"ok":true,"entries":{"entries":[...]}} (rpcd-style wrapper, legacy tests)
	var top struct {
		Entries json.RawMessage `json:"entries"`
	}
	if err := json.Unmarshal(body, &top); err != nil {
		return nil, fmt.Errorf("bad json: %w", err)
	}
	var list []CacheEntry
	if err := json.Unmarshal(top.Entries, &list); err == nil {
		return list, nil
	}
	// nested wrapper
	var nested struct {
		Entries []CacheEntry `json:"entries"`
	}
	if err := json.Unmarshal(top.Entries, &nested); err == nil {
		return nested.Entries, nil
	}
	return nil, fmt.Errorf("unexpected entries envelope: %.120s", string(body))
}
