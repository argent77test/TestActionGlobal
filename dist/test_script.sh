#!/bin/bash

test_params1() {
  while [ $# -gt 0 ]; do
    echo "Parameter: $1"
    shift
  done
}

test_params1 $@
