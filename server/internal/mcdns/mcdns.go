// Package mcdns è un DNS autoritativo minimale (solo A/SRV, zero dipendenze).
//
// Risolve  zerotier.<spazio>.<zona>  verso l'IP di chi sta hostando ADESSO quel
// server, letto dal lock. È "risoluzione tardiva": ogni volta che un client si
// connette rifà la lookup e arriva su chi ospita in quel momento, così TUTTI
// (host inclusi) salvano UN solo indirizzo in Minecraft e non lo toccano più.
//
// Split-horizon: la risposta dipende da CHI chiede. Se la query arriva dallo
// stesso IP ZeroTier di chi hosta (= è l'host che si connette al proprio
// server), gli diamo il suo IP LAN, così va in locale senza rimbalzare sul
// proprio stack ZeroTier. A tutti gli altri diamo l'IP ZeroTier.
//
// NON è un proxy: risponde solo "dove" (l'IP vivo). Il traffico di gioco resta
// diretto P2P tra i giocatori e l'host, sulla rete ZeroTier.
package mcdns

import (
	"context"
	"net"
	"strconv"
	"strings"
	"time"

	"minesync/server/internal/store"
)

// TTL basso: l'host cambia spesso, non vogliamo cache lunghe.
const ttlSec = 5

// Server serve una singola zona (es. "internal") sopra lo store.
type Server struct {
	store *store.Store
	zone  string // senza punti, minuscolo (es. "internal")
}

func New(st *store.Store, zone string) *Server {
	return &Server{store: st, zone: strings.ToLower(strings.Trim(zone, "."))}
}

// ListenAndServe apre il listener UDP e risponde finché non c'è un errore fatale
// (tipicamente il bind della :53). Va lanciato in una goroutine: se fallisce
// l'hub deve continuare comunque a servire l'HTTP.
func (s *Server) ListenAndServe(addr string) error {
	return s.ListenAndServeContext(context.Background(), addr)
}

// ListenAndServeContext è ListenAndServe che si ferma (restituendo nil) quando
// ctx viene chiuso: serve allo spegnimento ordinato dell'hub.
func (s *Server) ListenAndServeContext(ctx context.Context, addr string) error {
	pc, err := net.ListenPacket("udp", addr)
	if err != nil {
		return err
	}
	defer pc.Close()
	stop := context.AfterFunc(ctx, func() { pc.Close() })
	defer stop()
	buf := make([]byte, 512) // UDP DNS classico: messaggi ≤512B
	for {
		n, src, err := pc.ReadFrom(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		var srcIP net.IP // per lo split-horizon host↔amici
		if ua, ok := src.(*net.UDPAddr); ok {
			srcIP = ua.IP
		}
		if resp := s.handle(buf[:n], srcIP); resp != nil {
			_, _ = pc.WriteTo(resp, src)
		}
	}
}

// tipi di record che ci interessano
const (
	typeA   = 1
	typeSOA = 6
	typeSRV = 33
	classIN = 1

	rcodeOK       = 0
	rcodeNXDomain = 3
	rcodeRefused  = 5
)

func (s *Server) handle(req []byte, src net.IP) []byte {
	if len(req) < 12 {
		return nil
	}
	// solo query standard: le risposte (QR=1) e gli opcode diversi da QUERY
	// si scartano in silenzio (niente riflessione/amplificazione)
	if req[2]&0x80 != 0 || (req[2]>>3)&0x0F != 0 {
		return nil
	}
	// una sola question (è sempre così per le lookup dei client)
	labels, qtype, qclass, qend, ok := parseQuestion(req, 12)
	if !ok || qclass != classIN {
		return nil // malformato o classe non IN: ignora
	}
	m := &reply{id0: req[0], id1: req[1], opcode: int(req[2]>>3) & 0x0F,
		rd: req[2]&0x01 != 0, question: req[12:qend]}

	// la question deve stare nella nostra zona, altrimenti non è roba nostra
	if len(labels) == 0 || !strings.EqualFold(labels[len(labels)-1], s.zone) {
		m.rcode = rcodeRefused
		return m.finalize(s.zone)
	}
	// core = etichette senza la zona finale; scarto l'eventuale prefisso SRV
	core := lowerAll(labels[:len(labels)-1])
	if len(core) >= 2 && core[0] == "_minecraft" && core[1] == "_tcp" {
		core = core[2:]
	}
	// schema atteso: zerotier.<spazio>
	if len(core) != 2 || core[0] != "zerotier" {
		m.rcode = rcodeNXDomain
		return m.finalize(s.zone)
	}
	id := core[1]

	lk, err := s.store.CurrentLock(id)
	if err != nil { // lo spazio non esiste
		m.rcode = rcodeNXDomain
		return m.finalize(s.zone)
	}
	ips, port, online := hostAddrs(lk)
	var ip net.IP
	if online {
		ip = pickIP(ips, src) // LAN all'host che chiede, ZeroTier agli altri
	}

	// nome esiste (NOERROR); le risposte ci sono solo se qualcuno hosta adesso.
	switch qtype {
	case typeA:
		if online {
			m.answers = append(m.answers, rrA(ip))
		}
	case typeSRV:
		if online {
			target := []string{"zerotier", id, s.zone}
			m.answers = append(m.answers, rrSRV(port, target))
			m.additional = append(m.additional, rrGlueA(target, ip)) // glue: risparmia un giro
		}
	default:
		// AAAA e altri: NOERROR vuoto e autoritativo, così il client non aspetta l'IPv6.
	}
	return m.finalize(s.zone)
}

// hostAddrs estrae gli IPv4 pubblicati dall'host (nell'ordine del client:
// ZeroTier per primo, poi LAN) e la porta dal lock, solo se il lock è vivo.
func hostAddrs(lk *store.LockInfo) (ips []net.IP, port int, ok bool) {
	if lk == nil || lk.Stale(time.Now().UTC()) {
		return nil, 0, false
	}
	host := lk.Info["host"]
	if host == "" {
		return nil, 0, false
	}
	for _, s := range strings.Split(host, ",") {
		if ip := net.ParseIP(strings.TrimSpace(s)).To4(); ip != nil { // solo IPv4 (record A)
			ips = append(ips, ip)
		}
	}
	if len(ips) == 0 {
		return nil, 0, false
	}
	port = 25565
	if p := lk.Info["port"]; p != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(p)); err == nil && n > 0 && n < 65536 {
			port = n
		}
	}
	return ips, port, true
}

// pickIP fa lo split-horizon: ips[0] è l'IP ZeroTier dell'host, ips[1:] i suoi
// IP LAN. Se chi chiede È l'host (source == suo IP ZeroTier), gli diamo il primo
// IP LAN così raggiunge sé stesso in locale; a tutti gli altri l'IP ZeroTier.
// Se l'host non ha pubblicato una LAN, si ripiega sull'IP ZeroTier per tutti.
func pickIP(ips []net.IP, src net.IP) net.IP {
	zt := ips[0]
	if src != nil && src.Equal(zt) && len(ips) > 1 {
		return ips[1]
	}
	return zt
}

/* ---------- parsing della question ---------- */

func parseQuestion(msg []byte, off int) (labels []string, qtype, qclass, next int, ok bool) {
	labels, off, ok = parseName(msg, off)
	if !ok || off+4 > len(msg) {
		return nil, 0, 0, 0, false
	}
	qtype = int(msg[off])<<8 | int(msg[off+1])
	qclass = int(msg[off+2])<<8 | int(msg[off+3])
	return labels, qtype, qclass, off + 4, true
}

func parseName(msg []byte, off int) (labels []string, next int, ok bool) {
	for {
		if off >= len(msg) {
			return nil, 0, false
		}
		l := int(msg[off])
		if l == 0 {
			off++
			break
		}
		if l&0xC0 != 0 { // le question dei client non usano compressione
			return nil, 0, false
		}
		off++
		if off+l > len(msg) {
			return nil, 0, false
		}
		labels = append(labels, string(msg[off:off+l]))
		off += l
	}
	return labels, off, true
}

func lowerAll(in []string) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = strings.ToLower(s)
	}
	return out
}

/* ---------- costruzione della risposta ---------- */

type reply struct {
	id0, id1   byte
	opcode     int // copiato dalla richiesta (0 = QUERY)
	rd         bool
	rcode      int
	question   []byte // byte grezzi della question (name+type+class), riecheggiati
	answers    [][]byte
	authority  [][]byte // SOA per il caching negativo (RFC 2308)
	additional [][]byte
}

// finalize aggiunge l'SOA in AUTHORITY sulle risposte negative (NXDOMAIN e
// NODATA), così i resolver sanno per quanto tenere in cache il "niente" — vedi
// RFC 2308. Le REFUSED (fuori zona) non lo ricevono: lì non siamo autoritativi.
func (m *reply) finalize(zone string) []byte {
	if len(m.answers) == 0 && m.rcode != rcodeRefused {
		m.authority = append(m.authority, rrSOA(zone))
	}
	return m.bytes()
}

func (m *reply) bytes() []byte {
	out := make([]byte, 0, 128)
	out = append(out, m.id0, m.id1)
	// flags: QR=1, opcode copiato, AA=1, + RD copiato dalla richiesta, + RCODE
	flags := 0x8000 | (m.opcode << 11) | 0x0400 | m.rcode
	if m.rd {
		flags |= 0x0100
	}
	out = appendU16(out, flags)
	out = appendU16(out, 1)                 // QDCOUNT
	out = appendU16(out, len(m.answers))    // ANCOUNT
	out = appendU16(out, len(m.authority))  // NSCOUNT
	out = appendU16(out, len(m.additional)) // ARCOUNT
	out = append(out, m.question...)
	for _, rr := range m.answers {
		out = append(out, rr...)
	}
	for _, rr := range m.authority {
		out = append(out, rr...)
	}
	for _, rr := range m.additional {
		out = append(out, rr...)
	}
	return out
}

// il nome della question sta all'offset 12: lo puntiamo con la compressione (0xC00C).
var qnamePtr = []byte{0xC0, 0x0C}

func rrA(ip net.IP) []byte {
	rr := append([]byte{}, qnamePtr...)
	rr = appendU16(rr, typeA)
	rr = appendU16(rr, classIN)
	rr = appendU32(rr, ttlSec)
	rr = appendU16(rr, 4) // RDLENGTH
	return append(rr, ip[0], ip[1], ip[2], ip[3])
}

func rrSRV(port int, target []string) []byte {
	tb := encodeName(target)
	rd := make([]byte, 0, 6+len(tb))
	rd = appendU16(rd, 0)    // priority
	rd = appendU16(rd, 0)    // weight
	rd = appendU16(rd, port) // port
	rd = append(rd, tb...)   // target (nome completo, niente compressione nell'RDATA)

	rr := append([]byte{}, qnamePtr...)
	rr = appendU16(rr, typeSRV)
	rr = appendU16(rr, classIN)
	rr = appendU32(rr, ttlSec)
	rr = appendU16(rr, len(rd))
	return append(rr, rd...)
}

// rrGlueA: record A per il target dell'SRV (il suo nome è diverso dalla question,
// quindi lo scrivo per esteso).
func rrGlueA(target []string, ip net.IP) []byte {
	rr := encodeName(target)
	rr = appendU16(rr, typeA)
	rr = appendU16(rr, classIN)
	rr = appendU32(rr, ttlSec)
	rr = appendU16(rr, 4)
	return append(rr, ip[0], ip[1], ip[2], ip[3])
}

// rrSOA: SOA della zona in AUTHORITY, per il caching negativo (RFC 2308). Solo
// MINIMUM e il TTL del record contano (il neg-TTL è il minore dei due, qui
// ttlSec): gli altri campi servono ai secondari zone-transfer, che non esistono.
func rrSOA(zone string) []byte {
	rd := make([]byte, 0, 48)
	rd = append(rd, encodeName([]string{"hub", zone})...)        // MNAME
	rd = append(rd, encodeName([]string{"hostmaster", zone})...) // RNAME
	rd = appendU32(rd, 1)                                        // SERIAL
	rd = appendU32(rd, 3600)                                     // REFRESH
	rd = appendU32(rd, 600)                                      // RETRY
	rd = appendU32(rd, 604800)                                   // EXPIRE
	rd = appendU32(rd, ttlSec)                                   // MINIMUM = TTL del caching negativo

	rr := encodeName([]string{zone}) // owner = apex della zona
	rr = appendU16(rr, typeSOA)
	rr = appendU16(rr, classIN)
	rr = appendU32(rr, ttlSec)
	rr = appendU16(rr, len(rd))
	return append(rr, rd...)
}

func encodeName(labels []string) []byte {
	b := make([]byte, 0, 24)
	for _, l := range labels {
		b = append(b, byte(len(l)))
		b = append(b, l...)
	}
	return append(b, 0)
}

func appendU16(b []byte, v int) []byte { return append(b, byte(v>>8), byte(v)) }
func appendU32(b []byte, v uint32) []byte {
	return append(b, byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}
