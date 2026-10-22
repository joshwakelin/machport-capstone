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
