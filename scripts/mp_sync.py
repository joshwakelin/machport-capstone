"""mp-sync: updates admin_cidr in terraform.tfvars and the server ips in
~/.ssh/config. other entries in ~/.ssh/config are kept; the old copy is
saved as ~/.ssh/config.bak. safe to run any time."""
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TF_DIR = os.path.join(ROOT, "terraform")
TFVARS = os.path.join(TF_DIR, "terraform.tfvars")
SSH_CONFIG = os.path.expanduser("~/.ssh/config")

# Servers reached by SSH directly from the host machine
DIRECT = ["edge01", "branchedge01", "carrier01", "world01"]
# Host patterns this script owns in ~/.ssh/config
OURS = set(DIRECT) | {"10.10.*", "10.20.*"}
START = "# >>> machport (managed by mp-sync) >>>"
END = "# <<< machport <<<"


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def my_public_ip():
    result = subprocess.run(
        ["curl", "-s", "--max-time", "10", "https://checkip.amazonaws.com"],
        capture_output=True, text=True)
    ip = result.stdout.strip()
    if not re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ip):
        fail("couldn't get the host machine's public ip. check the internet connection.")
    return ip


def sync_admin_cidr(ip):
    if not os.path.exists(TFVARS):
        fail("can't find " + TFVARS)
    with open(TFVARS) as f:
        text = f.read()
    pattern = r'^[ \t]*admin_cidr[ \t]*=.*$'
    match = re.search(r'^[ \t]*admin_cidr[ \t]*=[ \t]*"([^"]*)"', text, re.M)
    current = match.group(1) if match else "not set"
    wanted = ip + "/32"

    if current == wanted:
        print("ip: " + ip + " (unchanged)")
        return

    print("ip: " + ip + " (was " + current + "), updating security groups. type yes when asked.\n")
    applied = subprocess.run(
        ["terraform", "-chdir=" + TF_DIR, "apply", "-var=admin_cidr=" + wanted])
    if applied.returncode != 0:
        fail("\napply cancelled, terraform.tfvars not changed")

    line = 'admin_cidr = "' + wanted + '"'
    if re.search(pattern, text, re.M):
        text = re.sub(pattern, line, text, count=1, flags=re.M)
    else:
        text = line + "\n" + text
    with open(TFVARS, "w") as f:
        f.write(text)
    print("\nsaved " + wanted + " to terraform.tfvars")


def server_ips():
    result = subprocess.run(
        ["terraform", "-chdir=" + TF_DIR, "output", "-json", "public_ips"],
        capture_output=True, text=True)
    if result.returncode != 0:
        fail("terraform output failed:\n" + result.stderr.strip())
    return json.loads(result.stdout or "{}")


def machport_block(ips):
    lines = [START]
    for name in DIRECT:
        if name in ips:
            lines += ["Host " + name, "  HostName " + ips[name]]
    lines += [
        "Host 10.10.*", "  ProxyJump edge01",
        "Host 10.20.*", "  ProxyJump branchedge01",
        "Host edge01 branchedge01 carrier01 world01 10.10.* 10.20.*",
        "  User ubuntu",
        "  IdentityFile ~/.ssh/machport",
        "  StrictHostKeyChecking no",
        "  UserKnownHostsFile /dev/null",
        "  LogLevel ERROR",
        END,
    ]
    return lines


def merge(old_lines, block):
    """Put the Machport block into the SSH config, keeping everything else."""
    if START in old_lines and END in old_lines:
        i, j = old_lines.index(START), old_lines.index(END)
        return old_lines[:i] + block + old_lines[j + 1:]

    # First run: remove the hand-typed Machport entries and put the
    # managed block where the first one was.
    kept, insert_at, skipping = [], None, False
    for line in old_lines:
        m = re.match(r"\s*(host|match)\s+(.*?)\s*$", line, re.I)
        if m:
            patterns = set(m.group(2).split())
            skipping = m.group(1).lower() == "host" and patterns <= OURS
            if skipping and insert_at is None:
                insert_at = len(kept)
        if not skipping:
            kept.append(line)
    if insert_at is None:
        # No old entries: go above the first Host/Match line so these take priority
        insert_at = next((n for n, l in enumerate(kept)
                          if re.match(r"\s*(host|match)\s", l, re.I)), len(kept))
    while insert_at > 0 and kept[insert_at - 1].strip() == "" and insert_at == len(kept):
        insert_at -= 1
    after = kept[insert_at:]
    if after and after[0].strip() != "":
        after = [""] + after
    before = kept[:insert_at]
    if before and before[-1].strip() != "":
        before = before + [""]
    return before + block + after


def sync_ssh_config(ips):
    os.makedirs(os.path.dirname(SSH_CONFIG), mode=0o700, exist_ok=True)
    old_text = ""
    if os.path.exists(SSH_CONFIG):
        with open(SSH_CONFIG) as f:
            old_text = f.read()
    new_lines = merge(old_text.splitlines(), machport_block(ips))
    new_text = "\n".join(new_lines).rstrip("\n") + "\n"

    if new_text == old_text:
        print("ssh config: up to date")
    else:
        if old_text:
            shutil.copy2(SSH_CONFIG, SSH_CONFIG + ".bak")
        mode = os.stat(SSH_CONFIG).st_mode & 0o777 if old_text else 0o600
        with open(SSH_CONFIG, "w") as f:
            f.write(new_text)
        os.chmod(SSH_CONFIG, mode)
        print("ssh config: updated" + (" (backup at ~/.ssh/config.bak)" if old_text else ""))

    for name in sorted(ips):
        note = "" if name in DIRECT else "  (no direct ssh)"
        print("  {:<14}{}{}".format(name, ips[name], note))
    missing = [n for n in DIRECT if n not in ips]
    if missing:
        print("  not built: " + ", ".join(missing))


def main():
    sync_admin_cidr(my_public_ip())
    ips = server_ips()
    if not ips:
        fail("no servers built. run terraform apply first.")
    sync_ssh_config(ips)
    print("done")


if __name__ == "__main__":
    main()
