#!/usr/bin/env python3
"""Exercise the real service and framed native host with isolated data, no browser UI."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='jarvis-bridge-') as directory:
    base = Path(directory)
    (base/'support').mkdir()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, AGENT_DECK_SUPPORT=str(base/'support'),
               AGENT_DECK_RUNTIME=directory, AGENT_DECK_PORT=str(port),
               AGENT_DECK_DISABLE_SCAN='1', AGENT_DECK_BROWSER_RUNTIME=directory)
    service = subprocess.Popen([str(root/'native/.build/debug/deck-service')], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if (base/'connection.json').exists():
                break
            if service.poll() is not None:
                raise RuntimeError(service.stderr.read().decode())
            time.sleep(.05)
        endpoint = json.loads((base/'connection.json').read_text())

        def request(path, body=None, token=endpoint['token']):
            req = urllib.request.Request(f'http://127.0.0.1:{port}'+path,
                data=None if body is None else json.dumps(body).encode(),
                headers={'Authorization':'Bearer '+token, 'Content-Type':'application/json'})
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.load(response)

        def native(body):
            payload=json.dumps(body).encode()
            output=subprocess.check_output(['/usr/bin/python3',str(root/'browser-extension/host.py')],
                input=struct.pack('<I',len(payload))+payload,env=env,timeout=10)
            size=struct.unpack('<I',output[:4])[0]
            assert len(output)==size+4
            return json.loads(output[4:])

        try:
            request('/supervisor/browser',token='wrong')
            raise AssertionError('Unauthorized request accepted')
        except urllib.error.HTTPError as error:
            assert error.code==401
        state={'origins':['http://localhost:3000'],'origin':'http://localhost:3000','tabId':7}
        native({'state':state})
        assert request('/supervisor/browser')['connected']
        denied=request('/supervisor/browser-command',{'kind':'observe','origin':'https://unapproved.example'})
        assert denied['ok'] is False
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future=pool.submit(request,'/supervisor/browser-command',{'kind':'observe','origin':state['origin']})
            command=None
            for _ in range(40):
                command=native({'state':state}).get('command')
                if command: break
                time.sleep(.025)
            assert command and command['tabId']==7
            busy=request('/supervisor/browser-command',{'kind':'observe','origin':state['origin']})
            assert busy['ok'] is False
            native({'state':state,'result':{'id':'wrong','ok':True}})
            assert not future.done()
            native({'state':state,'result':{'id':command['id'],'ok':True,'text':'fixture page'}})
            result=future.result(timeout=5)
            assert result['id']==command['id'] and result['text']=='fixture page'
        print('PASS: real native framing, authenticated service, origin denial, busy rejection, exact receipt identity.')
    finally:
        service.terminate()
        service.wait(timeout=5)
