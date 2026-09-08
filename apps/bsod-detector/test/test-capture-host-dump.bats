#!/usr/bin/env bats

load test-helper

setup() {
  SCRIPT="$REPO_ROOT/src/scripts/host/capture-host-dump.sh"
}

@test "capture-host-dump exits 2 when --vm is missing" {
  run bash "$SCRIPT" --out /tmp/test-out
  [ "$status" -eq 2 ]
  [[ "$output" == *"--vm required"* ]]
}

@test "capture-host-dump exits 2 when --out is missing" {
  run bash "$SCRIPT" --vm test-vm
  [ "$status" -eq 2 ]
  [[ "$output" == *"--out required"* ]]
}

@test "capture-host-dump does NOT check for elf2dmp" {
  ! grep -q 'Have elf2dmp' "$SCRIPT"
  ! grep -q 'elf2dmp' "$SCRIPT"
}

@test "capture-host-dump preserves raw ELF (no rm -f elfFile)" {
  ! grep -q 'rm -f.*elfFile\|rm -f.*elf' "$SCRIPT"
}

@test "capture-host-dump output references guest-memory.elf not host-crash.dmp" {
  grep -q 'guest-memory.elf' "$SCRIPT"
  ! grep -q 'host-crash.dmp' "$SCRIPT"
}
