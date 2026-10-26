# Infrastructure configuration and design

This explains the purpose of the configuration, how the less obvious settings work, and how the services fit together. The deployed configuration in `control`, `network`, and `boostrap` is described below. Package installation and SSH hardening are summarized; networking, identity mapping, permissions, and provisioning receive more detail.

Addresses and ports describe repository defaults. Software versions are selected in the linked variables, image definitions, and build tasks rather than repeated here. Hardware details and the Samba deployment decision include the operator's context.

## Control node

[control/setup.yml](control/setup.yml) prepares the server for shared storage, applications, network provisioning, and infrastructure automation.

### Host preparation and service ownership

[base_install.yml](control/tasks/base_install.yml) installs tools for interactive administration, diagnostics, development, and media/document processing, enables supporting repositories, and builds tools unavailable in the desired form from normal packages. Selected streams, source revisions, and source RPMs are defined there. [user_config.yml](control/tasks/user_config.yml) installs the administrator's dotfiles and user tools, including a separate Neovim Python environment. [user_setup.yml](control/tasks/user_setup.yml) grants administrator, shared-storage, and GitOps group access. SSH disables root/password login and limits authentication attempts.

Applications run under separate `runner`, `unifi`, `navidrome`, `vault`, and `netbox` accounts. Their user Quadlets live under `/var/lib/<account>/.config/containers/systemd`; PXE instead uses root-owned units under `/etc/containers/systemd`.

**Subordinate IDs and rootless Podman.** `/etc/subuid` delegates extra host user IDs to an account; `/etc/subgid` does the same for group IDs. An entry such as `runner:100000:65536` authorizes that account to map 65,536 IDs starting at 100000. It does not create those users or grant login access. See the upstream [subuid](https://github.com/shadow-maint/shadow/blob/master/man/subuid.5.xml) and [subgid](https://github.com/shadow-maint/shadow/blob/master/man/subgid.5.xml) manuals.

Podman uses these allocations, through `newuidmap`/`newgidmap`, to build a user namespace. With the ordinary rootless mapping, container root maps to the invoking host account; other container identities use subordinate IDs. Thus an image's database or application user can own files without becoming that UID on the host. These mappings also determine ownership on bind-mounted storage. See [Podman rootless operation](https://docs.podman.io/en/latest/markdown/podman.1.html) and [inspecting the namespace with podman unshare](https://docs.podman.io/en/latest/markdown/podman-unshare.1.html).

The current allocation loop advances for each user/file pair, so the same account gets different UID and GID starting ranges. Different starts are technically possible; the management issue is that allocations depend on dictionary order and are not checked against existing ranges. Changing mappings can leave persistent files owned by old mapped IDs. The allocation review remains in [todo.md](../todo.md).

**Keeping user services alive.** `loginctl enable-linger` starts the account's systemd user manager at boot and preserves it after logout. This lets rootless applications behave as server services without an interactive session. See [loginctl lingering](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html).

### Storage, SELinux, and common container settings

[Control variables](control/group_vars/control_nodes.yml) put application state under `/data/srv`, shared files under `/data/share/general`, and the infrastructure checkout/caches under `/data/sys`. Shared directories use the `share` or `gitops` group; the leading 2 in mode `2775` sets setgid so newly created entries inherit the directory group.

SELinux is an additional access check beyond Unix ownership and modes. The playbook records `public_content_rw_t` as the default type for `/data` and descendants, then uses `restorecon` to apply that policy to existing files. A persistent file-context rule survives later relabeling. See [RHEL SELinux guidance](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/using_selinux/index).

The enabled booleans allow containers to read/manage public content, manage cgroups, and use passed-through devices; Samba can write public content, and virtualization domains can use Samba content. These permit classes of access in SELinux policy, rather than granting Unix permissions or automatically mounting devices. See [container-selinux policy and boolean descriptions](https://github.com/containers/container-selinux/blob/main/container.te); local policy manuals such as `man container_selinux` and `man samba_selinux` describe the installed policy.

Common mount and access settings:

| Setting | Effect and reason here |
| --- | --- |
| `Volume=host:container` | Bind-mounts host storage so state survives container replacement. |
| `:ro` | Makes the mount read-only inside the container; used for music and selected configuration. |
| `:U` | Recursively adjusts host ownership to the container's mapped user/group. Useful for application state, but it changes the actual host files. |
| `:Z` | Relabels storage for private SELinux container access. Containers in one pod share its SELinux label; unrelated containers need a deliberate shared-label arrangement. Mount relabeling can replace the broader public-content label. |
| `GroupAdd=keep-groups` | Retains the launching account's supplementary group access, such as `gitops` cache access or `tss` device access. Requires a compatible runtime, documented as crun. |
| `PublishPort` | Exposes a port from a container/pod network on the host. Host-networked services bind directly instead. |

See [Podman mount, group, and network options](https://docs.podman.io/en/latest/markdown/podman-run.1.html).

Quadlet turns `.container` and `.pod` files into systemd services during boot or daemon reload. `[Install]` associates generated services with startup targets. `AutoUpdate=registry` opts a container into image checking when the corresponding auto-update timer runs. See [Quadlet lifecycle](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) and [container directives](https://docs.podman.io/en/latest/markdown/podman-container.unit.5.html).

`After=` orders startup but does not prove an application is ready. `Wants=` pulls in a dependency without making its failure fatal. `Restart=on-failure` retries failed processes; `Restart=always` also retries normal exits, except deliberate service stops. Several templates place `StartLimitIntervalSec`/`StartLimitBurst` under `[Service]`, although current systemd documents start limits under `[Unit]`; their intended purpose is to limit restart storms. See [unit dependencies and limits](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html) and [service restart behavior](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html).

### Samba: native file sharing

Samba runs as host `smb`/`nmb` services. **Deployment experience:** the container kept crashing while handling larger files, authentication was complex to configure, and it could not recover even after trying Podman's init support. This is the reason for the native deployment in this setup.

| Template | Configuration and purpose |
| --- | --- |
| [smb.conf.j2](control/templates/smb.conf.j2) | Configures local Samba authentication with `tdbsam`, home/profile/user shares, printing shares, and the custom data share. That share permits the administrator/`share` group to write, forces group ownership, and uses case-sensitive filenames while preserving case. Its mask/mode defaults are `0660` for files and `0770` for directories. `write list` grants Samba write permission; filesystem permissions still apply. `map to guest = Bad User` does not override the custom share's `guest ok = No`. |
| [samba.container.j2](control/templates/samba.container.j2) | Retained alternative; deployment is commented out. Uses host networking, persistent private authentication data, host identity snapshots, and `RunInit=true`. Init provides signal forwarding and child reaping; it does not repair Samba crashes or configure authentication. |
| [samba_entrypoint.sh.j2](control/templates/samba_entrypoint.sh.j2) | Inactive with the container alternative. Copies host users/groups with IDs at least 1000 and the shared group into the container's identity files before executing smbd. This aligns names with host-owned files; it does not create Samba passwords. |

`oplocks`/`level2 oplocks` allow client-side caching; change notifications inform clients about updates. ACL, creation-mask, case-handling, and guest settings are explained in the [Samba configuration manual](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html).

### UniFi: managing the physical switches

The controller exists because this deployment uses UniFi switches. The [adoption and management-VLAN runbook](../unifi/bootstrap/howto.md) adopts a switch on an untagged bootstrap network, tests VLAN 10, and then moves switch management to VLAN 10 before removing bootstrap connectivity.

The controller manages switch configuration; the network node supplies VLAN gateways, DHCP, and DNS. Creating a VLAN object in UniFi does not create its Linux interface or DHCP scope. The runbook's example addresses differ from the Ansible defaults; align actual addresses during deployment. Its switch port 1 carries the tagged uplink to the network node; controller/workstation management access ports carry untagged VLAN 10.

| Template | Configuration and purpose |
| --- | --- |
| [unifi-controller.pod.j2](control/templates/unifi-controller.pod.j2) | Groups application/database networking and publishes the configured TCP/UDP ports. TCP 8443 is the UI, TCP 8080 device inform traffic, UDP 3478 STUN, and UDP 10001 discovery. |
| [unifi-application.container.j2](control/templates/unifi-application.container.j2) | Runs the application with persistent configuration and shared environment settings; orders startup after the database. |
| [unifi-db.container.j2](control/templates/unifi-db.container.j2) | Persists MongoDB and mounts initialization scripts read-only. Its image tag selects the database version. |
| [unifi.env.j2](control/templates/unifi.env.j2) | Supplies root/application database credentials, timezone, and application memory setting. `MONGO_HOST=127.0.0.1` works because both containers share the pod network. |
| [init-mongo.js.j2](control/templates/init-mongo.js.j2) | Creates the application identity with ownership roles for the main, statistics, and audit databases, and seeds statistics/audit collections. This is database initialization, not a recurring credential reconciliation task. |

For migration, inform-address recovery, and switch-side tagged/access port settings, follow the linked runbook and its official UniFi references.

### Other applications

| Template | Configuration and purpose |
| --- | --- |
| [navidrome.container.j2](control/templates/navidrome.container.j2) | Serves the shared music collection with a read-only music mount and separate writable database/state. Publishes the configured service port and opts into registry auto-updates. |
| [netbox.pod.j2](control/templates/netbox.pod.j2) | Groups NetBox's application, database, cache, and worker; exposes the application through one host port. |
| [netbox-app.container.j2](control/templates/netbox-app.container.j2) | Runs the web application and persists uploaded media. Orders startup after database/cache services. |
| [netbox-db.container.j2](control/templates/netbox-db.container.j2) | Persists PostgreSQL independently of the container. Database credentials are supplied through the shared environment file. |
| [netbox-redis.container.j2](control/templates/netbox-redis.container.j2) | Provides the pod-local Redis service; no persistent Redis volume is defined. |
| [netbox-worker.container.j2](control/templates/netbox-worker.container.j2) | Runs `rqworker` to consume queued background jobs, using the same environment and media directory as the web application. |
| [netbox.env.j2](control/templates/netbox.env.j2) | Supplies database access, the application secret, allowed hosts, initial administrator settings, and database wait/debug settings. Localhost database/Redis addresses refer to the shared pod network. |
| [vault.container.j2](control/templates/vault.container.j2) | Runs OpenBao under an explicit container UID/GID, persists data/configuration, and passes through `/dev/tpmrm0`. Retained `tss` group access and device SELinux permission support device access. Passing a TPM device alone does not select a TPM seal. |
| [vault.env.j2](control/templates/vault.env.j2) | Supplies the local service address and static seal key through the environment. |
| [vault.hcl.j2](control/templates/vault.hcl.j2) | Configures single-node Raft storage and a static seal referencing that environment key, enables the UI, and listens on all container addresses without TLS. Disables memory locking, so OpenBao does not lock its memory against swapping. Advertised API/cluster addresses remain loopback. |

See [OpenBao configuration](https://openbao.org/docs/configuration/) for listener, storage, advertised-address, and memory-locking behavior. Image tags in the application templates select their releases.

### Permanent PXE: network-node DHCP and control-node TFTP/HTTP

The network node's DHCP service supplies both VLAN leases and PXE boot instructions. The control node serves boot files over TFTP and HTTP. Keeping DHCP on the router's VLAN interfaces lets clients receive boot information in their own VLAN, then reach the control node for file transfers.

The control playbook deploys TFTP and HTTP containers in a root-owned, host-networked PXE pod.

| Template | Configuration and purpose |
| --- | --- |
| [pxe.pod.j2](control/templates/pxe.pod.j2) | Defines a root-owned host-networked pod, activated with the host's multi-user target. Its containers use host interfaces and ports directly. The pod groups their lifecycle; it does not route traffic between VLANs. |
| [pxe_tftp.container.j2](control/templates/pxe_tftp.container.j2) | Installs tftp-hpa at startup and runs it in the foreground on UDP 69. `--secure` restricts the served filesystem root; `--map-file` enables firmware filename rewrites. Syslog goes to container output. |
| [pxe_nginx.container.j2](control/templates/pxe_nginx.container.j2) | Serves the read-only boot-content tree over HTTP. |

The component units use `After=pxe-pod.service` for order, `BindsTo=` to stop when the pod disappears, and `PartOf=` to propagate pod stop/restart operations. This keeps the TFTP and HTTP containers tied to the same provisioning service; network-node DHCP has a separate lifecycle. See [Pod Quadlets](https://docs.podman.io/en/latest/markdown/podman-pod.unit.5.html) and [systemd dependency semantics](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html).

| Template | Less obvious boot configuration |
| --- | --- |
| [boot.ipxe.j2](control/templates/boot.ipxe.j2) | Gets network configuration only if needed and sets `base_url` to `http://{{ remote_server_ip }}:{{ pxe_http_port }}`. First attempts to chain `${base_url}/ipxe/configs/${netX/mac:hexhyp}.ipxe`; a failed chain falls back to the generic rescue/shell/reboot menu. It calculates an architecture-directory mapping, but rescue URLs still use `${arch}` instead of `${arch_path}`; the arm64/aarch64 discrepancy remains a TODO. |
| [grub.cfg.j2](control/templates/grub.cfg.j2) | Loads video/filesystem/compression support, preserves the framebuffer, and offers rescue kernel/initrd loading or iPXE chainloading. It maps the GRUB CPU name to the content directory. The DHCP boot path uses unsigned iPXE and requires Secure Boot to be disabled. |
| [nginx.conf.j2](control/templates/nginx.conf.j2) | Serves the mounted web root, permits directory listings, uses `sendfile` for kernel-assisted file transfer, and `tcp_nopush` for packet batching with sendfile. The fallback content type is `application/octet-stream`; this describes payload type rather than modifying boot binaries. |
| [tftpd.map.j2](control/templates/tftpd.map.j2) | Normalizes backslashes and rewrites firmware-specific requests, including stripped paths and an Onboard pattern, to files in the architecture directories. Includes revocation-filename-to-shim substitutions; filename substitution does not itself establish a valid Secure Boot verification chain. |

The boot sequence is:

1. Network-node dnsmasq leases an address and matches UEFI client architecture: values 7/9 select `/x86_64/ipxe.efi`; value 11 selects `/aarch64/ipxe.efi`. Both point to the control node's reservation address.
2. The client downloads that binary from control-node TFTP. When iPXE requests boot information, its `iPXE` user class selects `/ipxe/configs/boot.ipxe` from the same TFTP server, avoiding another binary download.
3. The generic script tries a MAC-specific script over HTTP, using a hyphen-separated MAC filename such as `02-00-00-00-10-01.ipxe`. Place these scripts under `{{ pxe_base_dir }}/www/ipxe/configs/`; the playbook creates the directory but does not generate per-device scripts.
4. If chaining fails, the generic menu offers rescue, shell, and reboot. Rescue assets must already exist: the playbook downloads iPXE binaries but does not populate rescue kernels/initrds.

Clients need routed access to control-node TFTP and HTTP across VLANs. Keep the selected reservation address consistent with the control node's actual address and `remote_server_ip`, which supplies the HTTP base URL.

See [dnsmasq DHCP boot options](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html), [iPXE kernel loading](https://ipxe.org/cmd/kernel), [tftp-hpa remapping](https://manpages.debian.org/testing/tftpd-hpa/in.tftpd.8.en.html), and [Nginx transfer directives](https://nginx.org/en/docs/http/ngx_http_core_module.html).

### GitOps tooling and the GitHub-built runner

| Template | Configuration and purpose |
| --- | --- |
| [gitops_aliases.sh.j2](control/templates/gitops_aliases.sh.j2) | Runs infrastructure commands in disposable Podman containers with the checkout mounted at `/workspace`. Image/version variables in [control_nodes.yml](control/group_vars/control_nodes.yml) tie these commands to selected tool releases. Ansible aliases mount a collection directory; the Terraform alias mounts a cache directory, but does not itself set `TF_PLUGIN_CACHE_DIR`. |
| [runner.container.j2](control/templates/runner.container.j2) | Deploys `RUNNER_IMAGE` as the host's rootless runner account, with host networking, journald logging, registry auto-updates, and automatic restart. `keep-groups` retains access to group-owned cache paths. |
| [runner.env.j2](control/templates/runner.env.j2) | Supplies registration URL/token/name/labels and explicitly directs Ansible collections and Terraform providers to the mounted persistent cache paths. |
| [runner_auth.json.j2](control/templates/runner_auth.json.j2) | Writes GHCR pull authentication for the host service account. The `auth` field expects the registry auth format: base64-encoded username/password credentials, not an arbitrary raw PAT. See [Podman registry authentication](https://docs.podman.io/en/latest/markdown/podman-login.1.html). |

[gitops/runner_container/Dockerfile](../gitops/runner_container/Dockerfile) builds the image with the GitHub runner and selected Ansible/Terraform releases defined in that file. A build stage retrieves the architecture-specific runner archive; the final image runs under its own `runner` user. This container identity is distinct from the host service account. The Dockerfile writes a sudo policy but does not explicitly install the sudo package.

[entrypoint.sh](../gitops/runner_container/entrypoint.sh) validates registration inputs, obtains a GitHub registration token using the PAT, removes a matching old name, and registers unattended. The matching registration is removed without checking its online status. Signal handlers attempt deregistration during shutdown. Registration is persistent for the process lifetime and does not request an ephemeral runner.

The [GitHub Actions workflow](../.github/workflows/build_runner_container.yml) builds on relevant pushes to main, checks that Ansible/Terraform execute in an amd64 image, then publishes amd64/arm64 images to GHCR with tracking and date/commit tags. The control node pulls the image selected by `RUNNER_IMAGE`; its registry auto-update behavior depends on that reference.

## Network node: router on a stick

[network/setup.yml](network/setup.yml) configures a Linux router with one tagged LAN uplink carrying multiple VLANs, a separate WAN connection, DHCP/DNS services, and WireGuard remote access. Routing is performed by the host kernel; dnsmasq and AdGuard provide supporting services in host-networked containers.

### Physical NICs and early boot

| Template | Hardware context and configuration |
| --- | --- |
| [10-lan.link.j2](network/templates/10-lan.link.j2) | `lan0` is the added PCIe-connected M.2 A+E Key 2.5 GbE adapter with a Realtek RTL8125BG chip. Matches `Driver=r8125`, names the device `lan0`, and disables transmit checksum and receive/transmit VLAN-tag hardware acceleration. These request software handling instead of NIC offload; they do not remove VLAN support. The repository does not record the original offload fault, so treat these as hardware-specific settings rather than a universal performance improvement. |
| [20-wan.link.j2](network/templates/20-wan.link.j2) | Matches `Driver=e1000e` and names that interface `wan0` because it is the motherboard's onboard Ethernet device. The driver match reflects the installed hardware; it does not mean WAN connections require that driver. |

[network_setup.yml](network/tasks/network_setup.yml) installs `kmod-r8125`, prevents `r8169` from loading, explicitly loads `r8125`, and records it for subsequent boots. It rebuilds initramfs and reboots on relevant file changes so early-boot driver/naming state agrees with the installed configuration. The matches are by driver, not MAC/PCI address; multiple NICs using the same driver would need more specific rules.

See [systemd .link matching and offloads](https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html), [kernel e1000e documentation](https://docs.kernel.org/networking/device_drivers/ethernet/intel/e1000e.html), and [dracut/initramfs documentation](https://dracut-ng.github.io/dracut.html).

### How NetworkManager constructs the VLANs

The playbook renders connection profiles into `/etc/NetworkManager/system-connections/` with root ownership and mode `0600`. NetworkManager's keyfile plugin reads these INI-style files; restrictive permissions also protect WireGuard keys. `nmcli connection reload` rereads profiles but does not by itself reactivate an existing connection with new settings. The playbook reboots for physical LAN/WAN profile changes; VLAN changes currently notify only a reload. See [NetworkManager keyfile format and loading](https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html).

| Template | Role in the configuration |
| --- | --- |
| [lan0.nmconnection.j2](network/templates/lan0.nmconnection.j2) | Matches the physical `lan0` Ethernet interface and assigns it to firewalld's `internal` zone. Disables IP configuration on this parent: gateway addresses live on VLAN child interfaces instead of the untagged LAN. |
| [vlan.nmconnection.j2](network/templates/vlan.nmconnection.j2) | Rendered once per `router_vlans` item. `type=vlan` requests a VLAN device; `parent=lan0` chooses the physical link; `id` supplies the 802.1Q tag; `interface-name=lan0.<id>` names the kernel child device. `flags=1` selects reorder-headers behavior. The connection `id` is the human-readable profile name, such as `vlan10`, rather than the device name. |
| [wan0.nmconnection.j2](network/templates/wan0.nmconnection.j2) | Configures `wan0` in the `public` zone, using the discovered host IPv4 address/gateway as static configuration and an explicit /24 prefix. Selects localhost as the host DNS server. A previously discovered address becomes fixed configuration on later activation. IPv6 is disabled in these profiles. |

When activated, each VLAN profile creates a Linux virtual interface over `lan0`. Incoming tagged frames go to the matching child; outgoing traffic on that child leaves the physical link with its VLAN tag. `[ipv4] method=manual` assigns the configured gateway address. The current template passes a bare address through `address1`; keep the effective prefix aligned with the /24 networks/pools defined in variables. See [VLAN settings and flags](https://networkmanager.dev/docs/api/latest/settings-vlan.html), [keyfile address syntax](https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html), and [IPv4 addressing](https://networkmanager.dev/docs/api/latest/settings-ipv4.html).

| VLAN | Linux device | Gateway | DHCP pool |
| --- | --- | --- | --- |
| 10, management | `lan0.10` | `172.16.10.1` | `172.16.10.100–200` |
| 20 | `lan0.20` | `172.16.20.1` | `172.16.20.100–200` |
| 30 | `lan0.30` | `172.16.30.1` | `172.16.30.100–200` |
| 40 | `lan0.40` | `172.16.40.1` | `172.16.40.100–200` |

One switch uplink must allow these VLANs tagged. An ordinary endpoint can remain untagged on an access port: the switch associates it with that port's VLAN and adds the tag toward the router. For example, a VLAN 20 client reaches its gateway over switch → tagged uplink → `lan0` → `lan0.20`. Routed traffic can leave another VLAN child over the same cable, or leave `wan0` upstream. These are routed interfaces, not a Linux bridge.

The switch-side setup is described in the [UniFi runbook](../unifi/bootstrap/howto.md). NetworkManager creates the host interfaces; it does not configure switch ports. The `zone` profile property associates interfaces with firewalld; see [NetworkManager connection settings](https://networkmanager.dev/docs/api/latest/settings-connection.html).

### Forwarding, firewall policy, and WAN masquerading

Three separate settings cooperate:

1. **Kernel forwarding:** `net.ipv4.ip_forward=1` allows packets addressed to other machines to pass between interfaces.
2. **Firewall permission:** the internal-to-public policy allows the forwarded traffic along that path.
3. **Masquerading:** firewalld's public-zone masquerade rewrites an outgoing client's source address to the router's WAN address. Connection tracking maps replies back to the original client.

For example, traffic from `172.16.20.120` to an Internet service leaves with the WAN address as its source, so the upstream router does not need a return route for every lab VLAN. Masquerading is source NAT; it does not publish an internal service or create a destination port-forward.

See [kernel IP forwarding](https://docs.kernel.org/networking/ip-sysctl.html), [firewalld masquerading](https://firewalld.org/documentation/man-pages/firewalld.zone.html), and [policy objects](https://firewalld.org/documentation/man-pages/firewalld.policies.html).

| Template | Forwarded traffic it permits |
| --- | --- |
| [firewalld_int_to_ext.xml.j2](network/templates/firewalld_int_to_ext.xml.j2) | `internal` → `public` with target `ACCEPT`, allowing LAN clients upstream. |
| [firewalld_wg_to_internal.xml.j2](network/templates/firewalld_wg_to_internal.xml.j2) | `wireguard` → `internal` with target `ACCEPT`, allowing VPN clients toward the VLAN networks. |
| [firewalld_wg_to_wan_lan.xml.j2](network/templates/firewalld_wg_to_wan_lan.xml.j2) | Accepts VPN traffic only when its destination matches the discovered upstream WAN /24. Target `CONTINUE` leaves other traffic to subsequent policy evaluation; this file does not grant unrestricted VPN Internet forwarding. |

[firewall_setup.yml](network/tasks/firewall_setup.yml) also opens router-local SSH, DNS, DHCP, and the AdGuard UI in the internal zone and removes Cockpit from public. Local service permissions differ from forwarding permissions. All VLANs share `internal`; the repository does not define separate per-VLAN isolation policies.

### DHCP and DNS: what clients receive and where queries go

The router's dnsmasq leases addresses and advertises the control node's PXE boot files; AdGuard is the client-facing DNS resolver/filter. They cooperate without competing for port 53.

| Template | Configuration and purpose |
| --- | --- |
| [dnsmasq.conf.j2](network/templates/dnsmasq.conf.j2) | Listens on loopback and the generated VLAN interfaces. Per-VLAN `dhcp-range=set:vlan<id>,...` both selects a pool and sets a tag; matching `dhcp-option=tag:vlan<id>,...` sends that pool's gateway and DNS address. Leases last 24 hours. Architecture and iPXE user-class tags select control-node boot files through `dhcp-boot`. Advertises the lab search domain and MTU 1460. `bind-dynamic` accommodates interface/address changes. |
| [dhcp-hosts.conf.j2](network/templates/dhcp-hosts.conf.j2) | Converts reservations from `TARGET_DHCP_RESERVATIONS_JSON` into MAC/address entries with optional hostnames/comments. A fixed lease makes a device's address predictable; supplying DNS through DHCP does not independently create arbitrary DNS records. |
| [dnsmasq.container.j2](network/templates/dnsmasq.container.j2) | Runs with host networking to reach VLAN interfaces and DHCP broadcasts, mounts configuration read-only, and persists leases under `/data/state/dnsmasq`. Adds the networking capabilities described below. |
| [AdGuardHome.yaml.j2](network/templates/AdGuardHome.yaml.j2) | Binds DNS on router/VLAN/VPN/loopback addresses at port 53 and restricts allowed clients. Uses encrypted public upstreams and a lab-domain route to local dnsmasq. Configures the UI account, filters, cache, and schema expected by the application. |
| [adguard.container.j2](network/templates/adguard.container.j2) | Uses host networking for those host IP bindings and persists both AdGuard configuration and work data. |

**PXE server selection.** In [network/.env.example](network/.env.example), `TARGET_PXE_SERVER_REF` selects a reservation from `TARGET_DHCP_RESERVATIONS_JSON` by an exact, case-sensitive `ref_name` match. For example, `TARGET_PXE_SERVER_REF='Control node'` selects the example reservation with `ref_name: "Control node"` and IPv4 `172.16.10.10`. [Network variables](network/group_vars/network_nodes.yml) derive `pxe_server_ip` from that reservation's `ipv4`. [container_apps_setup.yml](network/tasks/container_apps_setup.yml) requires a nonempty reference and exactly one match before rendering configuration; unset, missing, or duplicate matches fail validation. This reference is required by the current network setup even though the reservation list itself defaults to empty.

A VLAN 20 client's DHCP exchange arrives through `lan0.20`. It receives an address from that VLAN's pool, a /24 mask, gateway `172.16.20.1`, and DNS server `172.16.20.1`. DHCP configures the client's network; later DNS queries are a separate exchange.

DNS flow:

- **Local names:** client → AdGuard at the VLAN gateway on port 53 → dnsmasq at `127.0.0.1:1053` for the lab domain → reply back through AdGuard.
- **Public names:** client → AdGuard → Quad9/Cloudflare DNS-over-HTTPS → reply back to the client.

dnsmasq's `domain` and `local=/.../` define local-domain handling, while DHCP lease/reservation names supply local host identities. `interface-name` associates the router's own lab name with `lan0.10`'s IPv4 address. dnsmasq's nonstandard DNS port leaves standard port 53 free for AdGuard. See [dnsmasq DHCP, tags, and local DNS](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html).

AdGuard's bootstrap resolvers resolve the public upstream servers' hostnames. Parallel upstream mode queries multiple resolvers; optimistic caching can answer with cached data while refreshing it. The template enables a 32 MiB cache, disables query rate limiting for bursts, and enables AdGuard/AdAway filters. See [AdGuard configuration fields](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration).

[base_setup.yml](network/tasks/base_setup.yml) disables/masks systemd-resolved and its stub listener, leaving AdGuard to provide the configured DNS service. `net.ipv4.ip_nonlocal_bind=1` permits binding IPv4 addresses not currently assigned, helping services start before VLAN/VPN addresses exist. It does not create those addresses or guarantee reachability. See [kernel bind-related sysctls](https://docs.kernel.org/networking/ip-sysctl.html).

### Why dnsmasq has extra Linux capabilities

The network dnsmasq container uses `AddCapability=NET_ADMIN NET_BIND_SERVICE NET_RAW`. Linux capabilities split privileged operations into specific permissions:

| Capability | Why this DHCP/PXE service is given it |
| --- | --- |
| `NET_BIND_SERVICE` | Permits binding low-numbered ports such as DHCP's UDP 67 when the namespace's privileged-port threshold requires it. |
| `NET_RAW` | Permits raw/packet sockets, used by DHCP's low-level Ethernet handling and address-conflict checks. |
| `NET_ADMIN` | Allows network administration operations; dnsmasq's DHCP paths can need operations such as neighbor/ARP management. This is broader than ordinary UDP socket access. |

The network dnsmasq container uses the host network namespace, so network privileges apply in that shared namespace. Adding capabilities allows operations; it does not itself enable forwarding or install the router's firewall policies. The dedicated routing/sysctl tasks do that. The separate TFTP container only explicitly adds low-port binding capability.

See [Linux capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html) and [Quadlet AddCapability](https://docs.podman.io/en/latest/markdown/podman-container.unit.5.html).

### WireGuard and dynamic DNS

| Template | Configuration and purpose |
| --- | --- |
| [wg0.nmconnection.j2](network/templates/wg0.nmconnection.j2) | Lets NetworkManager create the `wg0` tunnel with the configured private key, UDP port, VPN address, and `wireguard` firewall zone. Each peer section binds a public key to one VPN /32 plus a preshared key. Allowed IPs associate routes and permitted tunnel source addresses with a peer. Secret flags set to zero keep the secrets in the protected connection profile. |
| [duckdns.service.j2](network/templates/duckdns.service.j2) | Runs one update request after network availability. An empty `ip=` lets DuckDNS infer the public source address. The current `curl -k` disables TLS certificate verification. |
| [duckdns.timer.j2](network/templates/duckdns.timer.j2) | Triggers the service one minute after boot and every five minutes following activation, keeping the name usable when the upstream public address changes. |

VPN packets enter through the public UDP listener, emerge decrypted on `wg0`, and then follow the host's routing/firewall policies toward VLANs or the upstream subnet. Client-side allowed routes also determine what a client sends into the tunnel. See [NetworkManager WireGuard settings](https://networkmanager.dev/docs/api/latest/settings-wireguard.html) and [WireGuard cryptokey routing](https://www.wireguard.com/#cryptokey-routing).

## Temporary workstation provisioning: boostrap

[boostrap/bootstrap_setup.yml](boostrap/bootstrap_setup.yml) turns the workstation into a temporary installer server. Its spelling is the actual directory name. This temporary DHCP service is separate from the router's ongoing VLAN leases and PXE boot instructions; it serves the directly connected target while the control node's permanent TFTP/HTTP service remains a separate deployment.

The host receives a temporary bootstrap address, enables IPv4 forwarding/NAT for the directly connected target, and opens provisioning ports. `net.ipv4.ip_unprivileged_port_start=0` removes the low-port restriction in that network namespace; it does not make processes root. The actual PXE containers are nevertheless launched with privilege escalation and `privileged: true`. See [kernel privileged-port threshold](https://docs.kernel.org/networking/ip-sysctl.html).

| Template | Configuration and purpose |
| --- | --- |
| [dnsmasq.conf.j2](boostrap/templates/dnsmasq.conf.j2) | Supplies actual DHCP leases on the isolated interface, advertises the workstation as gateway and public DNS servers, and disables dnsmasq DNS with `port=0`. Architecture/user-class tags select shim for the Secure Boot path or iPXE otherwise. An iPXE request receives the HTTP script instead of its own binary. Advertises MTU 1460. |
| [boot.ipxe.j2](boostrap/templates/boot.ipxe.j2) | Downloads installer kernel/initrd over HTTP. Kernel arguments select the installation repository (`inst.repo`), installer runtime (`inst.stage2`), and unattended configuration (`inst.ks`). Requests DHCP, waits for network carrier, and boots the installer. |
| [grub.cfg.j2](boostrap/templates/grub.cfg.j2) | Provides the alternative shim/GRUB boot path with the same installer arguments. Loads the extracted kernel/initrd from the selected architecture's TFTP tree. |
| [nginx.conf.j2](boostrap/templates/nginx.conf.j2) | Serves extracted installation media and Kickstart over HTTP, with directory listing and the same kernel-assisted transfer/content-type settings as control's PXE web server. |
| [tftpd.map.j2](boostrap/templates/tftpd.map.j2) | Generates architecture-specific rewrites for firmware path quirks and stripped boot filenames. Retains a specifically x86_64 Onboard rewrite and a revocation-name substitution to shim. |
| [ks.cfg.j2](boostrap/templates/ks.cfg.j2) | Automates OS installation, storage preparation, accounts, hostname/timezone, SSH key installation, updates, and reboot. The pre-install phase writes the selected disk commands into an included file; the no-chroot post phase copies disk-selection state into the installed system for its later post script. |

The Kickstart chooses `nvme0n1`, then `sda`, then a remaining eligible disk, clears it, and uses automatic LVM partitioning. It also repartitions/formats other detected disks as ext4 and writes UUID-based mounts at `/data1`, `/data2`, etc. **These operations erase disk contents.** The resulting mount layout is distinct from control's configured `/data` directory.

Installation media is checksum-verified and unpacked into `boostrap/pxe-data`; the selected OS release is defined in [img_manager_gen.yml](boostrap/tasks/img_manager_gen.yml), with architecture/host settings in [localhost.yml](boostrap/host_vars/localhost.yml).

See [RHEL unattended installation and Kickstart](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/automatically_installing_rhel/index), [dracut boot arguments](https://dracut-ng.github.io/dracut.html), and the PXE/DHCP references above.

[bootstrap_cleanup.yml](boostrap/bootstrap_cleanup.yml) removes the temporary pod/containers, generated data, bootstrap address, and firewall openings. It disables forwarding/NAT and resets the low-port threshold to 1024. It applies explicit cleanup values rather than restoring saved previous host settings.

## How the two node-specific bootstrap directories fit in

Both [control/bootstrap](control/bootstrap) and [network/bootstrap](network/bootstrap) provide thin entry points around the shared workstation installer:

1. Their `setup.yml` imports `../../boostrap/bootstrap_setup.yml`. This prepares local PXE; it does not configure the final control/router role.
2. The target boots the shared installer and completes Kickstart.
3. Their separate `target_host_setup.yml` reads shared bootstrap host/account settings, uses an explicit target IP or the first neighbor-cache entry on the bootstrap interface, and adds that address to a temporary in-memory inventory.
4. It assigns the target to `control_nodes` or `network_nodes`, then imports the corresponding parent `setup.yml` for remote role configuration.
5. The shared cleanup playbook removes the workstation provisioning environment when it is no longer needed.

The neighbor lookup is a convenience rather than verified device identity; an explicit target IP avoids relying on cache ordering. The wrappers reuse the same installer logic while choosing which role runs after installation. Neither target wrapper automatically invokes cleanup.

## Shared maintenance

[update_system.yml](update_system.yml) upgrades inventory hosts in batches of 25% and reboots when the platform's reboot-needed check indicates it is required. Planned service recovery, secret permissions, ID allocation, and provisioning improvements are tracked in [todo.md](../todo.md).
