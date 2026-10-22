cd ~
set -e
setopt pipefail

P=~/machport-capstone
T=$P/terraform
A=$P/ansible

step() { print "\n==> $1" }

step "Writing Terraform files"

cat > $T/vpn.tf <<'EOF'
locals {
  wireguard_cidr = "10.30.0.0/24"

  corp_cidrs = [local.vpcs.hq.cidr, local.vpcs.branch.cidr, local.wireguard_cidr]

  vpn_peer = { hq = "branch", branch = "hq" }

  remote_cidrs = {
    hq     = [local.vpcs.branch.cidr, local.wireguard_cidr]
    branch = [local.vpcs.hq.cidr, local.wireguard_cidr]
  }

  ike_rules = merge([
    for site, router in local.active_routers : {
      for port in [500, 4500] : "${site}-${port}" => {
        site = site
        port = port
        peer = local.active_routers[local.vpn_peer[site]]
      }
    } if contains(keys(local.active_routers), local.vpn_peer[site])
  ]...)

  extra_security_groups = {
    for name, s in local.active_servers : name => concat(
      contains(values(local.active_routers), name) ? [aws_security_group.vpn[s.vpc].id] : [],
      s.access == "internal" && contains(keys(local.active_routers), s.vpc) ? [aws_security_group.corp[s.vpc].id] : [],
      name == "dc01" ? [aws_security_group.directory["hq"].id] : []
    )
  }
}

resource "aws_security_group" "vpn" {
  for_each    = local.active_routers
  name        = "${each.key}-vpn"
  description = "VPN traffic to the office router"
  vpc_id      = aws_vpc.vpc[each.key].id
  tags        = { Name = "${each.key}-vpn" }
}

resource "aws_vpc_security_group_ingress_rule" "ike" {
  for_each          = local.ike_rules
  security_group_id = aws_security_group.vpn[each.value.site].id
  description       = "IPsec from the other office router"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${aws_eip.public[each.value.peer].public_ip}/32"
}

resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  for_each          = { for site, router in local.active_routers : site => router if site == "hq" }
  security_group_id = aws_security_group.vpn[each.key].id
  description       = "WireGuard remote access"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "corp" {
  for_each    = local.active_routers
  name        = "${each.key}-corp"
  description = "Company traffic from the other office and WireGuard"
  vpc_id      = aws_vpc.vpc[each.key].id

  ingress {
    description = "Ping from company networks"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = local.corp_cidrs
  }

  ingress {
    description = "SSH from WireGuard users"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.wireguard_cidr]
  }

  ingress {
    description = "RDP from WireGuard users"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [local.wireguard_cidr]
  }

  tags = { Name = "${each.key}-corp" }
}
EOF

cat > $T/directory.tf <<'EOF'
resource "aws_security_group" "directory" {
  for_each    = { for site, vpc in local.active_vpcs : site => vpc if site == "hq" }
  name        = "hq-directory"
  description = "Active Directory services on dc01"
  vpc_id      = aws_vpc.vpc[each.key].id

  ingress {
    description = "DNS from company networks"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = local.corp_cidrs
  }

  ingress {
    description = "DNS over TCP from company networks"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = local.corp_cidrs
  }

  ingress {
    description = "LDAPS from pbx01 (provisioning) and WireGuard admins"
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = ["${local.servers.pbx01.ip}/32", local.wireguard_cidr]
  }

  tags = { Name = "hq-directory" }
}
EOF

step "Editing network.tf, servers.tf and ansible.cfg"

python3 - <<'PY'
import os, re, sys

root = os.path.expanduser("~/machport-capstone")

p = os.path.join(root, "terraform/network.tf")
s = open(p).read()
if "remote_cidrs" not in s:
    block = '''  dynamic "route" {
    for_each = contains(keys(local.active_routers), each.key) ? local.remote_cidrs[each.key] : []
    content {
      cidr_block           = route.value
      network_interface_id = aws_instance.server[local.active_routers[each.key]].primary_network_interface_id
    }
  }

'''
    i = s.find('resource "aws_route_table" "public"')
    if i < 0:
        sys.exit('network.tf: could not find resource "aws_route_table" "public"')
    m = re.compile(r'^[ \t]*tags[ \t]*=', re.M).search(s, i)
    nxt = s.find("\nresource ", i + 1)
    if not m or (nxt != -1 and m.start() > nxt):
        sys.exit('network.tf: no tags line inside aws_route_table "public"')
    s = s[:m.start()] + block + s[m.start():]
    open(p, "w").write(s)
    print("network.tf: route block added")
else:
    print("network.tf: already done")

p = os.path.join(root, "terraform/servers.tf")
s = open(p).read()
if "extra_security_groups" not in s:
    new = '  vpc_security_group_ids = concat([each.value.access == "public" ? aws_security_group.public[each.value.vpc].id : aws_security_group.internal[each.value.vpc].id], local.extra_security_groups[each.key])'
    s, n = re.subn(r'^[ \t]*vpc_security_group_ids[ \t]*=.*$', lambda m: new, s, count=1, flags=re.M)
    if n != 1:
        sys.exit("servers.tf: could not find the vpc_security_group_ids line")
    open(p, "w").write(s)
    print("servers.tf: security groups line updated")
else:
    print("servers.tf: already done")

p = os.path.join(root, "ansible/ansible.cfg")
s = open(p).read()
if "vault_password_file" not in s:
    line = "vault_password_file = ~/.machport-vault-pass\n"
    if re.search(r'^\[defaults\][ \t]*$', s, re.M):
        s = re.sub(r'^\[defaults\][ \t]*\n', lambda m: m.group(0) + line, s, count=1, flags=re.M)
    else:
        s = "[defaults]\n" + line + "\n" + s
    open(p, "w").write(s)
    print("ansible.cfg: vault line added")
else:
    print("ansible.cfg: already done")
PY

step "Writing Ansible files"

mkdir -p $A/group_vars/all $A/templates $A/files
touch $A/files/.gitkeep

cat > $A/requirements.yml <<'EOF'
collections:
  - name: ansible.posix
  - name: ansible.windows
  - name: microsoft.ad
EOF

cat > $A/group_vars/routers.yml <<'EOF'
vpn_if_id: 42

vpn_sites:
  hq:
    router: edge01
    asn: 65010
    tunnel_ip: 10.255.255.1
    networks: [10.10.0.0/16, 10.30.0.0/24]
    peer: branch
  branch:
    router: branchedge01
    asn: 65020
    tunnel_ip: 10.255.255.2
    networks: [10.20.0.0/16]
    peer: hq

wg_server_ip: 10.30.0.1
wg_host_machine_ip: 10.30.0.2
wg_extra_peers: []
EOF

cat > $A/group_vars/all/directory.yml <<'EOF'
ad_domain: corp.machport.test
ad_netbios: CORP
ad_base_dn: DC=corp,DC=machport,DC=test
dc_ip: 10.10.20.10
dc_fqdn: dc01.corp.machport.test
ad_ca_name: Machport Root CA

ad_groups:
  - { name: Voice-Users, description: Has a phone account on pbx01 }
  - { name: Voice-LongDistance, description: May dial long distance in Canada and the US }
  - { name: Voice-International, description: May dial international numbers }
  - { name: Executives, description: Impersonating these numbers raises a critical alert }
  - { name: Remote-Access, description: May connect with WireGuard }

ad_users:
  - sam: it.helpdesk
    first: IT
    last: Help Desk
    title: IT Help Desk (shared desk line)
    phone: "+15195550100"
    ext: "100"
    groups: [Voice-Users]
  - sam: achen
    first: Avery
    last: Chen
    title: Chief Executive Officer
    phone: "+15195550101"
    ext: "101"
    mobile: "+15195550181"
    groups: [Voice-Users, Voice-LongDistance, Voice-International, Executives, Remote-Access]
  - sam: jpatel
    first: Jordan
    last: Patel
    title: Chief Financial Officer
    phone: "+15195550102"
    ext: "102"
    mobile: "+15195550182"
    groups: [Voice-Users, Voice-LongDistance, Executives, Remote-Access]
  - sam: tbrooks
    first: Taylor
    last: Brooks
    title: Accounts Payable
    phone: "+15195550110"
    ext: "110"
    groups: [Voice-Users, Voice-LongDistance]
  - sam: rkim
    first: Riley
    last: Kim
    title: Dispatcher (works from home)
    phone: "+15195550120"
    ext: "120"
    mobile: "+15195550190"
    groups: [Voice-Users, Remote-Access]
  - sam: mlee
    first: Morgan
    last: Lee
    title: Branch Manager, Surrey
    phone: "+16045550201"
    ext: "201"
    mobile: "+16045550281"
    groups: [Voice-Users, Voice-LongDistance]
EOF

cat > $A/templates/swanctl.conf.j2 <<'EOF'
connections {
  {{ site }}-{{ me.peer }} {
    version = 2
    local_addrs = %any
    remote_addrs = {{ peer_public_ip }}
    encap = yes
    proposals = aes256gcm16-prfsha384-ecp384
    dpd_delay = 10s

    local {
      auth = psk
      id = {{ ansible_host }}
    }
    remote {
      auth = psk
      id = {{ peer_public_ip }}
    }

    children {
      site {
        local_ts = 0.0.0.0/0
        remote_ts = 0.0.0.0/0
        if_id_in = {{ vpn_if_id }}
        if_id_out = {{ vpn_if_id }}
        esp_proposals = aes256gcm16-ecp384
        dpd_action = trap
        start_action = trap
        close_action = trap
      }
    }
  }
}

secrets {
  ike-{{ me.peer }} {
    id-local = {{ ansible_host }}
    id-remote = {{ peer_public_ip }}
    secret = "{{ vault_ipsec_psk }}"
  }
}
EOF

cat > $A/templates/frr.conf.j2 <<'EOF'
frr defaults traditional
hostname {{ inventory_hostname }}
log syslog informational
service integrated-vtysh-config
ip route {{ vpc_cidr }} {{ ansible_facts['default_ipv4']['gateway'] }}
{% for net in peer.networks %}
ip prefix-list FROM-PEER seq {{ loop.index * 10 }} permit {{ net }}
{% endfor %}
{% for net in me.networks %}
ip prefix-list TO-PEER seq {{ loop.index * 10 }} permit {{ net }}
{% endfor %}
route-map FROM-PEER permit 10
 match ip address prefix-list FROM-PEER
exit
route-map TO-PEER permit 10
 match ip address prefix-list TO-PEER
exit
route-map SET-SRC permit 10
 set src {{ ansible_facts['default_ipv4']['address'] }}
exit
ip protocol bgp route-map SET-SRC
router bgp {{ me.asn }}
 bgp router-id {{ me.tunnel_ip }}
 neighbor {{ peer.tunnel_ip }} remote-as {{ peer.asn }}
 neighbor {{ peer.tunnel_ip }} description {{ peer.router }} over IPsec
 neighbor {{ peer.tunnel_ip }} timers 3 9
 neighbor {{ peer.tunnel_ip }} timers connect 5
 address-family ipv4 unicast
{% for net in me.networks %}
  network {{ net }}
{% endfor %}
  neighbor {{ peer.tunnel_ip }} route-map FROM-PEER in
  neighbor {{ peer.tunnel_ip }} route-map TO-PEER out
 exit-address-family
exit
EOF

cat > $A/templates/wg0.conf.j2 <<'EOF'
[Interface]
Address = {{ wg_server_ip }}/24
ListenPort = 51820
PrivateKey = {{ wg_server_private_key }}
{% for p in wg_peers %}

[Peer]
PublicKey = {{ p.public_key }}
AllowedIPs = {{ p.ip }}/32
{% endfor %}
EOF

cat > $A/templates/wg-client.conf.j2 <<'EOF'
[Interface]
PrivateKey = {{ lookup('ansible.builtin.file', wg_host_key_file) }}
Address = {{ wg_host_machine_ip }}/32

[Peer]
PublicKey = {{ wg_server_public_key }}
Endpoint = {{ ansible_host }}:51820
AllowedIPs = {{ vpn_sites | dict2items | map(attribute='value.networks') | flatten | join(', ') }}
PersistentKeepalive = 25
EOF

cat > $A/templates/ad-lookup.sh.j2 <<'EOF'
#!/bin/sh
BASE="OU=Staff,OU=Machport,{{ ad_base_dn }}"
exec ldapsearch -LLL -H ldaps://{{ dc_fqdn }} -D "svc-ldap@{{ ad_domain }}" -y /etc/machport/ldap.secret -b "$BASE" "(objectClass=user)" sAMAccountName displayName title telephoneNumber ipPhone mobile memberOf "$@"
EOF

cat > $A/vpn.yml <<'EOF'
---
- name: Site-to-site VPN between the office routers
  hosts: routers
  become: true
  vars:
    me: "{{ vpn_sites[site] }}"
    peer: "{{ vpn_sites[me.peer] }}"
    peer_built: "{{ peer.router in groups['routers'] }}"
    peer_public_ip: "{{ hostvars[peer.router].ansible_host if peer_built | bool else '' }}"
  tasks:
    - name: Install strongSwan (IPsec) and FRR (BGP)
      ansible.builtin.apt:
        name:
          - charon-systemd
          - strongswan-swanctl
          - frr
        state: present
        update_cache: true
        lock_timeout: 300

    - name: Define the ipsec0 tunnel interface
      ansible.builtin.copy:
        dest: /etc/systemd/network/40-ipsec0.netdev
        mode: "0644"
        content: |
          [NetDev]
          Name=ipsec0
          Kind=xfrm
          MTUBytes=1400

          [Xfrm]
          InterfaceId={{ vpn_if_id }}
          Independent=yes
      notify: Reload networkd

    - name: Give ipsec0 its tunnel address
      ansible.builtin.copy:
        dest: /etc/systemd/network/40-ipsec0.network
        mode: "0644"
        content: |
          [Match]
          Name=ipsec0

          [Network]
          Address={{ me.tunnel_ip }}/30

          [Link]
          RequiredForOnline=no
      notify: Reload networkd

    - name: Stop strongSwan adding its own routes
      ansible.builtin.copy:
        dest: /etc/strongswan.d/machport.conf
        mode: "0644"
        content: |
          charon {
            install_routes = no
          }
          charon-systemd {
            install_routes = no
          }
      notify: Restart IPsec

    - name: Write the IPsec tunnel settings
      ansible.builtin.template:
        src: templates/swanctl.conf.j2
        dest: /etc/swanctl/conf.d/machport.conf
        mode: "0600"
      when: peer_built | bool
      notify: Reload IPsec

    - name: Turn on FRR's BGP and static route daemons
      ansible.builtin.lineinfile:
        path: /etc/frr/daemons
        regexp: "^{{ item }}="
        line: "{{ item }}=yes"
      loop: [bgpd, staticd]
      notify: Restart FRR

    - name: Write the BGP settings
      ansible.builtin.template:
        src: templates/frr.conf.j2
        dest: /etc/frr/frr.conf
        owner: frr
        group: frr
        mode: "0640"
      when: peer_built | bool
      notify: Restart FRR

    - name: Make FRR wait for the tunnel interface before starting
      ansible.builtin.copy:
        dest: /etc/systemd/system/frr.service.d/machport.conf
        mode: "0644"
        content: |
          [Unit]
          After=systemd-networkd.service strongswan.service
          Wants=systemd-networkd.service

          [Service]
          ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do ip -4 addr show dev ipsec0 | grep -q "inet " && exit 0; sleep 1; done; exit 0'
      notify:
        - Reload systemd
        - Restart FRR

    - name: Start strongSwan and FRR now and at every boot
      ansible.builtin.service:
        name: "{{ item }}"
        state: started
        enabled: true
      loop: [strongswan, frr]

  handlers:
    - name: Reload systemd
      ansible.builtin.systemd:
        daemon_reload: true

    - name: Reload networkd
      ansible.builtin.command: networkctl reload
      changed_when: true

    - name: Restart IPsec
      ansible.builtin.service:
        name: strongswan
        state: restarted

    - name: Reload IPsec
      ansible.builtin.command: swanctl --load-all
      changed_when: true

    - name: Restart FRR
      ansible.builtin.service:
        name: frr
        state: restarted

- name: WireGuard server for remote staff
  hosts: edge01
  become: true
  vars:
    wg_host_key_file: "{{ lookup('ansible.builtin.env', 'HOME') }}/.wireguard/machport.key"
  tasks:
    - name: Install WireGuard
      ansible.builtin.apt:
        name: wireguard-tools
        state: present
        lock_timeout: 300

    - name: Create edge01's WireGuard private key
      ansible.builtin.shell: umask 077 && wg genkey > /etc/wireguard/server.key
      args:
        creates: /etc/wireguard/server.key

    - name: Read the private key for the config file
      ansible.builtin.slurp:
        src: /etc/wireguard/server.key
      register: wg_key
      no_log: true

    - name: Work out edge01's public key
      ansible.builtin.command: wg pubkey
      args:
        stdin: "{{ wg_key.content | b64decode | trim }}"
      register: wg_pub
      changed_when: false
      no_log: true

    - name: Build the list of WireGuard users
      ansible.builtin.set_fact:
        wg_server_private_key: "{{ wg_key.content | b64decode | trim }}"
        wg_server_public_key: "{{ wg_pub.stdout }}"
        wg_peers: >-
          {{ wg_extra_peers + ([{'name': 'host machine', 'ip': wg_host_machine_ip,
             'public_key': lookup('ansible.builtin.pipe', 'wg pubkey < ' ~ wg_host_key_file)}]
             if wg_host_key_file is file else []) }}
      no_log: true

    - name: Write the WireGuard server config
      ansible.builtin.template:
        src: templates/wg0.conf.j2
        dest: /etc/wireguard/wg0.conf
        mode: "0600"
      no_log: true
      notify: Reload WireGuard

    - name: Start WireGuard now and at every boot
      ansible.builtin.service:
        name: wg-quick@wg0
        state: started
        enabled: true

    - name: Write the host machine's WireGuard config
      ansible.builtin.template:
        src: templates/wg-client.conf.j2
        dest: "{{ lookup('ansible.builtin.env', 'HOME') }}/.wireguard/machport.conf"
        mode: "0600"
      delegate_to: localhost
      become: false
      when: wg_host_key_file is file
      no_log: true

  handlers:
    - name: Reload WireGuard
      ansible.builtin.service:
        name: wg-quick@wg0
        state: reloaded

- name: Network test tools
  hosts: linux
  become: true
  tasks:
    - name: Install the test tools
      ansible.builtin.apt:
        name: "{{ ['traceroute'] + (['nmap'] if inventory_hostname == 'world01' else []) }}"
        state: present
        lock_timeout: 300
EOF

cat > $A/directory.yml <<'EOF'
---
- name: Active Directory, DNS and certificate services on dc01
  hosts: windows
  gather_facts: false
  vars:
    ansible_become_method: runas
    ansible_become_user: Administrator
    ansible_become_password: "{{ vault_admin_password }}"
    staff_ou: "OU=Staff,OU=Machport,{{ ad_base_dn }}"
    groups_ou: "OU=Groups,OU=Machport,{{ ad_base_dn }}"
    service_ou: "OU=Service Accounts,OU=Machport,{{ ad_base_dn }}"
  tasks:
    - name: Check whether dc01 is already a domain controller
      ansible.windows.win_shell: (Get-CimInstance Win32_ComputerSystem).DomainRole
      register: domain_role
      changed_when: false

    - name: Set the Administrator password from Ansible Vault
      ansible.windows.win_user:
        name: Administrator
        password: "{{ vault_admin_password }}"
        update_password: always
      when: domain_role.stdout | trim | int < 4
      no_log: true

    - name: Remove AD CS until the domain exists
      ansible.windows.win_feature:
        name: ADCS-Cert-Authority
        state: absent
      register: adcs_removed
      when: domain_role.stdout | trim | int < 4

    - name: Install AD DS and DNS
      ansible.windows.win_feature:
        name:
          - AD-Domain-Services
          - DNS
        include_management_tools: true
      register: features

    - name: Reboot if a feature asked for it
      ansible.windows.win_reboot:
      when: features.reboot_required or (adcs_removed.reboot_required | default(false))

    - name: Create the forest {{ ad_domain }}
      microsoft.ad.domain:
        dns_domain_name: "{{ ad_domain }}"
        domain_netbios_name: "{{ ad_netbios }}"
        safe_mode_password: "{{ vault_dsrm_password }}"
        install_dns: true
        reboot: true
        reboot_timeout: 1800
      become: true

    - name: Wait until Active Directory answers
      ansible.windows.win_shell: (Get-ADDomain).DNSRoot
      become: true
      register: ad_ready
      until: ad_ready is succeeded
      retries: 30
      delay: 20
      changed_when: false

    - name: Install AD CS
      ansible.windows.win_feature:
        name: ADCS-Cert-Authority
        include_management_tools: true
      register: adcs_feature

    - name: Reboot if AD CS asked for it
      ansible.windows.win_reboot:
      when: adcs_feature.reboot_required

    - name: Point dc01's own DNS at itself
      ansible.windows.win_dns_client:
        adapter_names: "*"
        dns_servers: [127.0.0.1]

    - name: Send all other DNS lookups to the AWS resolver
      ansible.windows.win_shell: |
        $current = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { $_.IPAddressToString })
        if ($current -notcontains '169.254.169.253') {
          Set-DnsServerForwarder -IPAddress 169.254.169.253
          'changed'
        }
      become: true
      register: forwarder
      changed_when: "'changed' in forwarder.stdout"

    - name: Create the Machport OU
      microsoft.ad.ou:
        name: Machport
        path: "{{ ad_base_dn }}"
      become: true

    - name: Create the OUs inside it
      microsoft.ad.ou:
        name: "{{ item }}"
        path: "OU=Machport,{{ ad_base_dn }}"
      loop: [Staff, Groups, Service Accounts]
      become: true

    - name: Create the security groups
      microsoft.ad.group:
        name: "{{ item.name }}"
        description: "{{ item.description }}"
        scope: global
        category: security
        path: "{{ groups_ou }}"
      loop: "{{ ad_groups }}"
      loop_control:
        label: "{{ item.name }}"
      become: true

    - name: Create the staff accounts with their phone numbers
      microsoft.ad.user:
        name: "{{ item.first }} {{ item.last }}"
        sam_account_name: "{{ item.sam }}"
        upn: "{{ item.sam }}@{{ ad_domain }}"
        firstname: "{{ item.first }}"
        surname: "{{ item.last }}"
        display_name: "{{ item.first }} {{ item.last }}"
        description: "{{ item.title }}"
        path: "{{ staff_ou }}"
        password: "{{ vault_user_password }}"
        update_password: on_create
        password_never_expires: true
        enabled: true
        attributes:
          set: >-
            {{ {'title': item.title, 'telephoneNumber': item.phone, 'ipPhone': item.ext}
               | combine({'mobile': item.mobile} if item.mobile is defined else {}) }}
        groups:
          set: "{{ item.groups }}"
      loop: "{{ ad_users }}"
      loop_control:
        label: "{{ item.sam }}"
      become: true

    - name: Create the read-only LDAPS account pbx01 uses
      microsoft.ad.user:
        name: svc-ldap
        sam_account_name: svc-ldap
        upn: "svc-ldap@{{ ad_domain }}"
        description: Read-only LDAPS account for PBX provisioning (Goal 3)
        path: "{{ service_ou }}"
        password: "{{ vault_svc_ldap_password }}"
        update_password: when_changed
        password_never_expires: true
        user_cannot_change_password: true
        enabled: true
      become: true

    - name: Install the Machport Root CA
      ansible.windows.win_shell: |
        if (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -ErrorAction SilentlyContinue) { exit 0 }
        Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName '{{ ad_ca_name }}' -KeyLength 4096 -HashAlgorithmName SHA256 -ValidityPeriod Years -ValidityPeriodUnits 10 -Force | Out-Null
        'changed'
      become: true
      register: ca
      changed_when: "'changed' in ca.stdout"

    - name: Wait for dc01's own certificate from the CA
      ansible.windows.win_shell: |
        certutil -pulse | Out-Null
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
          $_.Issuer -like 'CN={{ ad_ca_name }}*' -and $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1'
        }
        if (-not $cert) { throw 'No server certificate yet' }
        $cert[0].Subject
      become: true
      register: dc_cert
      until: dc_cert is succeeded
      retries: 20
      delay: 15
      changed_when: false

    - name: Check LDAPS answers with that certificate
      ansible.windows.win_shell: |
        $rootDse = [ADSI]'LDAP://localhost/RootDSE'
        $rootDse.Put('renewServerCertificate', 1)
        $rootDse.SetInfo()
        $tcp = New-Object Net.Sockets.TcpClient('localhost', 636)
        $tls = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $tls.AuthenticateAsClient('{{ dc_fqdn }}')
        $tls.RemoteCertificate.Subject
        $tcp.Close()
      become: true
      register: ldaps
      until: ldaps is succeeded
      retries: 10
      delay: 15
      changed_when: false

    - name: Export the CA certificate for the Linux servers
      ansible.windows.win_shell: |
        $ca = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like 'CN={{ ad_ca_name }}*' } | Select-Object -First 1
        $pem = @('-----BEGIN CERTIFICATE-----', [Convert]::ToBase64String($ca.RawData, 'InsertLineBreaks'), '-----END CERTIFICATE-----')
        $pem | Set-Content -Path C:\Windows\Temp\machport-root-ca.crt -Encoding ascii
      changed_when: false

    - name: Copy the CA certificate to the host machine
      ansible.builtin.fetch:
        src: C:\Windows\Temp\machport-root-ca.crt
        dest: "{{ playbook_dir }}/files/machport-root-ca.crt"
        flat: true

- name: Linux servers trust the Machport CA and can find dc01
  hosts: linux
  become: true
  tasks:
    - name: Office servers only
      when: site in ['hq', 'branch']
      block:
        - name: Trust the Machport Root CA
          ansible.builtin.copy:
            src: files/machport-root-ca.crt
            dest: /usr/local/share/ca-certificates/machport-root-ca.crt
            mode: "0644"
          when: (playbook_dir ~ '/files/machport-root-ca.crt') is file
          notify: Update CA certificates

        - name: Resolve dc01's domain name
          ansible.builtin.lineinfile:
            path: /etc/hosts
            regexp: '\s{{ dc_fqdn | regex_escape }}(\s|$)'
            line: "{{ dc_ip }} {{ dc_fqdn }} dc01"

  handlers:
    - name: Update CA certificates
      ansible.builtin.command: update-ca-certificates
      changed_when: true

- name: pbx01 can read Active Directory over LDAPS
  hosts: pbx01
  become: true
  tasks:
    - name: Install the LDAP tools
      ansible.builtin.apt:
        name: ldap-utils
        state: present
        lock_timeout: 300

    - name: Create the folder for Machport secrets
      ansible.builtin.file:
        path: /etc/machport
        state: directory
        mode: "0700"

    - name: Store the svc-ldap password
      ansible.builtin.copy:
        dest: /etc/machport/ldap.secret
        content: "{{ vault_svc_ldap_password }}"
        mode: "0600"
      no_log: true

    - name: Install the ad-lookup test command
      ansible.builtin.template:
        src: templates/ad-lookup.sh.j2
        dest: /usr/local/bin/ad-lookup
        mode: "0755"
EOF

grep -q 'import_playbook: vpn.yml' $A/site.yml || printf '\n- import_playbook: vpn.yml\n- import_playbook: directory.yml\n' >> $A/site.yml

step "Updating mp commands"

cat > $P/scripts/mp_vpn.zsh <<'EOF'
conf=~/.wireguard/machport.conf
[ -f $conf ] || { echo "no vpn config yet, run: ansible-playbook vpn.yml"; exit 1; }
if [ "$1" = "--stop" ]; then
  sudo wg-quick down $conf 2> /dev/null && echo "vpn stopped" || echo "vpn not running"
  exit 0
fi
sudo wg-quick up $conf 2> /dev/null && echo "vpn started, company networks reachable directly" || echo "vpn already running, or failed. try: sudo wg-quick up $conf"
EOF

grep -q '^mp-vpn()' ~/.zshrc || print 'mp-vpn() { zsh ~/machport-capstone/scripts/mp_vpn.zsh "$@"; }' >> ~/.zshrc

cat > $P/scripts/mp_check.py <<'EOF'
import json
import os
import re
import socket
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TF_DIR = os.path.join(ROOT, "terraform")
ANSIBLE_DIR = os.path.join(ROOT, "ansible")
TFVARS = os.path.join(TF_DIR, "terraform.tfvars")
REGION = "us-east-2"
DIRECT = ["edge01", "branchedge01", "carrier01", "world01"]

SERVICES = {
    "linux": ["chrony"],
    "routers": ["nftables", "strongswan", "frr"],
    "edge01": ["wg-quick@wg0"],
    "windows": ["sshd", "NTDS", "DNS", "CertSvc"],
}

CROSS_SITE_TARGET = {"hq": "10.20.10.20", "branch": "10.10.20.20"}

ANSIBLE_ENV = dict(os.environ, ANSIBLE_NOCOLOR="1", ANSIBLE_FORCE_COLOR="0",
                   ANSIBLE_DEPRECATION_WARNINGS="False")

COLOR = sys.stdout.isatty()
LABELS = {"ok": "32", "fail": "31", "warn": "33", "skip": "36"}
counts = {k: 0 for k in LABELS}


def report(status, text):
    counts[status] += 1
    label = "{:<4}".format(status)
    if COLOR:
        label = "\033[{}m{}\033[0m".format(LABELS[status], label)
    print("  {}  {}".format(label, text))


def heading(text):
    print("\n" + ("\033[1m{}\033[0m".format(text) if COLOR else text))


def run(cmd, cwd=None, env=None, timeout=120):
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return 127, "", cmd[0] + " is not installed"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after {} seconds".format(timeout)


def last_line(text, default="no error text"):
    lines = [l for l in text.strip().splitlines() if l.strip()]
    return lines[-1] if lines else default


plan_result = {}


def terraform_plan():
    code, out, err = run(["terraform", "-chdir=" + TF_DIR, "plan", "-detailed-exitcode",
                          "-input=false", "-lock=false", "-no-color"], timeout=600)
    plan_result.update(code=code, out=out, err=err)


HEADER = re.compile(r"^(\S+) \| ([A-Z]+\S?)(?: \| rc=-?\d+)? (=>|>>)(.*)$")


def parse_ansible(text):
    blocks, current = [], None
    for line in text.splitlines():
        m = HEADER.match(line)
        if m:
            current = [m.group(1), m.group(2), m.group(3), [m.group(4)]]
            blocks.append(current)
        elif current:
            current[3].append(line)
    results = {}
    for host, status, kind, lines in blocks:
        body = "\n".join(lines).strip()
        stdout, message = body, ""
        if kind == "=>":
            try:
                data = json.loads(body)
                stdout = data.get("stdout", "")
                message = data.get("msg", "") or data.get("module_stderr", "")
            except ValueError:
                stdout, message = "", body
        results[host] = (status, stdout, message)
    return results


def probe_values(stdout, host):
    for line in stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0] == "MPCHECK" and parts[1] == host:
            return dict(p.split("=", 1) for p in parts[2:] if "=" in p)
    return None


def linux_probe(services):
    svc = ""
    if services:
        svc = (" svc=$(for s in " + " ".join(services) + "; do printf '%s:%s,' $s "
               "$(systemctl is-active $s 2>/dev/null || true); done)")
    return ('echo "MP""CHECK {{ inventory_hostname }}'
            ' host=$(hostname)'
            ' egress=$(curl -s --max-time 8 https://checkip.amazonaws.com | tr -dc 0-9.)'
            " sync=$(chronyc -n sources 2>/dev/null | grep -c '^\\^\\*')"
            ' fwd=$(sysctl -n net.ipv4.ip_forward)'
            ' nat=$(nft list ruleset 2>/dev/null | grep -c masquerade)'
            ' disk=$(df --output=pcent / | tail -n 1 | tr -dc 0-9)'
            ' reboot=$(test -f /var/run/reboot-required && echo yes || echo no)'
            " tun=$(swanctl --list-sas 2>/dev/null | grep -c ESTABLISHED)"
            " bgp=$(vtysh -c 'show ip route bgp' 2>/dev/null | grep -c '^B')"
            " xsite=$(ping -c 2 -W 2 {{ '" + CROSS_SITE_TARGET["hq"] + "' if site == 'hq' else '" + CROSS_SITE_TARGET["branch"] + "' }} >/dev/null 2>&1 && echo ok || echo fail)"
            + svc + '"')


def windows_probe(services):
    names = ",".join("'" + s + "'" for s in services) or "'sshd'"
    return ("$ip = try { (Invoke-RestMethod -Uri https://checkip.amazonaws.com -TimeoutSec 8).ToString().Trim() } catch { 'none' }; "
            "$svc = (Get-Service -Name " + names + " -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + ':' + $_.Status }) -join ','; "
            "$c = Get-PSDrive C; $disk = [math]::Round($c.Used * 100 / ($c.Used + $c.Free)); "
            "$role = (Get-CimInstance Win32_ComputerSystem).DomainRole; "
            "$ldaps = try { $t = New-Object Net.Sockets.TcpClient('localhost', 636); $s = New-Object Net.Security.SslStream($t.GetStream(), $false, { $true }); $s.AuthenticateAsClient('localhost'); $t.Close(); 'yes' } catch { 'no' }; "
            "$reboot = if (Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending') { 'yes' } else { 'no' }; "
            "Write-Output ('MP' + 'CHECK {{ inventory_hostname }} host=' + $env:COMPUTERNAME + ' egress=' + $ip + ' disk=' + $disk + ' reboot=' + $reboot + ' role=' + $role + ' ldaps=' + $ldaps + ' svc=' + $svc + ',')")


def services_for(host, groups):
    wanted = list(SERVICES.get(host, []))
    for group, members in groups.items():
        if host in members:
            wanted += [s for s in SERVICES.get(group, []) if s not in wanted]
    return wanted


def main():
    quick = "--quick" in sys.argv
    print("machport lab check" + (" (quick)" if quick else ""))

    if not quick:
        plan_thread = threading.Thread(target=terraform_plan, daemon=True)
        plan_thread.start()

    heading("aws")
    code, out, err = run(["aws", "sts", "get-caller-identity", "--output", "json"])
    if code != 0:
        report("fail", "aws cli not logged in: " + last_line(err))
        print("\nfix that first (aws configure), then run mp-check again")
        sys.exit(1)
    who = json.loads(out)
    report("ok", "logged in as {} (account {})".format(who["Arn"].split("/")[-1], who["Account"]))
    region = run(["aws", "configure", "get", "region"])[1].strip()
    if region == REGION:
        report("ok", "region is " + REGION)
    else:
        report("fail", "region is '{}', not {}. fix: aws configure set region {}".format(region, REGION, REGION))

    code, out, err = run(["terraform", "-chdir=" + TF_DIR, "output", "-json", "public_ips"])
    try:
        public_ips = json.loads(out) if code == 0 else {}
    except ValueError:
        public_ips = {}
    code, out, err = run(["ansible-inventory", "--list"], cwd=ANSIBLE_DIR, env=ANSIBLE_ENV)
    try:
        inventory = json.loads(out)
    except ValueError:
        inventory = {}
    hostvars = inventory.get("_meta", {}).get("hostvars", {})
    groups = {g: v.get("hosts", []) for g, v in inventory.items()
              if isinstance(v, dict) and "hosts" in v}
    expected = sorted(hostvars)

    heading("host machine")
    ip = run(["curl", "-s", "--max-time", "10", "https://checkip.amazonaws.com"])[1].strip()
    ip_ok = False
    tfvars = open(TFVARS).read() if os.path.exists(TFVARS) else ""
    m = re.search(r'^[ \t]*admin_cidr[ \t]*=[ \t]*"([^"]*)"', tfvars, re.M)
    allowed = m.group(1) if m else "not set"
    if not re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ip):
        report("fail", "couldn't get the host machine's public ip. check the internet connection")
    elif allowed == ip + "/32":
        ip_ok = True
        report("ok", "host ip {} is allowed in terraform.tfvars".format(ip))
    else:
        report("fail", "host ip is {} but terraform.tfvars allows {}. fix: mp-sync".format(ip, allowed))

    stale = []
    for name in DIRECT:
        if name in public_ips:
            cfg = run(["ssh", "-G", name])[1]
            hn = re.search(r"^hostname (\S+)", cfg, re.M)
            if not hn or hn.group(1) != public_ips[name]:
                stale.append(name)
    if not public_ips:
        report("fail", "terraform output has no public ips. has terraform apply run?")
    elif stale:
        report("fail", "~/.ssh/config has old ips for {}. fix: mp-sync".format(", ".join(stale)))
    else:
        report("ok", "~/.ssh/config has the current server ips")

    heading("servers")
    code, out, err = run(["aws", "ec2", "describe-instances", "--filters",
                          "Name=tag:Project,Values=machport-capstone",
                          "Name=instance-state-name,Values=pending,running,stopping,stopped",
                          "--query", "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,State.Name,InstanceId]",
                          "--output", "text"])
    instances = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            instances[parts[0]] = (parts[1], parts[2])
    code, out, err = run(["aws", "ec2", "describe-instance-status", "--query",
                          "InstanceStatuses[].[InstanceId,InstanceStatus.Status,SystemStatus.Status]",
                          "--output", "text"])
    status = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            status[parts[0]] = (parts[1], parts[2])

    if not expected:
        report("fail", "ansible/inventory.ini is missing or empty. fix: terraform apply")
    running = []
    for name in expected:
        state, iid = instances.get(name, ("missing", ""))
        label = "{:<15}".format(name)
        if state == "running":
            inst, system = status.get(iid, ("initializing", "initializing"))
            if inst == "ok" and system == "ok":
                report("ok", label + "running, aws status checks passed")
            elif "impaired" in (inst, system):
                report("fail", label + "running but aws status checks failed. fix: reboot it in the ec2 console")
            else:
                report("warn", label + "running, still starting up")
            running.append(name)
        elif state == "missing":
            report("fail", label + "not found in aws. fix: terraform apply")
        else:
            report("fail", label + state + ". fix: mp-start, wait 2-5 minutes")
    for name in sorted(set(instances) - set(expected)):
        report("warn", "{:<15}in aws ({}) but not in the ansible inventory".format(name, instances[name][0]))

    heading("inside each server")
    results = {}
    if not ip_ok:
        report("skip", "can't log in until the host ip is allowed. run mp-sync, then mp-check")
    elif not running:
        report("skip", "no servers running. run mp-start, wait 2-5 minutes, then mp-check")
    else:
        linux = [h for h in groups.get("linux", []) if h in running]
        windows = [h for h in groups.get("windows", []) if h in running]
        jobs = []
        if linux:
            svcs = sorted({s for h in linux for s in services_for(h, groups)})
            jobs.append(["ansible", "linux", "--limit", ",".join(linux), "-b",
                         "-m", "ansible.builtin.shell", "-a", linux_probe(svcs)])
        if windows:
            svcs = sorted({s for h in windows for s in services_for(h, groups)})
            jobs.append(["ansible", "windows", "--limit", ",".join(windows),
                         "-m", "ansible.windows.win_shell", "-a", windows_probe(svcs)])
        outputs = [("", "", "")] * len(jobs)

        def worker(i, cmd):
            outputs[i] = run(cmd, cwd=ANSIBLE_DIR, env=ANSIBLE_ENV, timeout=300)

        threads = [threading.Thread(target=worker, args=(i, c)) for i, c in enumerate(jobs)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        for code, out, err in outputs:
            results.update(parse_ansible(out))

        site_router = {hostvars[r].get("site"): r for r in groups.get("routers", [])}
        for host in linux + windows:
            check_host(host, results.get(host), hostvars.get(host, {}), groups,
                       public_ips, site_router)

    heading("security")
    sbc = public_ips.get("sbc01")
    if not sbc:
        report("skip", "sbc01 has no public ip right now")
    else:
        try:
            socket.create_connection((sbc, 22), timeout=5).close()
            report("fail", "sbc01 ({}) accepts ssh from the internet. check its security group".format(sbc))
        except OSError:
            report("ok", "sbc01 ({}) refuses ssh from the internet".format(sbc))

    heading("terraform")
    if quick:
        report("skip", "skipped (--quick)")
    else:
        if plan_thread.is_alive():
            print("  ...waiting for terraform plan")
        plan_thread.join()
        code = plan_result.get("code")
        if code == 0:
            report("ok", "aws matches the terraform code")
        elif code == 2:
            summary = re.search(r"^Plan: .*$", plan_result["out"], re.M)
            report("fail", "aws doesn't match the terraform code. {} see: terraform plan".format(
                summary.group(0).lower() if summary else ""))
        else:
            report("fail", "terraform plan failed: " + last_line(plan_result.get("err", ""), "unknown error"))

    print("\n{ok} ok, {fail} fail, {warn} warn, {skip} skip".format(**counts))
    sys.exit(1 if counts["fail"] else 0)


def check_host(host, result, hv, groups, public_ips, site_router):
    label = "{:<15}".format(host)
    if result is None:
        report("fail", label + "no answer from ansible")
        return
    state, stdout, message = result
    values = probe_values(stdout, host)
    if values is None:
        why = message.strip().splitlines()[0] if message.strip() else state.lower()
        if state.startswith("UNREACHABLE"):
            why = "can't log in: " + why
        report("fail", label + why[:150])
        return

    problems, warnings, good = [], [], ["logged in"]
    is_windows = host in groups.get("windows", [])

    if values.get("host", "").lower() == host.lower():
        good.append("hostname")
    else:
        problems.append("hostname is '{}'. fix: ansible-playbook site.yml".format(values.get("host")))

    if host in public_ips:
        want, via = public_ips[host], "own ip"
    else:
        router = site_router.get(hv.get("site"))
        want, via = public_ips.get(router), "{} nat".format(router)
    got = values.get("egress", "")
    if not got or got == "none":
        problems.append("no internet access")
    elif got == want:
        good.append("internet via " + via)
    else:
        problems.append("internet goes out as {}, expected {} ({})".format(got, want, via))

    if not is_windows:
        if values.get("sync", "0") not in ("", "0"):
            good.append("clock synced")
        else:
            problems.append("clock not synced (if it just started, wait a minute)")

    if host in groups.get("routers", []):
        if values.get("fwd") == "1" and values.get("nat", "0") not in ("", "0"):
            good.append("forwarding + nat")
        else:
            problems.append("forwarding={} nat rules={}. fix: ansible-playbook site.yml".format(
                values.get("fwd"), values.get("nat")))

    both_offices = len(groups.get("routers", [])) >= 2
    if both_offices and host in groups.get("routers", []):
        if values.get("tun", "0") in ("", "0"):
            problems.append("ipsec tunnel down. fix: ansible-playbook vpn.yml")
        elif values.get("bgp", "0") in ("", "0"):
            problems.append("tunnel up but no bgp routes from the other office")
        else:
            good.append("tunnel up, {} bgp routes".format(values.get("bgp")))
    if both_offices and not is_windows and hv.get("site") in CROSS_SITE_TARGET:
        if values.get("xsite") == "ok":
            good.append("reaches the other office")
        else:
            problems.append("can't ping {} in the other office".format(CROSS_SITE_TARGET[hv.get("site")]))

    if is_windows:
        if values.get("role") != "5":
            problems.append("not a domain controller yet. fix: ansible-playbook directory.yml")
        elif values.get("ldaps") != "yes":
            problems.append("ldaps not answering. fix: ansible-playbook directory.yml")
        else:
            good.append("domain controller, ldaps")

    states = dict(s.split(":", 1) for s in values.get("svc", "").split(",") if ":" in s)
    down = [s for s in services_for(host, groups)
            if states.get(s, "").lower() not in ("active", "running")]
    if down:
        problems.append("not running: " + ", ".join(down))
    else:
        good.append("services")

    disk = int(values.get("disk") or 0)
    if disk >= 95:
        problems.append("disk {}% full".format(disk))
    elif disk >= 85:
        warnings.append("disk {}% full".format(disk))
    if values.get("reboot") == "yes":
        warnings.append("needs a reboot for updates (ansible {} -b -m reboot)".format(host))

    if problems:
        report("fail", label + "; ".join(problems + warnings))
    elif warnings:
        report("warn", label + "; ".join(warnings))
    else:
        report("ok", label + ", ".join(good))


if __name__ == "__main__":
    main()
EOF

step "Creating secrets"

if [ ! -f ~/.machport-vault-pass ]; then
  openssl rand -base64 32 > ~/.machport-vault-pass
  chmod 600 ~/.machport-vault-pass
fi

if [ ! -f $A/group_vars/all/vault.yml ]; then
  printf 'vault_ipsec_psk: "%s"\nvault_admin_password: "Mp-%s-Q7"\nvault_dsrm_password: "Mp-%s-R8"\nvault_user_password: "Mp-%s-S9"\nvault_svc_ldap_password: "Mp-%s-T6"\n' "$(openssl rand -base64 32)" "$(openssl rand -hex 10)" "$(openssl rand -hex 10)" "$(openssl rand -hex 10)" "$(openssl rand -hex 10)" > $A/group_vars/all/vault.yml
  (cd $A && ansible-vault encrypt group_vars/all/vault.yml)
fi

step "Creating the WireGuard key for this Mac"

command -v wg >/dev/null || brew install wireguard-tools
mkdir -p ~/.wireguard && chmod 700 ~/.wireguard
if [ ! -f ~/.wireguard/machport.key ]; then
  wg genkey > ~/.wireguard/machport.key
  chmod 600 ~/.wireguard/machport.key
fi

step "Checking Terraform"

cd $T
terraform fmt >/dev/null
terraform validate

step "Planning AWS changes"

terraform plan -input=false -no-color -out=checkpoint1.tfplan | tee /tmp/checkpoint1-plan.txt
if grep -qE ' [1-9][0-9]* to destroy' /tmp/checkpoint1-plan.txt; then
  rm -f checkpoint1.tfplan
  print "\nSTOPPED: the plan wants to destroy something. Send Joshua the output above."
  exit 1
fi

step "Applying AWS changes"

terraform apply -input=false checkpoint1.tfplan
rm -f checkpoint1.tfplan

step "Starting the servers"

zsh $P/scripts/mp_start.zsh
ids=($(aws ec2 describe-instances --filters Name=tag:Project,Values=machport-capstone Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId' --output text))
print "Waiting for AWS status checks on ${#ids} servers..."
aws ec2 wait instance-status-ok --instance-ids $ids
sleep 30

step "Configuring the VPN and Active Directory"

cd $A
ansible-galaxy collection install -r requirements.yml
ansible-playbook vpn.yml
ansible-playbook directory.yml
ansible-playbook site.yml

step "Running mp-check"

if python3 $P/scripts/mp_check.py; then
  step "Committing to Git"
  cd $P
  git add .
  git diff --cached --quiet || git commit -m "Checkpoint 1: VPN and Active Directory"
  git push
  print "\nCheckpoint 1 is built. Take the evidence screenshots next."
else
  print "\nmp-check found problems. Fix them, then run this script again."
  exit 1
fi
