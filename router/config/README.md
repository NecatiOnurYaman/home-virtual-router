# Router configuration

This directory contains lab-mode component templates. Validated lab addresses and names remain under `lab/config/`; physical-router production configuration is not implemented.

`dnsmasq-dhcp.conf.template` defines R6 DHCP-only mode. R7 uses
`dnsmasq-router-dns.conf.template` for the combined LAN-bound DHCP/DNS process
and `dnsmasq-upstream-test.conf.template` for the deterministic resolver inside
`hvr-upstream`. Scripts render validated values into project-owned `/run` paths;
none of these templates reads the Ubuntu host resolver configuration.

`pmacctd-nfprobe.conf.template` defines the R8 namespace-scoped libpcap and
IPFIX v10 exporter. Its validated interface and collector placeholders are
rendered only into `/run/home-virtual-router/ipfix/`.
