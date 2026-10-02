import os, socket, subprocess, tempfile, threading

with tempfile.TemporaryDirectory() as d:
    path=os.path.join(d,"hook.sock")
    server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); server.bind(path); server.listen(1)
    received=[]
    def accept():
        for _ in range(2):
            conn,_=server.accept()
            with conn: received.append(conn.recv(32768))
    thread=threading.Thread(target=accept); thread.start()
    env=os.environ.copy(); env.update(MICA_HOOK_SOCK=path,MICA_TAB_TOKEN="0123456789abcdef0123456789abcdef")
    subprocess.run(["scripts/mica-hook","Stop"],input=b'{"agent":"claude"}',env=env,check=True,timeout=4)
    assert received and received[0].endswith(b'"token":"0123456789abcdef0123456789abcdef","event":"Stop","agent":"claude"}\n'),received
    subprocess.run(["scripts/mica-hook","codex-notify",'{"turn_id":"t1"}'],env=env,check=True,timeout=4)
    thread.join(4); server.close()
    assert len(received)==2 and received[1].endswith(b'"token":"0123456789abcdef0123456789abcdef","event":"agent-turn-complete","agent":"codex"}\n'),received
print("mica-hook helper sent one JSON line through nc -U")
