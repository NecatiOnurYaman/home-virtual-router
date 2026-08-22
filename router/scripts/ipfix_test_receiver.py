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
    def __init__(self, expected_observation_domain: int = 0) -> None:
        self.expected_observation_domain = expected_observation_domain
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
        if domain != self.expected_observation_domain:
            raise IPFIXValidationError(f"unexpected Observation Domain ID {domain}")
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

    def result(self, expected_client: str) -> dict[str, object]:
        required = {
            1, 2, 4, 6, 7, 8, 11, 12, 152, 153,
        }
        template_fields = {element for fields in self.templates.values() for element, _length in fields}
        return {
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
            "sample_records": self.records[:8],
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--client", required=True)
    parser.add_argument("--observation-domain", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=12.0)
    args = parser.parse_args()

    validator = IPFIXValidator(args.observation_domain)
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
            result = validator.result(args.client)
            if (
                result["template_sets"]
                and result["data_sets"]
                and result["required_fields_complete"]
                and result["client_source_preserved"]
            ):
                args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
                return 0

    args.output.write_text(json.dumps(validator.result(args.client), indent=2) + "\n", encoding="utf-8")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
