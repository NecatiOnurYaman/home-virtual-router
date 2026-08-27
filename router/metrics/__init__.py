"""Authoritative local router metric collection for R10."""

from .collector import (
    InterfaceIdentity,
    MetricSample,
    MetricSnapshot,
    MetricType,
    collect_snapshot,
)

__all__ = [
    "InterfaceIdentity",
    "MetricSample",
    "MetricSnapshot",
    "MetricType",
    "collect_snapshot",
]
