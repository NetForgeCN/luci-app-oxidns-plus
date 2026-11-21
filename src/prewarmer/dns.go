package main

import (
	"encoding/binary"
	"fmt"
	"math/rand"
	"net"
	"strings"
	"time"
)

// Prober sends a minimal A/AAAA query to OxiDNS's own listener. The point is
// NOT to read the answer: it is to make OxiDNS see a query for a stale entry,
// which makes its native lazy cache fire the asynchronous background refresh.
// We never cache, never store IPs and never touch an upstream ourselves.
type Prober interface {
	Probe(target, domain, qtype string) error
}

type UDPProber struct {
	timeout time.Duration
}

func NewUDPProber(timeout time.Duration) *UDPProber {
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	return &UDPProber{timeout: timeout}
}

func (p *UDPProber) Probe(target, domain, qtype string) error {
	q := uint16(1) // A
	if strings.EqualFold(qtype, "AAAA") {
		q = 28
	}
	packet, err := buildQuery(domain, q)
	if err != nil {
		return err
	}
	addr, err := net.ResolveUDPAddr("udp", target)
	if err != nil {
		return fmt.Errorf("bad dns target %q: %w", target, err)
	}
	conn, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(p.timeout))
	if _, err := conn.Write(packet); err != nil {
		return err
	}
	buf := make([]byte, 512)
	n, err := conn.Read(buf)
	if err != nil {
		return err
	}
	if n < 12 {
		return fmt.Errorf("short dns reply (%d bytes)", n)
	}
	// RCODE in the low 4 bits of byte 3; REFUSED/SERVFAIL/SNXDOMAIN are still
	// "a response arrived", which is enough for a trigger. Only a totally
	// absent reply is a transport failure.
	return nil
}

// buildQuery produces a standards-compliant DNS question with RD set and one
// question. No EDNS, no DO bit: we want the plainest possible cache lookup.
func buildQuery(domain string, qtype uint16) ([]byte, error) {
	domain = strings.TrimSuffix(strings.TrimSpace(domain), ".")
	if domain == "" {
		return nil, fmt.Errorf("empty domain")
	}
	buf := make([]byte, 0, 12+len(domain)+6)

	// Header: ID, flags=RD(0x0100), QDCOUNT=1, rest 0.
	id := uint16(rand.Intn(0xffff) | 1)
	var hdr [12]byte
	binary.BigEndian.PutUint16(hdr[0:2], id)
	binary.BigEndian.PutUint16(hdr[2:4], 0x0100)
	binary.BigEndian.PutUint16(hdr[4:6], 1)
	buf = append(buf, hdr[:]...)

	// QNAME: length-prefixed labels.
	for _, label := range strings.Split(domain, ".") {
		if len(label) > 63 {
			return nil, fmt.Errorf("label too long: %q", label)
		}
		buf = append(buf, byte(len(label)))
		buf = append(buf, []byte(label)...)
	}
	buf = append(buf, 0)

	var tail [4]byte
	binary.BigEndian.PutUint16(tail[0:2], qtype)
	binary.BigEndian.PutUint16(tail[2:4], 1) // IN
	buf = append(buf, tail[:]...)
	return buf, nil
}
