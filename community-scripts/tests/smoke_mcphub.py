import base64,json,os,secrets,socket,subprocess,tempfile,time,urllib.request,urllib.error
from pathlib import Path
package=Path(os.environ['MCPHUB_PACKAGE_DIR']).resolve()
with tempfile.TemporaryDirectory(prefix='mcphub-smoke-') as d:
 root=Path(d);(root/'home').mkdir();(root/'data').mkdir()
 fixture=root/'fixture.cjs'
 fixture.write_text("""const readline = require('node:readline');
readline.createInterface({input:process.stdin}).on('line', line => {
 const m=JSON.parse(line); if(m.id===undefined) return;
 let result={};
 if(m.method==='initialize') result={protocolVersion:'2025-03-26',capabilities:{tools:{}},serverInfo:{name:'fixture',version:'1'}};
 if(m.method==='tools/list') result={tools:[{name:'echo',description:'Smoke test',inputSchema:{type:'object',properties:{}}}]};
 if(m.method==='tools/call') result={content:[{type:'text',text:'mcp-smoke-ok'}]};
 console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result}));
});""")
 config=root/'data/mcp_settings.json';config.write_text(json.dumps({'mcpServers':{'fixture':{'command':'node','args':[str(fixture)]}},'systemConfig':{'routing':{'enableBearerAuth':True}}}))
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 password=secrets.token_hex(20)
 env=dict(os.environ,PORT=str(port),NODE_ENV='production',HOME=str(root/'home'),MCPHUB_SETTING_PATH=str(config),ADMIN_PASSWORD=password,JWT_SECRET=secrets.token_hex(32),MCPHUB_CREDENTIAL_ENCRYPTION_KEY=base64.b64encode(secrets.token_bytes(32)).decode())
 with (root/'server.log').open('w') as log:
  proc=subprocess.Popen(['node',str(package/'dist/index.js')],cwd=package,env=env,stdout=log,stderr=log,start_new_session=True)
  try:
   session_state={}
   def request(path,data=None,token=None):
    b=None if data is None else json.dumps(data).encode()
    req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=b,headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
    if token:
     if path.startswith('/api/'):req.add_header('x-auth-token',token)
     else:req.add_header('Authorization','Bearer '+token)
    if path=='/mcp':
     req.add_header('MCP-Protocol-Version','2025-03-26')
     if session_state.get('id'):req.add_header('Mcp-Session-Id',session_state['id'])
    try:
     with urllib.request.urlopen(req,timeout=5) as r:
      if r.headers.get('Mcp-Session-Id'):session_state['id']=r.headers['Mcp-Session-Id']
      return r.status,r.read()
    except urllib.error.HTTPError as e:return e.code,e.read()
   for attempt in range(60):
    if proc.poll() is not None:raise RuntimeError('server exited '+str(proc.returncode))
    try:
     status,body=request('/health')
     if status==200:break
    except OSError:pass
    time.sleep(.5)
   else:raise RuntimeError('health timed out')
   assert json.loads(body)['status'] in ['healthy','degraded']
   assert request('/')[0]==200,'dashboard'
   status,_=request('/mcp',{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'smoke','version':'1'}}})
   assert status==401,('MCP auth',status)
   status,body=request('/api/auth/login',{'username':'admin','password':password})
   assert status==200,('login',status)
   admin_token=json.loads(body)['token']
   status,body=request('/api/auth/keys',{'name':'smoke','enabled':True,'accessType':'all'},admin_token)
   assert status==201,('key creation',status)
   tool_token=json.loads(body)['data']['token']
   def rpc(method,params=None):
    status,body=request('/mcp',{'jsonrpc':'2.0','id':1,'method':method,'params':params or {}},tool_token)
    assert status==200,(method,status)
    text=body.decode()
    if text.startswith('event:') or text.startswith('data:'):
     text=next(line[5:].strip() for line in text.splitlines() if line.startswith('data:'))
    result=json.loads(text)
    assert 'error' not in result,(method,result.get('error',{}).get('code'))
    return result['result']
   rpc('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'smoke','version':'1'}})
   tools=rpc('tools/list')['tools'];tool=next(t['name'] for t in tools if 'echo' in t['name'])
   result=rpc('tools/call',{'name':tool,'arguments':{}})
   assert any(c.get('text')=='mcp-smoke-ok' for c in result['content']), 'forwarded tool response'
   saved=json.loads(config.read_text());assert saved.get('users'),'persistent admin'
   print('PASS: published npm 1.2.4 starts; /health and dashboard return 200; unauthenticated MCP returns 401; generated admin login returns 200; user persists in configured data path; authenticated MCP discovery and stdio tool forwarding succeed')
  except Exception:
   # Logs are not printed: initialization can contain sensitive material.
   print('Smoke failed. Log retained separately for local redacted inspection.')
   import shutil;shutil.copyfile(root/'server.log','/tmp/mcphub-smoke-failure.log');os.chmod('/tmp/mcphub-smoke-failure.log',0o600)
   raise
  finally:
   import signal
   os.killpg(proc.pid,signal.SIGTERM)
   try:proc.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
