#!/usr/bin/env python3
"""Measure dictation memory, latency, download size, and project-term accuracy.

Requires a built app helper, macOS `say`, and Apple's `footprint` utility. This is
an offline measurement: six fixed sentences are spoken locally and streamed to
the helper. Runs baseline, boosting, and (when supplied) vocabulary modes.
"""
import argparse
import base64
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
    parser.add_argument("--boost", action="store_true", help="also measure native vocabulary boosting")
    parser.add_argument("--vocabulary", type=Path, help="measure this vocabulary file (also enables boost)")
    parser.add_argument("--output", type=Path, default=ROOT / "build/boost-measurements.md")
    parser.add_argument("--helper", type=Path, default=HELPER)
    args = parser.parse_args()
    if not args.helper.is_file():
        parser.error(f"voice helper not found: {args.helper}; build the app first")
    if args.vocabulary and not args.vocabulary.is_file():
        parser.error(f"vocabulary file not found: {args.vocabulary}")
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


def directory_bytes(path):
    if not path.exists():
        return 0
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def model_cache():
    # FluidAudio 0.17.4 CtcModels.defaultCacheDirectory(.ctc110m).
    return (Path.home() / "Library/Application Support/FluidAudio/Models/"
            "parakeet-ctc-110m-coreml")


def correct_for_scoring(transcript, vocabulary_terms):
    """Score the shipped corrector's exact/near term effects conservatively.

    The production corrector is exercised separately in app tests. Here this
    applies only an unambiguous normalized whole-token or joined-token match;
    fuzzy corrections are deliberately not guessed by the measurement tool.
    """
    output = transcript
    for term in sorted(vocabulary_terms, key=len, reverse=True):
        aliases = []
        canonical = term
        if "=>" in term:
            alias, canonical = [part.strip() for part in term.split("=>", 1)]
            aliases.append(alias)
        aliases.append(canonical)
        for alias in aliases:
            if not alias:
                continue
            pattern = re.compile(r"(?<!\w)" + r"[\s_-]*".join(map(re.escape, alias)) + r"(?!\w)", re.I)
            output = pattern.sub(canonical, output)
    return output


def contains_term(transcript, term):
    key = re.sub(r"[^a-z0-9]", "", term.lower())
    folded = re.sub(r"[^a-z0-9]", "", transcript.lower())
    return bool(key) and key in folded


def vocabulary_payload(path):
    entries = []
    if path:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=>" in line:
                alias, canonical = (part.strip() for part in line.split("=>", 1))
                entries.append({"text": canonical, "aliases": [alias]})
            else:
                entries.append({"text": line})
    else:
        entries = [{"text": term} for term in TERMS]
    return entries


def run_one(helper, sentence, boost_terms, boost):
    audio = wav_samples(sentence)
    args = [str(helper), "stream"]
    if boost:
        encoded = base64.b64encode(json.dumps(boost_terms).encode()).decode()
        args.extend(["--vocabulary", encoded])
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    messages = []
    lock = threading.Lock()
    stats_lock = threading.Lock()
    sampling_done = threading.Event()
    finish_sent = threading.Event()
    samples = {"peak": 0.0, "latest": None, "after": None}

    def reader():
        for line in process.stdout:
            try:
                with lock:
                    messages.append(json.loads(line))
            except (ValueError, TypeError):
                continue

    threading.Thread(target=reader, daemon=True).start()

    def sample_footprint():
        while not sampling_done.is_set():
            value = footprint(process.pid)
            if value:
                with stats_lock:
                    samples["peak"] = max(samples["peak"], value)
                    samples["latest"] = value
                    if finish_sent.is_set():
                        samples["after"] = value
            sampling_done.wait(0.5)

    threading.Thread(target=sample_footprint, daemon=True).start()
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

    chunk_frames = 1600
    stream = audio + b"\0" * (4 * 16000 * 3)
    speech_end = None
    for offset in range(0, len(stream), chunk_frames * 4):
        chunk = stream[offset:offset + chunk_frames * 4]
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
    after_listening = None
    while time.monotonic() < deadline:
        with lock:
            final = next((item.get("text") for item in reversed(messages) if item.get("type") == "result"), None)
            error = next((item.get("message") for item in messages if item.get("type") == "error"), None)
        if error:
            process.kill()
            raise RuntimeError(error)
        if final is not None:
            break
        if process.poll() is not None:
            break
        time.sleep(0.1)
    latency = time.monotonic() - speech_end if final is not None else None
    if process.poll() is None:
        process.wait(timeout=10)
    sampling_done.set()
    with stats_lock:
        peak = samples["peak"]
        after_listening = samples["after"]
    if final is None:
        raise RuntimeError("voice helper exited without a final transcript")
    with lock:
        statuses = [item.get("message", "") for item in messages if item.get("type") == "status"]
    return {"transcript": final or "", "peak_mb": peak, "after_mb": after_listening,
            "latency_s": latency, "boost_status": " ".join(statuses)}


def main():
    args = parse_args()
    modes = [("baseline", False, None)]
    terms = vocabulary_payload(args.vocabulary)
    benchmark_terms = vocabulary_payload(None)
    if args.boost or args.vocabulary:
        modes.append(("boost", True, benchmark_terms))
    if args.vocabulary:
        modes.append((f"vocabulary ({args.vocabulary.name})", True, terms))
    cache = model_cache()
    rows = []
    results_by_mode = {}
    try:
        for mode, boost, supplied_terms in modes:
            mode_cache_before = directory_bytes(cache)
            mode_results = []
            for sentence in SENTENCES:
                result = run_one(args.helper, sentence, supplied_terms or terms, boost)
                mode_results.append(result)
                print(f"{mode}: {result['transcript']}", flush=True)
            score_terms = [(entry["aliases"][0] + " => " + entry["text"] if entry.get("aliases") else entry["text"])
                           for entry in (terms if mode.startswith("vocabulary (") else benchmark_terms)]
            correction_terms = score_terms
            raw_hits = sum(contains_term(item["transcript"], term) for item, term in zip(mode_results, TERMS))
            corrector_hits = sum(contains_term(correct_for_scoring(item["transcript"], correction_terms), term)
                                 for item, term in zip(mode_results, TERMS))
            boost_hits = raw_hits if boost else None
            rows.append({
                "mode": mode,
                "peak": max((item["peak_mb"] for item in mode_results), default=0),
                "after": next((item["after_mb"] for item in reversed(mode_results) if item["after_mb"] is not None), None),
                "latency": sum(item["latency_s"] for item in mode_results if item["latency_s"] is not None) / max(1, sum(item["latency_s"] is not None for item in mode_results)),
                "raw": f"{raw_hits}/{len(SENTENCES)}",
                "corrector": f"{corrector_hits}/{len(SENTENCES)}",
                "boost_hits": f"{boost_hits}/{len(SENTENCES)}" if boost_hits is not None else "—",
                "extra_mb": max(0, directory_bytes(cache) - mode_cache_before) / (1024 * 1024) if boost else None,
            })
            results_by_mode[mode] = mode_results
    finally:
        pass
    args.output.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# Dictation boost measurements", "", f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}",
             "", "Six locally spoken project-term sentences per mode. Footprint values are helper phys_footprint; latency is mean time from sending the end-of-audio marker to the final result.",
             "The after-listening footprint is the last sample after the end marker and before helper exit. Extra model download is measured as cache growth during each mode; it may be zero when the model was already cached.",
             "Corrector hit rate is a conservative normalized whole-term scoring pass in this measurement script; fuzzy production correction is not reproduced here. Each accuracy trial scores the one target term spoken in that sentence.", "",
             "| Mode | Peak footprint (MB) | After listening (MB) | End speech → final (s, mean) | Extra model download (MB) | Raw hits | Corrector hits | Boost hits |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        after = "n/a" if row["after"] is None else f"{row['after']:.1f}"
        extra = "—" if row["extra_mb"] is None else f"{row['extra_mb']:.1f}"
        lines.append(f"| {row['mode']} | {row['peak']:.1f} | {after} | {row['latency']:.2f} | {extra} | {row['raw']} | {row['corrector']} | {row['boost_hits']} |")
    lines.extend(["", "## Transcripts", ""])
    baseline = results_by_mode["baseline"]
    corrector_terms = [(entry["aliases"][0] + " => " + entry["text"] if entry.get("aliases") else entry["text"])
                       for entry in terms]
    corrector_transcripts = [correct_for_scoring(item["transcript"], corrector_terms) for item in baseline]
    boosted_mode = next((mode for mode, boost, _ in modes if boost), None)
    boost_results = results_by_mode.get(boosted_mode, []) if boosted_mode else []
    lines.extend(["## Per-term accuracy", "", "| Spoken term | Raw | Corrector | Boost |", "|---|---:|---:|---:|"])
    for index, term in enumerate(TERMS):
        raw_hit = contains_term(baseline[index]["transcript"], term)
        corrected_hit = contains_term(corrector_transcripts[index], term)
        boosted_hit = contains_term(boost_results[index]["transcript"], term) if boost_results else None
        lines.append(f"| {term} | {'1/1' if raw_hit else '0/1'} | {'1/1' if corrected_hit else '0/1'} | {'—' if boosted_hit is None else ('1/1' if boosted_hit else '0/1')} |")
    lines.extend([""])
    # Store all generated transcripts in a separate compact section for auditing.
    for row, (mode, boost, supplied_terms) in zip(rows, modes):
        lines.append(f"### {mode}")
        lines.append("")
        for sentence, result in zip(SENTENCES, results_by_mode[mode]):
            lines.append(f"- Expected: {sentence}  \n  Heard: {result['transcript'] or '(no final transcript)'}")
        lines.append("")
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError, TimeoutError) as error:
        print(f"measurement failed: {error}", file=sys.stderr)
        sys.exit(1)
