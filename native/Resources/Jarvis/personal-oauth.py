"""Public-client PKCE OAuth. Tokens travel only over private stdin/stdout pipes."""
import base64,hashlib,http.server,json,secrets,sys,time,urllib.parse,urllib.request,webbrowser

def main():
    data=json.loads(sys.stdin.buffer.read(16384))
    provider=data['provider']; client=data['clientID']; scopes=data['scopes']
    if provider not in ('google','slack') or not isinstance(client,str) or not client or len(client)>512:raise ValueError()
    verifier=secrets.token_urlsafe(64);state=secrets.token_urlsafe(32)
    challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    result={}
    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):
            parsed=urllib.parse.urlsplit(self.path);q=urllib.parse.parse_qs(parsed.query)
            if parsed.path!='/robin/oauth' or q.get('state')!=[state] or len(self.path)>8192:
                self.send_error(400);return
            if 'code' in q:result['code']=q['code'][0]
            else:result['error']='Authorization declined.'
            self.send_response(200);self.send_header('Content-Type','text/plain');self.end_headers();self.wfile.write(b'Robin sign-in received. You can close this tab.')
    # Slack app must register http://localhost:16687/robin/oauth and enable PKCE.
    server=http.server.HTTPServer(('127.0.0.1',16687 if provider=='slack' else 0),Callback);server.timeout=1
    redirect=('http://localhost:' if provider=='slack' else 'http://127.0.0.1:')+str(server.server_port)+'/robin/oauth'
    params=dict(client_id=client,redirect_uri=redirect,response_type='code',state=state,code_challenge=challenge,code_challenge_method='S256')
    if provider=='google':params.update(scope=' '.join(scopes),access_type='offline',prompt='consent');endpoint='https://accounts.google.com/o/oauth2/v2/auth'
    else:params.update(user_scope=','.join(scopes),scope='');endpoint='https://slack.com/oauth/v2/authorize'
    webbrowser.open(endpoint+'?'+urllib.parse.urlencode(params))
    deadline=time.monotonic()+180
    while not result and time.monotonic()<deadline:server.handle_request()
    server.server_close()
    if 'code' not in result:raise ValueError()
    body=dict(client_id=client,code=result['code'],code_verifier=verifier,redirect_uri=redirect,grant_type='authorization_code')
    if provider=='google' and data.get('clientSecret'):body['client_secret']=data['clientSecret']
    tokenURL='https://oauth2.googleapis.com/token' if provider=='google' else 'https://slack.com/api/oauth.v2.access'
    req=urllib.request.Request(tokenURL,data=urllib.parse.urlencode(body).encode(),method='POST')
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs):return None
    with urllib.request.build_opener(NoRedirect()).open(req,timeout=20) as response:token=json.load(response)
    if provider=='slack':
        if not token.get('ok'):raise ValueError()
        token=token.get('authed_user',{})
    if not token.get('access_token'):raise ValueError()
    print(json.dumps(token))
if __name__=='__main__':
    try:main()
    except Exception:print(json.dumps({'error':'Sign-in did not complete. Check your OAuth app setup, consent, and callback URL.'}));sys.exit(2)
