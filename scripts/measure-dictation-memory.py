#!/usr/bin/env python3
"""Measures the speech helper's memory during a real recognition, without a microphone.

Speaks a sentence with macOS `say` into a 16 kHz float WAV, starts build/Mica.app's helper exactly as the app does,
streams the audio in real time (0.1 s chunks) followed by 3 s of silence, and samples Apple's phys_footprint
(what Activity Monitor calls Memory) while it loads, listens and finishes. Prints the transcript so recognition
quality can be judged too. Run `make app` first.
"""
import subprocess, struct, time, os, json, threading, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
say_text = "Hello Mica. Please list the files in this folder, then show me the last three git commits, and open the readme file."
subprocess.run(['say','-r','165','-o','/tmp/mica-speech.wav','--data-format=LEF32@16000',say_text],check=True)
# say writes a WAV with float32 samples; read the data chunk manually
raw=open('/tmp/mica-speech.wav','rb').read()
idx=raw.find(b'data'); size=struct.unpack('<I',raw[idx+4:idx+8])[0]
samples=raw[idx+8:idx+8+size]
n=len(samples)//4
print('speech seconds:', n/16000)
helper=str(ROOT / 'build/Mica.app/Contents/Helpers/mica-voice')
p=subprocess.Popen([helper,'stream'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
def fp(pid):
    out=subprocess.run(['footprint','-p',str(pid)],capture_output=True,text=True).stdout
    for l in out.splitlines():
        if 'phys_footprint:' in l:
            v,u=l.split()[1:3]; v=float(v); return v/1024 if u=='KB' else v*1024 if u=='GB' else v
    return None
lines=[]
def reader():
    for l in p.stdout:
        try: lines.append(json.loads(l))
        except Exception: pass
threading.Thread(target=reader,daemon=True).start()
t0=time.time(); samples_log=[]; peak=0
# wait for ready
while time.time()-t0<90 and not any(m.get('type')=='ready' for m in lines):
    f=fp(p.pid); 
    if f: peak=max(peak,f); samples_log.append((round(time.time()-t0,1),'loading',round(f,1)))
    time.sleep(0.5)
print('ready after %.1fs'%(time.time()-t0))
# stream in real time, 0.1s chunks, plus 3s trailing silence
chunk=1600
tstream=time.time()
data=samples+b'\x00'*(4*16000*3)
total=len(data)//4
for off in range(0,total,chunk):
    c=data[off*4:(off+chunk)*4]
    p.stdin.write(struct.pack('<I',len(c)//4)+c); p.stdin.flush()
    if (off//chunk)%5==0:
        f=fp(p.pid)
        if f: peak=max(peak,f); samples_log.append((round(time.time()-t0,1),'streaming',round(f,1)))
    time.sleep(0.1)
p.stdin.write(struct.pack('<I',0)); p.stdin.flush()
time.sleep(4)
f=fp(p.pid)
if f: samples_log.append((round(time.time()-t0,1),'finishing',round(f,1))); peak=max(peak,f)
result=[m for m in lines if m.get('type')=='result']
print('transcript:', result[-1].get('text') if result else '(none)')
loading=[s[2] for s in samples_log if s[1]=='loading']
stream=[s[2] for s in samples_log if s[1]=='streaming']
print('helper footprint MB: while loading max=%.0f, while listening/recognizing min=%.0f max=%.0f, peak overall=%.0f'%(max(loading or [0]),min(stream or [0]),max(stream or [0]),peak))
try: p.wait(timeout=6)
except Exception: p.kill()
