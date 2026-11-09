package mc

import (
	"net"
	"sort"
	"strings"
)

// LocalIPs restituisce gli IPv4 della macchina utili per farsi raggiungere,
// ordinati per rilevanza: prima ZeroTier (gli amici arrivano da lì), poi LAN,
// poi il resto. Massimo 4.
func LocalIPs() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	type cand struct {
		ip   string
		rank int
	}
	var out []cand
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		lname := strings.ToLower(iface.Name)
		if isVirtualIface(lname) {
			continue // WSL/Hyper-V/VM: nessuno si connette lì
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipnet.IP.To4()
			if ip4 == nil {
				continue
			}
			rank := 2
			switch {
			case strings.Contains(lname, "zerotier") || strings.Contains(lname, "zt"):
				rank = 0
			case ip4.IsPrivate():
				rank = 1
			case ip4.IsLinkLocalUnicast():
				continue // 169.254.x inutile
			}
			out = append(out, cand{ip: ip4.String(), rank: rank})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].rank < out[j].rank })
	seen := map[string]bool{}
	var ips []string
	for _, c := range out {
		if !seen[c.ip] && len(ips) < 3 {
			seen[c.ip] = true
			ips = append(ips, c.ip)
		}
	}
	return ips
}

func isVirtualIface(lname string) bool {
	for _, bad := range []string{"vethernet", "wsl", "hyper-v", "virtualbox", "vmware", "docker", "loopback", "vbox"} {
		if strings.Contains(lname, bad) {
			return true
		}
	}
	return false
}
