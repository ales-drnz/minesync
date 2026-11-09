package mcdns

import "testing"

// S12: risposte (QR=1) e opcode diversi da QUERY si scartano senza rispondere.
func TestDropsResponsesAndNonQuery(t *testing.T) {
	s := newTestServer(t, true)
	q := buildQuery("zerotier.miomondo.internal", typeA)
	resp := append([]byte{}, q...)
	resp[2] |= 0x80 // QR=1
	if out := s.handle(resp, nil); out != nil {
		t.Fatal("risposto a un pacchetto QR=1")
	}
	notify := append([]byte{}, q...)
	notify[2] = notify[2]&^0x78 | 4<<3 // opcode NOTIFY
	if out := s.handle(notify, nil); out != nil {
		t.Fatal("risposto a un opcode non QUERY")
	}
	if out := s.handle(q, nil); out == nil {
		t.Fatal("la query normale non ha più risposta")
	}
}
