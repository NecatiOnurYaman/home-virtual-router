#!/usr/bin/env bash
set -euo pipefail

bash -n router/scripts/*.sh lab/scripts/*.sh tests/*.sh
