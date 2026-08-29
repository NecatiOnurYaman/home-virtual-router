#!/usr/bin/env python3
"""Small structural IPFIX receiver for the isolated R8 lab test only."""

from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import struct
import time
from pathlib import Path


IPFIX_HEADER = struct.Struct("!HHIII")
SET_HEADER = struct.Struct("!HH")
TEMPLATE_HEADER = struct.Struct("!HH")
FIELD_SPEC = struct.Struct("!HH")


class IPFIXValidationError(ValueError):
    pass


class IPFIXValidator:
    def __init__(self) -> None:
        self.templates: dict[int, list[tuple[int, int]]] = {}
        self.datagrams = 0
        self.template_sets = 0
        self.data_sets = 0
        self.records: list[dict[str, object]] = []
        self.observation_domains: set[int] = set()

    def consume(self, packet: bytes) -> None:
        if len(packet) < IPFIX_HEADER.size:
            raise IPFIXValidationError("datagram is shorter than the IPFIX header")
        version, message_length, _export_time, _sequence, domain = IPFIX_HEADER.unpack_from(packet)
        if version != 10:
            raise IPFIXValidationError(f"unexpected IPFIX version {version}")
        if message_length != len(packet):
            raise IPFIXValidationError("IPFIX message length does not match UDP datagram length")
        if self.observation_domains and domain not in self.observation_domains:
            raise IPFIXValidationError(
                f"inconsistent Observation Domain ID {domain}; "
                f"previously observed {sorted(self.observation_domains)}"
            )
        self.datagrams += 1
        self.observation_domains.add(domain)

        offset = IPFIX_HEADER.size
        while offset < message_length:
            if message_length - offset < SET_HEADER.size:
                raise IPFIXValidationError("truncated IPFIX set header")
            set_id, set_length = SET_HEADER.unpack_from(packet, offset)
            if set_length < SET_HEADER.size or offset + set_length > message_length:
                raise IPFIXValidationError("invalid IPFIX set length")
            payload = packet[offset + SET_HEADER.size : offset + set_length]
            if set_id == 2:
                self.template_sets += 1
                self._consume_templates(payload)
            elif set_id >= 256:
                self.data_sets += 1
                self._consume_data(set_id, payload)
            offset += set_length
        if offset != message_length:
            raise IPFIXValidationError("IPFIX sets do not fill declared message length")

    def _consume_templates(self, payload: bytes) -> None:
        offset = 0
        while len(payload) - offset >= TEMPLATE_HEADER.size:
            template_id, field_count = TEMPLATE_HEADER.unpack_from(payload, offset)
            if template_id < 256 or field_count == 0:
                raise IPFIXValidationError("invalid IPFIX template record")
            offset += TEMPLATE_HEADER.size
            fields: list[tuple[int, int]] = []
            for _ in range(field_count):
                if len(payload) - offset < FIELD_SPEC.size:
                    raise IPFIXValidationError("truncated IPFIX field specifier")
                element_id, field_length = FIELD_SPEC.unpack_from(payload, offset)
                offset += FIELD_SPEC.size
                enterprise = bool(element_id & 0x8000)
                element_id &= 0x7FFF
                if enterprise:
                    if len(payload) - offset < 4:
                        raise IPFIXValidationError("truncated enterprise field specifier")
                    offset += 4
                if field_length in (0, 65535):
                    raise IPFIXValidationError("R8 validator requires fixed non-zero field lengths")
                fields.append((element_id, field_length))
            self.templates[template_id] = fields
        if any(payload[offset:]):
            raise IPFIXValidationError("non-zero template-set padding")

    def _consume_data(self, template_id: int, payload: bytes) -> None:
        fields = self.templates.get(template_id)
        if fields is None:
            return
        record_length = sum(length for _element_id, length in fields)
        offset = 0
        while len(payload) - offset >= record_length:
            record_data = payload[offset : offset + record_length]
            self.records.append(self._decode_record(fields, record_data))
            offset += record_length
        if len(payload) - offset > 3 or any(payload[offset:]):
            raise IPFIXValidationError("invalid data-set record length or padding")

    @staticmethod
    def _decode_record(fields: list[tuple[int, int]], data: bytes) -> dict[str, object]:
        names = {
            1: "octetDeltaCount", 2: "packetDeltaCount", 4: "protocolIdentifier",
            6: "tcpControlBits", 7: "sourceTransportPort", 8: "sourceIPv4Address",
            11: "destinationTransportPort", 12: "destinationIPv4Address",
            152: "flowStartMilliseconds", 153: "flowEndMilliseconds",
        }
        record: dict[str, object] = {}
        offset = 0
        for element_id, length in fields:
            raw = data[offset : offset + length]
            offset += length
            name = names.get(element_id)
            if name is None:
                continue
            if element_id in (8, 12) and length == 4:
                record[name] = str(ipaddress.IPv4Address(raw))
            else:
                record[name] = int.from_bytes(raw, "big")
        return record

    def result(
        self, expected_client: str, *, expected_source: str | None = None,
        expected_destination: str | None = None, expected_protocol: int | None = None,
    ) -> dict[str, object]:
        required = {
            1, 2, 4, 6, 7, 8, 11, 12, 152, 153,
        }
        template_fields = {element for fields in self.templates.values() for element, _length in fields}
        source_addresses = sorted({
            str(record["sourceIPv4Address"]) for record in self.records if "sourceIPv4Address" in record
        })
        destination_addresses = sorted({
            str(record["destinationIPv4Address"]) for record in self.records if "destinationIPv4Address" in record
        })
        pairs = sorted({
            (str(record["sourceIPv4Address"]), str(record["destinationIPv4Address"]))
            for record in self.records
            if "sourceIPv4Address" in record and "destinationIPv4Address" in record
        })
        sample_records = self.records[:8]
        sample_pairs = sorted({
            (str(record["sourceIPv4Address"]), str(record["destinationIPv4Address"]))
            for record in sample_records
            if "sourceIPv4Address" in record and "destinationIPv4Address" in record
        })
        expected_matches = [
            record for record in self.records
            if expected_source is not None
            and record.get("sourceIPv4Address") == expected_source
            and record.get("destinationIPv4Address") == expected_destination
            and record.get("protocolIdentifier") == expected_protocol
        ]
        result: dict[str, object] = {
            "datagrams": self.datagrams,
            "version": 10,
            "template_sets": self.template_sets,
            "data_sets": self.data_sets,
            "templates": len(self.templates),
            "required_fields_present": sorted(required & template_fields),
            "required_fields_complete": required <= template_fields,
            "observation_domains": sorted(self.observation_domains),
            "records": len(self.records),
            "client_source_preserved": any(
                record.get("sourceIPv4Address") == expected_client for record in self.records
            ),
            "source_ipv4_addresses": source_addresses,
            "destination_ipv4_addresses": destination_addresses,
            "source_destination_pairs": [f"{source} -> {destination}" for source, destination in pairs],
            "sample_records_retained": len(sample_records),
            "sample_records_truncated": len(sample_records) < len(self.records),
            "sample_source_destination_pairs": [
                f"{source} -> {destination}" for source, destination in sample_pairs
            ],
            "sample_records": sample_records,
        }
        if expected_source is not None:
            result["expected_record_seen"] = bool(expected_matches)
            result["expected_record"] = expected_matches[0] if expected_matches else None
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--client", required=True)
    parser.add_argument("--traffic-start", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=12.0)
    parser.add_argument("--expect-source")
    parser.add_argument("--expect-destination")
    parser.add_argument("--expect-protocol", type=int)
    args = parser.parse_args()
    expected_values = (args.expect_source, args.expect_destination, args.expect_protocol)
    if any(value is not None for value in expected_values) and not all(value is not None for value in expected_values):
        parser.error("--expect-source, --expect-destination, and --expect-protocol must be used together")

    validator = IPFIXValidator()
    deadline = time.monotonic() + args.timeout
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
        receiver.bind((args.bind, args.port))
        receiver.settimeout(0.5)
        args.ready.touch()
        while time.monotonic() < deadline:
            try:
                packet, _peer = receiver.recvfrom(65535)
            except TimeoutError:
                continue
            validator.consume(packet)
            result = validator.result(
                args.client, expected_source=args.expect_source,
                expected_destination=args.expect_destination, expected_protocol=args.expect_protocol,
            )
            if (
                args.traffic_start.exists()
                and result["template_sets"]
                and result["data_sets"]
                and result["required_fields_complete"]
                and (
                    result.get("expected_record_seen", False)
                    if args.expect_source is not None else result["client_source_preserved"]
                )
            ):
                started_at = args.traffic_start.stat().st_mtime
                result["receive_latency_seconds"] = round(time.time() - started_at, 3)
                args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
                return 0

    result = validator.result(
        args.client, expected_source=args.expect_source,
        expected_destination=args.expect_destination, expected_protocol=args.expect_protocol,
    )
    started_at = args.traffic_start.stat().st_mtime
    result["receive_latency_seconds"] = round(time.time() - started_at, 3)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
