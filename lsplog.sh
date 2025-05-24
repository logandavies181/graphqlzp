#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

tail -n ${1:-10} ~/.local/state/nvim/lsp.log |
  awk '/stderr/ {print $2}' FS="\"stderr\"\t" |

  while IFS= read -r line; do

  line=${line:1}
  echo -ne "${line::-1}"
done
