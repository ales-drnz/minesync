package mcdns

import "testing"

// Il DNS risponde dall'istantanea dei lock (mai dal mutex dello spazio):
// segue acquisizione, rilascio ed eliminazione dello spazio.
func TestSnapshotFollowsLockChanges(t *testing.T) {
	s := newTestServer(t, false)
	q := buildQuery("zerotier.miomondo.internal", typeA)
	if rcode, an, _ := parseHeader(s.handle(q, nil)); rcode != rcodeOK || an != 0 {
		t.Fatalf("nessun host: rcode=%d an=%d", rcode, an)
	}
	lk, _, err := s.store.AcquireLock("miomondo", "alex", map[string]string{"host": "10.147.17.10"}, 90)
	if err != nil {
		t.Fatal(err)
	}
	if _, an, _ := parseHeader(s.handle(q, nil)); an != 1 {
		t.Fatal("lock preso ma il DNS non risponde")
	}
	if _, err := s.store.ReleaseLock("miomondo", lk.Session, false); err != nil {
		t.Fatal(err)
	}
	if _, an, _ := parseHeader(s.handle(q, nil)); an != 0 {
		t.Fatal("lock rilasciato ma il DNS risponde ancora")
	}
	if err := s.store.DeleteSpace("miomondo"); err != nil {
		t.Fatal(err)
	}
	if rcode, _, _ := parseHeader(s.handle(q, nil)); rcode != rcodeNXDomain {
		t.Fatalf("spazio eliminato: rcode=%d, atteso NXDOMAIN", rcode)
	}
}
