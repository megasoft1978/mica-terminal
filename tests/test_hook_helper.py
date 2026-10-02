import os, socket, subprocess, tempfile, threading

with tempfile.TemporaryDirectory() as d:
    path=os.path.join(d,"hook.sock")
    server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); server.bind(path); server.listen(1)
    received=[]
    def accept():
        conn,_=server.accept()
        with conn: received.append(conn.recv(32768))
    thread=threading.Thread(target=accept); thread.start()
    env=os.environ.copy(); env.update(MICA_HOOK_SOCK=path,MICA_TAB_TOKEN="0123456789abcdef0123456789abcdef")
    subprocess.run(["scripts/mica-hook","Stop"],input=b'{"agent":"claude"}',env=env,check=True,timeout=4)
    thread.join(4); server.close()
    assert received and received[0].endswith(b'"token":"0123456789abcdef0123456789abcdef","event":"Stop"}\n'),received
print("mica-hook helper sent one JSON line through nc -U")
