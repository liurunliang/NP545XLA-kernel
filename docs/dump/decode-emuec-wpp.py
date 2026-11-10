#!/usr/bin/env python3
"""Decode known NP545XLA EmuEC payloads from an offline EVENT_RECORD TSV export.

This does not read ETL files, connect to Windows, or control charging. The driver
argument verifies the analyzed disk sample, not the identity of loaded code.
Preserve the original ETL, exporter, provider snapshots and loss counters.
"""

import argparse
import base64
import collections
import csv
import datetime
import hashlib
import json
from pathlib import Path
import re
import statistics
import struct


DRIVER_SHA256 = "70de2be234da9d34125b4409f1272f8e74b2a7f1f1c651f9f09548823cb58bb9"
TEXT_GUID = "cb82acef-d6ce-3c92-28fd-52039420aa94"
CHARGER_GUID = "245af9f0-4406-34ac-f755-f0b0bd0e4b58"
POLL = re.compile(r"BatteryPolling::cmd =0x([0-9a-f]+), wData = 0x([0-9a-f]+)\[(\d+)\]")


def sha256(path):
    with path.open("rb") as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1048576), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc(filetime):
    # Preserve the original 100 ns integer as well as the displayed microseconds.
    epoch = datetime.datetime(1601, 1, 1, tzinfo=datetime.timezone.utc)
    return (epoch + datetime.timedelta(microseconds=filetime // 10)).isoformat()


def intervals(times):
    times = sorted(times)
    values = [(b - a) / 10000000 for a, b in zip(times, times[1:])]
    return {"count": len(times), "minSeconds": min(values),
            "medianSeconds": statistics.median(values), "maxSeconds": max(values)} if values else {"count": len(times)}


def decode(events, metadata):
    messages, writes, reads, polls, refresh = [], [], [], [], []
    counts = collections.Counter()
    payload_bytes = 0
    with events.open(encoding="utf-8-sig", newline="") as source:
        rows = csv.DictReader(source, delimiter="\t")
        required = {"timestamp_filetime", "provider", "id", "flags", "pid", "tid", "payload_base64", "header_size"}
        if not required.issubset(rows.fieldnames or []):
            raise ValueError("Unexpected TSV schema")
        for row in rows:
            data = base64.b64decode(row["payload_base64"], validate=True)
            guid, message_id = row["provider"].lower(), int(row["id"])
            counts[f"{guid}/{message_id}"] += 1
            payload_bytes += len(data)
            event = {"filetime": int(row["timestamp_filetime"]), "pid": int(row["pid"]), "tid": int(row["tid"])}
            event["timeUtc"] = utc(event["filetime"])
            known = (guid == TEXT_GUID and message_id == 15) or (guid == CHARGER_GUID and message_id in (11, 12))
            if known and not int(row["flags"]) & 0x8:
                raise ValueError("Known GUID/ID without TRACE_MESSAGE header flag")
            if guid == TEXT_GUID and message_id == 15:
                if not data.startswith(b"EmuEC\0") or not data.endswith(b"\0") or b"\0" in data[6:-1]:
                    raise ValueError("Unexpected formatted-message payload")
                message = data[6:-1].decode("ascii")
                messages.append(dict(event, message=message))
                if message.startswith("RefreshCharger::mainBattChg="):
                    refresh.append(event["filetime"])
                match = POLL.search(message)
                if match:
                    command, value = int(match[1], 16), int(match[2], 16)
                    if value != int(match[3]):
                        raise ValueError("BatteryPolling hex/decimal mismatch")
                    polls.append(dict(event, command=command, rawValue=value))
            elif guid == CHARGER_GUID and message_id == 12:
                if len(data) != 16:
                    raise ValueError("Unexpected charger-write payload length")
                register, value, status, length = struct.unpack("<4I", data)
                writes.append(dict(event, register=register, requestedRawValue=value,
                                   returnedStatus=status, requestedDataLength=length))
            elif guid == CHARGER_GUID and message_id == 11:
                if len(data) != 12:
                    raise ValueError("Unexpected charger-read payload length")
                register, value, repeated = struct.unpack("<3I", data)
                # The last word repeats the value; it is NOT an NTSTATUS.
                reads.append(dict(event, register=register, rawValue=value, repeatedValue=repeated))
    if sum(counts.values()) != metadata["Events"] or payload_bytes != metadata["PayloadBytes"]:
        raise ValueError("TSV counts do not match native exporter metadata")
    summary = {
        "events": sum(counts.values()), "payloadBytes": payload_bytes,
        "eventCounts": dict(sorted(counts.items())), "formattedMessages": len(messages),
        "refreshIntervals": intervals(refresh), "batteryPollIntervals": intervals([x["filetime"] for x in polls]),
        "pollIntervalsByCommand": {hex(c): intervals([x["filetime"] for x in polls if x["command"] == c])
                                   for c in sorted({x["command"] for x in polls})},
        "writeIntervalsByRegister": {hex(r): intervals([x["filetime"] for x in writes if x["register"] == r])
                                     for r in sorted({x["register"] for x in writes})},
        "writeEvents": len(writes), "writeStatusCounts": dict(collections.Counter(hex(x["returnedStatus"]) for x in writes)),
        "chargerReadEvents": len(reads), "successfulBatteryPollMessages": len(polls),
        "nativeExport": metadata,
        "limits": "Known message schemas only. Unknown payloads remain in the input TSV. Driver-return evidence, not bus capture or register readback. GetBattData is excluded from fresh battery reads. No sleep-state inference."
    }
    return summary, {"messages": messages, "charger-writes": writes, "charger-reads": reads, "battery-polls": polls}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("events", type=Path)
    parser.add_argument("metadata", type=Path, help="Native export result JSON")
    parser.add_argument("--driver", required=True, type=Path, help="Exact analyzed EmuEC.sys sample")
    parser.add_argument("--output", required=True, type=Path, help="New output directory")
    args = parser.parse_args()
    if sha256(args.driver) != DRIVER_SHA256:
        parser.error("Driver hash differs; reanalyze message schemas before decoding")
    metadata = json.loads(args.metadata.read_text(encoding="utf-8-sig"))
    if metadata["ProcessStatus"] or metadata["CloseStatus"] or metadata["Error"]:
        parser.error("Native export failed; do not analyze it as a complete capture")
    summary, decoded = decode(args.events, metadata)
    summary["inputs"] = {"driverSHA256": DRIVER_SHA256, "eventsSHA256": sha256(args.events),
                         "metadataSHA256": sha256(args.metadata)}
    # Keep nonzero loss counts visible; absence of a decoded event proves nothing.
    summary["reportedLoss"] = {key: metadata[key] for key in ("HeaderEventsLost", "HeaderBuffersLost", "EventsLost")}
    args.output.mkdir(parents=True, exist_ok=False)
    for name, values in decoded.items():
        (args.output / (name + ".jsonl")).write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in values), encoding="utf-8")
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
