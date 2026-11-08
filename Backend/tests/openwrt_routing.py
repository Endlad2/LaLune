#!/usr/bin/env python3
"""OpenWrt routing regressions in disposable network and mount namespaces."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile

from linux_tun import CORE, api, cmd, wait_for

CASES = ['clean', 'fw4', 'legacy', 'firewall_failure', 'dns_failure', 'core_exit']


def logs():
    return '\n'.join(api('/logs'))


def lan_packet():
    client = subprocess.Popen(['unshare', '--net', 'sleep', '30'])
    try:
        wait_for(lambda: os.readlink(f'/proc/{client.pid}/ns/net') != os.readlink('/proc/self/ns/net'))
        cmd('sysctl', '-q', '-w', 'net.ipv4.ip_forward=1')
        cmd('ip', 'link', 'add', 'lan0', 'type', 'veth', 'peer', 'name', 'client0')
        cmd('ip', 'addr', 'add', '10.30.0.1/24', 'dev', 'lan0')
        cmd('ip', 'link', 'set', 'lan0', 'up')
        cmd('ip', 'link', 'set', 'client0', 'netns', str(client.pid))
        enter = ['nsenter', '-t', str(client.pid), '-n']
        cmd(*enter, 'ip', 'link', 'set', 'lo', 'up')
        cmd(*enter, 'ip', 'addr', 'add', '10.30.0.2/24', 'dev', 'client0')
        cmd(*enter, 'ip', 'link', 'set', 'client0', 'up')
        cmd(*enter, 'ip', 'route', 'add', 'default', 'via', '10.30.0.1')
        packet = "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(2);s.sendto(b'LAN through TUN',('198.51.100.1',33445));assert s.recvfrom(2048)[0]==b'LAN through TUN'"
        cmd(*enter, 'python3', '-c', packet)
    finally:
        client.terminate()
        client.wait(timeout=3)


def inside(binary, case):
    assert os.geteuid() == 0
    assert os.readlink('/proc/self/ns/net') != os.readlink('/proc/1/ns/net')
    assert os.readlink('/proc/self/ns/mnt') != os.readlink('/proc/1/ns/mnt')
    cmd('mount', '--make-rprivate', '/')
    real_iptables = shutil.which('iptables-nft') or shutil.which('iptables')
    assert real_iptables, 'Install iptables-nft and nftables'
    with tempfile.TemporaryDirectory(prefix='lalune-openwrt-routing-') as temporary:
        root = Path(temporary)
        app = root / 'home/.la-lune'
        app.mkdir(parents=True)
        resolver = root / 'resolv.conf'
        original_dns = 'nameserver 192.0.2.53\n# fixture\n'
        resolver.write_text(original_dns)
        cmd('mount', '--bind', str(resolver), '/etc/resolv.conf')
        cmd('ip', 'link', 'set', 'lo', 'up')
        cmd('ip', 'link', 'add', 'wan0', 'type', 'dummy')
        cmd('ip', 'addr', 'add', '192.0.2.10/24', 'dev', 'wan0')
        cmd('ip', 'link', 'set', 'wan0', 'up')
        cmd('ip', 'route', 'add', 'default', 'via', '192.0.2.1', 'dev', 'wan0')
        routes = cmd('ip', '-N', '-4', 'route', 'show', 'table', 'all').stdout
        rules = cmd('ip', '-N', '-4', 'rule', 'show').stdout
        core = app / 'csqtt-client-aarch64'
        core.write_text(CORE)
        core.chmod(0o755)
        tools = root / 'bin'
        tools.mkdir()
        wrapper = tools / 'iptables'
        wrapper.write_text('#!/usr/bin/python3\nimport os,sys\n'
            + ("if sys.argv[1:]==['-t','filter','-I','FORWARD','1','-o','lalune0','-j','ACCEPT']:\n"
               " print('fixture firewall failure',file=sys.stderr);sys.exit(42)\n" if case == 'firewall_failure' else '')
            + 'os.execv(' + repr(real_iptables) + ',[' + repr(real_iptables) + ']+sys.argv[1:])\n')
        wrapper.chmod(0o755)
        if case == 'fw4':
            cmd('nft', 'add', 'table', 'inet', 'fw4')
            cmd('nft', 'add', 'chain', 'inet', 'fw4', 'forward', '{ type filter hook forward priority 0; policy drop; }')
        if case == 'legacy':
            cmd('ip', 'link', 'add', 'csqtt0', 'type', 'dummy')
            cmd('ip', 'link', 'set', 'csqtt0', 'up')
            cmd('ip', '-4', 'route', 'add', 'default', 'dev', 'csqtt0', 'table', '10620')
            cmd('ip', '-4', 'rule', 'add', 'priority', '10620', 'uidrange', '61062-61062', 'lookup', 'main')
            cmd('ip', '-4', 'rule', 'add', 'priority', '10621', 'lookup', 'main', 'suppress_prefixlength', '0')
            cmd('ip', '-4', 'rule', 'add', 'priority', '10622', 'lookup', '10620')
        if case == 'dns_failure':
            cmd('mount', '-o', 'remount,bind,ro', '/etc/resolv.conf')
        environment = {**os.environ, 'HOME': str(root / 'home'),
            'PATH': str(tools) + ':' + os.environ['PATH'], 'XTABLES_LOCKFILE': str(root / 'xtables.lock')}
        with (root / 'backend.log').open('w') as output:
            process = subprocess.Popen([binary], env=environment, stdout=output, stderr=output)
            try:
                wait_for(lambda: api('/ping'))
                config = api('/configs', {'name':'Routing fixture', 'protocol':'CSQTT',
                    'peer':'192.0.2.1:46000', 'password':'fixture', 'hashes':'fixture'})
                api('/vpn/connect', {'configId': config['id']})
                if case in ['firewall_failure', 'dns_failure']:
                    wait_for(lambda: 'tun start failed' in logs())
                    assert not api('/vpn/status')['connected']
                    expected = 'fixture firewall failure' if case == 'firewall_failure' else 'Read-only file system'
                    assert expected in logs(), 'Underlying error was hidden: ' + logs()
                else:
                    wait_for(lambda: api('/vpn/status')['connected'])
                    marked = cmd('ip', '-4', 'route', 'get', '198.51.100.1', 'mark', '0x1062').stdout
                    assert 'dev lalune0' in marked, marked
                    assert 'dev wan0' in cmd('ip', '-4', 'route', 'show', 'default').stdout
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as packet:
                        packet.settimeout(2)
                        packet.sendto(b'OpenWrt routing fixture', ('198.51.100.1', 33445))
                        assert packet.recvfrom(2048)[0] == b'OpenWrt routing fixture'
                    if case in ['clean', 'fw4']:
                        lan_packet()
                    children = {int(pid) for task in Path(f'/proc/{process.pid}/task').glob('*/children') for pid in task.read_text().split()}
                    if case == 'core_exit':
                        os.kill(next(iter(children)), signal.SIGKILL)
                        wait_for(lambda: not api('/vpn/status')['connected'])
                    else:
                        api('/vpn/disconnect', {})
                    if case == 'clean':
                        api('/vpn/connect', {'configId': config['id']})
                        wait_for(lambda: api('/vpn/status')['connected'])
                        api('/vpn/disconnect', {})
                wait_for(lambda: cmd('ip', 'link', 'show', 'lalune0', check=False).returncode != 0)
                if case == 'legacy':
                    cmd('ip', 'link', 'del', 'csqtt0')
                assert cmd('ip', '-N', '-4', 'route', 'show', 'table', 'all').stdout == routes, 'Routes were not restored'
                assert cmd('ip', '-N', '-4', 'rule', 'show').stdout == rules, 'Policy rules were not restored'
                assert Path('/etc/resolv.conf').read_text() == original_dns, 'DNS was not restored'
                assert 'LALUNE_' not in cmd(real_iptables, '-t', 'mangle', '-S').stdout
                assert 'LALUNE_' not in cmd(real_iptables, '-t', 'nat', '-S').stdout
                assert 'lalune-vpn-' not in cmd('nft', '-a', 'list', 'ruleset').stdout
                print(json.dumps({'case': case, 'passed': True}), flush=True)
            except BaseException:
                try: print(logs(), file=sys.stderr)
                except Exception: pass
                raise
            finally:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--case', choices=CASES)
    parser.add_argument('--inside', choices=CASES)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    if args.inside:
        return inside(binary, args.inside)
    failures = []
    for case in [args.case] if args.case else CASES:
        process = subprocess.Popen(['unshare', '--mount', '--net', '--fork', 'python3', str(Path(__file__).resolve()),
            binary, '--inside', case], start_new_session=True)
        try:
            code = process.wait(timeout=35)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            code = 124
        if code: failures.append(case)
    assert not failures, failures


if __name__ == '__main__':
    main()
