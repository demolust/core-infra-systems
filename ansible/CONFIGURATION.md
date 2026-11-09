# Infrastructure configuration and design

This explains the purpose of the configuration, how the less obvious settings work, and how the services fit together. The deployed configuration in `control`, `network`, `prod`, and `boostrap` is described below. Package installation and SSH hardening are summarized; networking, identity mapping, permissions, and provisioning receive more detail.

Guest-facing Proxmox network profiles, combinations, bastion SSH access, and general API/template plans are documented in [PE_CONFIGURATION.md](PE_CONFIGURATION.md). This file retains infrastructure configuration and deployment details.

Addresses and ports describe repository defaults. Software versions are selected in the linked variables, image definitions, and build tasks rather than repeated here. Hardware details and the Samba deployment decision include the operator's context.

## Control node

[control/setup.yml](control/setup.yml) prepares the server for shared storage, applications, network provisioning, and infrastructure automation.

### Host preparation and service ownership

[system_setup.yml](control/tasks/system_setup.yml) installs tools for interactive administration, diagnostics, development, and media/document processing, enables supporting repositories, and builds tools unavailable in the desired form from normal packages. Selected streams, source revisions, and source RPMs are defined there. [admin_user_config.yml](control/tasks/admin_user_config.yml) installs the administrator's dotfiles and user tools, including a separate Neovim Python environment. [admin_user_setup.yml](control/tasks/admin_user_setup.yml) grants administrator, shared-storage, and GitOps group access. SSH disables root/password login and limits authentication attempts. On Red Hat-family hosts, system setup enables and starts firewalld before applying service and port rules.

Applications run under separate `runner`, `unifi`, `navidrome`, `vault`, and `netbox` accounts. Their user Quadlets live under `/var/lib/<account>/.config/containers/systemd`; PXE instead uses root-owned units under `/etc/containers/systemd`.

The setup separates host preparation, administrator creation, container dependencies, shared SELinux settings, native Samba, application deployment, and administrator tool configuration. [container_deps.yml](control/tasks/container_deps.yml) installs Podman, creates root-owned storage and PXE directories, applies the persistent file-context rule, downloads iPXE binaries, and enables the host auto-update timer. [container_user_deps.yml](control/tasks/container_user_deps.yml) creates the remaining user-owned application directories; [post_system_setup.yml](control/tasks/post_system_setup.yml) enables the shared SELinux booleans.

Application definitions live in `quadlet_services` and `quadlet_user_services` in [control variables](control/group_vars/control_nodes.yml). Each entry names its service and lists configuration files and Quadlet templates. [container_apps_setup.yml](control/tasks/container_apps_setup.yml) deploys root services; [container_user_apps_setup.yml](control/tasks/container_user_apps_setup.yml) deploys user services through each account's systemd manager. Both deployment tasks enable each service and ensure it is running on every run. Changed configuration or Quadlet files trigger a restart; otherwise, a stopped service is started and an already running service is left running. Each task reloads its systemd manager only when Quadlet files change. The user task also enables and starts each account's Podman auto-update timer, leaving an already running timer in place.

**Subordinate IDs and rootless Podman.** `/etc/subuid` delegates extra host user IDs to an account; `/etc/subgid` does the same for group IDs. An entry such as `runner:100000:65536` authorizes that account to map 65,536 IDs starting at 100000. It does not create those users or grant login access. See the upstream [subuid](https://github.com/shadow-maint/shadow/blob/master/man/subuid.5.xml) and [subgid](https://github.com/shadow-maint/shadow/blob/master/man/subgid.5.xml) manuals.

Podman uses these allocations, through `newuidmap`/`newgidmap`, to build a user namespace. With the ordinary rootless mapping, container root maps to the invoking host account; other container identities use subordinate IDs. Thus an image's database or application user can own files without becoming that UID on the host. These mappings also determine ownership on bind-mounted storage. See [Podman rootless operation](https://docs.podman.io/en/latest/markdown/podman.1.html) and [inspecting the namespace with podman unshare](https://docs.podman.io/en/latest/markdown/podman-unshare.1.html).

The current allocation loop advances for each user/file pair, so the same account gets different UID and GID starting ranges. Different starts are technically possible; the management issue is that allocations depend on dictionary order and are not checked against existing ranges. Changing mappings can leave persistent files owned by old mapped IDs.

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

[samba_setup.yml](control/tasks/samba_setup.yml) installs the native Samba packages, renders `/etc/samba/smb.conf`, sets passwords with `smbpasswd`, and starts/enables the host services. `TARGET_ADMIN_SAMBA_PASSWORD` supplies the administrator's Samba password through `samba_users`; password tasks suppress Ansible logs. The former container templates, identity-copying entrypoint, private container directories, and NTLM-hash input have been removed.

| Template | Configuration and purpose |
| --- | --- |
| [smb.conf.j2](control/templates/smb.conf.j2) | Configures local Samba authentication with `tdbsam`, home/profile/user shares, printing shares, and the custom data share. That share permits the administrator/`share` group to write, forces group ownership, and uses case-sensitive filenames while preserving case. Its mask/mode defaults are `0660` for files and `0770` for directories. `write list` grants Samba write permission; filesystem permissions still apply. `map to guest = Bad User` does not override the custom share's `guest ok = No`. |

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

The control playbook deploys TFTP and HTTP containers in a root-owned, host-networked PXE pod. DHCP and PXE boot instructions are configured only on the network node; the former control-node proxy-DHCP template and dnsmasq Quadlet have been removed.

| Template | Configuration and purpose |
| --- | --- |
| [pxe.pod.j2](control/templates/pxe.pod.j2) | Defines a root-owned host-networked pod, activated with the host's multi-user target. Its containers use host interfaces and ports directly. The pod groups their lifecycle; it does not route traffic between VLANs. |
| [pxe_tftp.container.j2](control/templates/pxe_tftp.container.j2) | Installs tftp-hpa at startup and runs it in the foreground on UDP 69. `--secure` restricts the served filesystem root; `--map-file` enables firmware filename rewrites. Syslog goes to container output. |
| [pxe_nginx.container.j2](control/templates/pxe_nginx.container.j2) | Mounts the host web-content tree and JavaScript handlers read-only, serving boot files and Proxmox installation answers over HTTP. |

The component units use `After=pxe-pod.service` for order, `BindsTo=` to stop when the pod disappears, and `PartOf=` to propagate pod stop/restart operations. This keeps the TFTP and HTTP containers tied to the same provisioning service; network-node DHCP has a separate lifecycle. See [Pod Quadlets](https://docs.podman.io/en/latest/markdown/podman-pod.unit.5.html) and [systemd dependency semantics](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html).

| Template | Less obvious boot configuration |
| --- | --- |
| [boot.ipxe.j2](control/templates/boot.ipxe.j2) | Gets network configuration only if needed and sets `base_url` to `http://{{ remote_server_ip }}:{{ pxe_http_port }}`. First attempts to chain `${base_url}/configs/ipxe/${netX/mac:hexhyp}.ipxe`; a failed chain falls back to the generic rescue/shell/reboot menu. It calculates an architecture-directory mapping, but rescue URLs still use `${arch}` instead of `${arch_path}`; the arm64/aarch64 discrepancy remains a TODO. |
| [grub.cfg.j2](control/templates/grub.cfg.j2) | Deployed to `{{ pxe_base_dir }}/tftp/configs/grub/grub.cfg`. Loads video/filesystem/compression support, preserves the framebuffer, and offers rescue kernel/initrd loading or iPXE chainloading. It maps the GRUB CPU name to the content directory. The DHCP boot path uses unsigned iPXE and requires Secure Boot to be disabled. |
| [nginx.conf.j2](control/templates/nginx.conf.j2) | Serves the mounted web root, permits directory listings, uses `sendfile` for kernel-assisted file transfer, and `tcp_nopush` for packet batching with sendfile. The fallback content type is `application/octet-stream`. Loads the Nginx JavaScript module, selects QuickJS with `js_engine qjs`, and routes the exact path `/proxmox/answer` to `proxmox_setup.answer`, with a 256 KiB request-body limit and buffer. |
| [proxmox_setup.js.j2](control/templates/proxmox_setup.js.j2) | Selects an existing TOML answer file using MAC addresses from an installer JSON POST. Lowercases valid colon-separated MACs, converts them to hyphen-separated filenames, deduplicates candidates, and requires exactly one matching file. |
| [tftpd.map.j2](control/templates/tftpd.map.j2) | Normalizes backslashes and rewrites firmware-specific requests, including stripped paths and an Onboard pattern, to files in the architecture directories. Maps requests beginning with `grub.cfg` (with an optional leading slash, including per-client suffixes) to `configs/grub/grub.cfg`. Includes revocation-filename-to-shim substitutions; filename substitution does not itself establish a valid Secure Boot verification chain. |

The boot sequence is:

1. Network-node dnsmasq leases an address and matches UEFI client architecture: values 7/9 select `/x86_64/ipxe.efi`; value 11 selects `/aarch64/ipxe.efi`. Both point to the control node's reservation address.
2. The client downloads that binary from control-node TFTP. When iPXE requests boot information, its `iPXE` user class selects `/configs/ipxe/boot.ipxe` from the same TFTP server, avoiding another binary download.
3. The generic script tries a MAC-specific script over HTTP, using a hyphen-separated MAC filename such as `02-00-00-00-10-01.ipxe`. These scripts live under `{{ pxe_base_dir }}/www/configs/ipxe/`; control setup creates the directory, and the production provisioning playbook described below generates per-device scripts.
4. If chaining fails, the generic menu offers rescue, shell, and reboot. Rescue assets must already exist: the playbook downloads iPXE binaries but does not populate rescue kernels/initrds.

For the alternative Secure Boot path, DHCP selects the architecture-specific shim executable, which starts GRUB. The TFTP mapping serves `{{ pxe_base_dir }}/tftp/configs/grub/grub.cfg` for matching GRUB configuration requests, preserving the filename requested by the existing EFI binary. Moving this configuration therefore requires no changes to the shim/iPXE boot paths in the network-node dnsmasq template. Those Secure Boot DHCP alternatives remain commented out; the active path above uses unsigned iPXE. The separate `boostrap/` workflow retains its architecture-specific GRUB configuration layout.

Clients need routed access to control-node TFTP and HTTP across VLANs. Keep the selected reservation address consistent with the control node's actual address and `remote_server_ip`, which supplies the HTTP base URL.

See [dnsmasq DHCP boot options](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html), [iPXE kernel loading](https://ipxe.org/cmd/kernel), [tftp-hpa remapping](https://manpages.debian.org/testing/tftpd-hpa/in.tftpd.8.en.html), and [Nginx transfer directives](https://nginx.org/en/docs/http/ngx_http_core_module.html).

#### Proxmox installation answer service

[container_deps.yml](control/tasks/container_deps.yml) prepares the Proxmox content directories; the PXE entry in `quadlet_services` deploys the answer handler through [container_apps_setup.yml](control/tasks/container_apps_setup.yml). The Nginx container mounts the following host paths:

| Host path | Container path | Purpose |
| --- | --- | --- |
| `{{ pxe_base_dir }}/www` | `/usr/share/nginx/html` | Boot assets and configuration files, including `configs/ipxe` and `configs/proxmox`. |
| `{{ pxe_base_dir }}/scripts/nginx` | `/usr/share/nginx/scripts` | Contains the rendered `proxmox_setup.js` imported by Nginx. |

Place per-machine answer files under `{{ pxe_base_dir }}/www/configs/proxmox/`, using lowercase, hyphen-separated MAC filenames such as `02-00-00-00-10-01.toml`. The handler reads this directory as `/usr/share/nginx/html/configs/proxmox` inside the container. Configure an installer that fetches answers over HTTP to POST to `http://{{ remote_server_ip }}:{{ pxe_http_port }}/proxmox/answer`.

The handler accepts system information directly in the JSON body or inside `sysinfo`, with a `network_interfaces` or `network-interfaces` array containing `mac` fields. Exactly one existing answer file across the supplied interfaces returns HTTP 200 with `application/toml`; no match returns 404 and multiple distinct matches return 409. Invalid JSON or missing interface information returns 400, non-POST methods return 405, and file-read failures other than missing files return 500. Responses set `Cache-Control: no-store`.

The main control setup prepares the answer service and asset directories. [proxmox_iso_setup.yml](control/proxmox_iso_setup.yml) separately downloads and prepares the installer assets on the control node, using `TARGET_PXE_INT` to discover the address embedded in the answer-service URL.

[proxmox_download_isos.yml](control/tasks/proxmox_download_isos.yml) reads the upstream `SHA256SUMS` manifest and selects the highest matching version independently for `x86_64` and `aarch64`, with the latter matching the `-arm64.iso` suffix. Both architectures must have a matching release. Downloads go under `{{ pxe_base_dir }}/downloads`, use the manifest checksum, and receive an additional SHA-256 check after download. Selection follows the manifest at run time rather than a pinned installer version.

[proxmox_prepare_isos.yml](control/tasks/proxmox_prepare_isos.yml) runs with privilege escalation for each selected release. It mounts the source ISO read-only, copies its complete tree into a temporary workspace, and writes `auto-installer-mode.toml` with HTTP mode and `http://{{ pxe_server_ip }}:{{ pxe_http_port }}/proxmox/answer`. Here `pxe_server_ip` is discovered on the control node's PXE interface; keep it aligned with the network node's selected PXE reservation.

The task publishes these files under `{{ pxe_base_dir }}/www/<architecture>/proxmox/`:

| File | Purpose |
| --- | --- |
| `vmlinuz` | Installer kernel copied from `boot/linux26`. |
| `initrd-original.img` | Unmodified installer initrd retained from the source ISO. |
| `initrd.img` | Gzip initrd: Zstandard input is decompressed and recompressed; existing gzip input is copied unchanged. Other compression formats fail validation, and `gzip -t` checks the normalized result before publication. |
| `proxmox_installer.iso` | ISO rebuilt from the copied tree, including the HTTP automatic-installer configuration, using `mkisofs -R -J -iso-level 3`. |

The rebuild does not pass firmware boot options to `mkisofs`; this file is installer content for the PXE workflow, without a guarantee that it can boot directly as USB or optical media. Preparation requires host mount/loop support and the `file`, `zstd`, `gzip`, and `mkisofs` tools. An `always` block unmounts the source and removes the temporary workspace. Check mode skips ISO preparation and the additional checksum verification.

The production provisioning playbook described below generates TOML answers and machine-specific iPXE scripts separately. Neither control playbook adds a Proxmox entry to the generic iPXE menu.

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

[pre_setup.yml](network/tasks/pre_setup.yml) validates PXE server selection before system changes. [container_deps.yml](network/tasks/container_deps.yml) installs Podman, prepares service storage and the root Quadlet directory, and enables the host auto-update timer. The `quadlet_services` list in [network variables](network/group_vars/network_nodes.yml) defines dnsmasq and AdGuard configuration/templates. [container_apps_setup.yml](network/tasks/container_apps_setup.yml) deploys each entry, reloads systemd when its Quadlets change, and enables and ensures its service is running. Configuration or Quadlet changes trigger a restart; otherwise, stopped services are started without restarting running services. On Red Hat-family hosts, [system_setup.yml](network/tasks/system_setup.yml) enables and starts firewalld before subsequent firewall configuration.

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
| [dns-hosts.conf.j2](network/templates/dns-hosts.conf.j2) | Generates persistent `IP FQDN short-name` records from the same reservation facts, only for entries with a nonempty `name`. The optional `ref_name` is a comment. These records survive DHCP lease expiration. |
| [dnsmasq.container.j2](network/templates/dnsmasq.container.j2) | Runs with host networking to reach VLAN interfaces and DHCP broadcasts, mounts the main configuration, DHCP reservations, and DNS hosts file read-only, and persists leases under `/data/state/dnsmasq`. Adds the networking capabilities described below. |
| [AdGuardHome.yaml.j2](network/templates/AdGuardHome.yaml.j2) | Binds DNS on router/VLAN/VPN/loopback addresses at port 53 and restricts allowed clients. Uses encrypted public upstreams and a lab-domain route to local dnsmasq. Configures the UI account, filters, cache, and schema expected by the application. |
| [adguard.container.j2](network/templates/adguard.container.j2) | Uses host networking for those host IP bindings and persists both AdGuard configuration and work data. |

**PXE server selection.** In [network/.env.example](network/.env.example), `TARGET_PXE_SERVER_REF` selects a reservation from `TARGET_DHCP_RESERVATIONS_JSON` by an exact, case-sensitive `ref_name` match. For example, `TARGET_PXE_SERVER_REF='Control node'` selects the example reservation with `ref_name: "Control node"` and IPv4 `172.16.10.10`. [Network variables](network/group_vars/network_nodes.yml) derive `pxe_server_ip` from that reservation's `ipv4`. [pre_setup.yml](network/tasks/pre_setup.yml) requires a nonempty reference and exactly one match before rendering configuration; unset, missing, or duplicate matches fail validation. This reference is required by the current network setup even though the reservation list itself defaults to empty.

A VLAN 20 client's DHCP exchange arrives through `lan0.20`. It receives an address from that VLAN's pool, a /24 mask, gateway `172.16.20.1`, and DNS server `172.16.20.1`. DHCP configures the client's network; later DNS queries are a separate exchange.

DNS flow:

- **Local names:** client → AdGuard at the VLAN gateway on port 53 → dnsmasq at `127.0.0.1:1053` for the lab domain → reply back through AdGuard.
- **Public names:** client → AdGuard → Quad9/Cloudflare DNS-over-HTTPS → reply back to the client.

dnsmasq's `domain` and `local=/.../` define local-domain handling. `addn-hosts=/etc/dnsmasq.d/dns-hosts.conf` loads the generated persistent records independently of DHCP leases; unnamed reservations are skipped. Both the network setup and production provisioning workflow generate DHCP and DNS outputs from the same reservation facts. The first deployment of this feature must use network setup to install the main directive and container mount before production provisioning can update the additional file alone. `interface-name` associates the router's own lab name with `lan0.10`'s IPv4 address. dnsmasq's nonstandard DNS port leaves standard port 53 free for AdGuard. See [dnsmasq DHCP, tags, and local DNS](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html).

AdGuard's bootstrap resolvers resolve the public upstream servers' hostnames. Parallel upstream mode queries multiple resolvers; optimistic caching can answer with cached data while refreshing it. The template enables a 32 MiB cache, disables query rate limiting for bursts, and enables AdGuard/AdAway filters. See [AdGuard configuration fields](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration).

[system_setup.yml](network/tasks/system_setup.yml) disables/masks systemd-resolved and its stub listener, leaving AdGuard to provide the configured DNS service. `net.ipv4.ip_nonlocal_bind=1` permits binding IPv4 addresses not currently assigned, helping services start before VLAN/VPN addresses exist. It does not create those addresses or guarantee reachability. See [kernel bind-related sysctls](https://docs.kernel.org/networking/ip-sysctl.html).

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

## Production nodes: Proxmox provisioning

[prod/proxmox_setup_pxe_boot_files.yml](prod/proxmox_setup_pxe_boot_files.yml) prepares production machines for unattended Proxmox installation by updating the network node's DHCP reservations and publishing per-machine files on the control node. It runs against `network_nodes` and `control_nodes`; the production machines themselves do not need an installed OS or an Ansible connection.

Run the network and control setup first, then [control/proxmox_iso_setup.yml](control/proxmox_iso_setup.yml) to prepare the installer assets. Copy [prod/.env.example](prod/.env.example) to a local `prod/.env`, fill in the values, and load it before provisioning. The example addresses are documentation placeholders; use the actual VLAN addresses and reserve unique IPs outside the dynamic DHCP pools.

| Input | Role |
| --- | --- |
| `TARGET_DHCP_RESERVATIONS_JSON` | Complete reservation list, including existing infrastructure hosts. Each entry supplies `mac`, `ipv4`, and a `ref_name`; `name` supplies the short DHCP hostname and, when nonempty, a persistent DNS record. This replaces both `dhcp-hosts.conf` and `dns-hosts.conf`, so omitted entries are removed from those generated files. |
| `TARGET_LAB_DOMAIN` | Domain used to construct persistent guest/host FQDNs. Set it in the provisioning environment as well as the network setup environment; values must match. |
| `TARGET_PXE_SERVER_REF` | Exact, case-sensitive `ref_name` of the control node's reservation. Its IPv4 address supplies the generated iPXE scripts' HTTP server address. |
| `PROXMOX_REF_PATTERN` | Regular expression applied to reservation `ref_name` values using Ansible's `match` test, which matches from the start. Use anchors such as `^prod[0-9]+$` to select complete names. Reservations without `ref_name` are excluded. |
| `PROXMOX_COUNTRY`, `PROXMOX_TIMEZONE`, `PROXMOX_MAILTO` | Shared installer country code, IANA timezone, and notification email address. |
| `PROXMOX_SETTINGS_JSON` | Object keyed by each selected reservation's exact `ref_name`. Every selected host needs `arch`, `keyboard`, `root_password_hash`, `ssh_keys`, `filesystem`, and `disks`. Include `zfs_raid` for ZFS. Architecture must match a prepared `x86_64` or `aarch64` asset directory. |

From `prod/`, after filling in `.env`:

```sh
source ./.env
ansible-playbook -i ../control/inventories/control_nodes.yml -i ../network/inventories/network_nodes.yml proxmox_setup_pxe_boot_files.yml
```

The first play reuses the network application's deployment task to render `dhcp-hosts.conf` and `dns-hosts.conf`, enable dnsmasq, and ensure it is running. Changes to either file trigger a restart; otherwise, a stopped dnsmasq service is started without restarting an already running service. It does not deploy dnsmasq Quadlets or regenerate the main dnsmasq configuration. Keep `TARGET_PXE_SERVER_REF` aligned with the existing network configuration; changing the boot-server reservation address also requires rerunning network setup to update its DHCP boot instructions.

The second play selects reservations and calls [proxmox_host_boot_files.yml](prod/tasks/proxmox_host_boot_files.yml) for each match. Filenames use the reservation MAC lowercased and converted from colon-separated to hyphen-separated form.

| Template | Generated file and behavior |
| --- | --- |
| [proxmox_answer.toml.j2](prod/templates/proxmox_answer.toml.j2) | Writes `{{ pxe_base_dir }}/www/configs/proxmox/<mac>.toml` with shared locale/contact settings, the host's keyboard, hashed root password, root SSH keys, filesystem, and installation disks. The installer obtains hostname and network settings from DHCP; supply the reservation hostname and lab domain. The installed Proxmox host writes the received address/gateway as static configuration rather than continuing DHCP renewal. Disk names omit `/dev/`, for example `nvme0n1`. |
| [proxmox_boot.ipxe.j2](prod/templates/proxmox_boot.ipxe.j2) | Writes `{{ pxe_base_dir }}/www/configs/ipxe/<mac>.ipxe`. Loads the selected architecture's `vmlinuz` with `proxmox-start-auto-installer`, then `initrd.img` and the rebuilt `proxmox_installer.iso`, presenting the ISO as `/proxmox.iso` to the installer. |

At PXE boot, the control node's generic script chains the matching MAC script automatically. The installer assets then load over HTTP, and the embedded automatic-installer configuration directs the installer to POST system information to `/proxmox/answer`. The existing answer handler selects the corresponding MAC-named TOML file. This supplies the production installation path without adding a menu entry.

**Booting this unattended installer can erase the selected installation disks.** Answer rendering suppresses Ansible logs and diffs, but the generated files are mode `0644` and served through the existing HTTP service. They contain password hashes and public keys. The playbook updates selected files without removing files for hosts no longer selected; remove obsolete answer and iPXE files explicitly, and disable or remove the installation script after provisioning to avoid a later PXE boot starting installation again.

### Installed Proxmox host setup

[prod/setup.yml](prod/setup.yml) configures installed `prod_nodes` over SSH. It imports [system_setup.yml](prod/tasks/system_setup.yml); storage settings live in [prod variables](prod/group_vars/prod_nodes.yml). The existing provisioning playbook remains responsible for the installer assets and network-node records, not post-install host configuration.

| Configuration | Current behavior |
| --- | --- |
| APT sources | Enables `pve-no-subscription` for the installed Debian release and disables PVE Enterprise and Ceph Squid Enterprise. Debian sources remain separate. Disabling the Ceph repository does not create or remove a Ceph cluster. |
| Host packages | Installs `vim`, `parted`, `fwupd`, `udisks2`, `lm-sensors`, `lsof`, `bind9-dnsutils`, `tcpdump`, `ethtool`, `sysstat`, `nvme-cli`, and `smartmontools`, refreshing the APT cache. Also enables/starts `smartmontools`. The `deb822_repository` tasks require the target Python Debian library. |
| SATA selection | When `/data` is not mounted, discovers the disk using `/dev/disk/by-path/{{ disk_pattern }}`; the current pattern is `pci-*-ata-1`. Checks the selected device's reported mountpoints before partitioning. |
| Filesystem and mount | Ensures partition 1 and ext4, reads its UUID from the `-part1` by-path link, and maintains the `/data` mount in `/etc/fstab`. Mounting follows filesystem setup even if formatting reports no change. Current options are `defaults,_netdev,nofail`; `_netdev` is unnecessary for local SATA storage. |
| Storage registration | Renders [storage.cfg.j2](prod/templates/storage.cfg.j2) to `/etc/pve/storage.cfg` on every run, including when `/data` is already mounted. The template preserves the expected `local` and `local-lvm` definitions and adds the configured SATA storage ID. |

The current disk workflow assumes the by-path pattern resolves to exactly the intended SATA disk and that the disk is appropriate to initialize. Its mountpoint check is not a filesystem-signature or partition-table validation, and it does not assert exactly one matching path. Inspect existing storage before first deployment. The earlier size-based selection is no longer used.

From `prod/`, with the installed-node inventory populated:

```sh
ansible-playbook -i inventories/prod_nodes.yml setup.yml
```

The SATA disk has one data partition, mounted by filesystem UUID at `data_path` (currently `/data`). NVMe holds Proxmox and its original storage; NVMe capacity/brand differences do not require identical SATA layouts. The operator reported the data mount surviving reboot and `pvesm status` showing `sata-local` active on prod01. Apply the same validation to each host.

**Storage choice rationale.** One ext4 partition uses the SATA disk as a single capacity pool for the learning workloads. This keeps mounting and Directory storage simple without reserving fixed partitions or logical volumes for Kubernetes, HPC, or LocalStack before their needs are known. Separate partitions, multiple host filesystems, Btrfs, and an additional LVM layer were not selected. Preserve the installer-created NVMe storage rather than recreating it. Guest filesystems are independent of the host ext4 choice, and Proxmox manages its content directories under `/data`. This is local storage on each node, not a replicated or HA storage solution.

| Storage definition | Backing storage and purpose |
| --- | --- |
| `local` | NVMe-backed `/var/lib/vz`; permits ISO images, container templates, backups, and imports. |
| `local-lvm` | Installer-created `pve/data` thin pool on NVMe; permits guest/container disks. |
| `{{ pe_storage_name }}` (currently `sata-local`) | Directory storage at `{{ data_path }}` on the SATA filesystem; permits VM images, ISOs, container templates, and snippets. `is_mountpoint 1` makes it unavailable when its mount is absent; `shared 0` keeps its meaning local to each node. |

Proxmox creates its content layout under the registered path, including `images/<VMID>/`, `template/iso/`, `template/cache/`, and `snippets/`. The current SATA definition does not enable backup content. Do not create workload-specific host directories for Kubernetes or LocalStack. See [Directory storage behavior](https://github.com/proxmox/pve-docs/blob/master/pve-storage-dir.adoc) and [guest storage usage](PE_CONFIGURATION.md#guest-disks-templates-and-placement).

`/etc/pve` is managed by Proxmox's cluster filesystem, so the template omits Unix owner/group/mode changes. This template owns the entire storage file: add any later NFS/SMB or other definitions to the managed configuration rather than expecting manual additions to survive a rerun. Once clustered, manage cluster-wide definitions once per cluster; each node still needs its own local mount.

### Proxmox guest-network integration

[interfaces.cfg.j2](prod/templates/interfaces.cfg.j2) now owns the full `/etc/network/interfaces` file, including the uplink, node-local private bridge, node-local NAT bridge, and `source /etc/network/interfaces.d/*`. Do not also define these bridges in included files. [system_setup.yml](prod/tasks/system_setup.yml) deploys it and notifies the `Apply network configuration` handler in [handlers.yml](prod/handlers/handlers.yml), which runs `ifreload -a` when the template changes. Restarting `networking.service` is not the chosen apply method.

The template gets the existing uplink port from `ansible_facts[prod_uplink_bridge]['interfaces'] | first`. It preserves the running default IPv4 address, dotted netmask, and gateway through `ansible_facts['default_ipv4']`. This assumes the named bridge already exists, owns the default route, and has one intended member; the installed nodes reported `enp1s0` as that member. It does not discover an arbitrary spare NIC or rename an existing bridge.

| Variable | Current value and role |
| --- | --- |
| `prod_uplink_bridge` | `vmbr0`: physical uplink and management/native VLAN 20; VLAN-aware for guest VLANs. |
| `inter_prod_vlan` | `110`: tagged cross-node private guest network, with subnet `172.16.110.0/24`. |
| `prod_private_bridge` | `vmbr1`: portless bridge for guests on one node, with no host address. |
| `prod_nat_bridge` | `vmbr2`: portless bridge for host-provided NAT guests on one node. |
| `prod_nat_gateway_cidr` | `192.168.130.1/24`: the host's address on its own NAT bridge and the guests' intended gateway. |
| `prod_nat_subnet` | `192.168.130.0/24`: intended NAT source subnet. Declared for later NAT/DHCP/firewall work; the current interface template does not consume it. |

The installed host keeps its address on `vmbr0`, for example `172.16.20.21` on prod01. The template renders `address` and `netmask` separately and enables `bridge-vlan-aware yes` with `bridge-vids {{ inter_prod_vlan }}`. The physical port remains `inet manual`; ordinary untagged traffic follows the switch's native VLAN 20. Tagged guest traffic is separated by the bridge rather than assigning all of `vmbr0` to VLAN 110.

| Integration point | Configuration and usage |
| --- | --- |
| UniFi VLAN definition | VLAN 110 is a switch network; its VM subnet is `172.16.110.0/24`. VLAN IDs and IP subnets are distinct settings. |
| Physical switch ports 4, 5, 6 | Keep `native_vlan: "20"`, use `tagged: "custom"`, and allow `tagged_vlans: ["110"]`. Preserve each port's name and PoE setting. |
| Guest virtual NIC | Terraform selects `vmbr0` with tag `110` for inter-node private traffic; VLAN 20 NICs remain untagged in this native-VLAN design. |
| Proxmox host IPs | Keep management on VLAN 20. No `vmbr0.110` host address is needed for the selected guest-bastion access method. |
| Netnode | VLAN 110 stays outside `router_vlans` for the isolated inter-node profile. Same-subnet private guests need no router or DHCP scope there. |

The local UniFi input lists VLAN 110 and the custom tagged settings on ports 4–6. Desired switch input is distinct from verification of an applied state. See [port mapping](../unifi/terraform/switch_core_ports.tf) and [input schema](../unifi/terraform/variables.tf).

`vmbr1` is rendered with `inet manual`, `bridge-ports none`, STP off, and forwarding delay zero. `vmbr2` uses the same portless bridge settings but `inet static` with `prod_nat_gateway_cidr`. It needs that address because the Proxmox host will be its gateway. Neither bridge has a physical port, VLAN tag, or another host default-gateway directive.

`192.168.130.0/24` distinguishes node-local NAT from the lab's `172.16.<VLAN>.0/24` convention. It does not create VLAN 130 and needs no switch/netnode VLAN configuration. The same subnet and gateway are reused independently on every node; guests must have unique addresses within each local bridge. Do not reuse this subnet for another interface of the same guest or a network it must route to.

**Current boundary:** deploying `vmbr2` creates a local network and host gateway address only. The committed tasks do not enable forwarding, install masquerading, start DHCP/DNS for this bridge, or isolate guest ports. Without additional filtering, attached guests on one node can communicate. The intended NAT/isolation behavior is described in [PE_CONFIGURATION.md](PE_CONFIGURATION.md#nat-only-guests-and-the-router-boundary).

Validation after applying the template can use `ip -br addr`, `ip route`, and `bridge vlan show`. Confirm the management route remains on `vmbr0`, the private bridge has no host IP, and the NAT bridge has `192.168.130.1/24`. See [Proxmox bridge/VLAN configuration](https://github.com/proxmox/pve-docs/blob/master/pve-network.adoc).

### Host access, local diagnostics, and log retention

The host baseline added in commit `a5bdaf3` keeps troubleshooting tools on the Proxmox nodes while deferring central monitoring to a future dedicated host on switch port 8.

| Configuration | Implemented behavior and limits |
| --- | --- |
| SSH administrator access | `TARGET_ADMIN_SSH_PUB_KEY` supplies `admin_ssh_pub_key`. `ansible.posix.authorized_key` adds it for root with `follow: true`, `manage_dir: false`, and `exclusive: false`. |
| Proxmox SSH identity | Preserve `/root/.ssh/authorized_keys -> /etc/pve/priv/authorized_keys`, other authorized keys, and Proxmox-generated private/public keys. Once clustered, the authorized-key target is shared; reconcile identical administrator additions once rather than concurrently rewriting the shared file. |
| Local disk health | Ensures `smartmontools` is enabled/running; `smartctl` and `nvme-cli` support SATA/NVMe investigation. |
| Troubleshooting | Installs `lm-sensors`, `lsof`, `bind9-dnsutils`, `tcpdump`, `ethtool`, and `sysstat` alongside the existing host tools. Installing them does not configure central collection or alert delivery. |
| Local journal retention | [journal_log_retention.conf.j2](prod/templates/journal_log_retention.conf.j2) writes `/etc/systemd/journald.conf.d/retention.conf` with `SystemMaxUse=500M` and `MaxRetentionSec=14day`. Busy journals can retain less than 14 days because of the size limit. |
| Time synchronization | Keep the working default chrony configuration. No custom chrony template is currently required. |

Local journald retention is separate from central log ingestion and application-specific log files. The current task deploys the drop-in without a journald restart handler; activate changed settings with an appropriate service restart or reboot. Central metrics/log storage, dashboards, alerts, and any required collectors remain to be selected with the monitoring stack.

### nftables backend preparation and final firewall work

Commit `7eff557` prepares the nftables backend on each Proxmox host. It installs `proxmox-firewall`, ensures `/etc/pve/local/host.fw` exists, deploys [host.fw.j2](prod/templates/host.fw.j2), and enables/starts `proxmox-firewall.service`. The current template contains only:

```ini
[OPTIONS]
nftables: 1
```

`/etc/pve/local` is the current node's symlink under `/etc/pve/nodes/`, so no hostname interpolation is needed. This selects the backend; it does not create a general filtering policy or NAT rules. Verify the new backend with `systemctl status proxmox-firewall` and `nft list ruleset`; `pve-firewall status` refers to the older backend.

The filesystem fixes are deliberate: the task pre-creates the file with `touch` guarded by `creates`, then templates it with `unsafe_writes: true`, omitting owner/group/mode. On first creation, Ansible wrote the intended content but failed during metadata handling on pmxcfs; pre-creation avoids that path, while unsafe writes permit fallback when atomic replacement fails. The template owns the complete host file, so later host options/rules must be included rather than maintained separately in that same file.

| Scope | Configuration ownership |
| --- | --- |
| Shared Proxmox policy | `/etc/pve/firewall/cluster.fw`: shared rules, IP sets, security groups, and the global enable flag. Once clustered, deploy once and let Proxmox replicate it. |
| Current host | `/etc/pve/local/host.fw`: backend choice and node-specific overrides; managed by the current setup. |
| Guest | `/etc/pve/firewall/<VMID>.fw` and relevant VM/NIC firewall flags: guest rules and group associations. |
| Custom nftables behavior | Host-loaded, separately owned tables for masquerading or bridge-level filtering not represented by the selected Proxmox configuration. `cluster.fw` is not raw nftables syntax. |

The chosen order is baseline host preparation first, with cluster creation and final shared firewall/NAT enforcement deferred to the final phase. No cluster or filtering activation should be inferred from the backend service running. When implementing the policy, retain administration/controller access, peer cluster/migration traffic, required DNS/time/update access, and future monitoring access.

For `vmbr2`, the selected design is host-provided NAT with **guest isolation by default and explicit peer-communication opt-in**. The inverse shared-NAT design was discussed as an alternative. Remaining host work is IPv4 forwarding, source masquerading through `vmbr0`, forwarding/return rules, guest-to-guest bridge filtering, host/lab access restrictions, and DHCP/DNS if automatic address configuration is desired. NAT alone supplies none of the isolation guarantees. Keep `vmbr1` and VLAN 110 private behavior separate.

Proxmox's nftables backend manages its own generated tables and permits separately managed custom tables. Prepare policy before enabling filtering; switching firewall backends also requires restarting existing guests. The referenced documentation currently marks this backend as tech preview. See [Proxmox firewall and nftables behavior](https://github.com/proxmox/pve-docs/blob/master/pve-firewall.adoc#nftables).

#### Planned host-access policy

The following is the full baseline policy specification for the final firewall phase, not an already deployed ruleset. Resolve administration sources, controller endpoints, node membership, and optional service endpoints from the same inventory/configuration model: environment variables now, NetBox and OpenBao later. Do not duplicate literal node addresses in task definitions. Never include API tokens, passwords, private SSH keys, or OpenBao credentials in these documents.

| Traffic to/from a Proxmox host | Intended policy and scope |
| --- | --- |
| Administration SSH, TCP 22 | Allow incoming connections from approved workstation/administration sources and the Ansible controller. Include the actual management/VPN paths in use rather than assuming the administrator is on VLAN 20. |
| API/UI, TCP 8006 | Allow approved administration sources and the controller/Terraform execution environment. The port remains relevant even when management normally uses CLI/IaC. |
| Peer SSH/API | Permit the node-to-node SSH/API operations required for cluster management and joining. Keep peer membership distinct from general VLAN 20 guest access. |
| Corosync, UDP 5405–5412 | Permit between inventory-defined Proxmox peers on the selected cluster addresses. Guest VLAN 110 is not the host cluster communication network. |
| Migration, TCP 60000–60050 | Permit between Proxmox peers when migration is enabled. Preserve associated SSH/API access. |
| ICMP | Permit intended troubleshooting and required network error/path-MTU messages; rate limiting may be applied without breaking essential error handling. |
| Established replies and loopback | Preserve legitimate return traffic and local service communication. Inspect Proxmox's generated baseline before adding redundant or conflicting state rules. |
| Monitoring | Permit only the future monitoring host to reach the collectors actually deployed. No exporter ports are selected yet. |
| Optional consoles | TCP 5900–5999 for VNC console and TCP 3128 for SPICE only when those access paths are used, restricted to the relevant management/proxy sources. |
| Shared storage/backups | Permit the chosen storage/backup protocols to the selected servers once NFS, SMB, or another backend is selected; account for any required callbacks. Do not open every possible storage service in advance. |
| Other host input | Drop unsolicited traffic not covered by required services or explicit exceptions. |
| Host output | Initially allow host-originated traffic, including DNS, chrony/NTP, updates, storage, backups, and notifications. This does not authorize guest forwarding through the host. |

Ports are based on the [Proxmox firewall service-port reference](https://github.com/proxmox/pve-docs/blob/master/pve-firewall.adoc#ports-used-by-pve). Exact permitted source sets, optional service ports, and the final rule syntax remain implementation inputs. This policy describes the effective result: account for Proxmox's generated management/local-network allowances so that a guest sharing VLAN 20 does not gain unintended host-management access.

#### Planned guest-network and NAT enforcement

Host input, direct Ethernet forwarding, routed forwarding, and source NAT are different packet paths. A host input allowlist does not preserve all guest bridge traffic, and source masquerading does not block peers.

| Network/path | Intended policy |
| --- | --- |
| `vmbr0`, native VLAN 20 guest attachment | Preserve the intended lab connectivity and upstream path, subject to guest/application policy. Apply the host-access allowlist separately to traffic addressed to Proxmox itself. |
| `vmbr0`, VLAN 110 guest attachment | Preserve same-VLAN private peer traffic across the physical switch and approved bastion SSH. VLAN allowance/tagging belongs to the bridge, guest NIC, and switch configuration, not to an invented IP gateway. |
| `vmbr1` local bridge | Preserve communication among attached same-node guests, including ARP and selected IP protocols. No host routing, NAT, or external default gateway is added to this profile. |
| `vmbr2` direct peer traffic | Deny guest-to-guest Ethernet traffic by default, including paths that bypass IP routing. Implement intentional peer exceptions without exposing guests that remain isolated. |
| `vmbr2` routed egress | Enable IPv4 forwarding for the intended NAT path, allow approved outbound destinations and their replies, and masquerade the NAT subnet through `vmbr0`. Deny unintended forwarding between other guest networks. |
| `vmbr2` host/lab destinations | Block host services and lab/private destinations unless explicitly required. Source NAT alone does not enforce an internet-only boundary. Any permitted DNS/DHCP destination must precede broader restrictions. |
| Required gateway services | Permit ARP to the gateway and replies. If DHCP is selected, permit its discovery/request/reply exchanges only on the relevant bridge and constrain server replies to the intended server. Permit the selected DNS resolver over UDP/TCP 53. |
| Bastion access | Permit TCP 22 from the approved bastion to selected private guests and its return traffic. A NAT guest requires an explicit SSH exception; attaching the bastion does not waive default isolation. No kernel forwarding or agent forwarding is needed merely for ProxyJump. |
| Peer-access opt-in | Require policy approval for both endpoints or an explicitly approved peer group; one guest opting in must not expose an isolated guest. The proposed boolean is illustrative, not an implemented rule generator. |
| Guest source identity | Bind guest MAC/IP allowances to the appropriate attachment or equivalent enforcement so impersonating an approved source does not bypass isolation. Initial DHCP exceptions and later address changes must be handled deliberately. |
| IPv6 | Decide whether each profile supports it. If supported, apply equivalent peer/host/private restrictions while preserving necessary ICMPv6/NDP. Otherwise explicitly prevent unintended IPv6 connectivity for that profile; IPv4-only filtering is not complete isolation. |
| Invalid traffic and logging | Handle invalid traffic and legitimate related/established replies in the appropriate hooks. Rate-limit diagnostic deny logs and retain them under the local journal policy; central collection follows the monitoring plan. |

Use Proxmox shared security groups/IP sets and per-guest associations where they express the required policy. Custom nftables tables may be needed for NAT and direct bridge filtering on the selected plain Linux bridges. Do not paste raw nftables chains into `cluster.fw`, overwrite Proxmox-generated tables, or flush unrelated tables. The exact split and rule ordering are still to be implemented and tested with the selected backend.

#### Addressing and DHCP scope

| Attachment | Initial address plan | DHCP growth option |
| --- | --- | --- |
| VLAN 20 on `vmbr0` | Existing netnode DHCP/reservations remain available; a guest can use cloud-init DHCP settings with its reserved MAC or a deliberately managed static address. | Reuse the existing VLAN 20 service rather than adding competing host DHCP servers. |
| VLAN 110 on `vmbr0` | Static guest addresses supplied through cloud-init, no default gateway on the private NIC. | One coordinated service reachable on VLAN 110 can serve all nodes. Per-host servers must not independently offer conflicting leases on the same VLAN. |
| `vmbr1` | Static addresses supplied through cloud-init in the experiment's selected subnet; no default gateway. | A DHCP service must be reachable within each node-local bridge, for example a local service or service VM. One central service requires a deliberately configured relay/path; cluster configuration replication does not carry DHCP broadcasts. |
| `vmbr2` | DHCP versus cloud-init/static assignment remains open. Either choice must provide the NAT gateway, unique local addresses, and a reachable DNS resolver. | With the same subnet reused on disconnected nodes, use a separate local service/scope per bridge if DHCP is selected. Do not bridge those networks together to share one broadcast domain. |

Starting DHCP is a separate service/configuration task, not an effect of NAT or firewall enablement. Private-profile DHCP must not advertise an external default gateway when the intended profile has no external route. The `vmbr1` host bridge can remain without an IP if the future service is supplied by a guest on that bridge; host-provided services may require additional local addressing.

#### Activation and validation plan

Keep the selected order: finish the host baseline, create/join the cluster in the final phase, then deploy and enable the shared firewall/NAT policy. Validate cluster membership before enabling rules that depend on it. Manage replicated shared files once, and apply node-local bridge/NAT configuration on each host.

1. Resolve and review permitted source sets, guest identities, DNS destinations, and optional services; verify that current SSH/controller access is included.
2. Deploy policy and the selected DHCP/DNS services without claiming filtering is active merely because the backend service runs.
3. Enable and verify one node first, preserving a console recovery path; then continue to the remaining nodes.
4. Test SSH/API administration, peer cluster traffic, migration when selected, DNS, chrony, updates, and configured storage/monitoring paths.
5. Test `vmbr1` peers on one node and VLAN 110 peers across nodes, confirming that neither private profile obtains unintended internet routing.
6. Test a NAT-only guest's gateway, DNS, and outbound connectivity; confirm unsolicited inbound access, host services, private destinations, and NAT peers are denied.
7. Test peer opt-in in both directions and confirm a third guest that remains isolated is still protected. Include broadcast/ARP behavior and IPv6, not just IPv4 ping tests.
8. Verify bastion SSH exceptions, persistence after service reload/reboot, and rule reconciliation after guest creation/removal or migration.

Rollback should restore the previous owned policy/configuration or disable the affected enforcement scope, without flushing unrelated firewall tables. No such rollout or firewall rules are implemented by this documentation update.

### Planned Proxmox platform work

The following items were discussed but are not implemented by the current production setup. Guest-facing usage and the general API/template plans are in [PE_CONFIGURATION.md](PE_CONFIGURATION.md).

| Area | Plan and remaining decision |
| --- | --- |
| Cluster membership | Plan a three-node Proxmox cluster, with possible HA later. Follow the [general cluster workflow](#general-cluster-workflow); joining nodes must not already hold guests. |
| Shared storage | Optional NFS or SMB/CIFS backend. The control node is the candidate server, but whether to add shared storage is still undecided. Protocol, export/share, capacity, and storage ID remain open; the existing control-node Samba service is not automatically Proxmox storage. |
| HA | Enable recovery for selected guests after disk access/replication, network compatibility, capacity, and fencing behavior are established. Ordinary clustering does not replicate guest disks. |
| API access | Plan dedicated automation credentials for Terraform guest provisioning through a Proxmox Terraform provider. API permissions: Still undecided. The specific provider package, module parameters, credentials, and dependency layout remain undecided. Ansible cluster API calls run from the controller as described in the [general cluster workflow](#general-cluster-workflow). |
| NAT addressing | The node-local subnet/gateway are selected: `192.168.130.0/24` and `192.168.130.1`. DHCP versus cloud-init/static guest addressing and DNS service remain undecided; see [addressing and DHCP scope](#addressing-and-dhcp-scope). |
| Templates | Establish one reproducible cloud-image template and validate cloning/cloud-init before adding more operating systems. OS/version, template identifiers, and build tooling are undecided. Record the exact image build, checksum, and preparation inputs; see [template reproducibility](PE_CONFIGURATION.md#vm-templates-and-initial-guest-configuration). |
| Backups and notifications | Backup destination: Still undecided. Later choose schedules, retention, restore validation, and notification delivery for backup, storage, and HA events. |
| Monitoring | Local disk-health service and diagnostic packages are configured. A future dedicated host on switch port 8 is planned for central monitoring. Stack, agents/exporters, log collection, dashboards, alert delivery, and central retention are undecided; no monitoring stack is selected by installing the current host tools. |
| Maintenance | Keep the working default chrony setup. Local journal-retention configuration is deployed; central logging and alerting remain separate work. Extend the shared update workflow with cluster/guest checks and controlled maintenance before HA use. |

A three-node Proxmox cluster has distributed management and replicated `/etc/pve` configuration. Creating it on prod01 does not make that node a permanent primary. With equal votes, two connected nodes provide quorum. DNS and time synchronization support cluster operation; Corosync needs a reliable, low-latency network. See [Cluster Manager](https://github.com/proxmox/pve-docs/blob/master/pvecm.adoc).

Shared storage can let another node restart a failed node's guest, but all required guest disks and network attachments must be available there. Proxmox mounts [NFS](https://github.com/proxmox/pve-docs/blob/master/pve-storage-nfs.adoc) and [SMB/CIFS](https://github.com/proxmox/pve-docs/blob/master/pve-storage-cifs.adoc) through their native backends; adding a share does not move existing guest disks. One share server remains a common failure point, and a live share is not a backup.

Local ext4 Directory storage has no built-in Proxmox guest-volume replication. ZFS with scheduled replication and Ceph were discussed as alternatives rather than selected replacements for the SATA setup. Scheduled replication can lose changes since the last successful sync. See [replication storage support](https://github.com/proxmox/pve-docs/blob/master/pvesr.adoc) and [HA recovery/fencing](https://github.com/proxmox/pve-docs/blob/master/ha-manager.adoc). Proxmox HA recovers guest VMs; Kubernetes HA operates separately inside the guest environment.

#### General cluster workflow

Cluster deployment remains in the final platform phase, after the per-node baseline is ready.

1. Finish and verify DNS, time synchronization, storage mounts, and networking on each node.
2. Select an initial node from configuration/inventory and create the cluster there. It does not become a permanent master.
3. Join the remaining inventory nodes sequentially, before creating guests on those joining nodes.
4. Verify cluster membership, quorum, and connectivity between nodes.
5. Reconcile shared configuration once per cluster, including storage definitions and the final firewall policy. Each node still needs its local mounts and node-specific settings.
6. Prepare templates and provision guests. Add HA later if selected, after its storage, networking, spare-capacity, and fencing requirements are satisfied.

The Ansible flow should check existing membership, preserve an existing cluster on reruns, and join only new nodes. An unexpected cluster membership should stop the workflow for review. Derive members from configuration/inventory rather than duplicating per-node tasks.

For Ansible tasks that call the Proxmox API, use `delegate_to: localhost` so the API request originates from the Ansible controller; Proxmox performs the requested operation on the nodes. In the GitOps setup, `localhost` is the runner's execution environment. Ordinary SSH-based host setup still targets the managed nodes. Delegation selects where a task executes; it does not itself make cluster creation run once or joins run sequentially, so the workflow must enforce that ordering.

Exact API module parameters, credentials, and controller/runner dependency layout remain deferred.

## Temporary workstation provisioning: boostrap

[boostrap/bootstrap_setup.yml](boostrap/bootstrap_setup.yml) turns the workstation into a temporary installer server. Its spelling is the actual directory name. This temporary DHCP service is separate from the router's ongoing VLAN leases and PXE boot instructions; it serves the directly connected target while the control node's permanent TFTP/HTTP service remains a separate deployment.

The host receives a temporary bootstrap address, enables IPv4 forwarding/NAT for the directly connected target, and opens provisioning ports. On Red Hat-family workstations, [host_setup_gen.yml](boostrap/tasks/host_setup_gen.yml) starts firewalld before applying those rules; this task does not change whether firewalld is enabled at boot. `net.ipv4.ip_unprivileged_port_start=0` removes the low-port restriction in that network namespace; it does not make processes root. The actual PXE containers are nevertheless launched with privilege escalation and `privileged: true`. See [kernel privileged-port threshold](https://docs.kernel.org/networking/ip-sysctl.html).

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

[update_system.yml](update_system.yml) upgrades inventory hosts in batches of 25% and reboots when the platform's reboot-needed check indicates it is required.
