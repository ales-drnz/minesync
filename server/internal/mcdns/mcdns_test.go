package mcdns

import (
	"net"
	"strings"
	"testing"

	"minesync/server/internal/store"
)

// buildQuery costruisce una query DNS grezza (una sola question).
func buildQuery(name string, qtype int) []byte {
	msg := []byte{0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0} // RD=1, QDCOUNT=1
	for _, l := range strings.Split(name, ".") {
		msg = append(msg, byte(len(l)))
		msg = append(msg, l...)
	}
	msg = append(msg, 0, byte(qtype>>8), byte(qtype), 0, 1) // fine nome, QTYPE, QCLASS=IN
	return msg
}

func parseHeader(r []byte) (rcode, ancount, arcount int) {
	flags := int(r[2])<<8 | int(r[3])
	return flags & 0xF, int(r[6])<<8 | int(r[7]), int(r[10])<<8 | int(r[11])
}

func nscount(r []byte) int { return int(r[8])<<8 | int(r[9]) }

func newTestServer(t *testing.T, withHost bool) *Server {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	if _, err := st.CreateSpace("MioMondo", "minecraft", nil); err != nil {
		t.Fatalf("CreateSpace: %v", err)
	}
	if withHost {
		if _, _, err := st.AcquireLock("miomondo", "alex",
			map[string]string{"host": "10.147.17.10,192.168.1.5", "port": "25577"}, 90); err != nil {
			t.Fatalf("AcquireLock: %v", err)
		}
	}
	return New(st, "internal")
}

func TestA_LiveHost(t *testing.T) {
	s := newTestServer(t, true)
	resp := s.handle(buildQuery("zerotier.miomondo.internal", typeA), nil)
	rcode, an, _ := parseHeader(resp)
	if rcode != rcodeOK || an != 1 {
		t.Fatalf("atteso NOERROR con 1 risposta, ottenuto rcode=%d an=%d", rcode, an)
	}
	// gli ultimi 4 byte dell'RDATA A sono l'IPv4: 10.147.17.10
	ip := resp[len(resp)-4:]
	if ip[0] != 10 || ip[1] != 147 || ip[2] != 17 || ip[3] != 10 {
		t.Fatalf("IP errato: %d.%d.%d.%d (atteso 10.147.17.10)", ip[0], ip[1], ip[2], ip[3])
	}
}

func TestSplitHorizon_HostGetsLAN(t *testing.T) {
	s := newTestServer(t, true) // host pubblica "10.147.17.10,192.168.1.5"

	// l'host stesso interroga (source == suo IP ZeroTier) → deve avere la LAN
	respHost := s.handle(buildQuery("zerotier.miomondo.internal", typeA), net.ParseIP("10.147.17.10"))
	if ip := respHost[len(respHost)-4:]; ip[0] != 192 || ip[1] != 168 || ip[2] != 1 || ip[3] != 5 {
		t.Fatalf("host: atteso IP LAN 192.168.1.5, ottenuto %d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3])
	}

	// un amico remoto interroga → deve avere l'IP ZeroTier
	respFriend := s.handle(buildQuery("zerotier.miomondo.internal", typeA), net.ParseIP("10.147.17.30"))
	if ip := respFriend[len(respFriend)-4:]; ip[0] != 10 || ip[1] != 147 || ip[2] != 17 || ip[3] != 10 {
		t.Fatalf("amico: atteso IP ZeroTier 10.147.17.10, ottenuto %d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3])
	}
}

func TestSRV_PortAndGlue(t *testing.T) {
	s := newTestServer(t, true)
	resp := s.handle(buildQuery("_minecraft._tcp.zerotier.miomondo.internal", typeSRV), nil)
	rcode, an, ar := parseHeader(resp)
	if rcode != rcodeOK || an != 1 || ar != 1 {
		t.Fatalf("atteso SRV (1 answer + 1 glue), ottenuto rcode=%d an=%d ar=%d", rcode, an, ar)
	}
	// la porta 25577 (0x63e9) deve comparire nell'RDATA dell'SRV
	if !containsBytes(resp, []byte{0x63, 0xe9}) {
		t.Fatalf("porta 25577 non trovata nella risposta SRV: %x", resp)
	}
}

func TestOffline_NoerrorEmpty(t *testing.T) {
	s := newTestServer(t, false) // spazio esiste ma nessuno hosta
	resp := s.handle(buildQuery("zerotier.miomondo.internal", typeA), nil)
	rcode, an, _ := parseHeader(resp)
	if rcode != rcodeOK || an != 0 {
		t.Fatalf("offline: atteso NOERROR vuoto, ottenuto rcode=%d an=%d", rcode, an)
	}
	// NODATA deve portare l'SOA in AUTHORITY per il caching negativo (RFC 2308)
	if nscount(resp) != 1 {
		t.Fatalf("offline: atteso 1 record SOA in AUTHORITY, NSCOUNT=%d", nscount(resp))
	}
}

func TestUnknownSpace_NXDomain(t *testing.T) {
	s := newTestServer(t, false)
	resp := s.handle(buildQuery("zerotier.nonesiste.internal", typeA), nil)
	rcode, _, _ := parseHeader(resp)
	if rcode != rcodeNXDomain {
		t.Fatalf("spazio inesistente: atteso NXDOMAIN(3), ottenuto rcode=%d", rcode)
	}
	if nscount(resp) != 1 {
		t.Fatalf("NXDOMAIN: atteso 1 record SOA in AUTHORITY, NSCOUNT=%d", nscount(resp))
	}
}

func TestOnline_NoSOA(t *testing.T) {
	s := newTestServer(t, true) // host attivo: risposta positiva, niente SOA
	resp := s.handle(buildQuery("zerotier.miomondo.internal", typeA), nil)
	if nscount(resp) != 0 {
		t.Fatalf("risposta positiva: atteso NSCOUNT=0, ottenuto %d", nscount(resp))
	}
}

func TestRefused_NoSOA(t *testing.T) {
	s := newTestServer(t, true) // fuori zona: REFUSED, niente SOA (non autoritativi)
	resp := s.handle(buildQuery("example.com", typeA), nil)
	if nscount(resp) != 0 {
		t.Fatalf("REFUSED: atteso NSCOUNT=0, ottenuto %d", nscount(resp))
	}
}

func TestOutOfZone_Refused(t *testing.T) {
	s := newTestServer(t, true)
	resp := s.handle(buildQuery("example.com", typeA), nil)
	rcode, _, _ := parseHeader(resp)
	if rcode != rcodeRefused {
		t.Fatalf("fuori zona: atteso REFUSED(5), ottenuto rcode=%d", rcode)
	}
}

func TestAAAA_Empty(t *testing.T) {
	s := newTestServer(t, true)
	resp := s.handle(buildQuery("zerotier.miomondo.internal", 28), nil) // AAAA
	rcode, an, _ := parseHeader(resp)
	if rcode != rcodeOK || an != 0 {
		t.Fatalf("AAAA: atteso NOERROR vuoto, ottenuto rcode=%d an=%d", rcode, an)
	}
}

func containsBytes(hay, needle []byte) bool {
	for i := 0; i+len(needle) <= len(hay); i++ {
		if string(hay[i:i+len(needle)]) == string(needle) {
			return true
		}
	}
	return false
}
