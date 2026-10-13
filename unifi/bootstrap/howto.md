# Runbook: Adopt a UniFi switch and move management to VLAN 10

## Purpose

Adopt the switch on an untagged bootstrap network, test VLAN 10, then move the switch's management interface to VLAN 10.

**Done when:** the switch is online in UniFi and stays online after Bootstrap DHCP and the temporary host connections are removed.

This guide assumes the controller is installed and both DHCP services are prepared. The final step tests additional VLANs on a temporary access port; permanent workload port assignments are configured later.

## Example deployment

Replace these example addresses and port numbers for your environment. VLAN 10 is the management VLAN; the same network host and port 1 uplink can also serve VLANs 20, 30 and others.

| Item | Bootstrap network | Management network |
| --- | --- | --- |
| VLAN | Default VLAN 1, untagged | VLAN 10 |
| Subnet | `192.168.100.0/24` | `10.10.10.0/24` |
| Controller address | `192.168.100.10` | `10.10.10.10` |
| Workstation address | Bootstrap DHCP lease, or `192.168.100.20` when serving DHCP | VLAN DHCP lease |
| Gateway | Existing bootstrap router, if needed | `10.10.10.1` |

The controller hostname is **`unifi.example.com`**. Use direct IP addresses during the transition. Reserve the controller addresses or configure them statically outside the DHCP pools.

### Host roles

Use a **separate network host for VLAN DHCP and routing** in this runbook. These services can share the controller host, but a separate host keeps their operation independent of controller maintenance.

| Host | Role | Switch connections |
| --- | --- | --- |
| Controller host | Runs UniFi Network | Port 2 for bootstrap; port 7 for management |
| Workstation / laptop | Browser, temporary VLAN testing; optional Bootstrap DHCP | Port 4 for bootstrap; port 3 to test management; port 5 for other VLAN tests |
| Separate network host | Runs DHCP scopes and gateways for VLAN 10 and other VLANs, such as 20 and 30 | **Port 1**, connected to its VLAN-capable LAN interface |
| Optional Bootstrap DHCP host/router | Provides untagged VLAN 1 leases when the workstation does not run Bootstrap DHCP | **Port 8**; disconnect after management cutover |

**Port 1 is the physical connection to the separate network host.** The same cable carries tagged VLAN 10 traffic for DHCP and gateway access, plus any other VLANs allowed on that uplink. There is no additional DHCP-only cable. The network host can provide a separate VLAN interface, DHCP scope and gateway for each VLAN. All of them use this same port 1 uplink when their tags are allowed.

### The two DHCP services

| Name used in this guide | Provides addresses for | Runs on | Switch connection |
| --- | --- | --- | --- |
| **Bootstrap DHCP** | Untagged bootstrap network, VLAN 1 | Existing DHCP router/server **or** temporary workstation service | Port 8 for a separate device **or** port 4 for the workstation |
| **VLAN DHCP** | Management VLAN 10; other VLAN scopes as required | Separate network host providing VLAN DHCP and routing | Port 1, with VLAN 10 and other configured VLANs tagged |

**Both services remain available during migration.** Use only one Bootstrap DHCP provider: the separate device or the workstation.

VLAN DHCP serves VLAN 10 and any additional configured VLANs through their respective VLAN interfaces and DHCP scopes. It must not also offer bootstrap leases on the untagged port 1 connection. Creating a VLAN object in UniFi does not configure DHCP on an external network host.

### Two interfaces on each host

Keep **both networks connected at the same time** on the controller and workstation. The bootstrap interface preserves adoption access while the second interface tests the management network before cutover.

Use two motherboard Ethernet ports, or one motherboard port plus a USB Ethernet adapter. The adapter type does not determine the VLAN; the switch port configuration does.

| Host | Interface example | Switch port | Network and address |
| --- | --- | --- | --- |
| Controller | Motherboard Ethernet | 7 | Management VLAN 10: `10.10.10.10/24` |
| Controller | USB Ethernet adapter | 2 | Bootstrap VLAN 1: `192.168.100.10/24` |
| Workstation / laptop | Motherboard Ethernet | 4 | Bootstrap VLAN 1: DHCP lease, or `192.168.100.20/24` when serving Bootstrap DHCP |
| Workstation / laptop | USB Ethernet adapter | 3 | Management VLAN 10: lease from **VLAN DHCP** |

The management connections join the network served by **VLAN DHCP**, but frames on ports 3 and 7 are **untagged**. The switch carries VLAN 10 tagged over port 1 to the permanent network host; that same uplink carries other configured VLANs with their own tags. Configure ordinary Ethernet on both hosts, without VLAN subinterfaces.

**Port 1 connects the permanent network host, not the controller.** The controller's management connection uses port 7 in this example.

### Port allocation

| Port | Connection | Initial state | State before switch management cutover |
| --- | --- | --- | --- |
| 1 | Permanent network host: **VLAN DHCP and gateways** | Default/native VLAN 1 | Native VLAN 1; VLAN 10 and other required VLANs tagged |
| 2 | Controller bootstrap interface | Native VLAN 1 | Keep native VLAN 1 |
| 3 | Temporary workstation management test | Leave disconnected until configured | Native VLAN 10; tagged VLANs blocked |
| 4 | Workstation bootstrap interface; **Bootstrap DHCP** if hosted here | Native VLAN 1 | Keep native VLAN 1 |
| 5 | Temporary workstation test for VLAN 20, 30, etc. | Leave disconnected | Configure in the final test step |
| 6 | Unused / reserved | Leave disconnected | Configure later |
| 7 | Controller management interface | Leave disconnected until configured | Native VLAN 10; tagged VLANs blocked |
| 8 | Separate **Bootstrap DHCP** device, if used | Native VLAN 1 | Keep native VLAN 1 |
| Other ports | Unused | Disconnected | Configure later |

**Port 3 is temporary:** use it to verify the switch is accessible and managed on VLAN 10. Keep it for administrator access during the final VLAN tests, then disconnect the workstation when testing is complete.

Do not bridge bootstrap and management interfaces. Keep each interface's address on its own subnet and check which interface carries each test. If the workstation runs Bootstrap DHCP, bind it only to the port 4 interface; port 8 stays disconnected.

## Prerequisites

- Switch available for adoption; controller administrator login available.
- Two Ethernet interfaces available on **each** host, with bootstrap and management connections assigned as above.
- **Bootstrap DHCP** ready on VLAN 1.
- A **separate network host** with **VLAN interfaces, DHCP scopes, gateways, and DNS** configured for VLAN 10 and any additional VLANs in use. The example management gateway is `10.10.10.1/24`. Its VLAN-capable LAN interface connects to port 1, carrying those VLANs tagged.
- Controller reachable on TCP **8443** for the browser and TCP **8080** for device communication.
- Discovery UDP **10001** and STUN UDP **3478** permitted as required by the deployment.
- Access to both DHCP lease lists, a controller backup, and device SSH credentials for recovery.

Menu names vary by UniFi release. The steps below use **Port Manager**, **Native VLAN / Network**, **Tagged VLAN Management**, and **Network Override**.

## Procedure

### 1. Connect the bootstrap network

1. Connect the controller bootstrap interface to **port 2**.
2. Connect the workstation bootstrap interface to **port 4**.
3. Choose the **Bootstrap DHCP** provider:

   | Option | Action |
   | --- | --- |
   | Separate DHCP device | Connect it to **port 8**. Workstation receives a bootstrap lease. |
   | Workstation DHCP service | Set its port 4 interface to `192.168.100.20/24`, outside its lease pool. Start Bootstrap DHCP bound only to that interface. |

4. Keep ports 2, 4, and 8 (if used) on their default untagged VLAN 1 settings.
5. Power on the switch and inspect the **Bootstrap DHCP** leases.

**Check:** the switch has a `192.168.100.x` lease, and the workstation reaches the controller at `192.168.100.10`.

### 2. Adopt in the controller web UI

1. Open:

   ```text
   https://192.168.100.10:8443/manage/account/login?redirect=%2Fmanage
   ```

2. Sign in and select the intended site.
3. Open **UniFi Devices**.
4. Select the switch showing **Pending Adoption / Ready to Adopt**.
5. Click **Adopt** and wait for provisioning to finish.
6. Save a controller backup and record the adopted device's SSH credentials privately.

**Check:** the switch is **Online/Connected** with its bootstrap IP. Leave Network Override unchanged.

### 3. Create the management network object

On the **separate network host which will be connected to port 1 later on**, configure VLAN 10 and any additional VLANs in use, each with its gateway and **VLAN DHCP** scope. The controller host creates the matching UniFi network objects.

1. Open **Settings → Networks → Create New Network**.
2. Set:

   | Setting | Value |
   | --- | --- |
   | Name | Management |
   | Router | Third-party Gateway (VLAN Only in older releases) |
   | VLAN ID | 10 |

3. Save. Repeat for additional VLANs already configured on the network host, using their names and VLAN IDs.

**Check:** **Management (10)** is available in the switch's network selection menus.

### 4. Configure the VLAN DHCP uplink and host ports

1. Connect the **separate network host's VLAN-capable LAN interface directly to port 1**. This same uplink carries DHCP and gateway traffic for VLAN 10 and all other configured VLANs allowed on the link; keep it connected after bootstrap.
2. Open **UniFi Devices → [switch] → Port Manager**.
3. Apply these settings:

   | Port | Native VLAN / Network | Tagged VLAN Management |
   | --- | --- | --- |
   | 1: VLAN DHCP uplink | Default (1) | Allow All |
   | 3: workstation management | Management (10) | Block All |
   | 7: controller management | Management (10) | Block All |

4. Connect the workstation management interface to **port 3**.
5. Connect the controller management interface to **port 7**.
6. Keep the bootstrap connections on ports **2**, **4**, and **8** (if used). Both host interfaces now remain connected: controller on ports **2 + 7**, workstation on ports **4 + 3**.

Port 1 carries VLAN 10 **and any other configured VLANs** (such as 20 and 30) **tagged** to the network host. Ports 3 and 7 deliver only management VLAN 10 **untagged** to the hosts; those host interfaces do not need VLAN subinterfaces. Other access ports deliver their selected VLAN untagged.

**Check:** port 1 and every intermediate uplink allow tagged VLAN 10 and all additional VLANs in use. With a Custom tagged VLAN list, include each required VLAN explicitly. Keep port 1's native network as Default (1).

### 5. Test management before moving the switch

1. Obtain a **VLAN DHCP** lease on the workstation's port 3 interface.
2. Confirm its address is `10.10.10.x/24`.
3. Confirm the controller's port 7 interface uses `10.10.10.10/24`.
4. Test through the management interface. The routes below must use the workstation interface connected to **port 3**, even while its bootstrap interface on port 4 remains active:

   ```sh
   ip route get 10.10.10.1
   ip route get 10.10.10.10
   nc -vz 10.10.10.10 8080
   ```

5. Open the controller over management:

   ```text
   https://10.10.10.10:8443/manage/account/login?redirect=%2Fmanage
   ```

6. Check the switch's **inform destination**: the controller address it uses on TCP 8080. That address must work from VLAN 10. A retained bootstrap controller interface does not automatically provide routing to its old address.

If the inform destination is bootstrap-only, provide a working routed path or prepare to correct it over SSH after cutover using the recovery step below. Check any controller **Inform Host / Override Inform Host** setting too.

**Check:** VLAN DHCP works, the management UI opens, and the switch is still online on Bootstrap DHCP. Proceed with a working inform path or device SSH access ready.

### 6. Move switch management to VLAN 10

1. Open **UniFi Devices → [switch] → Settings → IP Settings**.
2. Enable **Network Override**.
3. Confirm the warning only after checking tagged VLAN 10 on the uplink.
4. Set:

   | Setting | Value |
   | --- | --- |
   | Virtual Network | Management (10) |
   | IP Configuration | DHCP |

5. Click **Apply Changes**.
6. Allow several minutes for provisioning and reconnection.

The switch now requests its address from the **VLAN 10 scope of VLAN DHCP**, instead of **Bootstrap DHCP**. Other VLAN DHCP scopes remain available to clients on their respective VLANs.

**Check:** VLAN DHCP shows a switch lease on `10.10.10.0/24`, and UniFi shows the switch online with that address. Keep both DHCP services connected until this check passes.

### 7. Remove bootstrap connections

1. Confirm the switch's inform destination works without the bootstrap network.
2. Disconnect the controller bootstrap interface from **port 2**.
3. Remove **Bootstrap DHCP**:

   | Provider | Action |
   | --- | --- |
   | Separate device | Disconnect it from **port 8**. |
   | Workstation service | Stop Bootstrap DHCP on the workstation. |

4. Disconnect the workstation bootstrap interface from **port 4**.
5. Keep the **separate VLAN DHCP/network host connected to port 1**, workstation management on **port 3**, and controller management on **port 7**.
6. Confirm the switch remains online; save a new controller backup.

**Check:** management works with all temporary bootstrap connections removed.

The DHCP services coexist because bootstrap VLAN 1, management VLAN 10 and each additional VLAN are separate broadcast domains. Each VLAN DHCP scope serves its own VLAN. Keep the bootstrap ports on native VLAN 1; optionally set their Tagged VLAN Management to **Block All** after adoption to exclude tagged traffic.

### 8. Test other VLANs through port 5

Use the same **network host and port 1 uplink** to test VLAN 20, VLAN 30, or any other configured VLAN. Keep switch management on VLAN 10.

1. On the network host, prepare each test VLAN's interface, gateway and DHCP scope. Example addressing:

   | VLAN | Example subnet | Example gateway |
   | --- | --- | --- |
   | 20 | `10.10.20.0/24` | `10.10.20.1` |
   | 30 | `10.10.30.0/24` | `10.10.30.1` |

2. In **Settings → Networks**, create the matching VLAN objects using **Third-party Gateway**.
3. Confirm **port 1** allows these VLANs tagged. **Allow All** covers the created VLANs; a **Custom** list must explicitly include 10, 20, 30 and any other VLAN being tested.
4. Keep the workstation's management interface on **port 3** for controller access. Move its now-free bootstrap interface's cable from **port 4 to port 5**. Bootstrap DHCP must already be stopped if the workstation supplied it.
5. In **Port Manager**, configure port 5:

   | Setting | First test | Next test |
   | --- | --- | --- |
   | Native VLAN / Network | VLAN 20 network | VLAN 30 network |
   | Tagged VLAN Management | Block All | Block All |

6. Apply the first test settings. Set the workstation's port 5 interface to DHCP, removing any static bootstrap address. Renew its lease.
7. Check that the test interface receives an address from the selected VLAN's scope and reaches that VLAN's gateway or an intended service. Check the route uses the **port 5 interface**, rather than the management interface.
8. Change port 5 to the next test VLAN, apply, and renew the lease. Repeat for each VLAN.
9. Through the management interface on port 3, confirm the switch remains online on VLAN 10 throughout the tests.
10. Disconnect the temporary workstation connections from **ports 3 and 5**. Assign those ports to their planned roles later; keep the network host on **port 1** and controller on **port 7**.

**Check:** each test VLAN provides the expected DHCP lease and gateway/service access while switch management stays on VLAN 10.

Access from VLAN 20 or 30 to the controller on VLAN 10 depends on routing and firewall policy. It is not required for these DHCP and access-port tests; use the retained port 3 connection to manage UniFi.

## Troubleshooting and recovery

| Symptom | Check |
| --- | --- |
| Switch missing during adoption | **Bootstrap DHCP** lease, bootstrap cabling, discovery and controller firewall |
| Workstation gets no management address | **VLAN DHCP**, port 1 tagged VLAN 10, port 3 native VLAN 10 |
| Switch gets management IP but stays offline | Inform destination, DNS, TCP 8080, controller firewall |
| Switch gets no management IP | **VLAN DHCP** lease list, VLAN interface and tagged uplink path |
| Failure after bootstrap removal | Inform address, DNS or route still depends on the bootstrap network |

For a stale inform address, SSH to the switch's new management IP using its adopted credentials and run **on the switch**:

```text
set-inform http://10.10.10.10:8080/inform
```

Repeat if needed after the device appears in UniFi. Correct any controller inform override that would restore the old address.

Do not continue cleanup if the switch is offline. Repair its management path first. If it is still controllable, revert Network Override to Default while Bootstrap DHCP is available. Retaining Bootstrap DHCP does **not** guarantee automatic fallback; a factory reset is the last resort and requires re-adoption.

## Operational handoff

Record the management address, controller endpoint, VLAN and port roles privately. Configure unused ports for their intended workloads later.

Use UniFi Network and controller backups for persistent configuration. Do not publish raw device configuration exports or private credentials with this guide.

## References

- [UniFi Device Adoption](https://help.ui.com/hc/en-us/articles/360012622613-UniFi-Device-Adoption)
- [Creating Virtual Networks with Third-Party Gateways](https://help.ui.com/hc/en-us/articles/9761080275607-Creating-Virtual-Networks-VLANs)
- [Switch Port VLAN Assignment](https://help.ui.com/hc/en-us/articles/26136855808919-Switch-Port-VLAN-Assignment-Trunk-Access-Ports)
- [Required Ports](https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference)
- [Layer 3 Adoption / Inform Configuration](https://help.ui.com/hc/en-us/articles/204909754-Remote-Adoption-Layer-3)
- [VLAN Troubleshooting](https://help.ui.com/hc/en-us/articles/9592924981911-Virtual-Network-VLAN-Troubleshooting)
