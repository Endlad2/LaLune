#!/usr/bin/env python3
"""Kernel/API regression checks. Each case runs in disposable net+mount namespaces.

Run as root: python3 Backend/tests/linux_tun.py /absolute/path/to/backend
No VK credentials, external network, packages or host route/DNS changes required.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import shutil
import urllib.error
import urllib.request

CORE = r'''#!/usr/bin/python3
import os,socket,struct,sys,time
args=sys.argv[1:]
listen=args[args.index('--listen' if '--listen' in args else '--socks5')+1].rsplit(':',1)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((listen[0],int(listen[1])))
print('TEST_CORE_UID='+str(os.getuid()),flush=True)
print('TEST_CORE_CWD='+os.getcwd(),flush=True)
print('TEST_CORE_HOME='+os.environ['HOME'],flush=True)
time.sleep(float(os.environ.get('TEST_CORE_DELAY','0')))
print('[КЛИЕНТ] Tunnel IP: 10.66.67.2/32 | DNS: 1.1.1.1',flush=True)
for _ in range(3):print('[СТАТИСТИКА] Активных: 1 | Трафик: 0.00 МБ',flush=True);time.sleep(.1)
while True:
 b,a=s.recvfrom(65535)
 if len(b)<28 or b[0]>>4!=4 or b[9]!=17:continue
 ihl=(b[0]&15)*4
 sport,dport,length,_=struct.unpack('!HHHH',b[ihl:ihl+8])
 udp=struct.pack('!HHHH',dport,sport,length,0)+b[ihl+8:]
 h=struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(udp),1,0,64,17,0,b[16:20],b[12:16])
 n=sum(struct.unpack('!10H',h))
 while n>>16:n=(n&65535)+(n>>16)
 h=h[:10]+struct.pack('!H',(~n)&65535)+h[12:]
 s.sendto(h+udp,a)
'''

CASES=['routes','packet','disconnect','cancel','setup_failure','dns_failure','dns_changed','core_exit','reconnect','group_conflict','table_alias','missing_kill','invalid_connect']
DESKTOP_CASES=['paperflux_compat','csqttr_compat']


def cmd(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=5)


def api(path, body=None, method=None, timeout=2):
    request=urllib.request.Request('http://127.0.0.1:1062'+path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type':'application/json'},method=method)
    with urllib.request.urlopen(request,timeout=timeout) as response:
        return json.load(response)


def wait_for(predicate, timeout=6):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        try:
            value=predicate()
            if value:return value
        except (OSError,urllib.error.URLError):pass
        time.sleep(.05)
    raise AssertionError('Condition timed out')


def inside(binary, case):
    assert os.geteuid()==0
    assert os.readlink('/proc/self/ns/net')!=os.readlink('/proc/1/ns/net')
    cmd('mount','--make-rprivate','/')
    with tempfile.TemporaryDirectory(prefix='lalune-test-') as temporary:
        root=Path(temporary);home=root/'home';app=home/'.la-lune';app.mkdir(parents=True)
        resolver=root/'resolv.conf';resolver.write_text('nameserver 192.0.2.53\n# original\n')
        cmd('mount','--bind',str(resolver),'/etc/resolv.conf')
        if case=='group_conflict':
            groups=root/'group';groups.write_text(Path('/etc/group').read_text()+'\nlalune-test-existing:x:61062:\n')
            cmd('mount','--bind',str(groups),'/etc/group')
        cmd('ip','link','set','lo','up')
        cmd('ip','link','add','wan0','type','dummy')
        cmd('ip','addr','add','192.0.2.10/24','dev','wan0')
        cmd('ip','link','set','wan0','up')
        cmd('ip','route','add','default','via','192.0.2.1','dev','wan0')
        if case=='table_alias' or case in DESKTOP_CASES:
            alias_file=Path('/usr/share/iproute2/rt_tables')
            aliases=root/'rt_tables';aliases.write_text(alias_file.read_text()+'\n10620 preexisting\n')
            cmd('mount','--bind',str(aliases),str(alias_file))
            cmd('ip','route','add','198.51.100.0/24','via','192.0.2.1','dev','wan0','table','10620')
        routes=cmd('ip','-4','route','show','table','all').stdout
        rules=cmd('ip','-4','rule','show').stdout
        symlink=Path('/etc/resolv.conf').is_symlink()
        for name in ['csqtt-client-aarch64','csqtt-core','paperflux-core','csqttr-core']:
            f=app/name;f.write_text(CORE);f.chmod(0o755)
        delay='0'
        environment={**os.environ,'HOME':str(home),'TEST_CORE_DELAY':delay,'RUST_LOG':'info'}
        if case=='setup_failure':
            tools=root/'bin';tools.mkdir()
            wrapper=tools/'ip'
            wrapper.write_text('#!/bin/sh\ncase "$*" in "-4 rule add priority 10621 "*) echo "injected rule failure" >&2; exit 1;; esac\nexec '+shutil.which('ip')+' "$@"\n')
            wrapper.chmod(0o755)
            environment['PATH']=str(tools)+':'+os.environ['PATH']
        if case=='dns_failure':
            cmd('mount','-o','remount,bind,ro','/etc/resolv.conf')
        log=(root/'backend.log').open('w')
        command=['setpriv','--bounding-set=-kill',binary] if case=='missing_kill' else [binary]
        process=subprocess.Popen(command,env=environment,stdout=log,stderr=log)
        try:
            wait_for(lambda:api('/ping'))
            protocol={'paperflux_compat':'PaperFlux','csqttr_compat':'CSQTTR'}.get(case,'CSQTT')
            conf=api('/configs',{'name':'Kernel regression','protocol':protocol,
                 'peer':'192.0.2.1:46000','password':'local-test','hashes':'local-test'})
            if case=='missing_kill':
                try:api('/vpn/connect',{'configId':conf['id']})
                except urllib.error.HTTPError as error:
                    assert error.code==500 and 'CAP_KILL' in error.read().decode()
                else:raise AssertionError('CSQTT started without permission to stop its core')
            else:api('/vpn/connect',{'configId':conf['id']})
            if case=='missing_kill':
                assert not api('/vpn/status')['connected']
                children={p for f in Path(f'/proc/{process.pid}/task').glob('*/children') for p in f.read_text().split()}
                assert not children,'Permission failure left a core process'
            elif case=='cancel':
                wait_for(lambda:(app/'logs.log').read_text().count('Активных:')>=3)
                api('/vpn/disconnect',{})
                time.sleep(2.5)
                assert not api('/vpn/status')['connected'],'Cancelled watcher restarted TUN'
                assert cmd('ip','link','show','csqtt0',check=False).returncode!=0
            elif case in ['setup_failure','dns_failure','table_alias']:
                wait_for(lambda:'tun start failed' in (root/'backend.log').read_text())
                assert not api('/vpn/status')['connected'],'Setup failure reported connected'
            else:
                wait_for(lambda:api('/vpn/status')['connected'])
                children={int(pid) for f in Path(f'/proc/{process.pid}/task').glob('*/children')
                          for pid in f.read_text().split()}
                child=next(iter(children))
                if case=='invalid_connect':
                    try:api('/vpn/connect',{'configId':999999})
                    except urllib.error.HTTPError as error:assert error.code==400
                    else:raise AssertionError('Invalid config was accepted')
                    assert api('/vpn/status')['connected'],'Invalid connect stopped the active VPN'
                    assert Path(f'/proc/{child}').exists(),'Invalid connect killed the active core'
                identity=Path(f'/proc/{child}/status').read_text()
                if case in DESKTOP_CASES:
                    assert '\nUid:\t0\t' in identity,'Legacy core identity changed'
                    logs=(app/'logs.log').read_text()
                    assert 'TEST_CORE_CWD='+os.getcwd()+'\n' in logs,'Legacy core cwd changed'
                    assert 'TEST_CORE_HOME='+str(home)+'\n' in logs,'Legacy core HOME changed'
                else:
                    assert '\nUid:\t0\t' not in identity,'Core must not run as root'
                    assert next(l for l in identity.splitlines() if l.startswith('Groups:')).strip()=='Groups:'
                if case=='group_conflict':
                    assert next(l for l in identity.splitlines() if l.startswith('Gid:')).split()[1]!='61062','Core inherited an existing dormant group'
                if case=='routes':
                    normal=cmd('ip','route','get','198.51.100.1','uid','0').stdout
                    assert 'dev csqtt0' in normal,normal
                    logs=app/'logs.log'
                    uid=int(next(l.split('=',1)[1] for l in logs.read_text().splitlines() if l.startswith('TEST_CORE_UID=')))
                    assert uid not in [0,65534],uid
                    core=cmd('ip','route','get','203.0.113.9','uid',str(uid)).stdout
                    assert 'dev wan0' in core,core
                    lan=cmd('ip','route','get','192.0.2.1','uid','0').stdout
                    assert 'dev wan0' in lan,lan
                    assert Path('/etc/resolv.conf').read_text()=='nameserver 1.1.1.1\n'
                elif case=='packet':
                    # Isolate the bridge failure even on the original broken routing code.
                    cmd('ip','route','replace','198.51.100.1/32','dev','csqtt0')
                    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
                        s.settimeout(1)
                        s.sendto(b'LaLune TUN regression',('198.51.100.1',33445))
                        answer,peer=s.recvfrom(2048)
                        assert answer==b'LaLune TUN regression' and peer==('198.51.100.1',33445)
                    cmd('ip','route','del','198.51.100.1/32','dev','csqtt0')
                if case=='dns_changed':
                    Path('/etc/resolv.conf').write_text('nameserver 9.9.9.9\n# DHCP update\n')
                if case=='core_exit':
                    os.kill(child,signal.SIGKILL)
                    wait_for(lambda:not api('/vpn/status')['connected'])
                else:
                    started=time.monotonic()
                    api('/vpn/disconnect',{},timeout=1)
                    assert time.monotonic()-started<1,'Idle disconnect must finish promptly'
                assert not api('/vpn/status')['connected']
                assert not Path(f'/proc/{child}').exists(),'Disconnected core is still alive'
                if case=='reconnect':
                    for _ in range(2):
                        api('/vpn/connect',{'configId':conf['id']})
                        wait_for(lambda:api('/vpn/status')['connected'])
                        assert 'dev csqtt0' in cmd('ip','route','get','198.51.100.1','uid','0').stdout
                        api('/vpn/disconnect',{},timeout=1)
            wait_for(lambda:cmd('ip','link','show','csqtt0',check=False).returncode!=0)
            assert cmd('ip','-4','route','show','table','all').stdout==routes,'Routes not restored'
            assert cmd('ip','-4','rule','show').stdout==rules,'Policy rules not restored'
            expected='nameserver 9.9.9.9\n# DHCP update\n' if case=='dns_changed' else 'nameserver 192.0.2.53\n# original\n'
            assert Path('/etc/resolv.conf').read_text()==expected,'DNS not restored or external change overwritten'
            assert Path('/etc/resolv.conf').is_symlink()==symlink,'Resolver symlink replaced'
            print(json.dumps({'case':case,'passed':True}),flush=True)
        finally:
            if case=='missing_kill':
                for f in Path(f'/proc/{process.pid}/task').glob('*/children'):
                    for pid in f.read_text().split():
                        try:os.kill(int(pid),signal.SIGKILL)
                        except ProcessLookupError:pass
            process.terminate()
            try:process.wait(timeout=2)
            except subprocess.TimeoutExpired:process.kill();process.wait()
            log.close()
            if sys.exc_info()[0]:print((root/'backend.log').read_text(),file=sys.stderr)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary');parser.add_argument('--inside',choices=CASES+DESKTOP_CASES)
    parser.add_argument('--case',choices=CASES+DESKTOP_CASES)
    args=parser.parse_args();binary=str(Path(args.binary).resolve())
    if args.inside:return inside(binary,args.inside)
    assert os.geteuid()==0,'Run as root inside disposable namespaces'
    failures=[]
    for case in ([args.case] if args.case else CASES):
        p=subprocess.Popen(['unshare','--mount','--net','--fork','python3',str(Path(__file__).resolve()),
                            binary,'--inside',case],start_new_session=True)
        try:code=p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL);p.wait();code=124
        if code:failures.append(case)
    assert not failures,'Failed cases: '+', '.join(failures)


if __name__=='__main__':main()
