#!/usr/bin/env python3
"""Offline PKCE/CSRF/redirect boundary tests; no account sign-in."""
import base64,hashlib,importlib.util,io,json,pathlib,unittest,urllib.parse
from unittest.mock import patch
p=pathlib.Path(__file__).resolve().parents[1]/'native/Resources/Jarvis/personal-oauth.py'
spec=importlib.util.spec_from_file_location('personal_oauth',p);oauth=importlib.util.module_from_spec(spec);spec.loader.exec_module(oauth)
class OAuthTests(unittest.TestCase):
 def flow(self,provider):
  seen={};token={'access_token':'synthetic','refresh_token':'synthetic-refresh','scope':'scope'}
  class Server:
   def __init__(self,address,handler):self.server_port=16687;self.handler=handler;self.calls=0
   def server_close(self):pass
   def handle_request(self):
    self.calls+=1;q=urllib.parse.parse_qs(urllib.parse.urlsplit(seen['url']).query)
    handler=self.handler.__new__(self.handler);handler.path='/robin/oauth?'+urllib.parse.urlencode({'state':'wrong' if self.calls==1 else q['state'][0],'code':'synthetic-code'})
    handler.send_error=lambda code:seen.setdefault('rejected',code)
    handler.send_response=lambda code:None;handler.send_header=lambda *args:None;handler.end_headers=lambda:None;handler.wfile=io.BytesIO();handler.do_GET()
  class Response:
   def __enter__(self):return io.StringIO(json.dumps({'ok':True,'authed_user':token} if provider=='slack' else token))
   def __exit__(self,*args):pass
  class Opener:
   def open(self,request,timeout):seen['request']=request;return Response()
  stdin=type('Input',(),{'buffer':io.BytesIO(json.dumps({'provider':provider,'clientID':'synthetic-client','scopes':['scope']}).encode())})()
  with patch.object(oauth.http.server,'HTTPServer',Server),patch.object(oauth.webbrowser,'open',lambda url:seen.update(url=url)),patch.object(oauth.urllib.request,'build_opener',return_value=Opener()),patch.object(oauth.sys,'stdin',stdin),patch.object(oauth.sys,'stdout',io.StringIO()) as output:oauth.main();seen['output']=json.loads(output.getvalue())
  return seen
 def test_pkce_state_and_no_client_secret_for_public_clients(self):
  for provider in ('google','slack'):
   with self.subTest(provider=provider):
    seen=self.flow(provider);params=urllib.parse.parse_qs(urllib.parse.urlsplit(seen['url']).query);body=urllib.parse.parse_qs(seen['request'].data.decode())
    verifier=body['code_verifier'][0];expected=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    self.assertEqual(params['code_challenge'],[expected]);self.assertEqual(params['code_challenge_method'],['S256']);self.assertEqual(seen['rejected'],400);self.assertNotIn('client_secret',body);self.assertEqual(seen['output']['access_token'],'synthetic')
if __name__=='__main__':unittest.main()
