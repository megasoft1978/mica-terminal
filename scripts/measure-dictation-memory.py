#!/usr/bin/env python3
"""Measure baseline dictation memory, latency, and project-term accuracy.

Requires a built app helper, macOS `say`, and Apple's `footprint` utility. This
offline measurement speaks six fixed sentences locally and streams them to the
helper, then scores raw and deterministically corrected transcripts.
"""
import argparse
import json
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "build/Mica.app/Contents/Helpers/mica-voice"
TERMS = ["MicaTerminal", "libvterm", "worktree", "FluidAudio", "OSC 133", "SwiftPM"]
SENTENCES = [
    "Open MicaTerminal and inspect its terminal settings.",
    "The libvterm parser handles escape sequences in this project.",
    "Create a worktree before testing the new branch.",
    "FluidAudio runs local speech recognition on this Mac.",
    "The shell prompt reports OSC 133 integration status.",
    "SwiftPM resolves the voice helper package dependencies.",
]


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/dictation-measurements.md")
    parser.add_argument("--helper", type=Path, default=HELPER)
    args = parser.parse_args()
    if not args.helper.is_file():
        parser.error(f"voice helper not found: {args.helper}; build the app first")
    return args


def wav_samples(text):
    with tempfile.TemporaryDirectory(prefix="mica-speech-") as temp:
        wav = Path(temp) / "speech.wav"
        subprocess.run(["say", "-r", "165", "-o", str(wav), "--data-format=LEF32@16000", text], check=True)
        raw = wav.read_bytes()
    marker = raw.find(b"data")
    if marker < 0 or marker + 8 > len(raw):
        raise RuntimeError("say produced an invalid WAV file")
    size = struct.unpack_from("<I", raw, marker + 4)[0]
    return raw[marker + 8:marker + 8 + size]


def footprint(pid):
    result = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True)
    match = re.search(r"phys_footprint:\s*([\d.]+)\s*(KB|MB|GB)", result.stdout)
    if not match:
        return None
    amount, unit = float(match.group(1)), match.group(2)
    return amount / 1024 if unit == "KB" else amount * 1024 if unit == "GB" else amount


def correct_for_scoring(transcript):
    """Conservatively model exact whole-token corrections for this report."""
    output = transcript
    for term in sorted(TERMS, key=len, reverse=True):
        pattern = re.compile(r"(?<!\w)" + r"[\s_-]*".join(map(re.escape, term)) + r"(?!\w)", re.I)
        output = pattern.sub(term, output)
    return output


def contains_term(transcript, term):
    key = re.sub(r"[^a-z0-9]", "", term.lower())
    folded = re.sub(r"[^a-z0-9]", "", transcript.lower())
    return bool(key) and key in folded


def run_one(helper, sentence):
    audio = wav_samples(sentence)
    process = subprocess.Popen([str(helper), "stream"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    messages, lock = [], threading.Lock()
    done, finish_sent = threading.Event(), threading.Event()
    samples = {"peak": 0.0, "after": None}

    def reader():
        for line in process.stdout:
            try:
                with lock:
                    messages.append(json.loads(line))
            except (ValueError, TypeError):
                continue

    def sample():
        while not done.is_set():
            value = footprint(process.pid)
            if value:
                samples["peak"] = max(samples["peak"], value)
                if finish_sent.is_set():
                    samples["after"] = value
            done.wait(0.5)

    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=sample, daemon=True).start()
    started = time.monotonic()
    while time.monotonic() - started < 300:
        with lock:
            ready = any(item.get("type") == "ready" for item in messages)
            error = next((item.get("message") for item in messages if item.get("type") == "error"), None)
        if error:
            process.kill()
            raise RuntimeError(error)
        if ready:
            break
        if process.poll() is not None:
            raise RuntimeError("voice helper exited before listening")
        time.sleep(0.5)
    else:
        process.kill()
        raise TimeoutError("voice helper did not become ready within 300 seconds")

    chunk_bytes = 1600 * 4
    stream = audio + b"\0" * (4 * 16000 * 3)
    speech_end = None
    for offset in range(0, len(stream), chunk_bytes):
        chunk = stream[offset:offset + chunk_bytes]
        process.stdin.write(struct.pack("<I", len(chunk) // 4) + chunk)
        process.stdin.flush()
        if offset + len(chunk) >= len(audio) and speech_end is None:
            speech_end = time.monotonic()
        time.sleep(0.1)
    process.stdin.write(struct.pack("<I", 0))
    process.stdin.flush()
    finish_sent.set()
    deadline = time.monotonic() + 90
    final = None
    while time.monotonic() < deadline:
        with lock:
            final = next((item.get("text") for item in reversed(messages) if item.get("type") == "result"), None)
            error = next((item.get("message") for item in messages if item.get("type") == "error"), None)
        if error:
            process.kill()
            raise RuntimeError(error)
        if final is not None or process.poll() is not None:
            break
        time.sleep(0.1)
    latency = time.monotonic() - speech_end if final is not None else None
    if process.poll() is None:
        process.wait(timeout=10)
    done.set()
    if final is None:
        raise RuntimeError("voice helper exited without a final transcript")
    return {"transcript": final, "peak": samples["peak"], "after": samples["after"], "latency": latency}


def main():
    args = parse_args()
    results = []
    for sentence in SENTENCES:
        result = run_one(args.helper, sentence)
        results.append(result)
        print(result["transcript"], flush=True)
    raw_hits = sum(contains_term(row["transcript"], term) for row, term in zip(results, TERMS))
    corrected_hits = sum(contains_term(correct_for_scoring(row["transcript"]), term)
                         for row, term in zip(results, TERMS))
    latency = [row["latency"] for row in results if row["latency"] is not None]
    lines = ["# Dictation measurements", "", f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}",
             "", "Six locally spoken project-term sentences. Footprint is helper phys_footprint; latency is measured from sending the end-of-audio marker to the final result.",
             "Corrector scoring is a conservative exact whole-token pass and does not reproduce fuzzy production correction.", "",
             "| Peak footprint (MB) | After listening (MB) | End marker → final (s, mean) | Raw hits | Corrector hits |",
             "|---:|---:|---:|---:|---:|",
             f"| {max((row['peak'] for row in results), default=0):.1f} | {next((row['after'] for row in reversed(results) if row['after'] is not None), 0):.1f} | {sum(latency) / max(1, len(latency)):.2f} | {raw_hits}/6 | {corrected_hits}/6 |",
             "", "## Transcripts", ""]
    for sentence, row in zip(SENTENCES, results):
        lines.append(f"- Expected: {sentence}  \n  Heard: {row['transcript'] or '(no final transcript)'}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError, TimeoutError) as error:
        print(f"measurement failed: {error}", file=sys.stderr)
        sys.exit(1)
